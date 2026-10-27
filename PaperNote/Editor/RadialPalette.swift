import UIKit
import UIKit.UIGestureRecognizerSubclass

/// 調色盤：先在筆尖旁出現小圖示，點了才打開。
/// 打開後有「文字選取、筆、螢光筆」；按住筆或螢光筆會往外展開常用顏色，滑到顏色後筆尖離開螢幕就選取。
final class PaletteOverlay: UIView {
    enum Mode { case launcher, open }

    var onSelectPreset: ((BrushPreset) -> Void)?
    var onSelectTool: ((EditorTool) -> Void)?
    var onDismiss: (() -> Void)?

    private(set) var mode: Mode = .launcher
    private var anchor: CGPoint
    private let currentTool: EditorTool
    private var hideTimer: Timer?
    private var expanded: BrushCategory?
    private var hoverMain: Int?
    private var hoverPreset: Int?
    private var touchActive = false

    static let launcherRadius: CGFloat = 22
    private let mainRadius: CGFloat = 70
    private let itemRadius: CGFloat = 28
    private let subRadius: CGFloat = 150
    private let presetRadius: CGFloat = 21

    private struct MainItem {
        let tool: EditorTool
        let symbol: String
        let title: String
        let angle: CGFloat   // 度
    }

    // 都放在左側，右手拿筆時不會被手擋住
    private let mainItems = [
        MainItem(tool: .pen, symbol: "pencil.tip", title: "筆", angle: 180),
        MainItem(tool: .highlighter, symbol: "highlighter", title: "螢光筆", angle: 130),
    ]

    /// 打開時的中心（切換橡皮擦時筆尖的位置）；nil 就以小圖示為中心
    private var paletteCenter: CGPoint?

    init(frame: CGRect, at point: CGPoint, currentTool: EditorTool, startOpen: Bool = false, paletteCenter: CGPoint? = nil) {
        self.currentTool = currentTool
        self.paletteCenter = paletteCenter
        anchor = point
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        if startOpen {
            open()
            return
        }
        let m = Self.launcherRadius + 10
        anchor.x = min(max(anchor.x, m), frame.width - m)
        anchor.y = min(max(anchor.y, m), frame.height - m)
        let t = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
            guard let self, self.mode == .launcher else { return }
            self.onDismiss?()
        }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    private let closeRadius: CGFloat = 20

    private func hitClose(_ p: CGPoint) -> Bool { p.distance(to: anchor) <= closeRadius + 6 }

    required init?(coder: NSCoder) { fatalError() }

    deinit { hideTimer?.invalidate() }

    // 小圖示狀態時只攔截點到圖示的觸控，其他地方照常書寫
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if mode == .launcher {
            return point.distance(to: anchor) <= Self.launcherRadius + 14 ? self : nil
        }
        return self
    }

    private func open() {
        mode = .open
        hideTimer?.invalidate()
        if let c = paletteCenter { anchor = c }
        let m = subRadius + presetRadius + 12
        anchor.x = min(max(anchor.x, m), max(m, bounds.width - m))
        anchor.y = min(max(anchor.y, m), max(m, bounds.height - m))
        UISelectionFeedbackGenerator().selectionChanged()
        setNeedsDisplay()
    }

    // MARK: 幾何

    private func point(_ angle: CGFloat, _ r: CGFloat) -> CGPoint {
        let a = angle * .pi / 180
        return CGPoint(x: anchor.x + cos(a) * r, y: anchor.y + sin(a) * r)
    }

    private func presets(_ c: BrushCategory) -> [BrushPreset] { Array(BrushStore.shared.presets(c).prefix(10)) }

    private func presetCenters(_ c: BrushCategory) -> [CGPoint] {
        guard let item = mainItems.first(where: { $0.tool == (c == .pen ? .pen : .highlighter) }) else { return [] }
        let n = presets(c).count
        let step = min(22, 150 / CGFloat(max(n - 1, 1)))
        return (0..<n).map { i in point(item.angle + (CGFloat(i) - CGFloat(n - 1) / 2) * step, subRadius) }
    }

    private func hitMain(_ p: CGPoint) -> Int? {
        mainItems.indices.first { p.distance(to: point(mainItems[$0].angle, mainRadius)) <= itemRadius + 8 }
    }

    private func hitPreset(_ p: CGPoint, _ c: BrushCategory) -> Int? {
        let centers = presetCenters(c)
        var best: Int?
        var bestD = CGFloat.greatestFiniteMagnitude
        for (i, cpt) in centers.enumerated() {
            let d = p.distance(to: cpt)
            if d < bestD { bestD = d; best = i }
        }
        return bestD <= presetRadius + 12 ? best : nil
    }

    // MARK: 觸控：按住 → 滑過去 → 放開

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        switch mode {
        case .launcher:
            // 點小圖示只負責打開；這一下不算選取，否則放開的位置剛好落在某個按鈕上會直接選掉並關閉
            open()
        case .open:
            if hitClose(p) {
                onDismiss?()
                return
            }
            if hitMain(p) == nil && expanded.flatMap({ hitPreset(p, $0) }) == nil && p.distance(to: anchor) > mainRadius + itemRadius + 10 {
                onDismiss?()
                return
            }
            touchActive = true
            update(p)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touchActive, let t = touches.first else { return }
        update(t.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touchActive, let t = touches.first else { return }
        touchActive = false
        commit(t.location(in: self))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchActive = false
        hoverMain = nil
        hoverPreset = nil
        setNeedsDisplay()
    }

    private func update(_ p: CGPoint) {
        let oldMain = hoverMain, oldPreset = hoverPreset, oldExpanded = expanded
        if let e = expanded, let i = hitPreset(p, e) {
            hoverPreset = i
            hoverMain = nil
        } else if let m = hitMain(p) {
            hoverMain = m
            hoverPreset = nil
            switch mainItems[m].tool {
            case .pen: expanded = .pen
            case .highlighter: expanded = .highlighter
            default: expanded = nil
            }
        } else {
            hoverMain = nil
            hoverPreset = nil
        }
        if oldMain != hoverMain || oldPreset != hoverPreset || oldExpanded != expanded {
            if hoverMain != nil || hoverPreset != nil { UISelectionFeedbackGenerator().selectionChanged() }
            setNeedsDisplay()
        }
    }

    private func commit(_ p: CGPoint) {
        if let e = expanded, let i = hitPreset(p, e) {
            onSelectPreset?(presets(e)[i])
            return
        }
        if let m = hitMain(p) {
            onSelectTool?(mainItems[m].tool)
            return
        }
        // 放在空白處：保持打開，可以再選
        hoverMain = nil
        hoverPreset = nil
        setNeedsDisplay()
    }

    // MARK: 繪製

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        if mode == .launcher {
            drawLauncher(ctx)
            return
        }

        // 主盤
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 12, color: UIColor.black.withAlphaComponent(0.25).cgColor)
        let discR = mainRadius + itemRadius + 10
        UIColor(white: 0.97, alpha: 0.97).setFill()
        UIBezierPath(ovalIn: CGRect(x: anchor.x - discR, y: anchor.y - discR, width: discR * 2, height: discR * 2)).fill()
        ctx.restoreGState()

        // 中央：關閉
        let cr = CGRect(x: anchor.x - closeRadius, y: anchor.y - closeRadius, width: closeRadius * 2, height: closeRadius * 2)
        UIColor(white: 0.88, alpha: 1).setFill()
        UIBezierPath(ovalIn: cr).fill()
        if let x = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))?
            .withTintColor(.darkGray, renderingMode: .alwaysOriginal) {
            x.draw(at: CGPoint(x: anchor.x - x.size.width / 2, y: anchor.y - x.size.height / 2))
        }

        for (i, item) in mainItems.enumerated() {
            let c = point(item.angle, mainRadius)
            let isExpandedItem = expanded != nil && item.tool == (expanded == .pen ? EditorTool.pen : EditorTool.highlighter)
            let hot = hoverMain == i || isExpandedItem
            let active = item.tool == currentTool
            let r = itemRadius * (hoverMain == i ? 1.1 : 1)
            let circle = UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            (hot ? UIColor.systemBlue : UIColor.white).setFill()
            circle.fill()
            circle.lineWidth = active ? 3 : 1
            (active ? UIColor.systemBlue : UIColor(white: 0.78, alpha: 1)).setStroke()
            circle.stroke()
            if let img = UIImage(systemName: item.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))?
                .withTintColor(hot ? .white : .label, renderingMode: .alwaysOriginal) {
                img.draw(at: CGPoint(x: c.x - img.size.width / 2, y: c.y - img.size.height / 2 - 6))
            }
            let label = NSAttributedString(string: item.title, attributes: [
                .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: hot ? UIColor.white : UIColor.secondaryLabel,
            ])
            let ls = label.size()
            label.draw(at: CGPoint(x: c.x - ls.width / 2, y: c.y + 7))
        }

        // 二級選單：常用顏色
        guard let e = expanded else { return }
        let list = presets(e)
        let currentID = BrushStore.shared.current(e).id
        for (i, c) in presetCenters(e).enumerated() where i < list.count {
            let preset = list[i]
            let hot = hoverPreset == i
            let r = presetRadius * (hot ? 1.25 : 1)
            let outer = CGRect(x: c.x - r - 3, y: c.y - r - 3, width: (r + 3) * 2, height: (r + 3) * 2)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: UIColor.black.withAlphaComponent(0.25).cgColor)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: outer).fill()
            ctx.restoreGState()
            let color = preset.style == .marker ? preset.color.withAlphaComponent(0.8) : preset.color
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
            if preset.id == currentID || hot {
                let ring = UIBezierPath(ovalIn: outer)
                ring.lineWidth = hot ? 3 : 2
                UIColor.systemBlue.setStroke()
                ring.stroke()
            }
            // 粗細示意
            let dot = min(r * 1.2, max(3, preset.width * 0.6))
            UIColor.white.withAlphaComponent(0.85).setFill()
            UIBezierPath(ovalIn: CGRect(x: c.x - dot / 2, y: c.y - dot / 2, width: dot, height: dot)).fill()
        }
    }

    private func drawLauncher(_ ctx: CGContext) {
        let r = Self.launcherRadius
        let rect = CGRect(x: anchor.x - r, y: anchor.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: UIColor.black.withAlphaComponent(0.3).cgColor)
        UIColor.systemBlue.setFill()
        UIBezierPath(ovalIn: rect).fill()
        ctx.restoreGState()
        let ring = UIBezierPath(ovalIn: rect)
        ring.lineWidth = 2
        UIColor.white.setStroke()
        ring.stroke()
        if let img = UIImage(systemName: "paintpalette.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal) {
            img.draw(at: CGPoint(x: anchor.x - img.size.width / 2, y: anchor.y - img.size.height / 2))
        }
    }
}

extension NotebookViewController {
    /// 在筆尖旁出現調色盤小圖示（點了才打開）
    func showPaletteLauncher(at p: CGPoint?, open: Bool = false) {
        dismissPalette()
        editMenu.dismissMenu()
        let point = p ?? lastPencilPoint ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        // 直接打開：以筆尖為中心；小圖示：放在筆尖右上方一點，不會被筆擋住
        // 調色盤中心：筆尖位置往寫字的手那側偏 65pt（左手往左；右手或沒開防誤觸都往右）
        var center = point
        center.x += settings.palmRejection == "left" ? -65 : 65
        // 小圖示放在筆尖右上方約 40pt；點了之後以上面的中心打開
        let at = open ? center : CGPoint(x: point.x + 40, y: point.y - 40)
        let overlay = PaletteOverlay(frame: view.bounds, at: at, currentTool: tool, startOpen: open, paletteCenter: center)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.onSelectPreset = { [weak self] preset in
            guard let self else { return }
            BrushStore.shared.select(preset.id)
            self.setTool(preset.category == .highlighter ? .highlighter : .pen)
            self.dismissPalette()
        }
        overlay.onSelectTool = { [weak self] t in
            self?.setTool(t)
            self?.dismissPalette()
        }
        overlay.onDismiss = { [weak self] in self?.dismissPalette() }
        view.addSubview(overlay)
        paletteOverlay = overlay
        overlay.alpha = 0
        UIView.animate(withDuration: 0.15) { overlay.alpha = 1 }
    }

    func dismissPalette() {
        guard let overlay = paletteOverlay else { return }
        paletteOverlay = nil
        UIView.animate(withDuration: 0.12, animations: { overlay.alpha = 0 }) { _ in overlay.removeFromSuperview() }
    }
}

/// 偵測 Apple Pencil 筆尖在螢幕上快速點兩下（不干擾 PencilKit）
final class PencilMultiTapRecognizer: UIGestureRecognizer {
    var requiredTaps = 2
    var maxInterval: TimeInterval = 0.4
    var maxDistance: CGFloat = 30
    var onFirstTapBegan: (() -> Void)?
    var onMultiTap: ((CGPoint) -> Void)?
    weak var coordinateView: UIView?

    private var tracked: UITouch?
    private var beganAt: TimeInterval = 0
    private var beganLoc: CGPoint = .zero
    private var taps: [(time: TimeInterval, loc: CGPoint)] = []

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil, let t = touches.first, t.type == .pencil else { return }
        tracked = t
        beganAt = t.timestamp
        beganLoc = t.location(in: nil)
        if let last = taps.last, t.timestamp - last.time > maxInterval { taps.removeAll() }
        if taps.isEmpty { onFirstTapBegan?() }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {}

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        tracked = nil
        let loc = t.location(in: nil)
        let isTap = t.timestamp - beganAt < 0.3 && loc.distance(to: beganLoc) < 10
        if isTap {
            if let last = taps.last, last.loc.distance(to: loc) > maxDistance { taps.removeAll() }
            taps.append((t.timestamp, loc))
            if taps.count >= requiredTaps {
                taps.removeAll()
                onMultiTap?(t.location(in: coordinateView))
            }
        } else {
            taps.removeAll()
        }
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        tracked = nil
        state = .failed
    }

    override func reset() {
        super.reset()
        tracked = nil
    }
}
