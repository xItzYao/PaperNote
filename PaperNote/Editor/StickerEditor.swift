import UIKit
import AVFoundation
import CoreImage
import Vision

/// 做貼紙前先選裁切範圍、要不要去背。去背時被選中的主體四周有一圈會動的藍色虛線；
/// 用 Apple Pencil 塗「保留」多留一些、塗「去掉」拿掉不要的部分（手指拖裁切框）
final class StickerEditorViewController: UIViewController {
    var onDone: ((UIImage) -> Void)?

    /// 方向轉正、縮小過的原圖（像素＝點）
    let image: UIImage
    /// 裁切範圍（0…1，相對原圖，左上角為原點）
    var unitCrop = CGRect(x: 0, y: 0, width: 1, height: 1) {
        didSet { layoutOverlay() }
    }
    /// 要不要去背（認不出主體時預設關掉）
    private(set) var removeBackground = true
    private(set) var maskState: MaskState = .computing
    enum MaskState { case computing, ready, unavailable }

    /// 可以塗改的遮罩（白＝留下來），和原圖一樣大（像素）
    private(set) var maskCanvas: StickerMaskCanvas?
    /// 塗的是「保留」還是「去掉」
    private(set) var brushKeeps = true
    /// 筆刷在畫面上的粗細
    static let brushWidth: CGFloat = 24

    private let container = UIView()
    private let imageView = UIImageView()
    /// 主體的外框：白色底線＋會動的藍色虛線
    let outlineLayer = CAShapeLayer()
    private let outlineBase = CAShapeLayer()
    /// 正在塗的那一筆（放開才寫進遮罩、重算外框）
    private let brushPreview = CAShapeLayer()
    private var brushPoints: [CGPoint] = []
    let cropView = StickerCropView()
    let backgroundSwitch = UISwitch()
    let brushMode = UISegmentedControl(items: [L("保留"), L("去掉")])
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private(set) var brushPan: UIPanGestureRecognizer!
    private var outlineJob = 0

    init(image: UIImage) {
        self.image = StickerMaker.normalized(image)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 主體的遮罩（白＝主體）；nil＝還沒算好、認不出來又還沒塗
    var mask: CIImage? { maskCanvas?.ciImage }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("製作貼紙")
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        let done = UIBarButtonItem(primaryAction: UIAction(title: L("加入")) { [weak self] _ in self?.finish() })
        done.style = .done
        navigationItem.rightBarButtonItem = done

        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .secondarySystemBackground
        view.addSubview(container)
        imageView.image = image
        imageView.contentMode = .scaleToFill
        container.addSubview(imageView)

        outlineBase.fillColor = nil
        outlineBase.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        outlineBase.lineWidth = 4
        outlineBase.lineJoin = .round
        outlineLayer.fillColor = nil
        outlineLayer.strokeColor = UIColor.systemBlue.cgColor
        outlineLayer.lineWidth = 2
        outlineLayer.lineJoin = .round
        outlineLayer.lineDashPattern = [7, 5]
        brushPreview.fillColor = nil
        brushPreview.lineCap = .round
        brushPreview.lineJoin = .round
        brushPreview.lineWidth = Self.brushWidth
        for l in [outlineBase, outlineLayer, brushPreview] { container.layer.addSublayer(l) }

        cropView.onChange = { [weak self] r in self?.cropChanged(r) }
        container.addSubview(cropView)
        // Pencil 塗遮罩；手指拖裁切框（開了「用手指書寫」手指也能塗）
        brushPan = UIPanGestureRecognizer(target: self, action: #selector(handleBrush(_:)))
        brushPan.maximumNumberOfTouches = 1
        cropView.addGestureRecognizer(brushPan)

        let label = UILabel()
        label.text = L("去背")
        label.font = .preferredFont(forTextStyle: .headline)
        backgroundSwitch.isOn = true
        backgroundSwitch.isEnabled = false
        backgroundSwitch.accessibilityIdentifier = "sticker.removeBackground"
        backgroundSwitch.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setRemoveBackground(self.backgroundSwitch.isOn)
        }, for: .valueChanged)
        brushMode.selectedSegmentIndex = 0
        brushMode.accessibilityIdentifier = "sticker.brushMode"
        brushMode.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setBrushKeeps(self.brushMode.selectedSegmentIndex == 0)
        }, for: .valueChanged)
        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .secondaryLabel
        status.numberOfLines = 2
        spinner.hidesWhenStopped = true
        spinner.startAnimating()
        let bar = UIStackView(arrangedSubviews: [label, backgroundSwitch, brushMode, spinner, status])
        bar.spacing = 12
        bar.alignment = .center
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            container.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -12),
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            bar.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        setBrushKeeps(true)
        updateTouchRoles()
        updateStatus()
        computeMask()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startMarching()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutOverlay()
    }

    /// 原圖在畫面上的位置（等比例放進 container，四周留空間給裁切框的把手）
    var imageRect: CGRect {
        let area = container.bounds.insetBy(dx: 28, dy: 28)
        guard area.width > 0, area.height > 0 else { return .zero }
        return AVMakeRect(aspectRatio: image.size, insideRect: area)
    }

    private var lastOutlineRect: CGRect = .zero

    private func layoutOverlay() {
        guard isViewLoaded else { return }
        let r = imageRect
        imageView.frame = r
        cropView.frame = container.bounds
        cropView.bounds_ = r
        cropView.cropRect = CGRect(x: r.minX + unitCrop.minX * r.width, y: r.minY + unitCrop.minY * r.height,
                                   width: unitCrop.width * r.width, height: unitCrop.height * r.height)
        if r != lastOutlineRect {
            lastOutlineRect = r
            refreshOutline()
        }
    }

    private func cropChanged(_ r: CGRect) {
        let ir = imageRect
        guard ir.width > 0, ir.height > 0 else { return }
        let u = CGRect(x: (r.minX - ir.minX) / ir.width, y: (r.minY - ir.minY) / ir.height,
                       width: r.width / ir.width, height: r.height / ir.height)
        unitCrop = u.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// 虛線一直往前走（像選取範圍的螞蟻線）。視窗切換、App 到背景時系統會拿掉動畫：顯示外框時沒有就重新加上
    private func startMarching() {
        guard outlineLayer.animation(forKey: "march") == nil else { return }
        let a = CABasicAnimation(keyPath: "lineDashPhase")
        a.isRemovedOnCompletion = false
        a.fromValue = 0
        a.toValue = -12
        a.duration = 0.6
        a.repeatCount = .infinity
        outlineLayer.add(a, forKey: "march")
    }

    private func computeMask() {
        let img = image
        DispatchQueue.global(qos: .userInitiated).async {
            let m = StickerMaker.subjectMask(img)
            DispatchQueue.main.async { [weak self] in self?.maskComputed(m) }
        }
    }

    /// 遮罩算好了（測試也直接呼叫）。認不出主體：還是可以打開去背、用 Pencil 塗出要保留的部分
    func maskComputed(_ m: CIImage?) {
        spinner.stopAnimating()
        maskState = m == nil ? .unavailable : .ready
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        maskCanvas = StickerMaskCanvas(size: px, initial: m)
        backgroundSwitch.isEnabled = true
        setRemoveBackground(m != nil && removeBackground)
    }

    func setRemoveBackground(_ on: Bool) {
        removeBackground = on
        backgroundSwitch.isOn = on
        brushMode.isHidden = !on || maskCanvas == nil
        updateTouchRoles()
        refreshOutline()
        updateStatus()
    }

    func setBrushKeeps(_ keep: Bool) {
        brushKeeps = keep
        brushMode.selectedSegmentIndex = keep ? 0 : 1
        brushPreview.strokeColor = (keep ? UIColor.systemBlue : UIColor.systemRed).withAlphaComponent(0.35).cgColor
    }

    /// 誰做什麼：去背時 Pencil 塗遮罩、手指拖裁切框；沒去背時都拖裁切框
    private func updateTouchRoles() {
        guard isViewLoaded else { return }
        let brushing = removeBackground && maskCanvas != nil
        let finger = EditorSettings.shared.fingerDrawing
        var brushTypes: [UITouch.TouchType] = [.pencil]
        if finger { brushTypes.append(.direct) }
        brushPan.isEnabled = brushing
        brushPan.allowedTouchTypes = brushTypes.map { NSNumber(value: $0.rawValue) }
        let cropTypes: [UITouch.TouchType] = brushing ? (finger ? [] : [.direct]) : [.direct, .pencil]
        cropView.panGesture.allowedTouchTypes = cropTypes.map { NSNumber(value: $0.rawValue) }
    }

    private func updateStatus() {
        switch maskState {
        case .computing: status.text = L("正在找主體…")
        case .unavailable:
            status.text = removeBackground ? L("用 Pencil 塗出要保留的部分；手指拖曳框框選裁切範圍") : L("認不出主體，打開去背可以用 Pencil 自己塗")
        case .ready:
            status.text = removeBackground ? L("藍色虛線裡的會留下來；用 Pencil 塗「保留」「去掉」修改，手指拖曳框框選裁切範圍")
                                           : L("拖曳框框選裁切範圍")
        }
    }

    // MARK: 塗遮罩

    @objc private func handleBrush(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: cropView)
        switch g.state {
        case .began:
            let t = g.translation(in: cropView)
            brushPoints = [CGPoint(x: p.x - t.x, y: p.y - t.y), p]
            updateBrushPreview()
        case .changed:
            brushPoints.append(p)
            updateBrushPreview()
        case .ended:
            brushPoints.append(p)
            paint(brushPoints, keep: brushKeeps)
            brushPoints = []
            updateBrushPreview()
        default:
            brushPoints = []
            updateBrushPreview()
        }
    }

    private func updateBrushPreview() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if brushPoints.isEmpty {
            brushPreview.path = nil
        } else {
            let path = UIBezierPath()
            path.move(to: brushPoints[0])
            for q in brushPoints.dropFirst() { path.addLine(to: q) }
            brushPreview.path = path.cgPath
        }
        CATransaction.commit()
    }

    /// 在畫面上（cropView 座標）塗一筆：keep＝保留（加進遮罩），否則去掉。測試也直接呼叫
    func paint(_ points: [CGPoint], keep: Bool) {
        let r = imageRect
        guard let canvas = maskCanvas, r.width > 0, !points.isEmpty else { return }
        let k = canvas.size.width / r.width
        let px = points.map { CGPoint(x: ($0.x - r.minX) * k, y: ($0.y - r.minY) * k) }
        canvas.stroke(px, width: Self.brushWidth * k, keep: keep)
        refreshOutline()
    }

    /// 重算主體的外框（Vision 找遮罩的邊，背景執行緒算）
    private func refreshOutline() {
        outlineJob += 1
        let job = outlineJob
        guard removeBackground, let cg = maskCanvas?.cgImage else {
            setOutline(nil)
            return
        }
        let r = imageRect
        DispatchQueue.global(qos: .userInitiated).async {
            let path = StickerMaker.outline(of: cg, in: r)
            DispatchQueue.main.async { [weak self] in
                guard let self, job == self.outlineJob else { return }
                self.setOutline(path)
            }
        }
    }

    private func setOutline(_ path: CGPath?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outlineLayer.path = path
        outlineBase.path = path
        CATransaction.commit()
        if path != nil { startMarching() }
    }

    /// 裁切範圍（原圖的像素）
    var pixelCrop: CGRect {
        let w = image.size.width * image.scale, h = image.size.height * image.scale
        return CGRect(x: unitCrop.minX * w, y: unitCrop.minY * h, width: unitCrop.width * w, height: unitCrop.height * h)
    }

    /// 照目前的裁切、去背（含塗改）做出貼紙
    func makeSticker() -> UIImage {
        StickerMaker.render(image, crop: pixelCrop, mask: removeBackground ? mask : nil)
    }

    private func finish() {
        let sticker = makeSticker()
        let done = onDone
        dismiss(animated: true) { done?(sticker) }
    }
}

/// 可以塗改的遮罩：灰階點陣圖（白＝留下來），左上角為原點、單位是原圖的像素
final class StickerMaskCanvas {
    let size: CGSize
    private let context: CGContext

    init?(size: CGSize, initial: CIImage?) {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        self.size = CGSize(width: w, height: h)
        context = ctx
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // 先照原本的方向畫進去（還沒翻轉座標），之後塗的用左上角為原點
        if let initial, let cg = CIContext().createCGImage(initial, from: initial.extent) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
    }

    /// 塗一筆（像素座標，左上角為原點）
    func stroke(_ points: [CGPoint], width: CGFloat, keep: Bool) {
        guard let first = points.first else { return }
        context.setStrokeColor(gray: keep ? 1 : 0, alpha: 1)
        context.setFillColor(gray: keep ? 1 : 0, alpha: 1)
        context.setLineWidth(width)
        if points.count == 1 {
            context.fillEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
            return
        }
        context.beginPath()
        context.move(to: first)
        for p in points.dropFirst() { context.addLine(to: p) }
        context.strokePath()
    }

    var cgImage: CGImage? { context.makeImage() }
    var ciImage: CIImage? { cgImage.map { CIImage(cgImage: $0) } }

    /// 這一點（像素座標，左上角為原點）會不會留下來（測試用）
    func keeps(_ p: CGPoint) -> Bool {
        guard let cg = cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let x = Int(p.x), y = Int(p.y)
        guard x >= 0, y >= 0, x < cg.width, y < cg.height else { return false }
        return bytes[y * cg.bytesPerRow + x] > 127
    }
}

extension StickerMaker {
    /// 遮罩（白＝留下來）的外框，換到畫面上 rect 的位置；找不到邊回傳 nil
    static func outline(of mask: CGImage, in rect: CGRect) -> CGPath? {
        let request = VNDetectContoursRequest()
        request.detectsDarkOnLight = false
        request.contrastAdjustment = 1
        request.maximumImageDimension = 512
        let handler = VNImageRequestHandler(cgImage: mask, options: [:])
        do {
            try handler.perform([request])
        } catch {
            DebugLog.add("sticker: outline failed \(error.localizedDescription)")
            return nil
        }
        guard let obs = request.results?.first, obs.contourCount > 0 else { return nil }
        // Vision 的座標 0…1、原點在左下角
        var t = CGAffineTransform(translationX: rect.minX, y: rect.maxY).scaledBy(x: rect.width, y: -rect.height)
        return obs.normalizedPath.copy(using: &t)
    }
}

/// 裁切框：框外變暗，拖曳四個角改大小、拖曳框內移動
final class StickerCropView: UIView {
    var onChange: ((CGRect) -> Void)?
    /// 框只能在這個範圍裡（圖片在畫面上的位置）
    var bounds_: CGRect = .zero
    var cropRect: CGRect = .zero { didSet { redraw() } }
    static let minSide: CGFloat = 40
    private(set) var panGesture: UIPanGestureRecognizer!

    private let dim = CAShapeLayer()
    private let border = CAShapeLayer()
    private let handles = CAShapeLayer()

    private enum Drag { case move, corner(Int) }
    private var drag: Drag?
    private var startRect: CGRect = .zero
    private var startPoint: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        dim.fillRule = .evenOdd
        dim.fillColor = UIColor.black.withAlphaComponent(0.45).cgColor
        border.fillColor = nil
        border.strokeColor = UIColor.white.cgColor
        border.lineWidth = 2
        border.shadowOpacity = 0.4
        border.shadowRadius = 2
        border.shadowOffset = .zero
        handles.fillColor = UIColor.white.cgColor
        handles.shadowOpacity = 0.4
        handles.shadowRadius = 2
        handles.shadowOffset = .zero
        for l in [dim, border, handles] { layer.addSublayer(l) }
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.maximumNumberOfTouches = 1
        addGestureRecognizer(panGesture)
        accessibilityIdentifier = "sticker.crop"
    }

    required init?(coder: NSCoder) { fatalError() }

    var corners: [CGPoint] {
        let r = cropRect
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let outer = UIBezierPath(rect: bounds_)
        outer.append(UIBezierPath(rect: cropRect))
        dim.path = outer.cgPath
        border.path = UIBezierPath(rect: cropRect).cgPath
        let h = UIBezierPath()
        for c in corners { h.append(UIBezierPath(ovalIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18))) }
        handles.path = h.cgPath
        CATransaction.commit()
    }

    /// 這一點開始拖曳要做什麼：靠近角就改大小，框內就移動
    private func dragKind(at p: CGPoint) -> Drag? {
        if let i = corners.indices.min(by: { corners[$0].distance(to: p) < corners[$1].distance(to: p) }),
           corners[i].distance(to: p) < 36 { return .corner(i) }
        return cropRect.contains(p) ? .move : nil
    }

    /// 拖曳（測試也直接呼叫）：from 開始的位置，to 現在的位置
    func dragged(from: CGPoint, to: CGPoint, began: Bool) {
        if began {
            drag = dragKind(at: from)
            startRect = cropRect
            startPoint = from
        }
        guard let drag else { return }
        let dx = to.x - startPoint.x, dy = to.y - startPoint.y
        let lim = bounds_
        let m = Self.minSide
        var r = startRect
        switch drag {
        case .move:
            r.origin.x = min(max(lim.minX, r.minX + dx), lim.maxX - r.width)
            r.origin.y = min(max(lim.minY, r.minY + dy), lim.maxY - r.height)
        case .corner(let i):
            var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
            if i == 0 || i == 3 { minX = min(max(lim.minX, minX + dx), maxX - m) } else { maxX = max(min(lim.maxX, maxX + dx), minX + m) }
            if i == 0 || i == 1 { minY = min(max(lim.minY, minY + dy), maxY - m) } else { maxY = max(min(lim.maxY, maxY + dy), minY + m) }
            r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        cropRect = r
        onChange?(r)
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            let t = g.translation(in: self)
            dragged(from: CGPoint(x: p.x - t.x, y: p.y - t.y), to: p, began: true)
        case .changed:
            dragged(from: startPoint, to: p, began: false)
        default:
            drag = nil
        }
    }
}
