import UIKit
import PDFKit
import PencilKit

/// 匯入 PDF 時處理別的 App 加上去的註解（例如 iPad「檔案」的「註記」）。
/// 頁面背景用 CGPDFPage 畫，只畫頁面本身的內容、不畫註解，所以：
/// - 手寫的註解（Ink）變成這一頁可以編輯的筆跡，從 PDF 拿掉
/// - 「檔案」、預覽程式的「註記」畫的筆跡：存成圖章，外觀是頁面 2 倍大的點陣圖（放大就糊）；
///   原本的筆跡（PencilKit）也存在圖章裡，拿出來變成這一頁的 PencilKit 筆跡（清楚、可以編輯），圖章拿掉
/// - 其他註解（圖形、文字、圖章…）畫進頁面裡（burn in），看得到但不能編輯
enum PDFMarkupImport {
    /// 每一頁轉出來的筆跡（頁面座標）。有改到 PDF 的話 changed 是 true，要另外存檔
    struct Result {
        var ink: [Int: [InkStroke]] = [:]
        /// 「註記」畫的筆跡（頁面座標）
        var drawings: [Int: PKDrawing] = [:]
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
            for a in page.annotations {
                guard let d = markupDrawing(a, on: page) else { continue }
                result.drawings[i, default: PKDrawing()].append(d)
                page.removeAnnotation(a)
            }
        }
        return result
    }

    static let markupExtrasKey = PDFAnnotationKey(rawValue: "/AAPL:AKExtras")

    /// 「註記」存在註解裡的筆跡，換到頁面座標；不是「註記」的筆跡、或轉過的頁面（畫的時候的座標不確定）回傳 nil
    static func markupDrawing(_ a: PDFAnnotation, on page: PDFPage) -> PKDrawing? {
        guard page.rotation % 360 == 0,
              let extras = a.value(forAnnotationKey: markupExtrasKey) as? [AnyHashable: Any],
              let encoded = ["/AAPL:AKAnnotationV2", "/AAPL:AKAnnotationObject", "AAPL:AKAnnotationV2", "AAPL:AKAnnotationObject"]
                .lazy.compactMap({ extras[$0] as? String }).first,
              let archive = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let ink = MarkupInk.decode(archive),
              let drawing = try? PKDrawing(data: ink.drawing), !drawing.strokes.isEmpty else { return nil }
        // 筆跡是從畫的那個框（和畫的時候一樣大的裁切框或媒體框）的左上角量的
        guard let box = [PDFDisplayBox.cropBox, .mediaBox].lazy.map({ page.bounds(for: $0) })
            .first(where: { abs($0.width - ink.size.width) < 1 && abs($0.height - ink.size.height) < 1 }) else { return nil }
        let toPDF = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: box.minX, ty: box.maxY)
        return drawing.transformed(using: toPDF.concatenating(NotebookSession.displayTransform(for: page)))
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

/// 讀「註記」的筆跡註解（AnnotationKit 的 AKInkAnnotation2，App 裡沒有這個類別）：只讀筆跡和畫的時候頁面的大小
@objc(PaperNoteMarkupInk)
final class MarkupInk: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    /// PKDrawing 的資料
    let drawing: Data
    let size: CGSize

    init?(coder: NSCoder) {
        guard let d = coder.decodeObject(of: NSData.self, forKey: "drawing"),
              let s = coder.decodeObject(of: [NSDictionary.self, NSString.self, NSNumber.self], forKey: "drawingSize") as? NSDictionary,
              let size = CGSize(dictionaryRepresentation: s as CFDictionary), size.width > 0, size.height > 0 else { return nil }
        drawing = d as Data
        self.size = size
    }

    func encode(with coder: NSCoder) {}

    static func decode(_ archive: Data) -> MarkupInk? {
        guard let u = try? NSKeyedUnarchiver(forReadingFrom: archive) else { return nil }
        defer { u.finishDecoding() }
        for name in ["AKInkAnnotation2", "AKInkAnnotation"] { u.setClass(MarkupInk.self, forClassName: name) }
        return u.decodeObject(of: MarkupInk.self, forKey: NSKeyedArchiveRootObjectKey)
    }
}
