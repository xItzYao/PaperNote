import UIKit
import AVFoundation
import CoreImage

/// 做貼紙前先選裁切範圍、要不要去背。去背會拿掉的地方蓋上會動的灰色斜線
final class StickerEditorViewController: UIViewController {
    var onDone: ((UIImage) -> Void)?

    /// 方向轉正、縮小過的原圖（像素＝點）
    let image: UIImage
    /// 裁切範圍（0…1，相對原圖，左上角為原點）
    var unitCrop = CGRect(x: 0, y: 0, width: 1, height: 1) {
        didSet { layoutOverlay() }
    }
    /// 要不要去背（認不出主體時會自己關掉）
    private(set) var removeBackground = true
    /// 主體的遮罩（白＝主體）；nil＝還沒算好或認不出來
    private(set) var mask: CIImage?
    private(set) var maskState: MaskState = .computing

    enum MaskState { case computing, ready, unavailable }

    private let container = UIView()
    private let imageView = UIImageView()
    /// 斜線（只蓋在背景上：mask 是背景的 alpha）
    private let stripes = CALayer()
    private let stripeClip = CALayer()
    private let stripeMask = CALayer()
    let cropView = StickerCropView()
    let backgroundSwitch = UISwitch()
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private static let stripePeriod: CGFloat = 18

    init(image: UIImage) {
        self.image = StickerMaker.normalized(image)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

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

        stripes.backgroundColor = UIColor(patternImage: Self.stripeTile()).cgColor
        stripeClip.masksToBounds = true
        stripeClip.addSublayer(stripes)
        stripeClip.mask = stripeMask
        stripeClip.isHidden = true
        container.layer.addSublayer(stripeClip)

        cropView.onChange = { [weak self] r in self?.cropChanged(r) }
        container.addSubview(cropView)

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
        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .secondaryLabel
        status.numberOfLines = 2
        spinner.hidesWhenStopped = true
        spinner.startAnimating()
        let bar = UIStackView(arrangedSubviews: [label, backgroundSwitch, spinner, status])
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
        updateStatus()
        startStripes()
        computeMask()
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

    private func layoutOverlay() {
        guard isViewLoaded else { return }
        let r = imageRect
        imageView.frame = r
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stripeClip.frame = r
        stripeMask.frame = stripeClip.bounds
        let p = Self.stripePeriod
        stripes.frame = CGRect(x: -p, y: 0, width: r.width + 2 * p, height: r.height)
        CATransaction.commit()
        cropView.frame = container.bounds
        cropView.bounds_ = r
        cropView.cropRect = CGRect(x: r.minX + unitCrop.minX * r.width, y: r.minY + unitCrop.minY * r.height,
                                   width: unitCrop.width * r.width, height: unitCrop.height * r.height)
    }

    private func cropChanged(_ r: CGRect) {
        let ir = imageRect
        guard ir.width > 0, ir.height > 0 else { return }
        let u = CGRect(x: (r.minX - ir.minX) / ir.width, y: (r.minY - ir.minY) / ir.height,
                       width: r.width / ir.width, height: r.height / ir.height)
        unitCrop = u.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func startStripes() {
        let a = CABasicAnimation(keyPath: "transform.translation.x")
        a.fromValue = 0
        a.toValue = Self.stripePeriod
        a.duration = 0.8
        a.repeatCount = .infinity
        stripes.add(a, forKey: "march")
    }

    /// 一格斜線（左右接起來是連續的 45° 斜線）
    static func stripeTile() -> UIImage {
        let p = stripePeriod
        let fmt = UIGraphicsImageRendererFormat()
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: p, height: p), format: fmt).image { rc in
            let ctx = rc.cgContext
            UIColor(white: 1, alpha: 0.35).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: p, height: p))
            UIColor.systemGray.withAlphaComponent(0.8).setStroke()
            ctx.setLineWidth(p * 0.35)
            for x0 in [-p, 0, p] {
                ctx.move(to: CGPoint(x: x0, y: p))
                ctx.addLine(to: CGPoint(x: x0 + p, y: 0))
            }
            ctx.strokePath()
        }
    }

    private func computeMask() {
        let img = image
        DispatchQueue.global(qos: .userInitiated).async {
            let m = StickerMaker.subjectMask(img)
            let bg = m.flatMap { StickerMaker.backgroundAlpha($0) }
            DispatchQueue.main.async { [weak self] in self?.maskComputed(m, background: bg) }
        }
    }

    /// 遮罩算好了（測試也直接呼叫）
    func maskComputed(_ m: CIImage?, background: CGImage?) {
        spinner.stopAnimating()
        mask = m
        maskState = m == nil ? .unavailable : .ready
        stripeMask.contents = background
        backgroundSwitch.isEnabled = m != nil
        setRemoveBackground(m != nil && removeBackground)
    }

    func setRemoveBackground(_ on: Bool) {
        removeBackground = on
        backgroundSwitch.isOn = on
        stripeClip.isHidden = !(on && mask != nil)
        updateStatus()
    }

    private func updateStatus() {
        switch maskState {
        case .computing: status.text = L("正在找主體…")
        case .unavailable: status.text = L("認不出主體，只會裁切")
        case .ready: status.text = removeBackground ? L("斜線的部分會變透明；拖曳框框選裁切範圍") : L("拖曳框框選裁切範圍")
        }
    }

    /// 裁切範圍（原圖的像素）
    var pixelCrop: CGRect {
        let w = image.size.width * image.scale, h = image.size.height * image.scale
        return CGRect(x: unitCrop.minX * w, y: unitCrop.minY * h, width: unitCrop.width * w, height: unitCrop.height * h)
    }

    /// 照目前的裁切、去背做出貼紙
    func makeSticker() -> UIImage {
        StickerMaker.render(image, crop: pixelCrop, mask: removeBackground ? mask : nil)
    }

    private func finish() {
        let sticker = makeSticker()
        let done = onDone
        dismiss(animated: true) { done?(sticker) }
    }
}

/// 裁切框：框外變暗，拖曳四個角改大小、拖曳框內移動
final class StickerCropView: UIView {
    var onChange: ((CGRect) -> Void)?
    /// 框只能在這個範圍裡（圖片在畫面上的位置）
    var bounds_: CGRect = .zero
    var cropRect: CGRect = .zero { didSet { redraw() } }
    static let minSide: CGFloat = 40

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
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
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
