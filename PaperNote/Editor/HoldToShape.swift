import UIKit
import PencilKit

/// 停住約 0.5 秒後的即時直線／圖形
struct LiveShape {
    var start: CGPoint
    var end: CGPoint
    var shapePoints: [CGPoint]?   // 有值＝封閉圖形；nil＝直線
    var preset: BrushPreset
    var countBefore: Int
    /// 封閉圖形剛辨識出來的樣子、停住時筆尖的位置、縮放時固定不動的角
    var baseShape: [CGPoint]? = nil
    var grab: CGPoint = .zero
    var anchor: CGPoint = .zero

    var points: [CGPoint] { shapePoints ?? ShapeRecognizer.segment(start, end) }
}

/// 剛放開的直線／圖形，等 PencilKit 收尾手繪的那一筆
struct PendingLiveStroke {
    var stroke: PKStroke
    var countBefore: Int
    var until: CFTimeInterval
    /// 筆離開螢幕的時間
    var endedAt: CFTimeInterval
    /// 畫這條線之前的筆跡（上一步就回到這裡）
    var before: PKDrawing
    /// 這支筆是虛線：換上去時切成一段一段
    var dashed = false
    var undoRegistered = false
}

/// 停住變直線／圖形用到的計算（不碰畫面，可以單獨測試）
enum HoldToShape {
    /// 圖形外框上離 p 最遠的角：調整長寬時固定不動
    static func anchorCorner(of shape: [CGPoint], farthestFrom p: CGPoint) -> CGPoint? {
        guard let minX = shape.map(\.x).min(), let maxX = shape.map(\.x).max(),
              let minY = shape.map(\.y).min(), let maxY = shape.map(\.y).max() else { return nil }
        let corners = [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY),
                       CGPoint(x: minX, y: maxY), CGPoint(x: maxX, y: maxY)]
        return corners.max { $0.distance(to: p) < $1.distance(to: p) }
    }

    /// 長寬分別依筆尖相對固定角的距離縮放（0.1～10 倍）
    static func scaled(_ base: [CGPoint], grab: CGPoint, anchor a: CGPoint, to p: CGPoint) -> [CGPoint] {
        func scale(_ now: CGFloat, _ grab: CGFloat, _ anchor: CGFloat) -> CGFloat {
            let d = grab - anchor
            guard abs(d) > 8 else { return 1 }
            return min(max((now - anchor) / d, 0.1), 10)
        }
        let sx = scale(p.x, grab.x, a.x), sy = scale(p.y, grab.y, a.y)
        return base.map { CGPoint(x: a.x + ($0.x - a.x) * sx, y: a.y + ($0.y - a.y) * sy) }
    }

    /// 手繪的那一筆：在原本筆跡之後、又比直線早建立的最後一筆
    static func handStrokeIndex(in strokes: [PKStroke], countBefore: Int, lineDate: Date) -> Int? {
        strokes.indices.last { $0 >= countBefore && strokes[$0].path.creationDate < lineDate }
    }

    /// 把手繪那一筆換成直線：原本的筆跡、之後才畫的新筆跡保留，直線放最後
    static func replacingHandStroke(in strokes: [PKStroke], countBefore: Int, with line: PKStroke) -> [PKStroke] {
        replacingHandStroke(in: strokes, countBefore: countBefore, with: [line])
    }

    /// 同上，直線可以是好幾段（虛線）；每一段的建立時間都和直線一樣
    static func replacingHandStroke(in strokes: [PKStroke], countBefore: Int, with lines: [PKStroke]) -> [PKStroke] {
        guard let date = lines.first?.path.creationDate else { return strokes }
        var kept = Array(strokes.prefix(countBefore))
        kept += strokes.dropFirst(countBefore).filter { $0.path.creationDate > date }
        kept += lines
        return kept
    }
}

/// 停住變直線／圖形的完整流程：停住 → 預覽 → 放開 → 等 PencilKit 收尾手繪那一筆 → 換成直線 → 登記上一步。
/// 停住時只取消 PencilKit 當下那一筆（書寫手勢不會一直關著）；狀態都在這裡，編輯器只把事件轉過來。
final class HoldToShapeController {
    private weak var editor: NotebookViewController?
    /// 預覽線：疊在畫布最上層（手繪那一筆的上面）
    let previewLayer = CAShapeLayer()

    private(set) var live: LiveShape?
    private var pending: PendingLiveStroke?
    /// PencilKit 正在畫一筆（還沒收尾前不去改筆跡，以免打斷它）
    private var pencilKitDrawing = false
    /// 每支筆最近一筆手寫的代表點（實際粗細、壓力），直線和預覽線照著畫
    private var samples: [UUID: PKStrokePoint] = [:]
    private var pendingPresetID: UUID?

    init(editor: NotebookViewController) {
        self.editor = editor
        previewLayer.fillColor = UIColor.clear.cgColor
        previewLayer.lineCap = .round
        previewLayer.lineJoin = .round
        previewLayer.zPosition = 1000
    }

    var isActive: Bool { live != nil }

    // MARK: 筆的事件（PencilHoldRecognizer）

    func hold(_ pts: [CGPoint]) {
        guard let editor, editor.tool.isInking, let start = pts.first, let last = pts.last else { return }
        let preset = BrushStore.shared.current
        let shape = ShapeRecognizer.closedShapePoints(pts)
        var ls = LiveShape(start: start, end: ShapeRecognizer.snappedLineEnd(from: start, to: last),
                           shapePoints: shape, preset: preset, countBefore: editor.strokeCountAtBegin)
        // 封閉圖形：筆不放開繼續拖曳可以調整長寬
        if let shape, let anchor = HoldToShape.anchorCorner(of: shape, farthestFrom: last) {
            ls.baseShape = shape
            ls.grab = last
            ls.anchor = anchor
        }
        live = ls
        // 取消 PencilKit 正在畫的手繪線，畫面上只留預覽線。
        // 關掉後馬上打開：只會中斷這一筆，之後的書寫不受影響（不能一直關到放開，新系統上可能恢復不了）
        let g = editor.canvas.drawingGestureRecognizer
        g.isEnabled = false
        g.isEnabled = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showPreview()
    }

    func move(_ p: CGPoint) {
        guard var ls = live else { return }
        if let base = ls.baseShape {
            ls.shapePoints = HoldToShape.scaled(base, grab: ls.grab, anchor: ls.anchor, to: p)
        } else {
            ls.end = ShapeRecognizer.snappedLineEnd(from: ls.start, to: p)
        }
        live = ls
        showPreview()
    }

    func end(_ p: CGPoint, cancelled: Bool) {
        guard var ls = live, let editor else { return }
        live = nil
        if ls.shapePoints == nil { ls.end = ShapeRecognizer.snappedLineEnd(from: ls.start, to: p) }
        guard !cancelled || ls.shapePoints != nil || ls.start.distance(to: ls.end) > 4 else {
            clearPreview()
            return
        }
        // 等 PencilKit 收尾手繪的那一筆再換成直線；1.5 秒內筆跡有變動或定時檢查發現不對，就再修正
        let stroke = ShapeRecognizer.makeStroke(points: ls.points, preset: ls.preset, sample: samples[ls.preset.id])
        let now = CACurrentMediaTime()
        pendingPresetID = ls.preset.id
        pending = PendingLiveStroke(stroke: stroke, countBefore: ls.countBefore, until: now + 1.5, endedAt: now,
                                    before: PKDrawing(strokes: Array(editor.canvas.drawing.strokes.prefix(ls.countBefore))),
                                    dashed: ls.preset.isDashed)
        ensureLine()
        for delay in [0.05, 0.15, 0.3, 0.6, 1.0, 1.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.ensureLine() }
        }
    }

    /// 筆尖碰到畫布：上一次沒收到筆離開 → 先結束它
    func pencilTouchedDown() {
        if let ls = live { end(ls.end, cancelled: true) }
    }

    // MARK: PencilKit 的事件

    func pencilKitBegan() {
        pencilKitDrawing = true
        // 開始寫下一筆：之後就不再補上一條直線（這時改筆跡會打斷正在寫的這一筆）
        finishPending()
    }

    /// 回傳 true 代表這次結束是停住變直線的那一筆，編輯器不用再當新筆跡處理
    func pencilKitEnded() -> Bool {
        pencilKitDrawing = false
        if live != nil { return true }
        if pending != nil {
            DispatchQueue.main.async { [weak self] in self?.ensureLine() }
            return true
        }
        return false
    }

    /// PencilKit 改了筆跡（例如收尾手繪那一筆）→ 確認直線在
    func drawingChanged() {
        if pending != nil { DispatchQueue.main.async { [weak self] in self?.ensureLine() } }
    }

    /// 記住這支筆實際畫出來的粗細
    func recordSample(of stroke: PKStroke, presetID: UUID) {
        if let s = ShapeRecognizer.samplePoint(of: stroke) { samples[presetID] = s }
    }

    // MARK: 上一步／下一步

    /// 回傳 true 代表已經處理（剛放上去、還沒登記上一步的直線直接拿掉）
    func undo() -> Bool {
        guard let p = pending else { return false }
        pending = nil
        guard !p.undoRegistered else { return false }
        editor?.setDrawing(p.before)
        clearPreview()
        return true
    }

    func redo() { finishPending() }

    // MARK: 換成直線

    /// 確認直線在筆跡裡，並把手繪那一筆換掉
    private func ensureLine() {
        guard var p = pending, let editor else { return }
        // PencilKit 還在收尾手繪那一筆：先別動筆跡（最多等 0.6 秒）
        if pencilKitDrawing && CACurrentMediaTime() - p.endedAt < 0.6 { return }
        var line = p.stroke
        let date = line.path.creationDate
        var d = editor.canvas.drawing
        let hasLine = d.strokes.contains { $0.path.creationDate == date }
        let handIndex = HoldToShape.handStrokeIndex(in: d.strokes, countBefore: p.countBefore, lineDate: date)
        if let hi = handIndex, let s = ShapeRecognizer.samplePoint(of: d.strokes[hi]) {
            // 直線改用手寫那一筆的墨水與粗細，和 PencilKit 畫出來的完全一樣
            line = ShapeRecognizer.makeStroke(points: line.path.map(\.location), ink: d.strokes[hi].ink,
                                              width: s.size.width, sample: s, creationDate: date)
            p.stroke = line
            pending = p
            if let id = pendingPresetID { samples[id] = s }
        }
        if !hasLine || handIndex != nil {
            let lines = DashedStroke.apply(line, dashed: p.dashed, lineWidth: line.path.first?.size.width ?? 3)
            d.strokes = HoldToShape.replacingHandStroke(in: d.strokes, countBefore: p.countBefore, with: lines)
            editor.setDrawingAddingStrokes(d, added: lines.count) { [weak self] in self?.clearPreview() }
        } else {
            clearPreview()
        }
        // PencilKit 收尾完（手繪那一筆已經被換掉）才登記上一步，排在它自己的紀錄之後
        if handIndex != nil { registerUndo() }
        if CACurrentMediaTime() > p.until { finishPending() }
    }

    /// 直線的上一步：回到畫這條線之前的筆跡
    private func registerUndo() {
        guard var p = pending, !p.undoRegistered else { return }
        editor?.registerCompositeUndo(drawing: p.before, pageIDs: [])
        p.undoRegistered = true
        pending = p
    }

    /// 不再補直線；還沒登記上一步就現在登記
    private func finishPending() {
        registerUndo()
        pending = nil
    }

    // MARK: 預覽線

    private func showPreview() {
        guard let ls = live, let editor else { return }
        // 預覽線用這支筆實際畫出來的粗細；點是文件座標，換成畫布座標
        let width = samples[ls.preset.id]?.size.width ?? ls.preset.width
        let pts = ls.points.map { editor.pagesContainer.convert($0, to: editor.canvas) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let first = pts.first {
            let path = UIBezierPath()
            path.move(to: first)
            for q in pts.dropFirst() { path.addLine(to: q) }
            previewLayer.path = path.cgPath
            previewLayer.strokeColor = ls.preset.inkColor.cgColor
            previewLayer.lineWidth = width * editor.canvas.zoomScale
            if ls.preset.isDashed {
                let z = editor.canvas.zoomScale, pattern = BrushPreset.dashPattern(lineWidth: width)
                // 圓頭會讓每段看起來長一個線寬，間隔補回來
                previewLayer.lineDashPattern = [NSNumber(value: Double(max(1, pattern.dash - width) * z)),
                                                NSNumber(value: Double((pattern.gap + width) * z))]
            } else {
                previewLayer.lineDashPattern = nil
            }
        }
        CATransaction.commit()
    }

    private func clearPreview() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.path = nil
        CATransaction.commit()
    }
}
