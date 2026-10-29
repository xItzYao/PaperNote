import UIKit
import PencilKit

/// 除錯：套索移動後舊位置留下殘影（只在實機上；放大縮小才消失，捲動不會）。
/// 量 PencilKit 自己畫在畫面上的筆跡（畫布裡頁面以外的 view，不含頁面和物件）在某塊區域有多少墨水，
/// 記進除錯紀錄，看殘影是哪一步留下的
extension NotebookViewController {
    /// PencilKit 的畫面在這塊區域（文件座標）的墨水量（不透明像素的總和）
    func pencilKitInkOnScreen(_ docRect: CGRect) -> Int {
        var total = 0
        for v in canvas.subviews where v !== pagesContainer {
            let r = pagesContainer.convert(docRect, to: v)
            guard r.width >= 1, r.height >= 1, r.width * r.height < 4_000_000 else { continue }
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            fmt.opaque = false
            let img = UIGraphicsImageRenderer(size: r.size, format: fmt).image { rc in
                rc.cgContext.translateBy(x: -r.minX, y: -r.minY)
                v.layer.render(in: rc.cgContext)
            }
            guard let cg = img.cgImage else { continue }
            let w = cg.width, h = cg.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            var sum = 0
            for i in 0..<(w * h) { sum += Int(px[i * 4 + 3]) }
            total += sum / 255
        }
        return total
    }

    /// 現在和過一下之後，各區域的 PencilKit 墨水量記進除錯紀錄
    func logPencilKitInk(_ label: String, _ regions: [(String, CGRect)]) {
        func measure(_ when: String) {
            let parts = regions.map { "\($0.0)=\(pencilKitInkOnScreen($0.1))" }.joined(separator: " ")
            DebugLog.add("redraw \(label) \(when): \(parts) strokes=\(canvas.drawing.strokes.count)")
        }
        measure("now")
        for delay in [0.3, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self != nil else { return }
                measure("+\(delay)s")
            }
        }
    }

    /// PencilKit 在畫布裡放了哪些 view／layer（只記一次）
    func logPencilKitViewsOnce() {
        guard !didLogPencilKitViews else { return }
        didLogPencilKitViews = true
        for v in canvas.subviews where v !== pagesContainer {
            let layers = (v.layer.sublayers ?? []).prefix(6).map { String(describing: type(of: $0)) }.joined(separator: ",")
            DebugLog.add("redraw pk view \(type(of: v)) frame=\(v.frame.integral) scale=\(String(format: "%.2f", v.transform.a)) sublayers=\(v.layer.sublayers?.count ?? 0) [\(layers)] subviews=\(v.subviews.map { String(describing: type(of: $0)) })")
        }
    }
}
