import UIKit

/// 類似 Snipaste 的「貼圖」：截圖釘在畫面最上層，換頁、換筆記本都會留著。
struct PinRecord: Codable, Equatable, Identifiable {
    var id = UUID()
    var file: String
    var center: CGPoint
    var width: CGFloat
    var alpha: CGFloat = 1
    var collapsed = false
    /// nil：所有分頁都顯示；有值：只在這本筆記本顯示
    var notebookID: UUID? = nil
}

final class PinStore {
    static let shared = PinStore()

    private(set) var pins: [PinRecord] = []
    private let dir: URL
    private var indexURL: URL { dir.appendingPathComponent("pins.json") }
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = support.appendingPathComponent("Pins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([PinRecord].self, from: data) {
            pins = saved.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.file).path) }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(pins) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    func image(for pin: PinRecord) -> UIImage? {
        if let img = cache.object(forKey: pin.file as NSString) { return img }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(pin.file)),
              let img = UIImage(data: data, scale: 2) else { return nil }
        cache.setObject(img, forKey: pin.file as NSString)
        return img
    }

    @discardableResult
    func add(image: UIImage, center: CGPoint, width: CGFloat, notebookID: UUID?) -> PinRecord? {
        let file = "pin-\(UUID().uuidString).png"
        guard let data = image.pngData() else { return nil }
        try? data.write(to: dir.appendingPathComponent(file), options: .atomic)
        var pin = PinRecord(file: file, center: center, width: width)
        pin.notebookID = notebookID
        pins.append(pin)
        persist()
        return pin
    }

    func update(_ pin: PinRecord) {
        guard let i = pins.firstIndex(where: { $0.id == pin.id }) else { return }
        pins[i] = pin
        persist()
    }

    func remove(_ id: UUID) {
        guard let pin = pins.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(pin.file))
        pins.removeAll { $0.id == id }
        persist()
    }

    func removeAll() {
        for p in pins { remove(p.id) }
    }
}

/// 只有貼圖本身接收觸控，其他地方穿透到底下的筆記
final class PinOverlayView: UIView {
    var onInsertIntoPage: ((UIImage) -> Void)?
    /// 目前分頁的筆記本（只顯示共用的和屬於這本的貼圖）
    var notebookID: UUID?
    private var views: [UUID: PinView] = [:]

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let v = super.hitTest(point, with: event)
        return v === self ? nil : v
    }

    func reload() {
        for v in views.values { v.removeFromSuperview() }
        views = [:]
        for pin in PinStore.shared.pins where pin.notebookID == nil || pin.notebookID == notebookID {
            addView(for: pin)
        }
    }

    func addPin(image: UIImage, near rect: CGRect) {
        // 和截取時在螢幕上看到的大小一樣
        let maxW = min(bounds.width * 0.6, 700)
        let w = min(max(rect.width, 120), maxW)
        var c = CGPoint(x: rect.maxX + w / 2 + 16, y: rect.midY)
        if c.x + w / 2 > bounds.width - 8 { c.x = bounds.width - w / 2 - 16 }
        // 新釘選的圖片一律先在所有分頁顯示，需要時再用圖片上的按鈕切換
        guard let pin = PinStore.shared.add(image: image, center: c, width: w, notebookID: nil) else { return }
        addView(for: pin)
    }

    private func addView(for pin: PinRecord) {
        guard let img = PinStore.shared.image(for: pin) else { return }
        let v = PinView(pin: pin, image: img)
        v.onClose = { [weak self, weak v] in
            guard let v else { return }
            PinStore.shared.remove(v.pin.id)
            v.removeFromSuperview()
            self?.views[v.pin.id] = nil
        }
        v.onInsert = { [weak self] image in self?.onInsertIntoPage?(image) }
        v.currentNotebook = { [weak self] in self?.notebookID }
        addSubview(v)
        views[pin.id] = v
        v.applyRecord()
    }

    func clampAll() {
        for v in views.values { v.clampIntoSuperview() }
    }
}

final class PinView: UIView, UIGestureRecognizerDelegate {
    private(set) var pin: PinRecord
    private let image: UIImage
    private let imageView = UIImageView()
    private let bar = UIStackView()
    private let resizeHandle = UIImageView()
    private var mainPan: UIPanGestureRecognizer!
    private var resizeStartWidth: CGFloat = 0
    private var resizeStartOrigin: CGPoint = .zero
    var onClose: (() -> Void)?
    var onInsert: ((UIImage) -> Void)?
    var currentNotebook: (() -> UUID?)?
    private var scopeButton: UIButton?

    private var aspect: CGFloat { image.size.height / max(image.size.width, 1) }

    init(pin: PinRecord, image: UIImage) {
        self.pin = pin
        self.image = image
        super.init(frame: .zero)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .white
        imageView.layer.cornerRadius = 6
        imageView.layer.borderColor = UIColor.systemTeal.cgColor
        imageView.layer.borderWidth = 1.5
        imageView.clipsToBounds = true
        addSubview(imageView)

        bar.axis = .horizontal
        bar.spacing = 2
        bar.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        bar.layer.cornerRadius = 14
        bar.isLayoutMarginsRelativeArrangement = true
        bar.layoutMargins = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        for (symbol, action) in [(scopeSymbol, #selector(scopeTapped)),
                                 ("square.and.arrow.down.on.square", #selector(insertTapped)),
                                 ("circle.lefthalf.filled", #selector(alphaTapped)),
                                 ("xmark", #selector(closeTapped))] {
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)), for: .normal)
            b.tintColor = .white
            b.addTarget(self, action: action, for: .touchUpInside)
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true
            bar.addArrangedSubview(b)
            if action == #selector(scopeTapped) { scopeButton = b }
        }
        addSubview(bar)

        // 右下角縮放控制點
        resizeHandle.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right",
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        resizeHandle.tintColor = .white
        resizeHandle.contentMode = .center
        resizeHandle.backgroundColor = UIColor.systemTeal
        resizeHandle.layer.cornerRadius = 15
        resizeHandle.layer.borderColor = UIColor.white.cgColor
        resizeHandle.layer.borderWidth = 2
        resizeHandle.isUserInteractionEnabled = true
        addSubview(resizeHandle)
        let resizePan = UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
        resizePan.maximumNumberOfTouches = 1
        resizeHandle.addGestureRecognizer(resizePan)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
        mainPan = pan
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        let dbl = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        dbl.numberOfTapsRequired = 2
        addGestureRecognizer(dbl)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || resizeHandle.frame.contains(point)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // 拖縮放點時不要同時移動整張圖
        !(other.view === resizeHandle || g.view === resizeHandle)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g === mainPan, touch.view === resizeHandle { return false }
        return true
    }

    private var displayWidth: CGFloat { pin.collapsed ? min(pin.width, 110) : pin.width }

    func applyRecord() {
        let w = displayWidth
        let h = w * aspect
        bounds = CGRect(x: 0, y: 0, width: w, height: h + 34)
        center = pin.center
        imageView.frame = CGRect(x: 0, y: 34, width: w, height: h)
        bar.frame = CGRect(x: max(0, w - 136), y: 0, width: min(w, 136), height: 28)
        imageView.alpha = pin.alpha
        resizeHandle.frame = CGRect(x: w - 22, y: 34 + h - 22, width: 30, height: 30)
        resizeHandle.isHidden = pin.collapsed
        clampIntoSuperview()
    }

    /// 縮放時固定左上角
    @objc private func handleResize(_ g: UIPanGestureRecognizer) {
        guard let sv = superview else { return }
        switch g.state {
        case .began:
            resizeStartWidth = pin.width
            resizeStartOrigin = frame.origin
        case .changed, .ended:
            let t = g.translation(in: sv)
            // 往右或往下拉都能放大，取兩者平均
            let delta = (t.x + t.y / max(aspect, 0.01)) / 2
            pin.width = min(max(resizeStartWidth + delta, 80), sv.bounds.width * 0.95)
            let w = pin.width, h = w * aspect
            pin.center = CGPoint(x: resizeStartOrigin.x + w / 2, y: resizeStartOrigin.y + (h + 34) / 2)
            applyRecord()
            if g.state == .ended { save() }
        default:
            break
        }
    }

    func clampIntoSuperview() {
        guard let sv = superview else { return }
        // 至少留 60pt 在畫面內，才拖得回來
        var c = center
        let hw = bounds.width / 2, hh = bounds.height / 2
        c.x = min(max(center.x, 60 - hw), sv.bounds.width - 60 + hw)
        c.y = min(max(center.y, hh), sv.bounds.height - 40 + hh)
        center = c
    }

    private func save() {
        pin.center = center
        PinStore.shared.update(pin)
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: superview)
        center = CGPoint(x: center.x + t.x, y: center.y + t.y)
        g.setTranslation(.zero, in: superview)
        if g.state == .ended || g.state == .cancelled {
            clampIntoSuperview()
            save()
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard !pin.collapsed else { return }
        let maxW = (superview?.bounds.width ?? 1000) * 0.95
        pin.width = min(max(pin.width * g.scale, 80), maxW)
        g.scale = 1
        let c = center
        applyRecord()
        center = c
        if g.state == .ended || g.state == .cancelled { save() }
    }

    @objc private func handleDoubleTap() {
        pin.collapsed.toggle()
        pin.center = center
        applyRecord()
        save()
    }

    @objc private func insertTapped() { onInsert?(image) }

    private var scopeSymbol: String { pin.notebookID == nil ? "globe" : "doc.text" }

    /// 切換：所有分頁都顯示 ↔ 只在這本筆記本顯示
    @objc private func scopeTapped() {
        if pin.notebookID == nil {
            guard let nb = currentNotebook?() else { return }
            pin.notebookID = nb
        } else {
            pin.notebookID = nil
        }
        scopeButton?.setImage(UIImage(systemName: scopeSymbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)), for: .normal)
        save()
        showScopeHint()
    }

    private func showScopeHint() {
        let label = UILabel()
        label.text = pin.notebookID == nil ? "  所有分頁都會顯示  " : "  只在這本筆記本顯示  "
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.sizeToFit()
        label.frame.size.height = 24
        label.center = CGPoint(x: bounds.midX, y: 34 + 20)
        addSubview(label)
        UIView.animate(withDuration: 0.3, delay: 1.2, options: [], animations: { label.alpha = 0 }) { _ in label.removeFromSuperview() }
    }

    @objc private func alphaTapped() {
        pin.alpha = pin.alpha > 0.9 ? 0.6 : (pin.alpha > 0.5 ? 0.35 : 1)
        imageView.alpha = pin.alpha
        save()
    }

    @objc private func closeTapped() { onClose?() }
}
