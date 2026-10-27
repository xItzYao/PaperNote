import UIKit

final class FastTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0.05 }
}

/// 頁面背景（紙張、螢光、PDF），用 CATiledLayer 讓放大時仍然清晰
final class PageBackgroundView: UIView {
    override class var layerClass: AnyClass { FastTiledLayer.self }

    private let lock = NSLock()
    private var _snapshot: BackgroundSnapshot?

    var snapshot: BackgroundSnapshot? {
        get { lock.lock(); defer { lock.unlock() }; return _snapshot }
        set {
            lock.lock(); _snapshot = newValue; lock.unlock()
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tiled = layer as! CATiledLayer
        tiled.tileSize = CGSize(width: 512, height: 512)
        tiled.levelsOfDetail = 6
        tiled.levelsOfDetailBias = 3
        backgroundColor = .white
        isOpaque = true
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let s = snapshot, let ctx = UIGraphicsGetCurrentContext() else { return }
        PageRenderer.drawBackground(s, in: ctx, clip: rect)
    }
}

/// 表格、文字框的顯示
final class DrawnElementView: UIView {
    var element: PageElement { didSet { setNeedsDisplay() } }
    weak var session: NotebookSession?

    init(element: PageElement, session: NotebookSession) {
        self.element = element
        self.session = session
        super.init(frame: element.frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        ElementRenderer.draw(element, in: bounds, session: session)
    }
}

/// 一個頁面：背景＋物件層。所有手勢都在畫布上處理，這裡不接收觸控。
final class PageContainerView: UIView {
    let pageID: UUID
    let background = PageBackgroundView()
    let elementsLayer = UIView()
    /// 自製筆刷的筆跡（畫在物件上面、PencilKit 筆跡底下）
    let inkView = PageInkView()
    private var elementViews: [UUID: UIView] = [:]
    private var lastPage: Page?

    init(pageID: UUID) {
        self.pageID = pageID
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .white
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(background)
        addSubview(elementsLayer)
        elementsLayer.clipsToBounds = false
        addSubview(inkView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(page: Page, session: NotebookSession, contentScale: CGFloat) {
        let size = session.fullSize(of: page)
        let base = session.baseSize(of: page)
        let bgChanged = lastPage == nil || lastPage!.insets != page.insets || lastPage!.highlights != page.highlights
            || lastPage!.background != page.background
        if bgChanged {
            background.frame = CGRect(origin: .zero, size: size)
            background.snapshot = session.backgroundSnapshot(for: page)
            layer.shadowPath = UIBezierPath(rect: CGRect(origin: .zero, size: size)).cgPath
        }
        elementsLayer.frame = CGRect(x: page.insets.left, y: page.insets.top, width: base.width, height: base.height)
        if inkView.frame.size != size { inkView.frame = CGRect(origin: .zero, size: size) }
        inkView.set(strokes: page.ink, offset: CGPoint(x: page.insets.left, y: page.insets.top), renderScale: contentScale)

        if lastPage == nil || lastPage!.elements != page.elements {
            var reuse = elementViews
            elementViews = [:]
            for e in page.elements {
                let view: UIView
                if let old = reuse.removeValue(forKey: e.id) {
                    view = old
                    if let iv = view as? UIImageView, case let .image(d) = e.content {
                        iv.image = session.image(named: d.file)
                    } else if let dv = view as? DrawnElementView, dv.element != e {
                        dv.element = e
                    }
                } else {
                    view = makeView(e, session: session)
                }
                view.frame = e.frame
                elementsLayer.addSubview(view)   // 重新加入維持疊放順序
                elementViews[e.id] = view
            }
            for v in reuse.values { v.removeFromSuperview() }
            updateContentScale(contentScale)
        }
        lastPage = page
    }

    private func makeView(_ e: PageElement, session: NotebookSession) -> UIView {
        switch e.content {
        case let .image(d):
            let iv = UIImageView(image: session.image(named: d.file))
            iv.contentMode = .scaleToFill
            iv.isUserInteractionEnabled = false
            return iv
        case .table, .text, .circuit:
            return DrawnElementView(element: e, session: session)
        }
    }

    func elementView(_ id: UUID) -> UIView? { elementViews[id] }

    /// 拖曳中即時更新，不重建整頁
    func liveUpdate(_ e: PageElement) {
        guard let v = elementViews[e.id] else { return }
        v.frame = e.frame
        if let dv = v as? DrawnElementView { dv.element = e }
    }

    func updateContentScale(_ scale: CGFloat) {
        for v in elementViews.values {
            if let dv = v as? DrawnElementView, abs(dv.contentScaleFactor - scale) > 0.01 {
                dv.contentScaleFactor = scale
                dv.setNeedsDisplay()
            }
        }
    }
}

/// 最上層：選取框、文字選取、截圖範圍（文件座標）
final class OverlayView: UIView {
    let selectionLayer = CAShapeLayer()
    let handleLayer = CAShapeLayer()
    let textLayer = CAShapeLayer()
    let captureLayer = CAShapeLayer()
    let tablePlusCircles = CAShapeLayer()
    let tablePlusMarks = CAShapeLayer()
    let gripLayer = CAShapeLayer()
    let pageContentLayer = CAShapeLayer()
    let pageOutlineLayer = CAShapeLayer()
    let pageHandleLayer = CAShapeLayer()
    let draftLayer = CAShapeLayer()
    let lassoPathLayer = CAShapeLayer()
    let circuitFrameLayer = CAShapeLayer()
    let circuitSelLayer = CAShapeLayer()
    let circuitDraftLayer = CAShapeLayer()
    let circuitInkLayer = CAShapeLayer()
    let circuitWireSelLayer = CAShapeLayer()
    let circuitHandleLayer = CAShapeLayer()
    let lassoSelLayer = CAShapeLayer()
    let lassoPreviewLayer = CALayer()
    let cellSelLayer = CAShapeLayer()
    let moveHandleLayer = CAShapeLayer()
    let moveHandleMarks = CAShapeLayer()
    /// 青綠色圓形控制點（和浮動圖片的縮放點同一風格）
    let moveHandleImage = CALayer()
    let resizeHandleImage = CALayer()
    let deleteHandleImage = CALayer()
    /// 電路元件旁的旋轉、水平翻轉按鈕
    let circuitRotateHandle = CALayer()
    let circuitFlipHandle = CALayer()
    let circuitDeleteHandle = CALayer()
    private static let handleSize: CGFloat = 30
    private var lockLayers: [CALayer] = []
    private static let lockedImage = lockImage(locked: true)
    private static let unlockedImage = lockImage(locked: false)

    private static func lockImage(locked: Bool) -> CGImage? {
        let size = CGSize(width: handleSize, height: handleSize)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 6
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
            let circle = UIBezierPath(ovalIn: r)
            (locked ? UIColor.systemOrange : UIColor.white).setFill()
            circle.fill()
            circle.lineWidth = 1.5
            (locked ? UIColor.white : UIColor.systemGray3).setStroke()
            circle.stroke()
            let symbol = locked ? "lock.fill" : "lock.open"
            if let img = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))?
                .withTintColor(locked ? .white : .darkGray, renderingMode: .alwaysOriginal) {
                img.draw(at: CGPoint(x: (size.width - img.size.width) / 2, y: (size.height - img.size.height) / 2))
            }
        }.cgImage
    }

    /// 表格旁的鎖頭（點一下鎖定／解鎖）
    func showLockIcons(_ items: [(CGPoint, Bool)]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while lockLayers.count < items.count {
            let l = CALayer()
            l.contentsGravity = .resizeAspect
            l.shadowColor = UIColor.black.cgColor
            l.shadowOpacity = 0.2
            l.shadowRadius = 2
            l.shadowOffset = CGSize(width: 0, height: 1)
            layer.addSublayer(l)
            lockLayers.append(l)
        }
        let s = Self.handleSize * lineScale
        for (i, l) in lockLayers.enumerated() {
            if i < items.count {
                let (p, locked) = items[i]
                l.contents = locked ? Self.lockedImage : Self.unlockedImage
                l.frame = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
                l.isHidden = false
            } else {
                l.isHidden = true
            }
        }
        CATransaction.commit()
    }

    private static func handleImage(_ symbol: String, color: UIColor = .systemTeal) -> CGImage? {
        let size = CGSize(width: handleSize, height: handleSize)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 6
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
            let circle = UIBezierPath(ovalIn: r)
            color.setFill()
            circle.fill()
            circle.lineWidth = 2
            UIColor.white.setStroke()
            circle.stroke()
            if let img = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                img.draw(at: CGPoint(x: (size.width - img.size.width) / 2, y: (size.height - img.size.height) / 2))
            }
        }.cgImage
    }

    var lineScale: CGFloat = 1 { didSet { updateLineWidths() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        textLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.25).cgColor
        layer.addSublayer(textLayer)

        cellSelLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.15).cgColor
        cellSelLayer.strokeColor = UIColor.systemBlue.cgColor
        layer.addSublayer(cellSelLayer)
        moveHandleLayer.fillColor = UIColor.systemBlue.cgColor
        moveHandleLayer.strokeColor = UIColor.white.cgColor
        layer.addSublayer(moveHandleLayer)
        moveHandleMarks.fillColor = UIColor.clear.cgColor
        moveHandleMarks.strokeColor = UIColor.white.cgColor
        moveHandleMarks.lineCap = .round
        layer.addSublayer(moveHandleMarks)
        for (l, symbol, color) in [(moveHandleImage, "arrow.up.and.down.and.arrow.left.and.right", UIColor.systemTeal),
                                   (resizeHandleImage, "arrow.up.left.and.arrow.down.right", UIColor.systemTeal),
                                   (deleteHandleImage, "xmark", UIColor.systemRed),
                                   (circuitRotateHandle, "rotate.right", UIColor.systemBlue),
                                   (circuitFlipHandle, "arrow.left.and.right", UIColor.systemBlue),
                                   (circuitDeleteHandle, "trash", UIColor.systemRed)] {
            l.contents = Self.handleImage(symbol, color: color)
            l.contentsGravity = .resizeAspect
            l.shadowColor = UIColor.black.cgColor
            l.shadowOpacity = 0.25
            l.shadowRadius = 3
            l.shadowOffset = CGSize(width: 0, height: 1)
            l.isHidden = true
            layer.addSublayer(l)
        }

        selectionLayer.fillColor = UIColor.clear.cgColor
        selectionLayer.lineDashPattern = [6, 4]
        layer.addSublayer(selectionLayer)

        handleLayer.fillColor = UIColor.white.cgColor
        handleLayer.strokeColor = UIColor.systemBlue.cgColor
        layer.addSublayer(handleLayer)

        captureLayer.fillColor = UIColor.systemTeal.withAlphaComponent(0.08).cgColor
        captureLayer.strokeColor = UIColor.systemTeal.cgColor
        captureLayer.lineDashPattern = [8, 5]
        layer.addSublayer(captureLayer)

        gripLayer.fillColor = UIColor.systemBlue.cgColor
        gripLayer.strokeColor = UIColor.white.cgColor
        layer.addSublayer(gripLayer)

        tablePlusCircles.fillColor = UIColor.white.cgColor
        tablePlusCircles.strokeColor = UIColor.systemBlue.cgColor
        layer.addSublayer(tablePlusCircles)
        tablePlusMarks.fillColor = UIColor.clear.cgColor
        tablePlusMarks.strokeColor = UIColor.systemBlue.cgColor
        tablePlusMarks.lineCap = .round
        layer.addSublayer(tablePlusMarks)

        pageContentLayer.fillColor = UIColor.clear.cgColor
        pageContentLayer.strokeColor = UIColor.systemGray.cgColor
        layer.addSublayer(pageContentLayer)
        pageOutlineLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.04).cgColor
        pageOutlineLayer.strokeColor = UIColor.systemBlue.cgColor
        layer.addSublayer(pageOutlineLayer)
        pageHandleLayer.fillColor = UIColor.white.cgColor
        pageHandleLayer.strokeColor = UIColor.systemBlue.cgColor
        layer.addSublayer(pageHandleLayer)

        // 手繪表格預覽，線寬就是表格實際線寬（文件單位）
        draftLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.05).cgColor
        draftLayer.strokeColor = UIColor(hex: "#333333FF").cgColor
        draftLayer.lineWidth = 2
        draftLayer.lineCap = .round
        layer.addSublayer(draftLayer)

        circuitFrameLayer.fillColor = UIColor.clear.cgColor
        circuitFrameLayer.strokeColor = UIColor.systemGray3.cgColor
        layer.addSublayer(circuitFrameLayer)
        circuitSelLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        circuitSelLayer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.6).cgColor
        circuitSelLayer.lineCap = .round
        circuitSelLayer.lineJoin = .round
        layer.addSublayer(circuitSelLayer)
        circuitWireSelLayer.fillColor = UIColor.clear.cgColor
        circuitWireSelLayer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.35).cgColor
        circuitWireSelLayer.lineCap = .round
        circuitWireSelLayer.lineJoin = .round
        layer.addSublayer(circuitWireSelLayer)
        circuitHandleLayer.fillColor = UIColor.white.cgColor
        circuitHandleLayer.strokeColor = UIColor.systemBlue.cgColor
        layer.addSublayer(circuitHandleLayer)
        circuitInkLayer.fillColor = UIColor.clear.cgColor
        circuitInkLayer.strokeColor = UIColor.systemGray.withAlphaComponent(0.45).cgColor
        circuitInkLayer.lineWidth = 2
        circuitInkLayer.lineCap = .round
        circuitInkLayer.lineJoin = .round
        layer.addSublayer(circuitInkLayer)
        circuitDraftLayer.fillColor = UIColor.clear.cgColor
        circuitDraftLayer.strokeColor = UIColor.systemBlue.cgColor
        circuitDraftLayer.lineWidth = 2
        circuitDraftLayer.lineCap = .round
        circuitDraftLayer.lineJoin = .round
        layer.addSublayer(circuitDraftLayer)
        lassoPreviewLayer.contentsGravity = .resize
        lassoPreviewLayer.isHidden = true
        layer.addSublayer(lassoPreviewLayer)
        lassoPathLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.05).cgColor
        lassoPathLayer.strokeColor = UIColor.systemBlue.cgColor
        layer.addSublayer(lassoPathLayer)
        lassoSelLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
        lassoSelLayer.strokeColor = UIColor.systemBlue.cgColor
        layer.addSublayer(lassoSelLayer)

        updateLineWidths()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateLineWidths() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.lineWidth = 2 * lineScale
        selectionLayer.lineDashPattern = [NSNumber(value: Double(6 * lineScale)), NSNumber(value: Double(4 * lineScale))]
        handleLayer.lineWidth = 2 * lineScale
        captureLayer.lineWidth = 2 * lineScale
        captureLayer.lineDashPattern = [NSNumber(value: Double(8 * lineScale)), NSNumber(value: Double(5 * lineScale))]
        gripLayer.lineWidth = 1.5 * lineScale
        tablePlusCircles.lineWidth = 1.5 * lineScale
        tablePlusMarks.lineWidth = 2 * lineScale
        pageContentLayer.lineWidth = 1 * lineScale
        pageContentLayer.lineDashPattern = [NSNumber(value: Double(4 * lineScale)), NSNumber(value: Double(4 * lineScale))]
        pageOutlineLayer.lineWidth = 2 * lineScale
        pageOutlineLayer.lineDashPattern = [NSNumber(value: Double(8 * lineScale)), NSNumber(value: Double(5 * lineScale))]
        pageHandleLayer.lineWidth = 2 * lineScale
        cellSelLayer.lineWidth = 2 * lineScale
        circuitFrameLayer.lineWidth = 1 * lineScale
        circuitFrameLayer.lineDashPattern = [NSNumber(value: Double(5 * lineScale)), NSNumber(value: Double(4 * lineScale))]
        circuitSelLayer.lineWidth = 6 * lineScale
        circuitWireSelLayer.lineWidth = 8 * lineScale
        circuitHandleLayer.lineWidth = 1.5 * lineScale
        circuitInkLayer.lineWidth = 2 * lineScale
        for l in [lassoPathLayer, lassoSelLayer] {
            l.lineWidth = 1.5 * lineScale
            l.lineDashPattern = [NSNumber(value: Double(6 * lineScale)), NSNumber(value: Double(4 * lineScale))]
        }
        moveHandleLayer.lineWidth = 1.5 * lineScale
        moveHandleMarks.lineWidth = 2 * lineScale
        CATransaction.commit()
    }

    // MARK: 電路圖

    func showCircuit(frame: CGRect?, selection: UIBezierPath?, wire: UIBezierPath? = nil, handles: UIBezierPath? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circuitFrameLayer.path = frame.map { UIBezierPath(rect: $0).cgPath }
        circuitSelLayer.path = selection?.cgPath
        circuitWireSelLayer.path = wire?.cgPath
        circuitHandleLayer.path = handles?.cgPath
        CATransaction.commit()
    }

    /// 接線預覽：排好的直角導線，加上淡淡的原始筆跡
    func showCircuitDraft(_ pts: [CGPoint]?, ink: [CGPoint]?) {
        func polyline(_ pts: [CGPoint]?) -> CGPath? {
            guard let pts, let first = pts.first else { return nil }
            let p = UIBezierPath()
            p.move(to: first)
            for q in pts.dropFirst() { p.addLine(to: q) }
            return p.cgPath
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circuitDraftLayer.path = polyline(pts)
        circuitInkLayer.path = polyline(ink)
        CATransaction.commit()
    }

    // MARK: 套索

    func showLassoPath(_ pts: [CGPoint]?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let pts, let first = pts.first {
            let path = UIBezierPath()
            path.move(to: first)
            for p in pts.dropFirst() { path.addLine(to: p) }
            lassoPathLayer.path = path.cgPath
        } else {
            lassoPathLayer.path = nil
        }
        CATransaction.commit()
    }

    func showLassoSelection(_ rect: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lassoSelLayer.path = rect.map { UIBezierPath(roundedRect: $0.insetBy(dx: -6 * lineScale, dy: -6 * lineScale), cornerRadius: 6 * lineScale).cgPath }
        CATransaction.commit()
    }

    func showLassoPreview(_ image: UIImage?, frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lassoPreviewLayer.contents = image?.cgImage
        lassoPreviewLayer.frame = frame
        lassoPreviewLayer.isHidden = image == nil
        CATransaction.commit()
    }

    func moveLassoPreview(to frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lassoPreviewLayer.frame = frame
        CATransaction.commit()
    }

    /// 表格左上角的刪除鈕
    func showDeleteHandle(_ p: CGPoint?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let p {
            let s = Self.handleSize * lineScale
            deleteHandleImage.frame = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
            deleteHandleImage.isHidden = false
        } else {
            deleteHandleImage.isHidden = true
        }
        CATransaction.commit()
    }

    /// 表格內選取的儲存格範圍
    func showCellSelection(_ rect: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cellSelLayer.path = rect.map { UIBezierPath(rect: $0).cgPath }
        CATransaction.commit()
    }

    /// 表格左上角的移動控制點（十字箭頭）
    func showMoveHandle(_ p: CGPoint?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        moveHandleLayer.path = nil
        moveHandleMarks.path = nil
        if let p {
            let s = Self.handleSize * lineScale
            moveHandleImage.frame = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
            moveHandleImage.isHidden = false
        } else {
            moveHandleImage.isHidden = true
        }
        CATransaction.commit()
    }

    /// 表格選取時的「＋」（插入列／欄）與格線拖拉點
    /// 電路元件旁的旋轉、翻轉按鈕（文件座標的中心點；nil 隱藏）
    func showCircuitPartHandles(rotate: CGPoint?, flip: CGPoint?, delete: CGPoint?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let s = Self.handleSize * lineScale
        for (l, p) in [(circuitRotateHandle, rotate), (circuitFlipHandle, flip), (circuitDeleteHandle, delete)] {
            if let p {
                l.frame = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
                l.isHidden = false
            } else {
                l.isHidden = true
            }
        }
        CATransaction.commit()
    }

    func showTableHandles(plus: [CGPoint], grips: [CGPoint]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = 11 * lineScale
        let circles = UIBezierPath()
        let marks = UIBezierPath()
        for p in plus {
            circles.append(UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)))
            let m = r * 0.5
            marks.move(to: CGPoint(x: p.x - m, y: p.y))
            marks.addLine(to: CGPoint(x: p.x + m, y: p.y))
            marks.move(to: CGPoint(x: p.x, y: p.y - m))
            marks.addLine(to: CGPoint(x: p.x, y: p.y + m))
        }
        tablePlusCircles.path = plus.isEmpty ? nil : circles.cgPath
        tablePlusMarks.path = plus.isEmpty ? nil : marks.cgPath
        let g = UIBezierPath()
        let gr = 7 * lineScale
        for p in grips {
            g.append(UIBezierPath(ovalIn: CGRect(x: p.x - gr, y: p.y - gr, width: gr * 2, height: gr * 2)))
        }
        gripLayer.path = grips.isEmpty ? nil : g.cgPath
        CATransaction.commit()
    }

    /// 擴展頁面：整頁外框、原始內容範圍、8 個控制點
    func showPageHandles(full: CGRect?, content: CGRect?, handles: [CGPoint]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageOutlineLayer.path = full.map { UIBezierPath(rect: $0).cgPath }
        pageContentLayer.path = content.map { UIBezierPath(rect: $0).cgPath }
        let s = 9 * lineScale
        let h = UIBezierPath()
        for p in handles {
            h.append(UIBezierPath(roundedRect: CGRect(x: p.x - s, y: p.y - s, width: s * 2, height: s * 2), cornerRadius: 3 * lineScale))
        }
        pageHandleLayer.path = handles.isEmpty ? nil : h.cgPath
        CATransaction.commit()
    }

    func showTableDraft(rect: CGRect?, xs: [CGFloat], ys: [CGFloat], live: (CGPoint, CGPoint)?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = UIBezierPath()
        if let r = rect {
            path.append(UIBezierPath(rect: r))
            for x in xs {
                path.move(to: CGPoint(x: x, y: r.minY))
                path.addLine(to: CGPoint(x: x, y: r.maxY))
            }
            for y in ys {
                path.move(to: CGPoint(x: r.minX, y: y))
                path.addLine(to: CGPoint(x: r.maxX, y: y))
            }
        }
        if let l = live {
            path.move(to: l.0)
            path.addLine(to: l.1)
        }
        draftLayer.path = path.isEmpty ? nil : path.cgPath
        CATransaction.commit()
    }

    func showSelection(_ rect: CGRect?, locked: Bool, handle: CGPoint?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let r = rect {
            selectionLayer.path = UIBezierPath(rect: r.insetBy(dx: -4 * lineScale, dy: -4 * lineScale)).cgPath
            selectionLayer.strokeColor = (locked ? UIColor.systemOrange : UIColor.systemBlue).cgColor
        } else {
            selectionLayer.path = nil
        }
        handleLayer.path = nil
        if let h = handle {
            let s = Self.handleSize * lineScale
            resizeHandleImage.frame = CGRect(x: h.x - s / 2, y: h.y - s / 2, width: s, height: s)
            resizeHandleImage.isHidden = false
        } else {
            resizeHandleImage.isHidden = true
        }
        CATransaction.commit()
    }

    func showTextRects(_ rects: [CGRect]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = UIBezierPath()
        for r in rects { path.append(UIBezierPath(rect: r)) }
        textLayer.path = rects.isEmpty ? nil : path.cgPath
        CATransaction.commit()
    }

    func showCapture(_ path: UIBezierPath?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        captureLayer.path = path?.cgPath
        CATransaction.commit()
    }
}
