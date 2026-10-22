// 在 macOS 上驗證 PDF 選字的座標轉換（和 App 內 NotebookSession.displayTransform 相同的公式）
import Foundation
import PDFKit
import CoreText
import CoreGraphics

func displayTransform(for p: PDFPage) -> CGAffineTransform {
    let c = p.bounds(for: .cropBox)
    let x0 = c.minX, y0 = c.minY, w = c.width, h = c.height
    switch ((p.rotation % 360) + 360) % 360 {
    case 90: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: -y0, ty: -x0)
    case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: x0 + w, ty: -y0)
    case 270: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: y0 + h, ty: x0 + w)
    default: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -x0, ty: y0 + h)
    }
}

let url = URL(fileURLWithPath: NSTemporaryDirectory() + "check.pdf")
var box = CGRect(x: 0, y: 0, width: 595, height: 842)
let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
ctx.beginPDFPage(nil)
let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
let attrs = [NSAttributedString.Key(kCTFontAttributeName as String): font]
for (i, s) in ["Hello PaperNote selection test", "Second line of text here"].enumerated() {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    ctx.textPosition = CGPoint(x: 72, y: 700 - CGFloat(i) * 40)
    CTLineDraw(line, ctx)
}
ctx.endPDFPage()
ctx.closePDF()

guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { fatalError("cannot open pdf") }
print("page.string =", page.string ?? "nil")
print("numberOfCharacters =", page.numberOfCharacters)
print("char0 bounds (page space) =", page.characterBounds(at: 0))

let toPDF = displayTransform(for: page).inverted()
// 第一行基線 y=700（由下往上）→ 顯示座標 y≈142，字約在 y 120~146
let a = CGPoint(x: 70, y: 135).applying(toPDF)
let b = CGPoint(x: 400, y: 175).applying(toPDF)
print("drag a =", a, " b =", b)
print("selection(from:to:) =", page.selection(from: a, to: b)?.string ?? "nil")
print("selectionForWord =", page.selectionForWord(at: CGPoint(x: 100, y: 135).applying(toPDF))?.string ?? "nil")
print("characterIndex(at:) =", page.characterIndex(at: CGPoint(x: 100, y: 135).applying(toPDF)))
if let sel = page.selection(from: a, to: b) {
    for line in sel.selectionsByLine() {
        print("line rect (display) =", line.bounds(for: page).applying(displayTransform(for: page)), line.string ?? "")
    }
}
