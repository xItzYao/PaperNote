import UIKit
import PencilKit

/// 橡皮擦擦螢光筆：螢光筆的筆跡是沿著中心軌跡的一個一個圓（圓心在軌跡上、半徑是線寬一半）。
/// 橡皮擦碰到哪個圓的任何一點，就把那個圓心拿掉，整個圓跟著不見：螢光筆比橡皮擦粗，擦一條線過去，那裡整個寬度都擦掉
/// （PencilKit 的橡皮擦只擦掉碰到的那一條細線，上下會留著）
enum HighlighterErase {
    /// 橡皮擦沿著 path（文件座標）走過、半徑 radius。整筆擦除：碰到就整筆拿掉；局部擦除：拿掉碰到的那段軌跡，其他留著。
    /// 只處理螢光筆；沒有變化回傳 nil
    static func erase(_ strokes: [PKStroke], along path: [CGPoint], radius: CGFloat, partial: Bool) -> [PKStroke]? {
        guard let first = path.first else { return nil }
        let area = path.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        var changed = false
        var out: [PKStroke] = []
        for s in strokes {
            let k = abs(s.transform.a * s.transform.d - s.transform.b * s.transform.c).squareRoot()
            // 先用外框快速排除：外框加上碰得到的距離（斜的筆頭橫著畫時外框比較扁，要用長的那邊算）
            let widest = s.path.map(\.size.width).max() ?? 0
            let reach = radius + drawnHalfWidth(s.ink, CGSize(width: widest, height: widest)) * k
            guard NotebookViewController.isHighlighterStroke(s),
                  s.renderBounds.insetBy(dx: -reach, dy: -reach).intersects(area.insetBy(dx: -1, dy: -1)) else {
                out.append(s)
                continue
            }
            let pts = Array(s.path.interpolatedPoints(by: .distance(2)))
            let hit = pts.map { q -> Bool in
                let w = q.location.applying(s.transform)
                return distance(w, to: path) <= radius + drawnHalfWidth(s.ink, q.size) * k
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

    /// PencilKit 實際畫出來的半個線寬（和點的 size 不一樣，實測見 PencilKitInkStudy）：
    /// 螢光筆用的 monoline 畫出來寬 2·size − 4；舊筆記的 marker 是斜的筆頭，長的那邊約 1.1·size（用長的那邊，比較好擦）
    static func drawnHalfWidth(_ ink: PKInk, _ size: CGSize) -> CGFloat {
        switch ink.inkType {
        case .monoline, .pen: return max(0, size.width - 2)
        case .marker: return size.width * 0.55
        default: return size.width / 2
        }
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
