import UIKit
import Photos

/// 插入圖片工具：畫面下方一排最近的照片，點一下就放到目前這頁（工具不關，可以接著捲到別頁再加）
final class PhotoStripView: UIView, UICollectionViewDataSource, UICollectionViewDelegate, PHPhotoLibraryChangeObserver {
    /// 點了一張照片（已載入完整的圖）
    var onPick: ((UIImage) -> Void)?
    /// 「全部照片…」：用系統的照片選擇器
    var onBrowse: (() -> Void)?
    /// 只開放部分照片時，讓使用者再多選幾張（需要一個 view controller 來顯示）
    weak var presenter: UIViewController?

    static let height: CGFloat = 112
    private static let cellSize = CGSize(width: 88, height: 88)

    private var assets: PHFetchResult<PHAsset>?
    private let manager = PHCachingImageManager()
    private let collection: UICollectionView
    private let message = UILabel()
    private let browse = UIButton(configuration: .tinted())
    private let more = UIButton(configuration: .plain())
    private var observing = false
    private var loading = Set<String>()

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = Self.cellSize
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 12)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 16
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)

        browse.configuration?.image = UIImage(systemName: "photo.on.rectangle")
        browse.configuration?.title = "全部照片…"
        browse.configuration?.imagePlacement = .top
        browse.configuration?.imagePadding = 4
        browse.configuration?.buttonSize = .small
        browse.addAction(UIAction { [weak self] _ in self?.onBrowse?() }, for: .touchUpInside)
        more.configuration?.title = "選擇更多照片"
        more.configuration?.buttonSize = .mini
        more.addAction(UIAction { [weak self] _ in
            guard let self, let vc = self.presenter else { return }
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: vc)
        }, for: .touchUpInside)
        let side = UIStackView(arrangedSubviews: [browse, more])
        side.axis = .vertical
        side.spacing = 2
        side.alignment = .fill

        collection.backgroundColor = .clear
        collection.showsHorizontalScrollIndicator = false
        collection.dataSource = self
        collection.delegate = self
        collection.register(PhotoCell.self, forCellWithReuseIdentifier: "photo")

        message.font = .systemFont(ofSize: 14)
        message.textColor = .secondaryLabel
        message.numberOfLines = 2
        message.textAlignment = .center

        for v in [side, collection, message] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            side.centerYAnchor.constraint(equalTo: centerYAnchor),
            side.widthAnchor.constraint(equalToConstant: 104),
            collection.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: 8),
            collection.trailingAnchor.constraint(equalTo: trailingAnchor),
            collection.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            collection.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            message.leadingAnchor.constraint(equalTo: collection.leadingAnchor, constant: 8),
            message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    /// 打開工具時呼叫：第一次會問照片權限
    func reload() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .notDetermined:
            show(message: "允許取用照片後，最近的照片會列在這裡")
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
                DispatchQueue.main.async { self?.reload() }
            }
        case .authorized, .limited:
            if !observing {
                PHPhotoLibrary.shared().register(self)
                observing = true
            }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = 300
            assets = PHAsset.fetchAssets(with: .image, options: options)
            more.isHidden = status != .limited
            collection.reloadData()
            if assets?.count ?? 0 == 0 {
                show(message: status == .limited ? "還沒有開放任何照片，按「選擇更多照片」" : "照片圖庫是空的")
            } else {
                show(message: nil)
            }
        default:
            assets = nil
            more.isHidden = true
            collection.reloadData()
            show(message: "沒有照片的取用權限（到「設定」開啟），也可以用「全部照片…」挑選")
        }
    }

    private func show(message text: String?) {
        message.text = text
        message.isHidden = text == nil
        collection.isHidden = text != nil
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        // 剛拍的照片、截圖馬上出現
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isHidden else { return }
            self.reload()
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        assets?.count ?? 0
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "photo", for: indexPath) as! PhotoCell
        guard let asset = assets?.object(at: indexPath.item) else { return cell }
        cell.assetID = asset.localIdentifier
        cell.imageView.image = nil
        let scale = window?.screen.scale ?? 2
        let size = CGSize(width: Self.cellSize.width * scale, height: Self.cellSize.height * scale)
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { img, _ in
            guard cell.assetID == asset.localIdentifier else { return }
            cell.imageView.image = img
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let asset = assets?.object(at: indexPath.item), loading.insert(asset.localIdentifier).inserted else { return }
        let cell = collectionView.cellForItem(at: indexPath) as? PhotoCell
        cell?.setLoading(true)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        // 放到頁面上的圖最多 2400 像素（insertImage 也會再縮）
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 2400, height: 2400),
                                              contentMode: .aspectFit, options: options) { [weak self] img, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(asset.localIdentifier)
                cell?.setLoading(false)
                if let img { self.onPick?(img) }
            }
        }
    }
}

private final class PhotoCell: UICollectionViewCell {
    let imageView = UIImageView()
    var assetID: String?
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 8
        imageView.backgroundColor = .tertiarySystemFill
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
        spinner.center = CGPoint(x: frame.width / 2, y: frame.height / 2)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        contentView.addSubview(spinner)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setLoading(_ on: Bool) {
        if on { spinner.startAnimating() } else { spinner.stopAnimating() }
        imageView.alpha = on ? 0.5 : 1
    }

    override var isHighlighted: Bool {
        didSet { imageView.alpha = isHighlighted ? 0.6 : 1 }
    }
}
