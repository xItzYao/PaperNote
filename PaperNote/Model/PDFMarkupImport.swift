import UIKit
import PDFKit

/// 匯入 PDF 時處理別的 App 加上去的註解（例如 iPad「檔案」的「註記」）。
/// 頁面背景用 CGPDFPage 畫，只畫頁面本身的內容、不畫註解，所以：
/// - 手寫的註解（Ink）變成這一頁可以編輯的筆跡，從 PDF 拿掉
/// - 其他註解（圖形、文字、圖章…）畫進頁面裡（burn in），看得到但不能編輯
enum PDFMarkupImport {
    /// 每一頁轉出來的筆跡（頁面座標）。有改到 PDF 的話 changed 是 true，要另外存檔
    struct Result {
        var ink: [Int: [InkStroke]] = [:]
        var changed = false
    }

    /// 拿掉 pdf 裡的手寫註解、轉成筆跡（pdf 會被改，存檔用 write）
    static func extractInk(from pdf: PDFDocument) -> Result {
        var result = Result()
        for i in 0..<pdf.pageCount {
            // 只有連結的頁面不用改（連結本來就看不到）
            guard let page = pdf.page(at: i), page.annotations.contains(where: { $0.type != "Link" }) else { continue }
            result.changed = true
            let t = NotebookSession.displayTransform(for: page)
            for a in page.annotations where a.type == "Ink" {
                let width = max(a.border?.lineWidth ?? 1, 0.3)
                let color = a.color.hexString
                // 註解的路徑以註解範圍的左下角為原點
                let o = a.bounds.origin
                for path in a.paths ?? [] {
                    for line in polylines(path.cgPath) where !line.isEmpty {
                        let pts = line.map { CGPoint(x: $0.x + o.x, y: $0.y + o.y).applying(t) }
                        result.ink[i, default: []].append(InkStroke(colorHex: color, points: pts.map { InkPoint($0, width: width) }))
                    }
                }
                page.removeAnnotation(a)
            }
        }
        return result
    }

    /// 改過註解的 PDF 存回 url：剩下的註解畫進頁面
    static func write(_ pdf: PDFDocument, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".markup-\(UUID().uuidString).pdf")
        guard pdf.write(to: tmp, withOptions: [.burnInAnnotationsOption: true]) else { throw LibraryError.unreadablePDF }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// 路徑拆成一筆一筆的折線（曲線取幾個點）
    static func polylines(_ path: CGPath) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        var current: [CGPoint] = []
        func finish() {
            if !current.isEmpty { out.append(current) }
            current = []
        }
        path.applyWithBlock { e in
            let p = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint:
                finish()
                current = [p[0]]
            case .addLineToPoint:
                current.append(p[0])
            case .addQuadCurveToPoint:
                guard let a = current.last else { current = [p[1]]; break }
                for k in 1...8 { current.append(quad(a, p[0], p[1], CGFloat(k) / 8)) }
            case .addCurveToPoint:
                guard let a = current.last else { current = [p[2]]; break }
                for k in 1...8 { current.append(cubic(a, p[0], p[1], p[2], CGFloat(k) / 8)) }
            case .closeSubpath:
                if let f = current.first { current.append(f) }
            @unknown default:
                break
            }
        }
        finish()
        return out
    }

    private static func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// 二次曲線上的點（de Casteljau）
    private static func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        mix(mix(a, c, t), mix(c, b, t), t)
    }

    /// 三次曲線上的點
    private static func cubic(_ a: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        quad(mix(a, c1, t), mix(c1, c2, t), mix(c2, b, t), t)
    }
}
