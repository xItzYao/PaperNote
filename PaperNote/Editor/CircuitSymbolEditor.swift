import UIKit

enum CircuitSymbolTool: Int, CaseIterable {
    case node, brush, pin, eraser

    var title: String {
        switch self {
        case .node: return "Node"
        case .brush: return "筆刷"
        case .pin: return "接腳"
        case .eraser: return "橡皮擦"
        }
    }

    var hint: String {
        switch self {
        case .node: return "一下一下點出節點，自動連成直線（對齊格點）；點最後一個節點結束，點第一個節點封閉。拖節點可以移動。"
        case .brush: return "用 Pencil 或手指直接畫。"
        case .pin: return "點格點加上接腳（導線接的地方），再點一下拿掉。至少要有一個。"
        case .eraser: return "點或劃過線條、接腳就整條擦掉。"
        }
    }
}

/// 畫到一半的自訂元件（座標同元件座標，不碰畫面，可以單獨測試）
struct CircuitSymbolDraft {
    private(set) var symbol: CircuitSymbol
    /// 還在接的 node 線
    private(set) var openLine: Int?
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
        openLine = nil
    }

    // MARK: Node

    mutating func tapNode(at p: CGPoint) {
        let q = CircuitData.snap(p)
        guard let i = openLine else {
            remember()
            symbol.strokes.append(.init(points: [q]))
            openLine = symbol.strokes.count - 1
            return
        }
        let points = symbol.strokes[i].points
        if q == points.last {
            finishLine()
            return
        }
        remember()
        symbol.strokes[i].points.append(q)
        // 回到第一個節點：封閉
        if q == points.first, points.count >= 2 { openLine = nil }
    }

    /// 結束正在接的線；只有一個節點的不算一條線
    mutating func finishLine() {
        guard let i = openLine else { return }
        openLine = nil
        if symbol.strokes[i].points.count < 2 { symbol.strokes.remove(at: i) }
    }

    func nodeHit(at p: CGPoint, tolerance: CGFloat) -> (stroke: Int, point: Int)? {
        for (i, s) in symbol.strokes.enumerated() where !s.freehand {
            if let k = s.points.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= tolerance }) { return (i, k) }
        }
        return nil
    }

    mutating func beginMovingNode() {
        remember()
    }

    /// 封閉的線：頭尾是同一個節點，一起動
    mutating func moveNode(stroke i: Int, point k: Int, to p: CGPoint) {
        let q = CircuitData.snap(p)
        let points = symbol.strokes[i].points
        symbol.strokes[i].points[k] = q
        if points.count > 2, points.first == points.last {
            if k == 0 { symbol.strokes[i].points[points.count - 1] = q }
            if k == points.count - 1 { symbol.strokes[i].points[0] = q }
        }
    }

    // MARK: 筆刷

    mutating func beginBrush(at p: CGPoint) {
        finishLine()
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
        finishLine()
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
        finishLine()
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
    mutating func finished() -> CircuitSymbol? {
        finishLine()
        guard !symbol.strokes.isEmpty, !symbol.pins.isEmpty else { return nil }
        return symbol.centered()
    }
}

/// 畫布：格點、線條、節點、接腳
final class CircuitSymbolCanvas: UIView {
    /// 一格（元件座標 10）在畫面上多大
    var scale: CGFloat { max(min(bounds.width, bounds.height) / 200, 1) }
    var draft: () -> CircuitSymbolDraft = { CircuitSymbolDraft() }
    var showsNodes = true

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
        if showsNodes {
            ctx.setFillColor(UIColor.systemBlue.cgColor)
            for s in symbol.strokes where !s.freehand {
                for p in s.points {
                    let v = viewPoint(p)
                    ctx.fill(CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8))
                }
            }
        }
        ctx.setStrokeColor(UIColor.systemRed.cgColor)
        ctx.setLineWidth(2)
        for p in symbol.pins {
            let v = viewPoint(p)
            ctx.strokeEllipse(in: CGRect(x: v.x - 6, y: v.y - 6, width: 12, height: 12))
        }
    }
}

/// 自訂元件編輯器：用 Node 和筆刷畫符號，再標出接腳
final class CircuitSymbolEditorViewController: UIViewController {
    private(set) var draft: CircuitSymbolDraft
    private(set) var tool: CircuitSymbolTool = .node
    let canvas = CircuitSymbolCanvas()
    let nameField = UITextField()
    private let toolPicker = UISegmentedControl(items: CircuitSymbolTool.allCases.map(\.title))
    private let hint = UILabel()
    private let onDone: (String, CircuitSymbol) -> Void
    private var movingNode: (stroke: Int, point: Int)?

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
        draft.finishLine()
        tool = t
        toolPicker.selectedSegmentIndex = t.rawValue
        hint.text = t.hint
        canvas.setNeedsDisplay()
    }

    func undoTapped() {
        draft.undo()
        canvas.setNeedsDisplay()
    }

    private var tolerance: CGFloat { 12 / canvas.scale }

    /// 點一下（元件座標）
    func handleTap(at p: CGPoint) {
        switch tool {
        case .node: draft.tapNode(at: p)
        case .pin: draft.togglePin(at: p)
        case .eraser: draft.erase(at: p, tolerance: tolerance)
        case .brush: break
        }
        canvas.setNeedsDisplay()
    }

    /// 拖曳（元件座標）
    func handlePan(_ state: UIGestureRecognizer.State, at p: CGPoint) {
        switch tool {
        case .brush:
            switch state {
            case .began: draft.beginBrush(at: p)
            case .changed: draft.continueBrush(to: p)
            case .ended, .cancelled, .failed:
                draft.continueBrush(to: p)
                draft.endBrush()
            default: break
            }
        case .node:
            if state == .began {
                movingNode = draft.nodeHit(at: p, tolerance: tolerance)
                if movingNode != nil { draft.beginMovingNode() }
            }
            if let m = movingNode { draft.moveNode(stroke: m.stroke, point: m.point, to: p) }
            if state != .began, state != .changed { movingNode = nil }
        case .eraser:
            draft.erase(at: p, tolerance: tolerance)
        case .pin:
            break
        }
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

    func finish() {
        guard let symbol = draft.finished() else {
            let missing = draft.symbol.strokes.isEmpty ? "還沒有畫符號" : "還沒有接腳，導線接不上去：用「接腳」工具在格點上點一下"
            let a = UIAlertController(title: missing, message: nil, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "好", style: .default))
            present(a, animated: true)
            return
        }
        onDone(nameField.text ?? "", symbol)
        dismiss(animated: true)
    }
}
