import UIKit

enum CircuitSymbolTool: Int, CaseIterable {
    case line, brush, text, pin, eraser

    var title: String {
        switch self {
        case .line: return "線條"
        case .brush: return "筆刷"
        case .text: return "文字"
        case .pin: return "接腳"
        case .eraser: return "橡皮擦"
        }
    }

    var hint: String {
        switch self {
        case .line: return "拖一條直線：兩端自動吸到最近的格點。從線的端點接著畫就連在一起。"
        case .brush: return "用 Pencil 或手指直接畫；畫到一半停住會修成直線、圓弧、圓、橢圓、矩形或三角形，筆不放開繼續移動可以調整。"
        case .text: return "點一下加上文字（例如 +、−、A、VCC），點已經有的字修改、換大小或刪除；拖曳移動。上下標寫 R_1、V^2。"
        case .pin: return "點格點加上接腳（導線接的地方），再點一下拿掉。至少要有一個。"
        case .eraser: return "點或劃過線條、接腳擦掉：「整條」擦掉整條線，「局部」只擦掉碰到的那一段。Pencil 筆身點兩下、Pencil Pro 按壓可以切換橡皮擦。"
        }
    }
}

/// 畫到一半的自訂元件（座標同元件座標，不碰畫面，可以單獨測試）
struct CircuitSymbolDraft {
    private(set) var symbol: CircuitSymbol
    /// 正在拖的直線
    private(set) var drawingLine: Int?
    private var history: [CircuitSymbol] = []
    /// 這一次擦除（點一下或一路劃過）記成一步了沒；nil＝不是在一路擦（每擦到一次算一步）
    private var eraseRecorded: Bool?

    init(_ symbol: CircuitSymbol = CircuitSymbol()) {
        self.symbol = symbol
    }

    var canUndo: Bool { !history.isEmpty }

    private mutating func remember() {
        history.append(symbol)
    }

    mutating func undo() {
        guard let last = history.popLast() else { return }
        symbol = last
        drawingLine = nil
    }

    /// 整個換掉（貼上 JSON），可以復原
    mutating func replace(with s: CircuitSymbol) {
        remember()
        symbol = s
        drawingLine = nil
    }

    // MARK: 線條

    /// 開始拖直線：起點吸到最近的格點
    mutating func beginLine(at p: CGPoint) {
        remember()
        let q = CircuitData.snap(p)
        symbol.strokes.append(.init(points: [q, q]))
        drawingLine = symbol.strokes.count - 1
    }

    /// 終點跟著筆尖，吸到最近的格點
    mutating func moveLine(to p: CGPoint) {
        guard let i = drawingLine else { return }
        symbol.strokes[i].points[1] = CircuitData.snap(p)
    }

    /// 放開：兩端在同一個格點就不算一條線
    mutating func endLine(at p: CGPoint) {
        moveLine(to: p)
        guard let i = drawingLine else { return }
        drawingLine = nil
        if symbol.strokes[i].points[0] == symbol.strokes[i].points[1] {
            symbol.strokes.remove(at: i)
            _ = history.popLast()
        }
    }

    // MARK: 筆刷

    mutating func beginBrush(at p: CGPoint) {
        remember()
        symbol.strokes.append(.init(points: [p], freehand: true))
    }

    mutating func continueBrush(to p: CGPoint) {
        guard let last = symbol.strokes.indices.last, symbol.strokes[last].freehand else { return }
        symbol.strokes[last].points.append(p)
    }

    /// 抖動的取樣點拿掉（線條還是照手畫的走），存起來和畫起來都比較輕。
    /// held：停住修成的圖形，已經是乾淨的線，不再簡化（圓簡化會變成多邊形）
    mutating func endBrush(held: Bool = false) {
        guard let last = symbol.strokes.indices.last, symbol.strokes[last].freehand else { return }
        let points = held ? symbol.strokes[last].points : Self.simplified(symbol.strokes[last].points, tolerance: 0.3)
        if points.count < 2 {
            symbol.strokes.removeLast()
            _ = history.popLast()
        } else {
            symbol.strokes[last].points = points
        }
    }

    /// 筆刷畫到一半停住：和頁面上的筆一樣認成直線、圓弧、圓、橢圓、矩形或三角形（InkShapes），
    /// 筆不放開繼續移動可以調整（直線、圓弧的終點跟著筆尖；封閉圖形縮放）。
    /// scale：一單位在畫面上多大，照畫面上的大小辨識；回傳的圖形用畫面上的大小（元件座標 × scale）
    mutating func holdBrush(scale: CGFloat) -> InkShape? {
        guard let last = symbol.strokes.indices.last, symbol.strokes[last].freehand else { return nil }
        let onScreen = symbol.strokes[last].points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        guard let shape = InkShapes.recognize(onScreen) else { return nil }
        applyHeld(shape, scale: scale)
        return shape
    }

    /// 停住變成的圖形跟著筆尖（p 是元件座標）
    mutating func moveHeldShape(_ shape: InkShape, to p: CGPoint, scale: CGFloat) -> InkShape {
        let s = InkShapes.moved(shape, to: CGPoint(x: p.x * scale, y: p.y * scale))
        applyHeld(s, scale: scale)
        return s
    }

    /// 直線只留兩端；圓弧、圓這些留所有的點（不簡化，才不會變成多邊形）
    private mutating func applyHeld(_ s: InkShape, scale: CGFloat) {
        guard let last = symbol.strokes.indices.last else { return }
        let pts = s.kind == .line ? [s.start, s.end] : s.points
        symbol.strokes[last].points = pts.map { CGPoint(x: $0.x / scale, y: $0.y / scale) }
    }

    static func simplified(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var worst = 0, distance: CGFloat = 0
        for i in 1..<(points.count - 1) {
            let d = segmentDistance(points[i], first, last)
            if d > distance {
                distance = d
                worst = i
            }
        }
        guard distance > tolerance else { return first == last ? [first] : [first, last] }
        let left = simplified(Array(points[...worst]), tolerance: tolerance)
        return Array(left.dropLast()) + simplified(Array(points[worst...]), tolerance: tolerance)
    }

    private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: 文字

    /// 點到的字（容許誤差 tolerance）
    func textIndex(at p: CGPoint, tolerance: CGFloat) -> Int? {
        symbol.texts.indices.last { symbol.texts[$0].bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p) }
    }

    /// 新增一段字；空白不算
    mutating func addText(_ text: String, at p: CGPoint, size: CGFloat) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        remember()
        symbol.texts.append(.init(text: t, center: p, size: size))
    }

    /// 改字、換大小；改成空白就刪掉
    mutating func updateText(_ i: Int, text: String, size: CGFloat) {
        guard symbol.texts.indices.contains(i) else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != symbol.texts[i].text || size != symbol.texts[i].size else { return }
        remember()
        if t.isEmpty {
            symbol.texts.remove(at: i)
        } else {
            symbol.texts[i].text = t
            symbol.texts[i].size = size
        }
    }

    /// 開始拖一段字（拖完算一步）
    mutating func beginMovingText(_ i: Int) {
        guard symbol.texts.indices.contains(i) else { return }
        remember()
    }

    mutating func moveText(_ i: Int, to p: CGPoint) {
        guard symbol.texts.indices.contains(i) else { return }
        symbol.texts[i].center = p
    }

    // MARK: 接腳、橡皮擦

    mutating func togglePin(at p: CGPoint) {
        remember()
        let q = CircuitData.snap(p)
        if let i = symbol.pins.firstIndex(of: q) {
            symbol.pins.remove(at: i)
        } else {
            symbol.pins.append(q)
        }
    }

    /// 開始一路擦：放開前擦掉的都算同一步
    mutating func beginErase() { eraseRecorded = false }
    mutating func endErase() { eraseRecorded = nil }

    /// 擦到了回傳 true。partial：只擦掉線條碰到的那一段（剩下的分成幾條），不然整條擦掉
    @discardableResult
    mutating func erase(at p: CGPoint, tolerance: CGFloat, partial: Bool = false) -> Bool {
        var s = symbol
        if let i = s.pins.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= tolerance }) {
            s.pins.remove(at: i)
        } else if let i = s.texts.firstIndex(where: { $0.bounds.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(p) }) {
            s.texts.remove(at: i)
        } else if partial {
            let cut = s.strokes.flatMap { Self.cutting($0, around: p, radius: tolerance) }
            guard cut != s.strokes else { return false }
            s.strokes = cut
        } else if let i = s.strokes.firstIndex(where: { st in
            zip(st.points, st.points.dropFirst()).contains { Self.segmentDistance(p, $0, $1) <= tolerance }
        }) {
            s.strokes.remove(at: i)
        } else {
            return false
        }
        if eraseRecorded != true { remember() }
        if eraseRecorded == false { eraseRecorded = true }
        symbol = s
        return true
    }

    /// 局部擦除：線條在圓裡面的部分拿掉，剩下的分成幾條（沒碰到就原樣）
    static func cutting(_ stroke: CircuitSymbol.Stroke, around c: CGPoint, radius r: CGFloat) -> [CircuitSymbol.Stroke] {
        let pts = stroke.points
        guard pts.count >= 2 else { return [stroke] }
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        var pieces: [[CGPoint]] = []
        var current: [CGPoint] = hypot(pts[0].x - c.x, pts[0].y - c.y) < r ? [] : [pts[0]]
        var touched = false
        for (a, b) in zip(pts, pts.dropFirst()) {
            guard let (t0, t1) = circleInterval(a, b, c, r) else {
                current.append(b)
                continue
            }
            touched = true
            if t0 > 0 { current.append(lerp(a, b, t0)) }
            if current.count >= 2 { pieces.append(current) }
            current = t1 < 1 ? [lerp(a, b, t1), b] : []
        }
        guard touched else { return [stroke] }
        if current.count >= 2 { pieces.append(current) }
        // 擦剩一點點的不留
        return pieces.filter { p in zip(p, p.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } > 0.5 }
            .map { .init(points: $0, freehand: stroke.freehand) }
    }

    /// 線段 a→b 在圓裡面的範圍（0...1 之間的 t0...t1）；沒穿過圓回傳 nil
    private static func circleInterval(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ r: CGFloat) -> (CGFloat, CGFloat)? {
        let dx = b.x - a.x, dy = b.y - a.y
        let fx = a.x - c.x, fy = a.y - c.y
        let qa = dx * dx + dy * dy
        guard qa > 0 else { return hypot(fx, fy) < r ? (0, 1) : nil }
        let qb = 2 * (fx * dx + fy * dy)
        let qc = fx * fx + fy * fy - r * r
        let disc = qb * qb - 4 * qa * qc
        guard disc > 0 else { return nil }
        let s = disc.squareRoot()
        let t0 = (-qb - s) / (2 * qa), t1 = (-qb + s) / (2 * qa)
        guard t1 > 0, t0 < 1 else { return nil }
        return (max(t0, 0), min(t1, 1))
    }

    /// 畫好的元件：中心移到格點上的原點。沒有線條或接腳回傳 nil
    func finished() -> CircuitSymbol? {
        guard !(symbol.strokes.isEmpty && symbol.texts.isEmpty), !symbol.pins.isEmpty else { return nil }
        return symbol.centered()
    }
}

/// 畫布：格點（draw 畫，只有大小改變才重畫）、線條和接腳（各自的圖層，畫筆刷時只更新路徑）
final class CircuitSymbolCanvas: UIView {
    /// 一格（元件座標 10）在畫面上多大
    var scale: CGFloat { max(min(bounds.width, bounds.height) / 200, 1) }
    var draft: () -> CircuitSymbolDraft = { CircuitSymbolDraft() }
    let strokeLayer = CAShapeLayer()
    private let pinLayer = CAShapeLayer()
    /// 橡皮擦擦到的範圍（擦的時候、Pencil 懸停時顯示）
    let eraserLayer = CAShapeLayer()
    /// 文字：字改了才重畫（畫筆刷時不用每次重畫）
    private let labelsView = SymbolLabelsView()
    private(set) var drawnTexts: [CircuitSymbol.Label] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        contentMode = .redraw
        strokeLayer.fillColor = nil
        strokeLayer.lineCap = .round
        strokeLayer.lineJoin = .round
        pinLayer.fillColor = nil
        pinLayer.strokeColor = UIColor.systemRed.cgColor
        pinLayer.lineWidth = 2
        layer.addSublayer(strokeLayer)
        layer.addSublayer(pinLayer)
        eraserLayer.fillColor = UIColor.systemGray.withAlphaComponent(0.12).cgColor
        eraserLayer.strokeColor = UIColor.systemGray.cgColor
        eraserLayer.lineWidth = 1
        eraserLayer.isHidden = true
        eraserLayer.zPosition = 1
        layer.addSublayer(eraserLayer)
        labelsView.isOpaque = false
        labelsView.backgroundColor = .clear
        labelsView.isUserInteractionEnabled = false
        labelsView.contentMode = .redraw
        labelsView.render = { [weak self] in self?.drawTexts() }
        addSubview(labelsView)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: CircuitSymbolCanvas, _) in
            v.refresh()
            v.labelsView.setNeedsDisplay()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        strokeLayer.frame = bounds
        pinLayer.frame = bounds
        labelsView.frame = bounds
        refresh()
    }

    /// 橡皮擦的圓圈（畫面座標）；nil 收起來
    func showEraser(at v: CGPoint?, radius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let v {
            eraserLayer.path = UIBezierPath(ovalIn: CGRect(x: v.x - radius, y: v.y - radius, width: radius * 2, height: radius * 2)).cgPath
            eraserLayer.isHidden = false
        } else {
            eraserLayer.isHidden = true
        }
        CATransaction.commit()
    }

    private func drawTexts() {
        for t in drawnTexts {
            let str = CircuitRenderer.nameString(t.text, size: t.size * scale, color: .label)
            let sz = str.size()
            let c = viewPoint(t.center)
            str.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2))
        }
    }

    /// 線條、接腳改了：更新路徑
    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let symbol = draft().symbol
        let path = CGMutablePath()
        for s in symbol.strokes {
            guard let first = s.points.first else { continue }
            path.move(to: viewPoint(first))
            for p in s.points.dropFirst() { path.addLine(to: viewPoint(p)) }
        }
        strokeLayer.path = path
        strokeLayer.lineWidth = scale
        strokeLayer.strokeColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
        let pins = CGMutablePath()
        for p in symbol.pins {
            let v = viewPoint(p)
            pins.addEllipse(in: CGRect(x: v.x - 6, y: v.y - 6, width: 12, height: 12))
        }
        pinLayer.path = pins
        CATransaction.commit()
        if symbol.texts != drawnTexts {
            drawnTexts = symbol.texts
            labelsView.setNeedsDisplay()
        }
    }

    func symbolPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - bounds.midX) / scale, y: (p.y - bounds.midY) / scale)
    }

    private func viewPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: bounds.midX + p.x * scale, y: bounds.midY + p.y * scale)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let g = CircuitData.grid * scale
        ctx.setFillColor(UIColor.systemGray3.cgColor)
        let columns = Int(bounds.width / 2 / g), rows = Int(bounds.height / 2 / g)
        if columns > 0, rows > 0 {
            for x in -columns...columns {
                for y in -rows...rows {
                    ctx.fillEllipse(in: CGRect(x: bounds.midX + CGFloat(x) * g - 1, y: bounds.midY + CGFloat(y) * g - 1, width: 2, height: 2))
                }
            }
        }
    }
}

/// 畫元件的文字（由畫布畫）
private final class SymbolLabelsView: UIView {
    var render: (() -> Void)?
    override func draw(_ rect: CGRect) { render?() }
}

/// 畫元件的筆刷、橡皮擦：一碰到就開始（拖曳手勢要先移動一小段才開始，畫起來會慢半拍），每個取樣點都送出來
final class SymbolStrokeRecognizer: UIGestureRecognizer {
    var onBegin: ((CGPoint) -> Void)?
    var onMove: (([CGPoint]) -> Void)?
    var onEnd: ((CGPoint) -> Void)?
    private var tracked: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delaysTouchesBegan = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let old = tracked, old.isOver { tracked = nil }
        guard tracked == nil, let t = touches.first else { return }
        tracked = t
        state = .began
        onBegin?(t.location(in: view))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        state = .changed
        onMove?((event.coalescedTouches(for: t) ?? [t]).map { $0.location(in: view) })
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        tracked = nil
        onEnd?(t.location(in: view))
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        tracked = nil
        onEnd?(t.location(in: view))
        state = .cancelled
    }

    override func reset() {
        super.reset()
        tracked = nil
    }
}

/// 自訂元件編輯器：用線條和筆刷畫符號，再標出接腳；也可以貼上 JSON（例如請 AI 照手繪的元件產生）
final class CircuitSymbolEditorViewController: UIViewController {
    private(set) var draft: CircuitSymbolDraft
    private(set) var tool: CircuitSymbolTool = .line
    let canvas = CircuitSymbolCanvas()
    let nameField = UITextField()
    private let toolPicker = UISegmentedControl(items: CircuitSymbolTool.allCases.map(\.title))
    /// 橡皮擦：整條擦掉或只擦碰到的那一段（選橡皮擦時才出現）
    let eraseKind = UISegmentedControl(items: ["整條擦除", "局部擦除"])
    let hint = UILabel()
    let strokeTouch = SymbolStrokeRecognizer(target: nil, action: nil)
    private(set) var tapGesture: UITapGestureRecognizer!
    private(set) var panGesture: UIPanGestureRecognizer!
    private let onDone: (String, CircuitSymbol) -> Void
    /// Pencil 切到橡皮擦之前的工具
    private var toolBeforeEraser: CircuitSymbolTool = .line
    private var holdTimer: Timer?
    private var holdAnchor: CGPoint = .zero
    private var heldShape: InkShape?
    /// 文字工具正在拖的字
    private var movingText: Int?
    /// 文字的大小選項（元件座標，格點 10）
    static let textSizes: [(String, CGFloat)] = [("小字", 8), ("中字", 12), ("大字", 16)]

    init(name: String, symbol: CircuitSymbol?, onDone: @escaping (String, CircuitSymbol) -> Void) {
        draft = CircuitSymbolDraft(symbol ?? CircuitSymbol())
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
        nameField.text = name
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        isModalInPresentation = true
        preferredContentSize = CGSize(width: 720, height: 820)

        nameField.placeholder = "元件名稱"
        nameField.textAlignment = .center
        nameField.borderStyle = .roundedRect
        nameField.frame.size = CGSize(width: 240, height: 34)
        navigationItem.titleView = nameField
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.finish() }),
            UIBarButtonItem(title: "復原", primaryAction: UIAction { [weak self] _ in self?.undoTapped() }),
            UIBarButtonItem(title: "JSON", menu: jsonMenu()),
        ]

        toolPicker.selectedSegmentIndex = tool.rawValue
        toolPicker.addAction(UIAction { [weak self] _ in
            guard let self, let t = CircuitSymbolTool(rawValue: self.toolPicker.selectedSegmentIndex) else { return }
            self.setTool(t)
        }, for: .valueChanged)
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = .secondaryLabel
        hint.numberOfLines = 0
        hint.text = tool.hint
        eraseKind.selectedSegmentIndex = EditorSettings.shared.symbolPartialErase ? 1 : 0
        eraseKind.addAction(UIAction { [weak self] _ in
            EditorSettings.shared.symbolPartialErase = self?.eraseKind.selectedSegmentIndex == 1
        }, for: .valueChanged)

        canvas.draft = { [weak self] in self?.draft ?? CircuitSymbolDraft() }
        canvas.layer.borderColor = UIColor.separator.cgColor
        canvas.layer.borderWidth = 1
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        canvas.addGestureRecognizer(tap)
        tapGesture = tap
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        canvas.addGestureRecognizer(pan)
        panGesture = pan
        strokeTouch.onBegin = { [weak self] v in
            guard let self else { return }
            self.showEraser(at: v)
            self.handlePan(.began, at: self.canvas.symbolPoint(v))
        }
        strokeTouch.onMove = { [weak self] vs in
            guard let self else { return }
            self.showEraser(at: vs.last)
            for v in vs { self.apply(.changed, at: self.canvas.symbolPoint(v)) }
            self.canvas.refresh()
        }
        strokeTouch.onEnd = { [weak self] v in
            guard let self else { return }
            self.showEraser(at: nil)
            self.handlePan(.ended, at: self.canvas.symbolPoint(v))
        }
        canvas.addGestureRecognizer(strokeTouch)
        // Pencil 懸停：還沒碰到就看得到橡皮擦的範圍
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        canvas.addGestureRecognizer(hover)
        // 筆身點兩下、Pencil Pro 按壓：切換這裡的橡皮擦（筆記本那邊不會跟著切）
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)

        let stack = UIStackView(arrangedSubviews: [toolPicker, eraseKind, hint, canvas])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
        setTool(tool)
    }

    func setTool(_ t: CircuitSymbolTool) {
        tool = t
        toolPicker.selectedSegmentIndex = t.rawValue
        hint.text = t.hint
        eraseKind.isHidden = t != .eraser
        if t != .eraser { canvas.showEraser(at: nil, radius: Self.eraserRadius) }
        // 筆刷、橡皮擦一碰到就開始；線條、接腳用點一下、拖曳（拖曳的起點會扣回剛碰到的位置）
        let immediate = t == .brush || t == .eraser
        strokeTouch.isEnabled = immediate
        panGesture?.isEnabled = !immediate
        tapGesture?.isEnabled = !immediate
    }

    /// 橡皮擦和原本的工具之間切換
    func toggleEraser() {
        if tool == .eraser {
            setTool(toolBeforeEraser == .eraser ? .line : toolBeforeEraser)
        } else {
            toolBeforeEraser = tool
            setTool(.eraser)
        }
    }

    func undoTapped() {
        draft.undo()
        canvas.refresh()
    }

    private var tolerance: CGFloat { Self.eraserRadius / canvas.scale }
    /// 橡皮擦（和點選）的範圍：畫面上的半徑
    static let eraserRadius: CGFloat = 12

    /// 橡皮擦工具：在畫面座標 v 顯示擦到的範圍（nil 收起來）
    private func showEraser(at v: CGPoint?) {
        canvas.showEraser(at: tool == .eraser ? v : nil, radius: Self.eraserRadius)
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed: showEraser(at: g.location(in: canvas))
        default: showEraser(at: nil)
        }
    }

    /// 點一下（元件座標）
    func handleTap(at p: CGPoint) {
        switch tool {
        case .pin: draft.togglePin(at: p)
        case .eraser: draft.erase(at: p, tolerance: tolerance, partial: EditorSettings.shared.symbolPartialErase)
        case .text: presentTextEditor(editing: draft.textIndex(at: p, tolerance: tolerance / 2), at: p)
        case .line, .brush: break
        }
        canvas.refresh()
    }

    /// 文字工具：輸入字、選大小。editing：點到的那一段（nil＝新增在 p）
    func presentTextEditor(editing: Int?, at p: CGPoint) {
        let old = editing.flatMap { draft.symbol.texts[safe: $0] }
        let a = UIAlertController(title: old == nil ? "加上文字" : "修改文字", message: "上下標寫成 R_1、V^2", preferredStyle: .alert)
        a.addTextField { f in
            f.text = old?.text
            f.placeholder = "例如 +、A、VCC"
        }
        for (title, size) in Self.textSizes {
            let current = old.map { abs($0.size - size) < 0.5 } ?? (size == CircuitSymbol.Label.defaultSize)
            a.addAction(UIAlertAction(title: current ? title + " ✓" : title, style: .default) { [weak self, weak a] _ in
                self?.commitText(a?.textFields?.first?.text ?? "", size: size, editing: editing, at: p)
            })
        }
        if editing != nil {
            a.addAction(UIAlertAction(title: "刪除", style: .destructive) { [weak self] _ in
                self?.commitText("", size: old?.size ?? CircuitSymbol.Label.defaultSize, editing: editing, at: p)
            })
        }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(a, animated: true)
    }

    /// 文字輸入完：新增或修改（空白＝刪掉）
    func commitText(_ text: String, size: CGFloat, editing: Int?, at p: CGPoint) {
        if let i = editing {
            draft.updateText(i, text: text, size: size)
        } else {
            draft.addText(text, at: p, size: size)
        }
        canvas.refresh()
    }

    /// 拖曳（元件座標）
    func handlePan(_ state: UIGestureRecognizer.State, at p: CGPoint) {
        apply(state, at: p)
        canvas.refresh()
    }

    private func apply(_ state: UIGestureRecognizer.State, at p: CGPoint) {
        switch tool {
        case .line:
            switch state {
            case .began: draft.beginLine(at: p)
            case .changed: draft.moveLine(to: p)
            case .ended, .cancelled, .failed: draft.endLine(at: p)
            default: break
            }
        case .brush:
            switch state {
            case .began:
                heldShape = nil
                draft.beginBrush(at: p)
                restartHoldTimer(at: p)
            case .changed:
                if let s = heldShape {
                    heldShape = draft.moveHeldShape(s, to: p, scale: canvas.scale)
                } else {
                    draft.continueBrush(to: p)
                    // 還在動：重新等停住（抖一點點不算動）
                    if hypot(p.x - holdAnchor.x, p.y - holdAnchor.y) * canvas.scale > 3 { restartHoldTimer(at: p) }
                }
            case .ended, .cancelled, .failed:
                holdTimer?.invalidate()
                if let s = heldShape {
                    _ = draft.moveHeldShape(s, to: p, scale: canvas.scale)
                } else {
                    draft.continueBrush(to: p)
                }
                draft.endBrush(held: heldShape != nil)
                heldShape = nil
            default: break
            }
        case .eraser:
            switch state {
            case .began:
                draft.beginErase()
                draft.erase(at: p, tolerance: tolerance, partial: EditorSettings.shared.symbolPartialErase)
            case .changed:
                draft.erase(at: p, tolerance: tolerance, partial: EditorSettings.shared.symbolPartialErase)
            default:
                // 放開的位置已經擦過了（整條擦除再擦一次會多擦掉底下的另一條）
                draft.endErase()
            }
        case .text:
            switch state {
            case .began:
                movingText = draft.textIndex(at: p, tolerance: tolerance / 2)
                if let i = movingText { draft.beginMovingText(i) }
            case .changed:
                if let i = movingText { draft.moveText(i, to: p) }
            default:
                if let i = movingText { draft.moveText(i, to: p) }
                movingText = nil
            }
        case .pin:
            break
        }
    }

    /// 和頁面上的筆一樣：「⋯」的「畫線停住變直線／圖形」關掉就不修
    private func restartHoldTimer(at p: CGPoint) {
        holdAnchor = p
        holdTimer?.invalidate()
        guard EditorSettings.shared.shapeSnap else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.brushHeld() }
    }

    /// 筆刷停住了（計時器叫的）
    func brushHeld() {
        guard tool == .brush, heldShape == nil, let s = draft.holdBrush(scale: canvas.scale) else { return }
        heldShape = s
        canvas.refresh()
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        handleTap(at: canvas.symbolPoint(g.location(in: canvas)))
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        var v = g.location(in: canvas)
        if g.state == .began {
            let t = g.translation(in: canvas)
            v = CGPoint(x: v.x - t.x, y: v.y - t.y)
        }
        handlePan(g.state, at: canvas.symbolPoint(v))
    }

    // MARK: JSON

    private func jsonMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "貼上 JSON", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.importJSON(UIPasteboard.general.string ?? "")
            },
            UIAction(title: "拷貝 JSON", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                guard let self else { return }
                UIPasteboard.general.string = CircuitSymbolJSON.export(self.draft.symbol, name: self.nameField.text ?? "")
                self.hint.text = "已拷貝這個元件的 JSON。"
            },
            UIAction(title: "拷貝給 AI 的說明", image: UIImage(systemName: "sparkles")) { [weak self] _ in
                UIPasteboard.general.string = CircuitSymbolJSON.aiPrompt
                self?.hint.text = "已拷貝給 AI 的說明：貼到 AI 聊天裡、附上手繪元件的照片，把回覆的 JSON 拷貝起來，再按「JSON」→「貼上 JSON」。"
            },
        ])
    }

    /// 貼上的 JSON 換掉現在畫的（可以復原）；還沒打名稱就用 JSON 裡的
    func importJSON(_ text: String) {
        do {
            let file = try CircuitSymbolJSON.parse(text)
            draft.replace(with: file.symbol)
            if let name = file.name, !name.isEmpty, (nameField.text ?? "").isEmpty { nameField.text = name }
            hint.text = "已貼上 JSON；可以再用線條、筆刷修改。"
            canvas.refresh()
        } catch {
            alert(title: "沒辦法讀這段 JSON", message: error.localizedDescription)
        }
    }

    private func alert(title: String, message: String?) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }

    func finish() {
        guard let symbol = draft.finished() else {
            alert(title: draft.symbol.strokes.isEmpty && draft.symbol.texts.isEmpty ? "還沒有畫符號" : "還沒有接腳，導線接不上去：用「接腳」工具在格點上點一下", message: nil)
            return
        }
        onDone(nameField.text ?? "", symbol)
        dismiss(animated: true)
    }
}

extension CircuitSymbolEditorViewController: UIPencilInteractionDelegate {
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        toggleEraser()
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        toggleEraser()
    }
}
