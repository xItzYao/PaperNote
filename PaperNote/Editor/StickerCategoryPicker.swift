import UIKit

/// 「添加至貼紙」：跳出一個大的浮動視窗，分類用大圖排列、底下是分類名稱。第一格是「創建新分類」
final class StickerCategoryPickerViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    static let thumbnailSide: CGFloat = 150

    /// 選好分類（或建好新分類）：視窗收起來之後才呼叫
    var onPick: ((UUID) -> Void)?

    let image: UIImage
    private(set) var collection: UICollectionView!
    private let preview = UIImageView()

    init(image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
        title = L("添加至貼紙")
        modalPresentationStyle = .formSheet
        preferredContentSize = CGSize(width: 720, height: 620)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 格子：第一格是「創建新分類」，接著是每個分類
    var categories: [StickerCategory] { StickerStore.shared.categories }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })

        preview.image = image
        preview.contentMode = .scaleAspectFit
        preview.backgroundColor = .secondarySystemBackground
        preview.layer.cornerRadius = 12
        preview.clipsToBounds = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.accessibilityIdentifier = "stickerPicker.preview"
        let hint = UILabel()
        hint.text = L("選一個分類，或創建新的分類")
        hint.font = .systemFont(ofSize: 15)
        hint.textColor = .secondaryLabel
        hint.numberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false

        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: Self.thumbnailSide + 16, height: Self.thumbnailSide + 52)
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 18
        layout.sectionInset = UIEdgeInsets(top: 8, left: 20, bottom: 24, right: 20)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.register(StickerCategoryCell.self, forCellWithReuseIdentifier: "cell")
        collection.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(preview)
        view.addSubview(hint)
        view.addSubview(collection)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: g.topAnchor, constant: 16),
            preview.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 20),
            preview.widthAnchor.constraint(equalToConstant: 96),
            preview.heightAnchor.constraint(equalToConstant: 96),
            hint.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
            hint.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            collection.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 12),
            collection.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { categories.count + 1 }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath) as! StickerCategoryCell
        if indexPath.item == 0 {
            cell.show(image: nil, symbol: "folder.badge.plus", name: L("創建新分類"), detail: nil)
            cell.accessibilityIdentifier = "stickerPicker.new"
        } else {
            let c = categories[indexPath.item - 1]
            let thumb = c.cover.flatMap { StickerStore.shared.thumbnail(for: $0, side: Self.thumbnailSide) }
            cell.show(image: thumb, symbol: "folder", name: c.name, detail: L("\(c.stickers.count) 張"))
            cell.accessibilityIdentifier = "stickerPicker.\(c.id.uuidString)"
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        choose(item: indexPath.item)
    }

    /// 點了第 item 格
    func choose(item: Int) {
        if item == 0 {
            promptNewCategory()
        } else if let c = categories[safe: item - 1] {
            finish(c.id)
        }
    }

    private func promptNewCategory() {
        let store = StickerStore.shared
        let a = UIAlertController(title: L("創建新分類"), message: nil, preferredStyle: .alert)
        a.addTextField { tf in
            tf.placeholder = store.defaultCategoryName()
            tf.clearButtonMode = .whileEditing
        }
        a.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        a.addAction(UIAlertAction(title: L("建立"), style: .default) { [weak self, weak a] _ in
            self?.createCategory(named: a?.textFields?.first?.text ?? "")
        })
        present(a, animated: true)
    }

    func createCategory(named name: String) {
        let c = StickerStore.shared.addCategory(named: name)
        finish(c.id)
    }

    private func finish(_ id: UUID) {
        let pick = onPick
        onPick = nil
        // 包在 navigation controller 裡：收起整個視窗
        let host = navigationController ?? self
        if host.presentingViewController == nil {
            pick?(id)
        } else {
            host.dismiss(animated: true) { pick?(id) }
        }
    }
}

/// 分類格子：大縮圖，底下是名稱、張數
final class StickerCategoryCell: UICollectionViewCell {
    private let box = UIView()
    private let thumb = UIImageView()
    private let name = UILabel()
    private let detail = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        box.backgroundColor = .secondarySystemBackground
        box.layer.cornerRadius = 14
        box.layer.borderColor = UIColor.separator.cgColor
        box.layer.borderWidth = 1
        box.translatesAutoresizingMaskIntoConstraints = false
        thumb.contentMode = .scaleAspectFit
        thumb.tintColor = .systemBlue
        thumb.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        thumb.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.textAlignment = .center
        name.translatesAutoresizingMaskIntoConstraints = false
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabel
        detail.textAlignment = .center
        detail.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(box)
        box.addSubview(thumb)
        contentView.addSubview(name)
        contentView.addSubview(detail)
        let side = StickerCategoryPickerViewController.thumbnailSide
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: contentView.topAnchor),
            box.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            box.widthAnchor.constraint(equalToConstant: side),
            box.heightAnchor.constraint(equalToConstant: side),
            thumb.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            thumb.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            thumb.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            thumb.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            name.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 6),
            name.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            name.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            detail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { box.backgroundColor = isHighlighted ? .systemFill : .secondarySystemBackground }
    }

    private(set) var title = ""

    func show(image: UIImage?, symbol: String, name text: String, detail sub: String?) {
        thumb.image = image ?? UIImage(systemName: symbol)
        name.text = text
        detail.text = sub
        detail.isHidden = sub == nil
        title = text
        accessibilityLabel = text
    }
}

extension NotebookViewController {
    /// 「添加至貼紙」的大視窗：選好分類後交給 then
    func presentStickerCategoryPicker(_ image: UIImage, then: @escaping (UIImage, UUID) -> Void) {
        let picker = StickerCategoryPickerViewController(image: image)
        picker.onPick = { [weak self] id in
            StickerStore.shared.select(id)
            self?.refreshStickers()
            then(image, id)
        }
        let nav = UINavigationController(rootViewController: picker)
        nav.modalPresentationStyle = .formSheet
        nav.preferredContentSize = picker.preferredContentSize
        present(nav, animated: true)
    }

    /// 套索選單的「添加至貼紙」：圈到的東西（背景透明）選分類後加進去
    func addLassoToStickers() {
        guard let img = lassoStickerImage().map(StickerMaker.trimmedTransparentEdges) else { return }
        presentStickerCategoryPicker(img) { [weak self] img, id in self?.saveSticker(img, into: id) }
    }

    /// 圖片選單的「變成貼紙」：選分類，再選裁切範圍、要不要去背
    func makeSticker(fromImageFile file: String) {
        guard let img = session.image(named: file) else { return }
        presentStickerCategoryPicker(img) { [weak self] img, id in self?.presentStickerEditor(img, into: id) }
    }

    /// 跳出來的「添加至貼紙」視窗（測試用）
    var presentedStickerCategoryPicker: StickerCategoryPickerViewController? {
        (presentedViewController as? UINavigationController)?.topViewController as? StickerCategoryPickerViewController
    }
}
