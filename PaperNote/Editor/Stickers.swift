import UIKit
import Vision
import CoreImage
import PhotosUI

/// 貼紙：把圖片去背後存起來，所有筆記本共用；工具列的「貼紙」點一下就貼到目前這一頁
struct StickerRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    var file: String
}

final class StickerStore {
    static let shared = StickerStore()
    /// 新做的排最前面
    private(set) var stickers: [StickerRecord] = []
    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("stickers.json") }
    private let cache = NSCache<NSString, UIImage>()

    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? support.appendingPathComponent("Stickers", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([StickerRecord].self, from: data) {
            stickers = saved.filter { FileManager.default.fileExists(atPath: self.directory.appendingPathComponent($0.file).path) }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(stickers) { try? data.write(to: indexURL, options: .atomic) }
    }

    func image(for s: StickerRecord) -> UIImage? {
        if let img = cache.object(forKey: s.file as NSString) { return img }
        guard let img = UIImage(contentsOfFile: directory.appendingPathComponent(s.file).path) else { return nil }
        cache.setObject(img, forKey: s.file as NSString)
        return img
    }

    /// 存成 PNG（保留透明的背景）
    @discardableResult
    func add(_ image: UIImage) -> StickerRecord? {
        let file = "sticker-\(UUID().uuidString).png"
        guard let data = image.pngData() else { return nil }
        do {
            try data.write(to: directory.appendingPathComponent(file), options: .atomic)
        } catch {
            return nil
        }
        let s = StickerRecord(file: file)
        cache.setObject(image, forKey: file as NSString)
        stickers.insert(s, at: 0)
        persist()
        return s
    }

    func remove(_ id: UUID) {
        guard let s = stickers.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(s.file))
        stickers.removeAll { $0.id == id }
        persist()
    }
}

enum StickerMaker {
    /// 貼紙圖最長邊（像素）
    static let maxPixel: CGFloat = 1200

    /// 圖片變成貼紙：去背留下主體（和相簿長按拉出主體一樣），認不出主體就用整張；透明的邊裁掉
    static func makeSticker(from image: UIImage) -> UIImage {
        let upright = normalized(image)
        return trimmedTransparentEdges(liftSubject(upright) ?? upright)
    }

    /// 方向轉正、縮到 maxPixel 以內、scale 1（Vision 和裁邊都用像素算）
    static func normalized(_ image: UIImage) -> UIImage {
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let s = min(1, maxPixel / max(px.width, px.height, 1))
        let target = CGSize(width: max(1, (px.width * s).rounded()), height: max(1, (px.height * s).rounded()))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: target, format: fmt).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }

    /// 去背：Vision 認出的主體（全部主體一起），裁到主體的範圍；認不出來回傳 nil
    static func liftSubject(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)
            let ci = CIImage(cvPixelBuffer: buffer)
            guard let out = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
            return UIImage(cgImage: out, scale: 1, orientation: .up)
        } catch {
            DebugLog.add("sticker: subject lift failed \(error.localizedDescription)")
            return nil
        }
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
        // CGContext 的列是從上往下存的（和 CGImage 一樣），直接用同樣的座標裁
        guard let cropped = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }
}

/// 從相簿挑照片做貼紙（和插入圖片的選擇器分開，挑完不會放到頁面上）
final class StickerPhotoPicker: NSObject, PHPickerViewControllerDelegate {
    var onPick: (([UIImage]) -> Void)?

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let providers = results.map(\.itemProvider).filter { $0.canLoadObject(ofClass: UIImage.self) }
        guard !providers.isEmpty else { return }
        let group = DispatchGroup()
        var images: [Int: UIImage] = [:]
        let lock = NSLock()
        for (i, p) in providers.enumerated() {
            group.enter()
            p.loadObject(ofClass: UIImage.self) { obj, _ in
                if let img = obj as? UIImage {
                    lock.lock(); images[i] = img; lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.onPick?(images.keys.sorted().compactMap { images[$0] })
        }
    }
}

// MARK: - 編輯器：貼紙工具

extension NotebookViewController {
    /// 貼紙放到頁面上的大小：最長邊 160pt
    static let stickerSide: CGFloat = 160

    /// 工具列第二列：＋（從相簿做貼紙）和所有貼紙
    func buildStickerBar() -> [UIView] {
        var views: [UIView] = []
        let add = makeButton(symbol: "plus", title: L("加貼紙"), action: nil)
        add.accessibilityLabel = L("加貼紙")
        add.addAction(UIAction { [weak self] _ in self?.presentStickerPicker() }, for: .touchUpInside)
        views.append(add)
        let store = StickerStore.shared
        if store.stickers.isEmpty {
            views.append(hintLabel(L("從相簿挑照片會自動去背做成貼紙；頁面上的圖片點一下也能選「變成貼紙」")))
            return views
        }
        let stack = UIStackView()
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        for s in store.stickers {
            let b = UIButton(type: .custom)
            b.setImage(store.image(for: s), for: .normal)
            b.imageView?.contentMode = .scaleAspectFit
            b.widthAnchor.constraint(equalToConstant: 40).isActive = true
            b.heightAnchor.constraint(equalToConstant: 40).isActive = true
            b.accessibilityLabel = L("貼紙")
            b.accessibilityIdentifier = "sticker.\(s.id.uuidString)"
            b.addAction(UIAction { [weak self] _ in self?.placeSticker(s) }, for: .touchUpInside)
            b.menu = UIMenu(children: [
                UIAction(title: L("刪除貼紙"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    StickerStore.shared.remove(s.id)
                    if self?.tool == .sticker { self?.rebuildSubBar() }
                },
            ])
            stack.addArrangedSubview(b)
        }
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
            strip.heightAnchor.constraint(equalToConstant: 44),
            fit,
        ])
        views.append(strip)
        return views
    }

    func presentStickerPicker() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 5
        let picker = PHPickerViewController(configuration: config)
        let delegate = StickerPhotoPicker()
        delegate.onPick = { [weak self] images in self?.makeStickers(from: images) }
        stickerPicker = delegate
        picker.delegate = delegate
        present(picker, animated: true)
    }

    /// 在背景去背（Vision 比較慢），做好就加進貼紙
    func makeStickers(from images: [UIImage], then done: (() -> Void)? = nil) {
        guard !images.isEmpty else { return }
        showToast(L("正在去背，做成貼紙…"))
        DispatchQueue.global(qos: .userInitiated).async {
            let made = images.map { StickerMaker.makeSticker(from: $0) }
            DispatchQueue.main.async { [weak self] in
                for img in made { StickerStore.shared.add(img) }
                self?.showToast(L("已加到貼紙"))
                if self?.tool == .sticker { self?.rebuildSubBar() }
                done?()
            }
        }
    }

    /// 點貼紙：貼到畫面中央（同一頁連續貼往右下錯開），留在貼紙工具可以接著貼
    @discardableResult
    func placeSticker(_ s: StickerRecord) -> ElementRef? {
        guard !pages.isEmpty, let img = StickerStore.shared.image(for: s) else { return nil }
        guard let file = session.saveImage(img, jpeg: false) else { return nil }
        let r = visibleDocRect()
        let pi = currentPageIndex
        let o = contentOrigin(pi)
        var c = CGPoint(x: r.midX, y: r.midY)
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
