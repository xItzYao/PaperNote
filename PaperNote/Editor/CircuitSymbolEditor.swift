import UIKit

enum CircuitSymbolTool: Int, CaseIterable {
    case line, brush, pin, eraser

    var title: String {
        switch self {
        case .line: return "線條"
        case .brush: return "筆刷"
        case .pin: return "接腳"
        case .eraser: return "橡皮擦"
        }
    }

    var hint: String {
        switch self {
        case .line: return "拖一條直線：兩端自動吸到最近的格點。從線的端點接著畫就連在一起。"
        case .brush: return "用 Pencil 或手指直接畫；畫完停住一下會變成直線，或修成圓、三角形、四邊形。"
        case .pin: return "點格點加上接腳（導線接的地方），再點一下拿掉。至少要有一個。"
        case .eraser: return "點或劃過線條、接腳就整條擦掉。Pencil 筆身點兩下、Pencil Pro 按壓可以切換橡皮擦。"
        }
    }
}

/// 畫到一半的自訂元件（座標同元件座標，不碰畫面，可以單獨測試）
struct CircuitSymbolDraft {
    private(set) var symbol: CircuitSymbol
    /// 正在拖的直線
    private(set) var drawingLine: Int?
    private var history: [CircuitSymbol] = []

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

    /// 抖動的取樣點拿掉（線條還是照手畫的走），存起來和畫起來都比較輕
    mutating func endBrush() {
        guard let last = symbol.strokes.indices.last, symbol.strokes[last].freehand else { return }
        let points = Self.simplified(symbol.strokes[last].points, tolerance: 0.3)
        if points.count < 2 {
            symbol.strokes.removeLast()
            _ = history.popLast()
        } else {
            symbol.strokes[last].points = points
        }
    }

    /// 筆刷停住時修成的圖形
    enum HeldShape { case line, closed }

    /// 筆刷畫到一半停住（和頁面上的筆一樣）：封閉的修成圓、三角形、四邊形，不然變直線（之後終點跟著筆尖）。
    /// scale：一單位在畫面上多大，照畫面上的大小辨識
    mutating func holdBrush(scale: CGFloat) -> HeldShape? {
        guard let last = symbol.strokes.indices.last, symbol.strokes[last].freehand else { return nil }
        let points = symbol.strokes[last].points
        guard let first = points.first, let end = points.last, first != end else { return nil }
        let onScreen = points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        if let shape = ShapeRecognizer.closedShapePoints(onScreen) {
            symbol.strokes[last].points = shape.map { CGPoint(x: $0.x / scale, y: $0.y / scale) }
            return .closed
        }
        symbol.strokes[last].points = [first, ShapeRecognizer.snappedLineEnd(from: first, to: end)]
        return .line
    }

    /// 停住變成的直線：終點跟著筆尖（接近水平、垂直時拉正）
    mutating func moveHeldLine(to p: CGPoint) {
        guard let last = symbol.strokes.indices.last, symbol.strokes[last].freehand,
              let first = symbol.strokes[last].points.first else { return }
        symbol.strokes[last].points = [first, ShapeRecognizer.snappedLineEnd(from: first, to: p)]
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

    /// 擦到了回傳 true
    @discardableResult
    mutating func erase(at p: CGPoint, tolerance: CGFloat) -> Bool {
        if let i = symbol.pins.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= tolerance }) {
            remember()
            symbol.pins.remove(at: i)
            return true
        }
        for (i, s) in symbol.strokes.enumerated() where zip(s.points, s.points.dropFirst()).contains(where: { Self.segmentDistance(p, $0, $1) <= tolerance }) {
            remember()
            symbol.strokes.remove(at: i)
            return true
        }
        return false
    }

    /// 畫好的元件：中心移到格點上的原點。沒有線條或接腳回傳 nil
    func finished() -> CircuitSymbol? {
        guard !symbol.strokes.isEmpty, !symbol.pins.isEmpty else { return nil }
        return symbol.centered()
    }
}

/// 畫布：格點、線條、接腳
final class CircuitSymbolCanvas: UIView {
    /// 一格（元件座標 10）在畫面上多大
    var scale: CGFloat { max(min(bounds.width, bounds.height) / 200, 1) }
    var draft: () -> CircuitSymbolDraft = { CircuitSymbolDraft() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

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
        let symbol = draft().symbol
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(scale)
        ctx.setStrokeColor(UIColor.label.cgColor)
        for s in symbol.strokes {
            guard let first = s.points.first else { continue }
            ctx.move(to: viewPoint(first))
            for p in s.points.dropFirst() { ctx.addLine(to: viewPoint(p)) }
            ctx.strokePath()
        }
        ctx.setStrokeColor(UIColor.systemRed.cgColor)
        ctx.setLineWidth(2)
        for p in symbol.pins {
            let v = viewPoint(p)
            ctx.strokeEllipse(in: CGRect(x: v.x - 6, y: v.y - 6, width: 12, height: 12))
        }
    }
}

/// 自訂元件編輯器：用線條和筆刷畫符號，再標出接腳；也可以貼上 JSON（例如請 AI 照手繪的元件產生）
final class CircuitSymbolEditorViewController: UIViewController {
    private(set) var draft: CircuitSymbolDraft
    private(set) var tool: CircuitSymbolTool = .line
    let canvas = CircuitSymbolCanvas()
    let nameField = UITextField()
    private let toolPicker = UISegmentedControl(items: CircuitSymbolTool.allCases.map(\.title))
    let hint = UILabel()
    private let onDone: (String, CircuitSymbol) -> Void
    /// Pencil 切到橡皮擦之前的工具
    private var toolBeforeEraser: CircuitSymbolTool = .line
    private var holdTimer: Timer?
    private var holdAnchor: CGPoint = .zero
    private var heldShape: CircuitSymbolDraft.HeldShape?

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

        canvas.draft = { [weak self] in self?.draft ?? CircuitSymbolDraft() }
        canvas.layer.borderColor = UIColor.separator.cgColor
        canvas.layer.borderWidth = 1
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        canvas.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        canvas.addGestureRecognizer(pan)
        // 筆身點兩下、Pencil Pro 按壓：切換這裡的橡皮擦（筆記本那邊不會跟著切）
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)

        let stack = UIStackView(arrangedSubviews: [toolPicker, hint, canvas])
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
    }

    func setTool(_ t: CircuitSymbolTool) {
        tool = t
        toolPicker.selectedSegmentIndex = t.rawValue
        hint.text = t.hint
        canvas.setNeedsDisplay()
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
        canvas.setNeedsDisplay()
    }

    private var tolerance: CGFloat { 12 / canvas.scale }

    /// 點一下（元件座標）
    func handleTap(at p: CGPoint) {
        switch tool {
        case .pin: draft.togglePin(at: p)
        case .eraser: draft.erase(at: p, tolerance: tolerance)
        case .line, .brush: break
        }
        canvas.setNeedsDisplay()
    }

    /// 拖曳（元件座標）
    func handlePan(_ state: UIGestureRecognizer.State, at p: CGPoint) {
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
                if heldShape == .line {
                    draft.moveHeldLine(to: p)
                } else if heldShape == nil {
                    draft.continueBrush(to: p)
                    // 還在動：重新等停住（抖一點點不算動）
                    if hypot(p.x - holdAnchor.x, p.y - holdAnchor.y) * canvas.scale > 3 { restartHoldTimer(at: p) }
                }
            case .ended, .cancelled, .failed:
                holdTimer?.invalidate()
                if heldShape == .line {
                    draft.moveHeldLine(to: p)
                } else if heldShape == nil {
                    draft.continueBrush(to: p)
                }
                heldShape = nil
                draft.endBrush()
            default: break
            }
        case .eraser:
            draft.erase(at: p, tolerance: tolerance)
        case .pin:
            break
        }
        canvas.setNeedsDisplay()
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
        canvas.setNeedsDisplay()
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
            canvas.setNeedsDisplay()
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
            alert(title: draft.symbol.strokes.isEmpty ? "還沒有畫符號" : "還沒有接腳，導線接不上去：用「接腳」工具在格點上點一下", message: nil)
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
