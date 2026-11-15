import UIKit
import Vision
import CoreImage
import PhotosUI
import PencilKit

/// 貼紙：分類（資料夾）裡放去背、裁切過的圖片，所有筆記本共用。
/// 工具列第二列是分類（縮圖用封面，沒設就是第一張），畫面下面一排是這個分類的貼紙，點一下就貼到目前這一頁
struct StickerRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    /// 預覽圖（PNG，背景透明）
    var file: String
    /// 筆跡做的貼紙：向量的筆跡另外存一份（貼上時是真的筆跡，放大也清楚、還能改顏色、擦掉）；nil＝圖片貼紙
    var vector: String? = nil
}

/// 筆跡貼紙的向量內容：PencilKit 和自製筆刷的筆跡，左上角移到原點
struct VectorSticker: Codable {
    /// PencilKit 的筆跡（PKDrawing 的資料）
    var drawing: Data
    var ink: [InkStroke]
    var size: CGSize

    /// strokes、ink 是文件座標，bounds 是它們的範圍
    init(strokes: [PKStroke], ink: [InkStroke], bounds: CGRect) {
        let t = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
        drawing = PKDrawing(strokes: strokes.map { s in
            var s = s
            s.transform = s.transform.concatenating(t)
            return s
        }).dataRepresentation()
        self.ink = ink.map { InkGeometry.offset($0, by: CGPoint(x: -bounds.minX, y: -bounds.minY)) }
        size = bounds.size
    }

    /// 當成套索拷貝的內容（範圍在原點），用 pasteLasso 貼上
    func clipboard() -> LassoClipboard? {
        guard let d = try? PKDrawing(data: drawing) else { return nil }
        return LassoClipboard(strokes: d.strokes, elements: [], highlights: [], bounds: CGRect(origin: .zero, size: size),
                              changeCount: -1, ink: ink)
    }
}

struct StickerCategory: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// 設為封面的貼紙；nil＝第一張
    var coverID: UUID? = nil
    var stickers: [StickerRecord] = []

    /// 分類的縮圖：設為封面的那張，沒有就第一張
    var cover: StickerRecord? { stickers.first { $0.id == coverID } ?? stickers.first }
}

final class StickerStore {
    static let shared = StickerStore()

    private struct Index: Codable {
        var categories: [StickerCategory]
        var selected: UUID?
    }

    private(set) var categories: [StickerCategory] = []
    private var selectedID: UUID?
    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("categories.json") }
    /// 第一版（沒有分類）的清單：搬進「我的貼紙」
    private var legacyURL: URL { directory.appendingPathComponent("stickers.json") }
    private let cache = NSCache<NSString, UIImage>()

    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? support.appendingPathComponent("Stickers", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let fm = FileManager.default
        func exists(_ s: StickerRecord) -> Bool { fm.fileExists(atPath: self.directory.appendingPathComponent(s.file).path) }
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode(Index.self, from: data) {
            categories = saved.categories.map { c in
                var c = c
                c.stickers = c.stickers.filter(exists)
                return c
            }
            selectedID = saved.selected
        } else if let data = try? Data(contentsOf: legacyURL), let old = try? JSONDecoder().decode([StickerRecord].self, from: data) {
            let kept = old.filter(exists)
            if !kept.isEmpty { categories = [StickerCategory(name: L("我的貼紙"), stickers: kept)] }
            persist()
            try? fm.removeItem(at: legacyURL)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Index(categories: categories, selected: selectedID)) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    var allStickers: [StickerRecord] { categories.flatMap(\.stickers) }

    /// 目前選的分類（沒選過就是第一個）
    var selectedCategory: StickerCategory? { categories.first { $0.id == selectedID } ?? categories.first }

    func select(_ id: UUID) {
        guard categories.contains(where: { $0.id == id }) else { return }
        selectedID = id
        persist()
    }

    @discardableResult
    func addCategory(named name: String) -> StickerCategory {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = StickerCategory(name: trimmed.isEmpty ? defaultCategoryName() : trimmed)
        categories.append(c)
        persist()
        return c
    }

    /// 新分類的預設名字：分類 1、分類 2…（不和已經有的重複）
    func defaultCategoryName() -> String {
        var n = categories.count + 1
        while categories.contains(where: { $0.name == L("分類 \(n)") }) { n += 1 }
        return L("分類 \(n)")
    }

    func renameCategory(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[i].name = trimmed
        persist()
    }

    /// 刪除分類和裡面的貼紙
    func removeCategory(_ id: UUID) {
        guard let i = categories.firstIndex(where: { $0.id == id }) else { return }
        for s in categories[i].stickers { removeFiles(of: s) }
        categories.remove(at: i)
        if selectedID == id { selectedID = nil }
        persist()
    }

    private func removeFiles(of s: StickerRecord) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(s.file))
        if let v = s.vector { try? FileManager.default.removeItem(at: directory.appendingPathComponent(v)) }
    }

    /// 筆跡貼紙的向量內容；圖片貼紙（或檔案讀不到）回傳 nil
    func vector(for s: StickerRecord) -> VectorSticker? {
        guard let v = s.vector, let data = try? Data(contentsOf: directory.appendingPathComponent(v)) else { return nil }
        return try? JSONDecoder().decode(VectorSticker.self, from: data)
    }

    func image(for s: StickerRecord) -> UIImage? {
        if let img = cache.object(forKey: s.file as NSString) { return img }
        guard let img = UIImage(contentsOfFile: directory.appendingPathComponent(s.file).path) else { return nil }
        cache.setObject(img, forKey: s.file as NSString)
        return img
    }

    /// 存成 PNG（保留透明的背景），放在分類的最後面（第一張不會變，分類的縮圖也不會變）
    @discardableResult
    func add(_ image: UIImage, to categoryID: UUID, vector: VectorSticker? = nil) -> StickerRecord? {
        guard let ci = categories.firstIndex(where: { $0.id == categoryID }) else { return nil }
        let name = "sticker-\(UUID().uuidString)"
        let file = name + ".png"
        guard let data = image.pngData() else { return nil }
        var vectorFile: String?
        do {
            try data.write(to: directory.appendingPathComponent(file), options: .atomic)
            if let vector {
                vectorFile = name + ".vector.json"
                try JSONEncoder().encode(vector).write(to: directory.appendingPathComponent(name + ".vector.json"), options: .atomic)
            }
        } catch {
            return nil
        }
        let s = StickerRecord(file: file, vector: vectorFile)
        cache.setObject(image, forKey: file as NSString)
        categories[ci].stickers.append(s)
        persist()
        return s
    }

    func remove(_ stickerID: UUID) {
        for ci in categories.indices {
            guard let si = categories[ci].stickers.firstIndex(where: { $0.id == stickerID }) else { continue }
            let s = categories[ci].stickers.remove(at: si)
            removeFiles(of: s)
            if categories[ci].coverID == stickerID { categories[ci].coverID = nil }
            persist()
            return
        }
    }

    /// 設為分類的封面（工具列上分類的縮圖）
    func setCover(_ stickerID: UUID) {
        guard let ci = categories.firstIndex(where: { $0.stickers.contains { $0.id == stickerID } }) else { return }
        categories[ci].coverID = stickerID
        persist()
    }

    /// 縮圖：等比例放進 side×side 的方塊
    func thumbnail(for s: StickerRecord, side: CGFloat) -> UIImage? {
        guard let img = image(for: s) else { return nil }
        let k = side / max(img.size.width, img.size.height, 1)
        let size = CGSize(width: img.size.width * k, height: img.size.height * k)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { _ in
            img.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
    }
}

enum StickerMaker {
    /// 貼紙圖最長邊（像素）
    static let maxPixel: CGFloat = 1600

    /// 方向轉正、縮到 maxPixel 以內、scale 1（Vision、裁切都用像素算）
    static func normalized(_ image: UIImage) -> UIImage {
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let s = min(1, maxPixel / max(px.width, px.height, 1))
        let target = CGSize(width: max(1, (px.width * s).rounded()), height: max(1, (px.height * s).rounded()))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: target, format: fmt).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }

    /// 主體的遮罩（和相簿長按拉出主體一樣；白＝主體），大小和圖片一樣；認不出主體回傳 nil
    static func subjectMask(_ image: UIImage) -> CIImage? {
        guard let cg = image.cgImage else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            return CIImage(cvPixelBuffer: buffer)
        } catch {
            DebugLog.add("sticker: subject mask failed \(error.localizedDescription)")
            return nil
        }
    }

    /// 做成貼紙：crop（圖片像素座標，左上角為原點）裁切；mask 有值就去背（背景透明，透明的邊裁掉）
    static func render(_ image: UIImage, crop: CGRect?, mask: CIImage?) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        var out = CIImage(cgImage: cg)
        if let mask {
            out = out.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        var region = full
        if let crop {
            let c = crop.integral.intersection(full)
            if c.width >= 1, c.height >= 1 {
                // Core Image 的原點在左下角
                region = CGRect(x: c.minX, y: h - c.maxY, width: c.width, height: c.height)
            }
        }
        guard let res = CIContext().createCGImage(out, from: region, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) else { return image }
        let img = UIImage(cgImage: res, scale: 1, orientation: .up)
        return mask == nil ? img : trimmedTransparentEdges(img)
    }

    /// 裁掉四周完全透明的部分（全部透明就原樣回傳）
    static func trimmedTransparentEdges(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where data[(y * w + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        if minX == 0, minY == 0, maxX == w - 1, maxY == h - 1 { return image }
        // CGContext 的記憶體第一列是圖的最上面一列（和 CGImage 一樣），直接用同樣的座標裁
        guard let cropped = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }
}

/// 從相簿挑一張照片做貼紙（和插入圖片的選擇器分開，挑完不會放到頁面上）
final class StickerPhotoPicker: NSObject, PHPickerViewControllerDelegate {
    var onPick: ((UIImage) -> Void)?

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let p = results.first?.itemProvider, p.canLoadObject(ofClass: UIImage.self) else { return }
        p.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
            guard let img = obj as? UIImage else { return }
            DispatchQueue.main.async { self?.onPick?(img) }
        }
    }
}

/// 不會反白的按鈕（貼紙列：點選著的貼紙是打開選單）
final class NoHighlightButton: UIButton {
    override var isHighlighted: Bool {
        get { false }
        set {}
    }
}

/// 貼紙工具：畫面下面一排目前分類的貼紙（和圖片工具的照片列一樣的位置）。
/// 點一下選起來，再點頁面貼到那裡；選著的貼紙再點一下打開選單（和長按一樣）
final class StickerStripView: UIView {
    static let height: CGFloat = 112
    /// 選著的貼紙：點頁面就貼上這張
    private(set) var selectedID: UUID?
    var onPick: ((StickerRecord) -> Void)?
    var onAdd: (() -> Void)?
    var onDelete: ((StickerRecord) -> Void)?
    var onSetCover: ((StickerRecord) -> Void)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let message = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 16
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        scroll.showsHorizontalScrollIndicator = false
        scroll.scrollsToTop = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        addSubview(scroll)
        message.font = .systemFont(ofSize: 14)
        message.textColor = .secondaryLabel
        message.numberOfLines = 2
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 120),
            message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 這一排的貼紙按鈕（測試用）
    private(set) var stickerButtons: [UIButton] = []

    func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stickerButtons = []
        let store = StickerStore.shared
        var add = UIButton.Configuration.tinted()
        add.image = UIImage(systemName: "photo.badge.plus")
        add.title = L("從相簿加入")
        add.imagePlacement = .top
        add.imagePadding = 4
        add.buttonSize = .small
        let addButton = UIButton(configuration: add)
        addButton.accessibilityIdentifier = "sticker.add"
        addButton.widthAnchor.constraint(equalToConstant: 96).isActive = true
        addButton.heightAnchor.constraint(equalToConstant: 88).isActive = true
        addButton.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .touchUpInside)
        stack.addArrangedSubview(addButton)
        guard let category = store.selectedCategory else {
            selectedID = nil
            addButton.isEnabled = false
            message.text = L("先在上面按「新增分類」")
            message.isHidden = false
            return
        }
        message.text = L("這個分類還沒有貼紙：從相簿加入，或用套索圈起來選「添加至貼紙」")
        message.isHidden = !category.stickers.isEmpty
        if let id = selectedID, !category.stickers.contains(where: { $0.id == id }) { selectedID = nil }
        for s in category.stickers {
            let b = NoHighlightButton(type: .custom)
            b.setImage(store.thumbnail(for: s, side: 80), for: .normal)
            b.imageView?.contentMode = .scaleAspectFit

            b.widthAnchor.constraint(equalToConstant: 88).isActive = true
            b.heightAnchor.constraint(equalToConstant: 88).isActive = true
            b.layer.cornerRadius = 10
            b.accessibilityLabel = L("貼紙")
            b.accessibilityIdentifier = "sticker.\(s.id.uuidString)"
            let isSelected = s.id == selectedID
            b.isSelected = isSelected
            if isSelected {
                b.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.15)
                b.layer.borderWidth = 2.5
                b.layer.borderColor = UIColor.systemBlue.cgColor
            }
            if s.vector != nil {
                // 筆跡貼紙（向量）：右下角一枝筆
                let pen = UIImageView(image: UIImage(systemName: "scribble"))
                pen.tintColor = .secondaryLabel
                pen.frame = CGRect(x: 66, y: 66, width: 18, height: 18)
                pen.accessibilityIdentifier = "sticker.vector"
                b.addSubview(pen)
                b.accessibilityValue = L("筆跡")
            }
            if s.id == category.cover?.id {
                // 分類封面：左上角一顆星
                let star = UIImageView(image: UIImage(systemName: "star.fill"))
                star.tintColor = .systemYellow
                star.frame = CGRect(x: 4, y: 4, width: 16, height: 16)
                star.accessibilityIdentifier = "sticker.cover"
                b.addSubview(star)
            }
            b.addAction(UIAction { [weak self] _ in self?.tapped(s) }, for: .touchUpInside)
            // 長按（選著的貼紙是點一下）：刪除、設為分類封面
            b.menu = UIMenu(children: [
                UIAction(title: L("設為分類封面"), image: UIImage(systemName: "photo")) { [weak self] _ in self?.onSetCover?(s) },
                UIAction(title: L("刪除"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.onDelete?(s) },
            ])
            b.showsMenuAsPrimaryAction = isSelected
            stack.addArrangedSubview(b)
            stickerButtons.append(b)
        }
    }

    /// 點了一張貼紙：選起來（選著的那張點了是打開選單，不會走到這裡）
    func tapped(_ s: StickerRecord) {
        selectedID = s.id
        reload()
        onPick?(s)
    }

    /// 選著的貼紙
    var selectedSticker: StickerRecord? {
        guard let id = selectedID else { return nil }
        return StickerStore.shared.selectedCategory?.stickers.first { $0.id == id }
    }
}

// MARK: - 編輯器：貼紙工具

extension NotebookViewController {
    /// 貼紙放到頁面上的大小：最長邊 160pt
    static let stickerSide: CGFloat = 160

    func setupStickerStrip() {
        stickerStrip.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stickerStrip)
        stickerStrip.isHidden = true
        NSLayoutConstraint.activate([
            stickerStrip.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stickerStrip.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stickerStrip.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            stickerStrip.heightAnchor.constraint(equalToConstant: StickerStripView.height),
        ])
        stickerStrip.onPick = { [weak self] _ in self?.showToast(L("點頁面貼上這張貼紙")) }
        stickerStrip.onAdd = { [weak self] in
            guard let id = StickerStore.shared.selectedCategory?.id else { return }
            self?.presentStickerPicker(into: id)
        }
        stickerStrip.onDelete = { [weak self] s in
            StickerStore.shared.remove(s.id)
            self?.refreshStickers()
        }
        stickerStrip.onSetCover = { [weak self] s in
            StickerStore.shared.setCover(s.id)
            self?.refreshStickers()
        }
    }

    /// 貼紙改了：工具列的分類和下面那一排一起更新
    func refreshStickers() {
        guard tool == .sticker else { return }
        rebuildSubBar()
        stickerStrip.reload()
    }

    /// 工具列第二列：分類（縮圖＋名字）和「新增分類」
    func buildStickerBar() -> [UIView] {
        let store = StickerStore.shared
        var views: [UIView] = []
        let selected = store.selectedCategory?.id
        for c in store.categories {
            var cfg = UIButton.Configuration.plain()
            cfg.title = c.name
            cfg.image = c.cover.flatMap { store.thumbnail(for: $0, side: 28) } ?? UIImage(systemName: "folder")
            cfg.imagePadding = 6
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 8)
            cfg.baseForegroundColor = c.id == selected ? .systemBlue : .label
            cfg.background.backgroundColor = c.id == selected ? UIColor.systemBlue.withAlphaComponent(0.15) : .clear
            cfg.background.cornerRadius = 8
            let b = UIButton(configuration: cfg)
            b.accessibilityIdentifier = "stickerCategory.\(c.id.uuidString)"
            b.addAction(UIAction { [weak self] _ in
                StickerStore.shared.select(c.id)
                self?.refreshStickers()
            }, for: .touchUpInside)
            b.menu = UIMenu(children: [
                UIAction(title: L("重新命名"), image: UIImage(systemName: "pencil")) { [weak self] _ in self?.promptRenameStickerCategory(c) },
                UIAction(title: L("刪除分類"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.confirmDeleteStickerCategory(c)
                },
            ])
            views.append(b)
        }
        let add = makeButton(symbol: "folder.badge.plus", title: L("新增分類"), action: nil)
        add.accessibilityLabel = L("新增分類")
        add.addAction(UIAction { [weak self] _ in self?.promptNewStickerCategory { _ in } }, for: .touchUpInside)
        views.append(add)
        if store.categories.isEmpty { views.append(hintLabel(L("建立分類後，從相簿或套索加入貼紙"))) }
        // 分類很多時左右捲動，不把工具列撐出畫面
        let stack = UIStackView(arrangedSubviews: views)
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        let strip = UIScrollView()
        strip.showsHorizontalScrollIndicator = false
        strip.scrollsToTop = false
        strip.addSubview(stack)
        let fit = strip.widthAnchor.constraint(equalTo: stack.widthAnchor)
        fit.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: strip.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: strip.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: strip.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: strip.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: strip.frameLayoutGuide.heightAnchor),
            strip.heightAnchor.constraint(equalToConstant: 40),
            fit,
        ])
        return [strip]
    }

    /// 建立新分類（輸入名字）；建好後選它，再交給 then
    func promptNewStickerCategory(then: @escaping (UUID) -> Void) {
        let store = StickerStore.shared
        let a = UIAlertController(title: L("新增分類"), message: nil, preferredStyle: .alert)
        a.addTextField { tf in
            tf.placeholder = store.defaultCategoryName()
            tf.clearButtonMode = .whileEditing
        }
        a.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        a.addAction(UIAlertAction(title: L("建立"), style: .default) { [weak self, weak a] _ in
            let c = store.addCategory(named: a?.textFields?.first?.text ?? "")
            store.select(c.id)
            self?.refreshStickers()
            then(c.id)
        })
        present(a, animated: true)
    }

    func promptRenameStickerCategory(_ c: StickerCategory) {
        let a = UIAlertController(title: L("重新命名"), message: nil, preferredStyle: .alert)
        a.addTextField { tf in
            tf.text = c.name
            tf.clearButtonMode = .whileEditing
        }
        a.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        a.addAction(UIAlertAction(title: L("完成"), style: .default) { [weak self, weak a] _ in
            StickerStore.shared.renameCategory(c.id, to: a?.textFields?.first?.text ?? "")
            self?.refreshStickers()
        })
        present(a, animated: true)
    }

    func confirmDeleteStickerCategory(_ c: StickerCategory) {
        let a = UIAlertController(title: L("刪除「\(c.name)」？"), message: L("分類裡的 \(c.stickers.count) 張貼紙會一起刪除"), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        a.addAction(UIAlertAction(title: L("刪除"), style: .destructive) { [weak self] _ in
            StickerStore.shared.removeCategory(c.id)
            self?.refreshStickers()
        })
        present(a, animated: true)
    }

    func presentStickerPicker(into categoryID: UUID) {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        let delegate = StickerPhotoPicker()
        delegate.onPick = { [weak self] img in self?.presentStickerEditor(img, into: categoryID) }
        stickerPicker = delegate
        picker.delegate = delegate
        present(picker, animated: true)
    }

    /// 選裁切範圍、要不要去背，做好就加進這個分類
    func presentStickerEditor(_ image: UIImage, into categoryID: UUID) {
        let editor = StickerEditorViewController(image: image)
        editor.onDone = { [weak self] sticker in self?.saveSticker(sticker, into: categoryID) }
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    func saveSticker(_ image: UIImage, into categoryID: UUID, vector: VectorSticker? = nil) {
        guard StickerStore.shared.add(image, to: categoryID, vector: vector) != nil else { return }
        StickerStore.shared.select(categoryID)
        let name = StickerStore.shared.categories.first { $0.id == categoryID }?.name ?? ""
        showToast(L("已加到貼紙「\(name)」"))
        refreshStickers()
    }

    /// 套索只圈到筆跡：也存一份向量的筆跡（貼上時是真的筆跡）。圈到物件、螢光標示就只有圖片
    func lassoVectorSticker() -> VectorSticker? {
        guard let sel = lassoSel, sel.elements.isEmpty, sel.highlights.isEmpty, sel.hasInk else { return nil }
        let strokes = sel.strokeIndices.compactMap { canvas.drawing.strokes[safe: $0] }
        let ink = inkStrokes(sel.ink)
        guard !strokes.isEmpty || !ink.isEmpty else { return nil }
        return VectorSticker(strokes: strokes, ink: ink, bounds: sel.bounds)
    }

    /// 套索圈到的東西畫成貼紙：背景透明（不含紙張、PDF），只有筆跡、物件、螢光標示
    func lassoStickerImage() -> UIImage? {
        guard let sel = lassoSel, !sel.bounds.isNull else { return nil }
        let rect = sel.bounds.insetBy(dx: -4, dy: -4).integral
        guard rect.width > 2, rect.height > 2 else { return nil }
        // 筆跡是向量：照貼紙的最大解析度重畫（小小一個字放大貼上也清楚），不是照螢幕的 3 倍
        let scale = min(16, StickerMaker.maxPixel / max(rect.width, rect.height))
        let pk = sel.strokeIndices.compactMap { canvas.drawing.strokes[safe: $0] }
        let pkImage = pk.isEmpty ? nil : PageRenderer.inkImage(PKDrawing(strokes: pk), rect: rect, scale: scale)
        let ink = inkStrokes(sel.ink)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: rect.size, format: fmt).image { rc in
            let ctx = rc.cgContext
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
            for h in sel.highlights {
                guard let pi = pageIndex(of: h.pageID), let hl = pages[pi].highlights.first(where: { $0.id == h.id }) else { continue }
                let o = contentOrigin(pi)
                UIColor(hex: hl.colorHex).setFill()
                for r in hl.rects { ctx.fill(r.offsetBy(dx: o.x, dy: o.y)) }
            }
            for ref in sel.elements {
                guard case let (pi, ei)? = locate(ref) else { continue }
                let e = pages[pi].elements[ei]
                ElementRenderer.draw(e, in: docFrame(of: e, pageIndex: pi), session: session)
            }
            pkImage?.draw(in: rect)
            InkRenderer.draw(ink, in: ctx)
        }
    }

    /// 貼上貼紙：貼在 p（文件座標，點頁面的位置），沒給就貼到畫面中央（同一點連續貼往右下錯開）；
    /// 留在貼紙工具可以接著貼
    @discardableResult
    func placeSticker(_ s: StickerRecord, at p: CGPoint? = nil) -> ElementRef? {
        guard !pages.isEmpty else { return nil }
        // 筆跡貼紙：貼上真的筆跡（原本的大小），不是圖片
        if let v = StickerStore.shared.vector(for: s), let clip = v.clipboard() {
            let r = visibleDocRect()
            pasteLasso(clip, center: p ?? CGPoint(x: r.midX, y: r.midY), select: false)
            return nil
        }
        guard let img = StickerStore.shared.image(for: s) else { return nil }
        guard let file = session.saveImage(img, jpeg: false) else { return nil }
        let r = visibleDocRect()
        let pi = p.flatMap { pageIndex(containing: $0) } ?? currentPageIndex
        let o = contentOrigin(pi)
        var c = p ?? CGPoint(x: r.midX, y: r.midY)
        let centers = pages[pi].elements.map { CGPoint(x: $0.frame.midX + o.x, y: $0.frame.midY + o.y) }
        var k = 0
        while k < 12, centers.contains(where: { $0.distance(to: c) < 4 }) {
            c = CGPoint(x: c.x + 24, y: c.y + 24)
            k += 1
        }
        let k2 = Self.stickerSide / max(img.size.width, img.size.height, 1)
        let size = CGSize(width: (img.size.width * k2).rounded(), height: (img.size.height * k2).rounded())
        return insertElement(.image(ImageData(file: file)), size: size, at: c)
    }
}
