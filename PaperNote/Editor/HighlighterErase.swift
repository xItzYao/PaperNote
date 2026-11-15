import UIKit
import PencilKit

/// 橡皮擦擦螢光筆：螢光筆的筆跡是中心一條軌跡、用很粗的線寬畫出來的。
/// 橡皮擦的圓圈只要碰到畫出來的範圍（軌跡中心 ± 線寬一半），就擦掉那一段的軌跡中心，不用剛好擦到正中間
enum HighlighterErase {
    /// 橡皮擦沿著 path（文件座標）走過、半徑 radius。整筆擦除：碰到就整筆拿掉；局部擦除：拿掉碰到的那段軌跡，其他留著。
    /// 只處理螢光筆；沒有變化回傳 nil
    static func erase(_ strokes: [PKStroke], along path: [CGPoint], radius: CGFloat, partial: Bool) -> [PKStroke]? {
        guard let first = path.first else { return nil }
        let area = path.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        var changed = false
        var out: [PKStroke] = []
        for s in strokes {
            guard NotebookViewController.isHighlighterStroke(s),
                  s.renderBounds.insetBy(dx: -radius, dy: -radius).intersects(area.insetBy(dx: -1, dy: -1)) else {
                out.append(s)
                continue
            }
            let k = abs(s.transform.a * s.transform.d - s.transform.b * s.transform.c).squareRoot()
            let pts = Array(s.path.interpolatedPoints(by: .distance(2)))
            let hit = pts.map { q -> Bool in
                let w = q.location.applying(s.transform)
                return distance(w, to: path) <= radius + q.size.width * k / 2
            }
            guard hit.contains(true) else {
                out.append(s)
                continue
            }
            changed = true
            guard partial else { continue }
            // 局部擦除：連續沒碰到的點各自變成一段
            var run: [PKStrokePoint] = []
            func flush() {
                if run.count >= 2 {
                    let p = PKStrokePath(controlPoints: run, creationDate: s.path.creationDate)
                    out.append(PKStroke(ink: s.ink, path: p, transform: s.transform, mask: s.mask))
                }
                run = []
            }
            for (q, h) in zip(pts, hit) {
                if h { flush() } else { run.append(q) }
            }
            flush()
        }
        return changed ? out : nil
    }

    /// 點到橡皮擦走過的折線的距離
    static func distance(_ p: CGPoint, to path: [CGPoint]) -> CGFloat {
        guard let first = path.first else { return .infinity }
        if path.count == 1 { return p.distance(to: first) }
        return zip(path, path.dropFirst()).map { InkGeometry.distance(p, $0, $1) }.min() ?? .infinity
    }
}

extension NotebookViewController {
    /// 這一次擦除結束（PencilKit 擦完了）：螢光筆碰到範圍就擦掉。和 PencilKit 擦掉的算同一步
    func eraseHighlighterStrokes(along path: [CGPoint], gesture: StrokeGesture?) {
        guard path.count > 0,
              let result = HighlighterErase.erase(canvas.drawing.strokes, along: path, radius: eraserRadius, partial: settings.pixelEraser)
        else { return }
        // PencilKit 什麼都沒擦到時還沒登記上一步：先登記（復原回到下筆前），才能復原
        recordStrokeGesture(gesture)
        var d = canvas.drawing
        d.strokes = result
        setDrawing(d)
        DebugLog.add("eraser touched highlighter strokes=\(canvas.drawing.strokes.count)")
    }
}
