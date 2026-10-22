import UIKit
import PencilKit

/// 畫頁面背景（紙張、螢光標示、PDF）所需的資料。可在背景執行緒使用。
struct BackgroundSnapshot {
    var fullSize: CGSize
    var insets: PageInsets
    var baseSize: CGSize
    var paper: PaperStyle?
    var pdfPage: CGPDFPage?
    var pdfTransform: CGAffineTransform
    var highlights: [TextHighlight]
}

enum PageRenderer {
    /// 在整頁座標（含擴展區，左上為原點）畫背景
    static func drawBackground(_ s: BackgroundSnapshot, in ctx: CGContext, clip: CGRect? = nil) {
        let full = CGRect(origin: .zero, size: s.fullSize)
        let area = clip.map { $0.intersection(full) } ?? full
        guard !area.isNull, !area.isEmpty else { return }

        ctx.saveGState()
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(area)
        if let paper = s.paper {
            drawPaper(paper, in: full, visible: area, ctx: ctx)
        }

        ctx.translateBy(x: s.insets.left, y: s.insets.top)
        let base = CGRect(origin: .zero, size: s.baseSize)

        // 螢光標示畫在 PDF 底下，再用 multiply 疊上 PDF，文字就不會被蓋暗
        for h in s.highlights {
            ctx.setFillColor(UIColor(hex: h.colorHex).cgColor)
            for r in h.rects { ctx.fill(r) }
        }

        if let pdf = s.pdfPage {
            ctx.saveGState()
            ctx.clip(to: base)
            ctx.setBlendMode(.multiply)
            ctx.concatenate(s.pdfTransform)
            ctx.interpolationQuality = .high
            ctx.setRenderingIntent(.defaultIntent)
            ctx.drawPDFPage(pdf)
            ctx.restoreGState()

            if !s.insets.isZero {
                ctx.setStrokeColor(UIColor(white: 0.85, alpha: 1).cgColor)
                ctx.setLineWidth(0.5)
                ctx.stroke(base)
            }
        }
        ctx.restoreGState()
    }

    static func drawPaper(_ style: PaperStyle, in full: CGRect, visible: CGRect, ctx: CGContext) {
        switch style {
        case .blank:
            return
        case .ruled:
            let spacing: CGFloat = 32
            ctx.setStrokeColor(UIColor(hex: "#C9D6E8").cgColor)
            ctx.setLineWidth(0.8)
            var y = full.minY + 96
            while y < full.maxY - 24 {
                if y >= visible.minY - 1 && y <= visible.maxY + 1 {
                    ctx.move(to: CGPoint(x: visible.minX, y: y))
                    ctx.addLine(to: CGPoint(x: visible.maxX, y: y))
                }
                y += spacing
            }
            ctx.strokePath()
        case .grid:
            let spacing: CGFloat = 24
            ctx.setStrokeColor(UIColor(hex: "#DDE3EA").cgColor)
            ctx.setLineWidth(0.6)
            var x = full.minX + spacing
            while x < full.maxX {
                if x >= visible.minX - 1 && x <= visible.maxX + 1 {
                    ctx.move(to: CGPoint(x: x, y: visible.minY))
                    ctx.addLine(to: CGPoint(x: x, y: visible.maxY))
                }
                x += spacing
            }
            var y = full.minY + spacing
            while y < full.maxY {
                if y >= visible.minY - 1 && y <= visible.maxY + 1 {
                    ctx.move(to: CGPoint(x: visible.minX, y: y))
                    ctx.addLine(to: CGPoint(x: visible.maxX, y: y))
                }
                y += spacing
            }
            ctx.strokePath()
        case .dotted:
            let spacing: CGFloat = 24
            ctx.setFillColor(UIColor(hex: "#B8C0CA").cgColor)
            var y = full.minY + spacing
            while y < full.maxY {
                if y >= visible.minY - 2 && y <= visible.maxY + 2 {
                    var x = full.minX + spacing
                    while x < full.maxX {
                        if x >= visible.minX - 2 && x <= visible.maxX + 2 {
                            ctx.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                        }
                        x += spacing
                    }
                }
                y += spacing
            }
        }
    }

    /// 畫整頁（背景＋物件＋筆跡），整頁座標。用於匯出、縮圖。
    static func drawFullPage(_ page: Page, session: NotebookSession, in ctx: CGContext, inkScale: CGFloat) {
        let snap = session.backgroundSnapshot(for: page)
        drawBackground(snap, in: ctx)
        ctx.saveGState()
        ctx.translateBy(x: page.insets.left, y: page.insets.top)
        drawElements(page.elements, session: session, in: ctx)
        if let drawing = session.drawings[page.id], !drawing.strokes.isEmpty {
            let rect = CGRect(x: -page.insets.left, y: -page.insets.top, width: snap.fullSize.width, height: snap.fullSize.height)
            let img = inkImage(drawing, rect: rect, scale: inkScale)
            img.draw(in: rect)
        }
        ctx.restoreGState()
    }

    /// 只畫背景與物件（不含筆跡），整頁座標。截圖時筆跡另外從畫布取得。
    static func drawPageWithoutInk(_ page: Page, session: NotebookSession, in ctx: CGContext) {
        drawBackground(session.backgroundSnapshot(for: page), in: ctx)
        ctx.saveGState()
        ctx.translateBy(x: page.insets.left, y: page.insets.top)
        drawElements(page.elements, session: session, in: ctx)
        ctx.restoreGState()
    }

    static func drawElements(_ elements: [PageElement], session: NotebookSession, in ctx: CGContext) {
        UIGraphicsPushContext(ctx)
        for e in elements {
            ElementRenderer.draw(e, in: e.frame, session: session)
        }
        UIGraphicsPopContext()
    }

    static func inkImage(_ drawing: PKDrawing, rect: CGRect, scale: CGFloat) -> UIImage {
        var img = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            img = drawing.image(from: rect, scale: scale)
        }
        return img
    }
}

enum ElementRenderer {
    /// 在目前的 UIKit context 中畫物件
    static func draw(_ e: PageElement, in rect: CGRect, session: NotebookSession?) {
        switch e.content {
        case let .image(data):
            session?.image(named: data.file)?.draw(in: rect)
        case let .table(t):
            drawTable(t, in: rect)
        case let .text(t):
            drawText(t, in: rect)
        case let .circuit(c):
            CircuitRenderer.draw(c, in: rect)
        }
    }

    static func drawTable(_ t: TableData, in rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), t.rows > 0, t.cols > 0 else { return }
        let size = t.size
        let sx = size.width > 0 ? rect.width / size.width : 1
        let sy = size.height > 0 ? rect.height / size.height : 1
        func map(_ r: CGRect) -> CGRect {
            CGRect(x: rect.minX + r.minX * sx, y: rect.minY + r.minY * sy, width: r.width * sx, height: r.height * sy)
        }

        // 底色
        for f in t.fills where f.row < t.rows && f.col < t.cols {
            UIColor(hex: f.hex).setFill()
            UIRectFill(map(t.cellRect(row: f.row, col: f.col)))
        }

        // 文字（合併格只畫左上角那格的文字）
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: t.fontSize * min(sx, sy)),
            .foregroundColor: UIColor(hex: "#1A1A1AFF"),
            .paragraphStyle: para,
        ]
        for r in 0..<t.rows {
            for c in 0..<t.cols where t.isAnchor(r, c) {
                let text = t.text(row: r, col: c)
                guard !text.isEmpty else { continue }
                let cell = map(t.cellRect(row: r, col: c)).insetBy(dx: 6, dy: 4)
                (text as NSString).draw(with: cell, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: attrs, context: nil)
            }
        }

        ctx.saveGState()
        ctx.setStrokeColor(UIColor(hex: t.lineColorHex).cgColor)
        ctx.setLineWidth(t.lineWidth)
        ctx.setLineCap(.square)
        // 外框往內縮半個線寬，否則會被裁掉一半，看起來比內線細
        let half = t.lineWidth / 2
        let inner = rect.insetBy(dx: half, dy: half)
        ctx.stroke(inner)
        // 內部直線：同一個合併格內的那段不畫
        for c in 1..<max(t.cols, 1) {
            let x = rect.minX + t.colX(c) * sx
            for r in 0..<t.rows {
                if let m = t.merge(at: r, c - 1), m.contains(r, c) { continue }
                ctx.move(to: CGPoint(x: x, y: rect.minY + t.rowY(r) * sy))
                ctx.addLine(to: CGPoint(x: x, y: rect.minY + t.rowY(r + 1) * sy))
            }
        }
        // 內部橫線
        for r in 1..<max(t.rows, 1) {
            let y = rect.minY + t.rowY(r) * sy
            for c in 0..<t.cols {
                if let m = t.merge(at: r - 1, c), m.contains(r, c) { continue }
                ctx.move(to: CGPoint(x: rect.minX + t.colX(c) * sx, y: y))
                ctx.addLine(to: CGPoint(x: rect.minX + t.colX(c + 1) * sx, y: y))
            }
        }
        // 斜線
        for d in t.diagonals where d.row < t.rows && d.col < t.cols {
            let cr = map(t.cellRect(row: d.row, col: d.col))
            if d.reverse {
                ctx.move(to: CGPoint(x: cr.maxX, y: cr.minY))
                ctx.addLine(to: CGPoint(x: cr.minX, y: cr.maxY))
            } else {
                ctx.move(to: CGPoint(x: cr.minX, y: cr.minY))
                ctx.addLine(to: CGPoint(x: cr.maxX, y: cr.maxY))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func textAttributes(_ t: TextBoxData) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        return [
            .font: UIFont.systemFont(ofSize: t.fontSize),
            .foregroundColor: UIColor(hex: t.colorHex),
            .paragraphStyle: para,
        ]
    }

    static func drawText(_ t: TextBoxData, in rect: CGRect) {
        if let bg = t.backgroundHex {
            UIColor(hex: bg).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 4).fill()
        }
        (t.text as NSString).draw(with: rect.insetBy(dx: 6, dy: 4), options: [.usesLineFragmentOrigin],
                                  attributes: textAttributes(t), context: nil)
    }

    static func textHeight(_ t: TextBoxData, width: CGFloat) -> CGFloat {
        let r = (t.text as NSString).boundingRect(with: CGSize(width: max(10, width - 12), height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin], attributes: textAttributes(t), context: nil)
        return ceil(r.height) + 8
    }
}

enum NotebookExporter {
    static func exportPDF(session: NotebookSession) throws -> URL {
        let safe = session.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).pdf")
        try? FileManager.default.removeItem(at: url)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        try renderer.writePDF(to: url) { ctx in
            for page in session.document.pages {
                autoreleasepool {
                    let size = session.fullSize(of: page)
                    ctx.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                    PageRenderer.drawFullPage(page, session: session, in: ctx.cgContext, inkScale: 3)
                }
            }
        }
        return url
    }
}
