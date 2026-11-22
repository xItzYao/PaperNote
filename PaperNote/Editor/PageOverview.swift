import UIKit

/// 全部頁面：縮圖一覽。點一下跳到那頁；長按拖曳調整順序、長按放開加入大綱；右上角的星號加入我的最愛；選取後可以複製、刪除。
/// 「大綱」：自己加的大綱和 PDF 的大綱（書籤），點一下跳到那頁
final class PageOverviewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
                                    UITableViewDataSource, UITableViewDelegate {
    private weak var editor: NotebookViewController?
    private var collection: UICollectionView!
    private let layout = UICollectionViewFlowLayout()
    let filter = UISegmentedControl(items: [L("全部頁面"), L("我的最愛"), L("大綱")])
    static let outlineSegment = 2
    let outlineTable = UITableView(frame: .zero, style: .insetGrouped)
    /// PDF 的大綱（第一次打開「大綱」時才讀）
    private(set) var outline: [PDFOutlineEntry]?
    /// 自己加的大綱（照頁面順序）
    private(set) var bookmarks: [(bookmark: OutlineBookmark, pageIndex: Int)] = []
    /// 大綱的兩段：自己加的、PDF 的
    static let bookmarkSection = 0, pdfSection = 1
    /// 長按：按下去的位置、那一格、有沒有開始拖曳排序
    private var press: (start: CGPoint, item: IndexPath, moving: Bool)?
    private var selecting = false
    private var selectedIDs = Set<UUID>()
    private let currentID: UUID?
    private let thumbs = NSCache<NSUUID, UIImage>()
    /// 等著畫的縮圖（後加的先畫：捲到哪裡就先畫哪裡）
    private var waiting: [UUID] = []
    private var drawingThumb = false
    private let thumbQueue = DispatchQueue(label: "PaperNote.overview.thumbs", qos: .userInitiated)
    private var didScrollToCurrent = false

    /// 目前顯示的頁面與原本的頁碼（0 起算）
    private var items: [(index: Int, page: Page)] = []

    init(editor: NotebookViewController) {
        self.editor = editor
        let pages = editor.pages
        currentID = pages.indices.contains(editor.currentPageIndex) ? pages[editor.currentPageIndex].id : nil
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 22
        layout.sectionInset = UIEdgeInsets(top: 20, left: 24, bottom: 32, right: 24)
        collection = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.register(PageThumbCell.self, forCellWithReuseIdentifier: "cell")
        view.addSubview(collection)

        outlineTable.frame = view.bounds
        outlineTable.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        outlineTable.dataSource = self
        outlineTable.delegate = self
        outlineTable.register(PDFOutlineCell.self, forCellReuseIdentifier: "outline")
        outlineTable.isHidden = true
        view.addSubview(outlineTable)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleReorder(_:)))
        press.minimumPressDuration = 0.3
        collection.addGestureRecognizer(press)

        filter.selectedSegmentIndex = 0
        filter.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
        navigationItem.titleView = filter
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: L("關閉"), primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        updateBars()
        reload()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let inset = layout.sectionInset.left + layout.sectionInset.right
        let width = collection.bounds.width - inset
        let cols = max(3, Int((width + layout.minimumInteritemSpacing) / (170 + layout.minimumInteritemSpacing)))
        let w = floor((width - CGFloat(cols - 1) * layout.minimumInteritemSpacing) / CGFloat(cols))
        let size = CGSize(width: w, height: (w * 1.3).rounded() + 26)
        if layout.itemSize != size {
            layout.itemSize = size
            thumbs.removeAllObjects()
            layout.invalidateLayout()
        }
        if !didScrollToCurrent, let id = currentID, let row = items.firstIndex(where: { $0.page.id == id }) {
            didScrollToCurrent = true
            collection.layoutIfNeeded()
            collection.scrollToItem(at: IndexPath(item: row, section: 0), at: .centeredVertically, animated: false)
        }
    }

    var showingOutline: Bool { filter.selectedSegmentIndex == Self.outlineSegment }

    private func reload() {
        let pages = editor?.pages ?? []
        collection.isHidden = showingOutline
        outlineTable.isHidden = !showingOutline
        if showingOutline {
            if selecting {
                selecting = false
                selectedIDs.removeAll()
            }
            if outline == nil, let editor {
                outline = PDFOutlineList.entries(pages: pages) { editor.session.pdfDocument($0) }
            }
            bookmarks = editor?.outlineBookmarks ?? []
            outlineTable.reloadData()
            let empty = (outline?.isEmpty ?? true) && bookmarks.isEmpty
            outlineTable.backgroundView = empty ? emptyLabel(L("還沒有大綱。長按「全部頁面」裡的頁面，或在頁碼的選單選「將該頁加入大綱」。")) : nil
            updateBars()
            return
        }
        let favOnly = filter.selectedSegmentIndex == 1
        items = pages.enumerated().filter { !favOnly || $0.element.favorite }.map { (index: $0.offset, page: $0.element) }
        selectedIDs.formIntersection(items.map(\.page.id))
        collection.reloadData()
        updateBars()
        collection.backgroundView = items.isEmpty ? emptyLabel(favOnly ? L("還沒有我的最愛頁面") : L("沒有頁面")) : nil
    }

    private func emptyLabel(_ text: String) -> UIView {
        let l = UILabel()
        l.text = text
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.numberOfLines = 0
        return l
    }

    // MARK: 工具列

    private func updateBars() {
        guard !showingOutline else {
            navigationItem.rightBarButtonItem = nil
            navigationController?.setToolbarHidden(true, animated: true)
            return
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: selecting ? L("完成") : L("選取"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.selecting.toggle()
            self.selectedIDs.removeAll()
            self.collection.reloadData()
            self.updateBars()
        })
        navigationController?.setToolbarHidden(!selecting, animated: true)
        guard selecting else { return }
        let n = selectedIDs.count
        let allSelected = !items.isEmpty && n == items.count
        let selectAll = UIBarButtonItem(title: allSelected ? L("全部取消") : L("全選"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.selectedIDs = allSelected ? [] : Set(self.items.map(\.page.id))
            self.collection.reloadData()
            self.updateBars()
        })
        let count = UIBarButtonItem(title: n == 0 ? L("選擇頁面") : L("已選 \(n) 頁"), style: .plain, target: nil, action: nil)
        count.isEnabled = false
        let duplicate = UIBarButtonItem(title: L("複製"), image: UIImage(systemName: "plus.square.on.square"), primaryAction: UIAction { [weak self] _ in
            self?.duplicateSelected()
        })
        let delete = UIBarButtonItem(title: L("刪除"), image: UIImage(systemName: "trash"), primaryAction: UIAction { [weak self] _ in
            self?.deleteSelected()
        })
        delete.tintColor = .systemRed
        duplicate.isEnabled = n > 0
        delete.isEnabled = n > 0
        let flex = UIBarButtonItem(systemItem: .flexibleSpace)
        toolbarItems = [selectAll, flex, count, flex, duplicate, delete]
    }

    private func duplicateSelected() {
        guard let editor, !selectedIDs.isEmpty else { return }
        let n = selectedIDs.count
        editor.duplicatePages(selectedIDs)
        selectedIDs.removeAll()
        reload()
        editor.showToast(L("已複製 \(n) 頁"))
    }

    private func deleteSelected() {
        guard let editor, !selectedIDs.isEmpty else { return }
        let n = selectedIDs.count
        guard n < editor.pages.count else {
            editor.showMessage(L("至少要保留一頁"))
            return
        }
        let a = UIAlertController(title: L("刪除 \(n) 頁？"), message: L("會移到「最近刪除的頁面」，30 天內可以還原。"), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        a.addAction(UIAlertAction(title: L("刪除"), style: .destructive) { [weak self] _ in
            guard let self, let editor = self.editor else { return }
            editor.trashPages(self.selectedIDs)
            self.selectedIDs.removeAll()
            self.reload()
        })
        present(a, animated: true)
    }

    // MARK: 拖曳排序（只在「全部頁面」）

    @objc private func handleReorder(_ g: UILongPressGestureRecognizer) {
        handlePress(g.state, at: g.location(in: collection))
    }

    /// 長按：拖曳調整順序（只在「全部頁面」）；沒移動就放開 → 把這頁加入大綱
    func handlePress(_ state: UIGestureRecognizer.State, at p: CGPoint) {
        guard !selecting, !showingOutline else { return }
        switch state {
        case .began:
            guard let ip = collection.indexPathForItem(at: p) else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            let reorder = filter.selectedSegmentIndex == 0
            if reorder { collection.beginInteractiveMovementForItem(at: ip) }
            press = (p, ip, reorder)
        case .changed:
            if press?.moving == true { collection.updateInteractiveMovementTargetPosition(p) }
        case .ended:
            guard let pr = press else { return }
            press = nil
            if hypot(p.x - pr.start.x, p.y - pr.start.y) < 12 {
                if pr.moving { collection.cancelInteractiveMovement() }
                addToOutline(item: pr.item.item)
            } else if pr.moving {
                collection.endInteractiveMovement()
            }
        default:
            if press?.moving == true { collection.cancelInteractiveMovement() }
            press = nil
        }
    }

    /// 第 item 格的頁面加入大綱（跳出視窗命名）
    func addToOutline(item: Int) {
        guard let editor, let page = items[safe: item]?.page, let i = editor.pageIndex(of: page.id) else { return }
        editor.promptAddToOutline(i, from: self) { [weak self] in self?.bookmarks = self?.editor?.outlineBookmarks ?? [] }
    }

    /// 縮圖右上角的星號：跳出備註然後加入我的最愛（已經是就編輯備註、移除）
    func tappedStar(item: Int, source: UIView) {
        guard let editor, let page = items[safe: item]?.page, let i = editor.pageIndex(of: page.id) else { return }
        editor.toggleFavorite(i, from: self, source: source) { [weak self] in self?.reload() }
    }

    func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool {
        filter.selectedSegmentIndex == 0
    }

    func collectionView(_ collectionView: UICollectionView, moveItemAt source: IndexPath, to destination: IndexPath) {
        guard source.item != destination.item else { return }
        editor?.movePage(from: source.item, to: destination.item)
        let pages = editor?.pages ?? []
        items = pages.enumerated().map { (index: $0.offset, page: $0.element) }
        // 頁碼都變了，重畫看得到的標籤
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for ip in self.collection.indexPathsForVisibleItems {
                (self.collection.cellForItem(at: ip) as? PageThumbCell)?.number = self.items[safe: ip.item].map { $0.index + 1 } ?? 0
            }
        }
    }

    // MARK: 資料

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath) as! PageThumbCell
        let item = items[indexPath.item]
        cell.pageID = item.page.id
        cell.number = item.index + 1
        cell.favorite = item.page.favorite
        cell.isCurrent = item.page.id == currentID
        cell.selecting = selecting
        cell.checked = selectedIDs.contains(item.page.id)
        cell.thumbnail = thumbs.object(forKey: item.page.id as NSUUID)
        cell.onStar = { [weak self, weak cell] in
            guard let self, let cell, let ip = self.collection.indexPath(for: cell) else { return }
            self.tappedStar(item: ip.item, source: cell.starButton)
        }
        return cell
    }

    // 系統會提前準備畫面外的格子，所以等格子真的要出現時才畫縮圖
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? PageThumbCell, let id = cell.pageID else { return }
        if let img = thumbs.object(forKey: id as NSUUID) {
            cell.thumbnail = img
        } else {
            requestThumbnail(id)
        }
    }

    /// 縮圖在背景執行緒一張一張畫（主執行緒只取資料，捲動不會卡）；快速捲過、已經離開畫面的就不畫
    private func requestThumbnail(_ id: UUID) {
        waiting.removeAll { $0 == id }
        waiting.append(id)
        // 等這一格真的出現在畫面上再看要不要畫（willDisplay 時還不算在畫面上）
        DispatchQueue.main.async { [weak self] in self?.drawNextThumbnail() }
    }

    private func visibleCell(_ id: UUID) -> PageThumbCell? {
        collection.visibleCells.lazy.compactMap { $0 as? PageThumbCell }.first { $0.pageID == id }
    }

    private func drawNextThumbnail() {
        guard !drawingThumb, let editor else { return }
        // 從最新的開始，跳過已經捲出畫面的
        while let id = waiting.popLast() {
            guard thumbs.object(forKey: id as NSUUID) == nil, visibleCell(id) != nil, let i = editor.pageIndex(of: id) else { continue }
            let w = layout.itemSize.width * traitCollection.displayScale
            guard let job = editor.session.thumbnailJob(pageIndex: i, width: max(120, w)) else { continue }
            drawingThumb = true
            thumbQueue.async { [weak self] in
                let img = job()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.drawingThumb = false
                    if let img {
                        self.thumbs.setObject(img, forKey: id as NSUUID)
                        self.visibleCell(id)?.thumbnail = img
                    }
                    self.drawNextThumbnail()
                }
            }
            return
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { fillVisibleThumbnails() }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { fillVisibleThumbnails() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { fillVisibleThumbnails() }

    private func fillVisibleThumbnails() {
        for ip in collection.indexPathsForVisibleItems {
            guard let cell = collection.cellForItem(at: ip) as? PageThumbCell, let id = cell.pageID else { continue }
            if cell.thumbnail == nil { requestThumbnail(id) }
        }
    }

    // MARK: 大綱

    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == Self.bookmarkSection ? bookmarks.count : (outline?.count ?? 0)
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == Self.bookmarkSection { return bookmarks.isEmpty ? nil : L("我的大綱") }
        return (outline?.isEmpty ?? true) ? nil : L("PDF 大綱")
    }

    /// 這一行：自己加的大綱也用同樣的樣子（第一層）
    func outlineEntry(at ip: IndexPath) -> PDFOutlineEntry? {
        if ip.section == Self.bookmarkSection {
            return bookmarks[safe: ip.row].map { PDFOutlineEntry(title: $0.bookmark.title, depth: 0, pageIndex: $0.pageIndex) }
        }
        return outline?[safe: ip.row]
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "outline", for: indexPath) as! PDFOutlineCell
        if let e = outlineEntry(at: indexPath) { cell.show(e) }
        return cell
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        outlineEntry(at: indexPath)?.pageIndex == nil ? nil : indexPath
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        openOutline(at: indexPath)
    }

    /// 自己加的大綱：往左滑可以重新命名、刪除
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == Self.bookmarkSection, let b = bookmarks[safe: indexPath.row]?.bookmark else { return nil }
        let delete = UIContextualAction(style: .destructive, title: L("刪除")) { [weak self] _, _, done in
            self?.editor?.removeOutlineBookmark(b.id)
            self?.reload()
            done(true)
        }
        let rename = UIContextualAction(style: .normal, title: L("重新命名")) { [weak self] _, _, done in
            guard let self else { return done(false) }
            self.editor?.promptRenameOutlineBookmark(b, from: self) { [weak self] in self?.reload() }
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete, rename])
    }

    /// 點大綱的那一行：跳到那一頁
    func openOutline(at ip: IndexPath) {
        guard let i = outlineEntry(at: ip)?.pageIndex, let editor, let id = editor.pages[safe: i]?.id else { return }
        dismiss(animated: true) { [weak editor] in
            guard let editor, let i = editor.pageIndex(of: id) else { return }
            editor.scrollToPage(i, animated: false)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let item = items[safe: indexPath.item] else { return }
        if selecting {
            if selectedIDs.contains(item.page.id) { selectedIDs.remove(item.page.id) } else { selectedIDs.insert(item.page.id) }
            (collectionView.cellForItem(at: indexPath) as? PageThumbCell)?.checked = selectedIDs.contains(item.page.id)
            updateBars()
            return
        }
        let id = item.page.id
        dismiss(animated: true) { [weak editor] in
            guard let editor, let i = editor.pageIndex(of: id) else { return }
            editor.scrollToPage(i, animated: false)
        }
    }
}

/// 一頁的縮圖：圖、頁碼、右上角的我的最愛星號（點了加入）、目前頁面的藍框、選取勾勾
final class PageThumbCell: UICollectionViewCell {
    var pageID: UUID?
    var thumbnail: UIImage? { didSet { imageView.image = thumbnail; setNeedsLayout() } }
    var number = 0 { didSet { label.text = "\(number)" } }
    var favorite = false { didSet { updateStar() } }
    var isCurrent = false { didSet { updateFrame() } }
    var selecting = false { didSet { check.isHidden = !selecting; updateStar() } }
    /// 點了星號
    var onStar: (() -> Void)?
    let starButton = UIButton(type: .system)
    var checked = false { didSet { check.image = UIImage(systemName: checked ? "checkmark.circle.fill" : "circle"); updateFrame() } }

    private let paper = UIView()
    private let imageView = UIImageView()
    private let label = UILabel()
    private let check = UIImageView(image: UIImage(systemName: "circle"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        paper.backgroundColor = .white
        paper.layer.shadowColor = UIColor.black.cgColor
        paper.layer.shadowOpacity = 0.12
        paper.layer.shadowRadius = 4
        paper.layer.shadowOffset = CGSize(width: 0, height: 1)
        paper.layer.cornerRadius = 3
        contentView.addSubview(paper)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 3
        paper.addSubview(imageView)
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textAlignment = .center
        contentView.addSubview(label)
        starButton.accessibilityIdentifier = "page.star"
        starButton.addAction(UIAction { [weak self] _ in self?.onStar?() }, for: .touchUpInside)
        contentView.addSubview(starButton)
        updateStar()
        check.tintColor = .systemBlue
        check.backgroundColor = .systemBackground
        check.layer.cornerRadius = 12
        check.isHidden = true
        contentView.addSubview(check)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail = nil
        pageID = nil
    }

    private func updateStar() {
        let cfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        starButton.setImage(UIImage(systemName: favorite ? "star.fill" : "star", withConfiguration: cfg), for: .normal)
        // 沒加入的星號用灰色、加白色外框，放在縮圖上也看得到
        starButton.tintColor = favorite ? .systemYellow : UIColor.systemGray
        starButton.layer.shadowColor = UIColor.white.cgColor
        starButton.layer.shadowOpacity = favorite ? 0 : 0.9
        starButton.layer.shadowRadius = 1.5
        starButton.layer.shadowOffset = .zero
        starButton.accessibilityLabel = favorite ? L("我的最愛") : L("加入我的最愛")
        starButton.isHidden = selecting
    }

    private func updateFrame() {
        let on = checked || isCurrent
        paper.layer.borderWidth = on ? 3 : 0
        paper.layer.borderColor = UIColor.systemBlue.cgColor
        label.textColor = isCurrent ? .systemBlue : .secondaryLabel
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let box = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 26)
        // 依頁面比例縮放，紙張外框貼著縮圖
        var r = box
        if let img = thumbnail, img.size.width > 0, img.size.height > 0 {
            let s = min(box.width / img.size.width, box.height / img.size.height)
            let size = CGSize(width: img.size.width * s, height: img.size.height * s)
            r = CGRect(x: (box.width - size.width) / 2, y: box.maxY - size.height, width: size.width, height: size.height)
        } else {
            let h = min(box.height, box.width * 1.3)
            r = CGRect(x: 0, y: box.maxY - h, width: box.width, height: h)
        }
        paper.frame = r
        paper.layer.shadowPath = UIBezierPath(roundedRect: paper.bounds, cornerRadius: 3).cgPath
        imageView.frame = paper.bounds
        label.frame = CGRect(x: 0, y: box.maxY + 4, width: bounds.width, height: 20)
        // 點的範圍大一點（44×44），星號在縮圖的右上角
        starButton.frame = CGRect(x: r.maxX - 40, y: r.minY - 6, width: 44, height: 44)
        check.frame = CGRect(x: r.maxX - 30, y: r.maxY - 30, width: 24, height: 24)
    }
}

extension NotebookViewController {
    func presentPageOverview() {
        endTextEditing()
        commitDrawing()
        let nav = UINavigationController(rootViewController: PageOverviewController(editor: self))
        nav.modalPresentationStyle = .overFullScreen
        present(nav, animated: true)
    }

    func movePage(from: Int, to: Int) {
        guard pages.indices.contains(from), pages.indices.contains(to), from != to else { return }
        performLayoutChange {
            let p = session.document.pages.remove(at: from)
            session.document.pages.insert(p, at: to)
        }
    }

    /// 每一頁複製一份放在原頁後面（筆跡、物件、螢光標示都複製；我的最愛與備註不複製）
    func duplicatePages(_ ids: Set<UUID>) {
        performLayoutChange {
            for i in session.document.pages.indices.reversed() where ids.contains(session.document.pages[i].id) {
                let original = session.document.pages[i]
                var copy = original
                copy.id = UUID()
                copy.elements = copy.elements.map { var e = $0; e.id = UUID(); return e }
                copy.highlights = copy.highlights.map { var h = $0; h.id = UUID(); return h }
                copy.favorite = false
                copy.note = ""
                if let d = session.drawings[original.id] { session.drawings[copy.id] = d }
                session.document.pages.insert(copy, at: i + 1)
            }
        }
    }

    /// 移到「最近刪除的頁面」，至少保留一頁
    func trashPages(_ ids: Set<UUID>) {
        let n = pages.filter { ids.contains($0.id) }.count
        guard n > 0, n < pages.count else { return }
        performLayoutChange {
            for i in session.document.pages.indices.reversed() where ids.contains(session.document.pages[i].id) {
                session.trashPage(at: i)
            }
        }
        showToast(L("\(n) 頁已移到「頁面 → 最近刪除的頁面」，30 天內可以還原"))
    }
}
