import UIKit
import PencilKit

/// 虛線筆：PencilKit 畫不出虛線，所以虛線筆由 App 自己接手——畫的時候就是虛線，放開後原樣放進筆跡。
/// 虛線筆啟用時 PencilKit 的書寫手勢固定關著；只在換筆、換工具時切換，不會在下筆中途開關。
final class DashedPenController {
    private weak var editor: NotebookViewController?
    let tracker = TouchTracker(target: nil, action: nil)
    private let previewLayer = CAShapeLayer()
    private var points: [CGPoint] = []

    init(editor: NotebookViewController) {
        self.editor = editor
        previewLayer.fillColor = UIColor.clear.cgColor
        previewLayer.lineCap = .round
        previewLayer.lineJoin = .round
        previewLayer.zPosition = 1000
        tracker.onBegan = { [weak self] p in self?.began(p) }
        tracker.onPoint = { [weak self] p in self?.moved(p) }
        tracker.onEnded = { [weak self] in self?.ended() }
    }

    /// 掛到畫布上（點是文件座標，預覽畫在疊加層）
    func install() {
        guard let editor else { return }
        tracker.coordinateView = editor.pagesContainer
        tracker.delegate = editor
        editor.canvas.addGestureRecognizer(tracker)
        editor.overlay.layer.addSublayer(previewLayer)
    }

    private func began(_ p: CGPoint) {
        editor?.dismissToolPopover()
        points = [p]
        showPreview()
    }

    private func moved(_ p: CGPoint) {
        guard let last = points.last, p.distance(to: last) >= 0.8 else { return }
        points.append(p)
        showPreview()
    }

    private func ended() {
        let pts = points
        points = []
        guard let editor, let first = pts.first else {
            clearPreview()
            return
        }
        let preset = BrushStore.shared.current
        let tool = preset.tool
        // 只點一下也留一小段
        let path = pts.count > 1 ? pts : [first, CGPoint(x: first.x + 0.1, y: first.y)]
        let stroke = ShapeRecognizer.makeStroke(points: path, ink: tool.ink, width: tool.width, sample: nil)
        let pieces = DashedStroke.apply(stroke, dashed: true, lineWidth: tool.width, preset: preset)
        let before = editor.canvas.drawing
        var d = before
        d.strokes += pieces
        editor.registerCompositeUndo(drawing: before, pageIDs: [])
        editor.setDrawingAddingStrokes(d, added: pieces.count) { [weak self] in self?.clearPreview() }
    }

    // MARK: 畫的時候的虛線

    private func showPreview() {
        guard let first = points.first else { return }
        let preset = BrushStore.shared.current
        let tool = preset.tool
        let pattern = preset.dashPattern(lineWidth: tool.width)
        let path = UIBezierPath()
        path.move(to: first)
        for q in points.dropFirst() { path.addLine(to: q) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.path = path.cgPath
        previewLayer.strokeColor = tool.color.cgColor
        previewLayer.lineWidth = tool.width
        // 和放進筆跡的每一段一樣：從路徑起點開始，dash 長、gap 空（圓頭兩端各多半個線寬）
        previewLayer.lineDashPattern = [NSNumber(value: Double(pattern.dash)), NSNumber(value: Double(pattern.gap))]
        CATransaction.commit()
    }

    private func clearPreview() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.path = nil
        CATransaction.commit()
    }
}
