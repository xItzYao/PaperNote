// 在 macOS 上檢查 PDFKit 對「一行最後一個字」的回報（回報的問題：選不到每行最後的字）。
// 用和 macOS「列印成 PDF」一樣的結構手寫一個 PDF：內容包在 Form XObject 裡、座標上下翻轉、字級 1 配上很大的 Tm
import Foundation
import PDFKit

func pdf(_ objects: [String]) -> Data {
    var out = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (i, o) in objects.enumerated() {
        offsets.append(out.utf8.count)
        out += "\(i + 1) 0 obj\n\(o)\nendobj\n"
    }
    let xref = out.utf8.count
    out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for o in offsets { out += String(format: "%010d 00000 n \n", o) }
    out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(out.utf8)
}

func stream(_ s: String, _ dict: String = "") -> String { "<< \(dict) /Length \(s.utf8.count) >>\nstream\n\(s)\nendstream" }

let form = """
q 0.1347653 0 0 -0.1347653 0 595.32 cm BT 0.003 Tc 327.68 0 0 -327.68 1547.52 2513.76 Tm /G4 1 Tf [ (Intr) 20 (oduction) 10 ( to Matla) 7 (b) ] TJ ET Q
q 0.1347653 0 0 -0.1347653 0 595.32 cm BT 0.003 Tc 163.84 0 0 -163.84 1855 3510 Tm /G4 1 Tf [ (Department of Electrical Engineerin) 5 (g) ] TJ ET Q
"""
let data = pdf([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 841.92 595.32] /Resources << /XObject << /Fm1 4 0 R >> >> /Contents 5 0 R >>",
    stream(form, "/Type /XObject /Subtype /Form /BBox [20.26 0 817.8 595.32] /Resources << /Font << /G4 6 0 R >> >>"),
    stream("q /Fm1 Do Q"),
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>",
])

guard let doc = PDFDocument(data: data), let page = doc.page(at: 0), let text = page.string else { fatalError("cannot open pdf") }
print("page.string =", text.debugDescription)
var failures = 0
let ns = text as NSString
for word in ["Matlab", "Engineering"] {
    let r = ns.range(of: word)
    guard r.location != NSNotFound else { print("FAIL \(word) not found"); failures += 1; continue }
    let last = r.location + r.length - 1
    for i in (last - 2)...min(last + 1, page.numberOfCharacters - 1) {
        print("  char \(i) \(ns.substring(with: NSRange(location: i, length: 1)).debugDescription) bounds", page.characterBounds(at: i))
    }
    let b = page.characterBounds(at: last)
    let p = CGPoint(x: b.minX + b.width * 0.75, y: b.midY)
    let hit = page.characterIndex(at: p)
    print("\(word): last=\(last) bounds=\(b) characterIndex(at 3/4)=\(hit)")
    if b.width <= 0 { print("FAIL \(word): last character has no width"); failures += 1 }
    if hit != last { print("FAIL \(word): characterIndex on the last character = \(hit)"); failures += 1 }
    let first = page.characterBounds(at: r.location)
    let start = CGPoint(x: first.minX + 1, y: first.midY)
    print("  selection(from:to:) ending at 3/4 of the last char =", page.selection(from: start, to: p)?.string.debugDescription ?? "nil")
    let past = CGPoint(x: b.maxX + 6, y: b.midY)
    print("  characterIndex(at past the end) =", page.characterIndex(at: past))
    // App 舊的做法（PDFKit 自己決定頭尾）：筆拖過行尾、停在最後一個字上
    print("  OLD selection(from:to:) past the end =", page.selection(from: start, to: past)?.string.debugDescription ?? "nil")
    for k in [0.25, 0.5, 0.9] {
        let q = CGPoint(x: b.minX + b.width * k, y: b.midY)
        print("  OLD selection(from:to:) ending at \(k) of the last char =", page.selection(from: start, to: q)?.string.debugDescription ?? "nil")
    }
    print("  selection(for: word) =", page.selection(for: r)?.string.debugDescription ?? "nil",
          "bounds", page.selection(for: r)?.bounds(for: page) ?? .zero)
}
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
