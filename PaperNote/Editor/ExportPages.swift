import UIKit
import SwiftUI

/// 匯出：上面打頁碼（7-10、1 3 5…），下面是和「全部頁面」一樣的縮圖可以勾選，兩邊同步：
/// 打 6 → 第 6 頁勾起來；勾第 7 頁 → 上面多寫 7。一開始全部勾著
final class ExportPagesViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UITextFieldDelegate {
    private let session: NotebookSession
    /// 選好按格式：paperNote＝PaperNote 檔，否則 PDF；pages 是排好的頁面索引（0 起算）
    var onExport: ((_ paperNote: Bool, _ pages: [Int]) -> Void)?
    /// 按「取消」（nil＝自己關掉）
    var onCancel: (() -> Void)?

    let field = UITextField()
    let status = UILabel()
    let pdfButton = UIButton(configuration: .filled())
    let paperNoteButton = UIButton(configuration: .tinted())
    private(set) var collection: UICollectionView!
    private let layout = UICollectionViewFlowLayout()
    /// 勾著的頁面（索引）
    private(set) var selected: Set<Int>
    /// 打的頁碼看不懂（或超過頁數）：不能匯出
    private(set) var textError: String?
    private let thumbs = NSCache<NSNumber, UIImage>()
    private var waiting: [Int] = []
    private var drawingThumb = false
    private let thumbQueue = DispatchQueue(label: "PaperNote.export.thumbs", qos: .userInitiated)

    var pageCount: Int { session.document.pages.count }

    init(session: NotebookSession) {
        self.session = session
        selected = Set(session.document.pages.indices)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        title = L("匯出「\(session.title)」")
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: L("取消"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            if let cancel = self.onCancel { cancel() } else { self.dismiss(animated: true) }
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("全選"), primaryAction: UIAction { [weak self] _ in
            self?.toggleAll()
        })

        field.placeholder = PageSelection.hint
        field.accessibilityLabel = L("匯出的頁面")
        field.borderStyle = .roundedRect
        field.keyboardType = .numbersAndPunctuation
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .done
        field.delegate = self
        field.addAction(UIAction { [weak self] _ in self?.textChanged() }, for: .editingChanged)
        status.font = .systemFont(ofSize: 13)
        status.numberOfLines = 0

        var pdf = pdfButton.configuration ?? .filled()
        pdf.title = L("PDF（給別人看、列印）")
        pdfButton.configuration = pdf
        pdfButton.addAction(UIAction { [weak self] _ in self?.export(paperNote: false) }, for: .touchUpInside)
        var pn = paperNoteButton.configuration ?? .tinted()
        pn.title = L("PaperNote（可以繼續編輯筆跡）")
        paperNoteButton.configuration = pn
        paperNoteButton.addAction(UIAction { [weak self] _ in self?.export(paperNote: true) }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [pdfButton, paperNoteButton])
        buttons.spacing = 12
        buttons.distribution = .fillEqually

        let top = UIStackView(arrangedSubviews: [field, status])
        top.axis = .vertical
        top.spacing = 6
        top.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(top)
        view.addSubview(buttons)

        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 18
        layout.sectionInset = UIEdgeInsets(top: 12, left: 20, bottom: 20, right: 20)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.keyboardDismissMode = .onDrag
        collection.register(PageThumbCell.self, forCellWithReuseIdentifier: "cell")
        view.addSubview(collection)

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: g.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 20),
            top.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
            collection.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 4),
            collection.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            buttons.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            buttons.heightAnchor.constraint(equalToConstant: 48),
        ])
        field.text = PageSelection.format(selected.sorted(), pageCount: pageCount)
        refreshStatus()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let inset = layout.sectionInset.left + layout.sectionInset.right
        let width = collection.bounds.width - inset
        guard width > 0 else { return }
        let cols = max(3, Int((width + layout.minimumInteritemSpacing) / (130 + layout.minimumInteritemSpacing)))
        let w = floor((width - CGFloat(cols - 1) * layout.minimumInteritemSpacing) / CGFloat(cols))
        let size = CGSize(width: w, height: (w * 1.3).rounded() + 26)
        if layout.itemSize != size {
            layout.itemSize = size
            thumbs.removeAllObjects()
            layout.invalidateLayout()
        }
    }

    // MARK: 頁碼 ↔ 勾選

    /// 打字：看得懂就照著勾（不改使用者打的字）；看不懂就先不動勾選，下面顯示哪裡有問題
    func textChanged() {
        let text = field.text ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textError = nil
            setSelected([])
            return
        }
        do {
            let pages = try PageSelection.parse(text, pageCount: pageCount)
            textError = nil
            setSelected(Set(pages))
        } catch {
            textError = error.localizedDescription
            refreshStatus()
        }
    }

    /// 勾選或取消一頁：上面的頁碼跟著改
    func toggle(_ index: Int) {
        guard (0..<pageCount).contains(index) else { return }
        var s = selected
        if s.contains(index) { s.remove(index) } else { s.insert(index) }
        textError = nil
        setSelected(s)
        field.text = PageSelection.format(s.sorted(), pageCount: pageCount)
    }

    /// 全選；已經全選就全部取消
    func toggleAll() {
        let all = Set(0..<pageCount)
        let s = selected == all ? [] : all
        textError = nil
        setSelected(s)
        field.text = PageSelection.format(s.sorted(), pageCount: pageCount)
    }

    private func setSelected(_ s: Set<Int>) {
        selected = s
        for case let cell as PageThumbCell in collection?.visibleCells ?? [] {
            if let ip = collection.indexPath(for: cell) { cell.checked = s.contains(ip.item) }
        }
        refreshStatus()
    }

    private func refreshStatus() {
        let ok = textError == nil && !selected.isEmpty
        if let textError {
            status.text = textError
            status.textColor = .systemRed
        } else if selected.isEmpty {
            status.text = L("還沒選要匯出的頁面")
            status.textColor = .secondaryLabel
        } else {
            status.text = selected.count == pageCount ? L("全部 \(pageCount) 頁") : L("已選 \(selected.count) 頁")
            status.textColor = .secondaryLabel
        }
        pdfButton.isEnabled = ok
        paperNoteButton.isEnabled = ok
        navigationItem.rightBarButtonItem?.title = selected.count == pageCount ? L("全部取消") : L("全選")
    }

    func export(paperNote: Bool) {
        guard textError == nil, !selected.isEmpty else { return }
        onExport?(paperNote, selected.sorted())
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    // MARK: 縮圖

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { pageCount }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath) as! PageThumbCell
        let i = indexPath.item
        cell.pageID = session.document.pages[safe: i]?.id
        cell.number = i + 1
        cell.selecting = true
        cell.checked = selected.contains(i)
        cell.accessibilityLabel = L("第 \(i + 1) 頁")
        cell.accessibilityTraits = selected.contains(i) ? [.button, .selected] : [.button]
        cell.thumbnail = thumbs.object(forKey: NSNumber(value: i))
        if cell.thumbnail == nil { requestThumbnail(i) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        view.endEditing(true)
        toggle(indexPath.item)
        if let cell = collectionView.cellForItem(at: indexPath) {
            cell.accessibilityTraits = selected.contains(indexPath.item) ? [.button, .selected] : [.button]
        }
    }

    private func requestThumbnail(_ i: Int) {
        waiting.removeAll { $0 == i }
        waiting.append(i)
        DispatchQueue.main.async { [weak self] in self?.drawNextThumbnail() }
    }

    private func visibleCell(_ i: Int) -> PageThumbCell? {
        collection.cellForItem(at: IndexPath(item: i, section: 0)) as? PageThumbCell
    }

    /// 和「全部頁面」一樣：背景執行緒一張一張畫，捲過去的先畫
    private func drawNextThumbnail() {
        guard !drawingThumb else { return }
        while let i = waiting.popLast() {
            guard thumbs.object(forKey: NSNumber(value: i)) == nil, visibleCell(i) != nil else { continue }
            let w = layout.itemSize.width * traitCollection.displayScale
            guard let job = session.thumbnailJob(pageIndex: i, width: max(120, w)) else { continue }
            drawingThumb = true
            thumbQueue.async { [weak self] in
                let img = job()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.drawingThumb = false
                    if let img {
                        self.thumbs.setObject(img, forKey: NSNumber(value: i))
                        self.visibleCell(i)?.thumbnail = img
                    }
                    self.drawNextThumbnail()
                }
            }
            return
        }
    }
}

/// 資料庫裡的「匯出…」：SwiftUI 這邊用的外殼
struct ExportPagesSheet: UIViewControllerRepresentable {
    let session: NotebookSession
    let onExport: (Bool, [Int]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = ExportPagesViewController(session: session)
        vc.onExport = onExport
        vc.onCancel = onCancel
        return UINavigationController(rootViewController: vc)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}
