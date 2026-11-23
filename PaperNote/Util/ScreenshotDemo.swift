#if DEBUG
import UIKit
import PencilKit

/// App Store 截圖用的示範筆記（只在 Debug 版；UI 測試 AppStoreScreenshotUITests 加 -screenshotDemo 才會建立）。
/// 內容都是自己寫的：沒有課本、講義，也沒有任何人的資料。每次啟動先清空資料庫再重建，截出來每次都一樣
enum ScreenshotDemo {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-screenshotDemo") }

    /// notes、pdf、extend、circuit、table、pin、library
    static var scene: String {
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-screenshotScene"), i + 1 < a.count { return a[i + 1] }
        return "notes"
    }

    static var english: Bool { AppLanguage.current == .english }
    static func t(_ zh: String, _ en: String) -> String { english ? en : zh }

    /// 主要那一本（編輯器看到是這一本才擺場景）
    private(set) static var mainID: UUID?
    /// 每個場景要看的頁
    private(set) static var scenePages: [String: UUID] = [:]
    private(set) static var circuitRef: ElementRef?
    private(set) static var selectedPart: UUID?
    private(set) static var tableRef: ElementRef?
    private(set) static var pdfPageID: UUID?

    // MARK: 顏色、字體

    static let black = "#1A1A1AFF"
    static let blue = "#1E4FB4FF"
    static let navy = "#1E3A8AFF"
    static let red = "#D32F2FFF"
    static let gray = "#6B6B6BFF"
    static let hand = "Iansui-Regular"

    // MARK: 建立

    /// 清空資料庫、建立示範資料；回傳要打開的筆記本（書櫃那張不打開）
    static func build(store: LibraryStore) -> (notebook: UUID, page: UUID, otherTabs: [UUID])? {
        for nb in store.index.notebooks { store.deleteNotebook(nb.id) }
        for f in store.index.folders where f.parentId == nil { store.deleteFolder(f.id) }
        TabStore.shared.prune(existing: [])
        PinStore.shared.removeAll()
        scenePages = [:]

        for name in [t("社團", "Club"), t("大一", "Freshman year"), t("大二上", "Sophomore fall")] {
            _ = store.createFolder(name: name, parent: nil)
        }
        // 最後改的排最前面：主要那一本最後建
        let lab = simpleNotebook(store, title: t("普物實驗報告", "Physics Lab Reports"), cover: 5, paper: .ruled, seed: 11,
                                 lines: t("實驗 6　單擺週期\nT = 2π √(L / g)\nL = 0.80 m，T = 1.79 s\n→ g ≈ 9.86 m/s²",
                                          "Lab 6  Pendulum period\nT = 2π √(L / g)\nL = 0.80 m, T = 1.79 s\n→ g ≈ 9.86 m/s²"))
        let circuits = simpleNotebook(store, title: t("電路學", "Circuit Analysis"), cover: 1, paper: .grid, seed: 12,
                                      lines: t("節點電壓法\nKCL：流入 = 流出\n(V₁ − 5) / 2k + V₁ / 1k\n  + (V₁ − V₂) / 3k = 0",
                                               "Nodal analysis\nKCL: in = out\n(V₁ − 5) / 2k + V₁ / 1k\n  + (V₁ − V₂) / 3k = 0"))
        let exam = simpleNotebook(store, title: t("期中考重點", "Midterm Review"), cover: 2, paper: .dotted, seed: 13,
                                  lines: t("期中考範圍\n1. 二極體電路\n2. BJT 偏壓\n3. 小訊號模型\n4. 運算放大器",
                                           "Midterm topics\n1. Diode circuits\n2. BJT biasing\n3. Small-signal models\n4. Op amps"))
        let calculus = simpleNotebook(store, title: t("微積分習題", "Calculus Homework"), cover: 4, paper: .grid, seed: 14,
                                      lines: t("4.3 分部積分\n∫ x eˣ dx = x eˣ − ∫ eˣ dx\n= (x − 1) eˣ + C",
                                               "4.3 Integration by parts\n∫ x eˣ dx = x eˣ − ∫ eˣ dx\n= (x − 1) eˣ + C"))
        _ = (lab, circuits)
        guard let main = mainNotebook(store) else { return nil }
        store.setStarred(main, true)
        mainID = main
        guard scene != "library", let page = scenePages[scene] ?? scenePages["notes"] else { return nil }
        return (main, page, [calculus, exam])
    }

    private static func simpleNotebook(_ store: LibraryStore, title: String, cover: Int, paper: PaperStyle, seed: UInt64,
                                       lines: String) -> UUID {
        let meta = store.createNotebook(title: title, folder: nil, paper: paper, landscape: false, coverHex: Palette.covers[cover])
        guard let s = try? NotebookSession(id: meta.id) else { return meta.id }
        var p = s.document.pages[0]
        let first = lines.components(separatedBy: "\n").first ?? ""
        let rest = lines.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        let head = text(first, 48, 50, w: 480, size: 34, color: navy)
        p.elements.append(head)
        p.elements.append(text(rest, 48, head.frame.maxY + 16, w: 500, size: 26))
        var h = DemoHand(seed: seed, color: navy, width: 2.4)
        p.ink.append(h.line(CGPoint(x: 52, y: head.frame.maxY + 2), CGPoint(x: 330, y: head.frame.maxY + 5)))
        h.color = red
        p.ink.append(h.ellipse(CGPoint(x: 400, y: 600), rx: 90, ry: 55))
        p.ink.append(contentsOf: h.arrow(CGPoint(x: 150, y: 680), CGPoint(x: 300, y: 610)))
        s.document.pages = [p]
        s.save()
        s.writeLibraryThumbnails()
        return meta.id
    }

    // MARK: 主要那一本

    private static func mainNotebook(_ store: LibraryStore) -> UUID? {
        let meta = store.createNotebook(title: t("電子學筆記", "Electronics Notes"), folder: nil, paper: .grid, landscape: false,
                                        coverHex: Palette.covers[0])
        guard let s = try? NotebookSession(id: meta.id) else { return nil }
        let file = "handout.pdf"
        let handout = Handout.make()
        try? handout.data.write(to: s.filesURL.appendingPathComponent(file), options: .atomic)

        let notes = notesPage(s)
        var pdf1 = Page(background: .pdf(file: file, index: 0))
        var pdf2 = Page(background: .pdf(file: file, index: 1))
        decoratePDF1(&pdf1, marks: handout.marks)
        decoratePDF2(&pdf2, marks: handout.marks)
        let circuit = circuitPage()
        let table = tablePage()
        let practice = practicePage()
        s.document.pages = [notes, pdf1, pdf2, circuit, table, practice]
        s.save()
        s.writeLibraryThumbnails()

        scenePages = ["notes": notes.id, "pdf": pdf1.id, "extend": pdf2.id, "circuit": circuit.id,
                      "table": table.id, "pin": practice.id]
        pdfPageID = pdf1.id
        if let e = circuit.elements.first(where: \.isCircuit) { circuitRef = ElementRef(pageID: circuit.id, elementID: e.id) }
        if let e = table.elements.first(where: \.isTable) { tableRef = ElementRef(pageID: table.id, elementID: e.id) }
        return meta.id
    }

    /// 第 1 頁：RC 低通濾波器的手寫筆記
    private static func notesPage(_ s: NotebookSession) -> Page {
        var p = Page(background: .paper(width: 595, height: 842, style: .grid))
        var h = DemoHand(seed: 1, color: navy, width: 2.2)
        let title = text(t("Ch.3　RC 低通濾波器", "Ch.3  RC Low-pass Filter"), 36, 30, w: 520, size: 30, color: navy)
        p.elements.append(title)
        p.ink.append(h.line(CGPoint(x: 42, y: title.frame.maxY), CGPoint(x: 330, y: title.frame.maxY + 3)))

        p.elements.append(text(t("電容的阻抗隨頻率變小：\nZc = 1 / (jωC)\n高頻被電容短路到地，\n低頻可以通過。",
                                 "Capacitor impedance falls\nwith frequency:\nZc = 1 / (jωC)\nHighs are shunted to\nground, lows pass."),
                               36, 100, w: 290, size: 19))
        p.elements.append(PageElement(frame: CGRect(x: 330, y: 92, width: 250, height: 190), content: .circuit(rcFilter())))

        // 公式圈起來、拉一條線寫註解
        let formula = text("fc = 1 / (2πRC)", 56, 290, w: 300, size: 28)
        p.elements.append(formula)
        let fw = width(of: "fc = 1 / (2πRC)", size: 28)
        let c = CGPoint(x: formula.frame.minX + 6 + fw / 2, y: formula.frame.midY)
        h.color = red
        p.ink.append(h.ellipse(c, rx: fw / 2 + 20, ry: formula.frame.height / 2 + 8))
        p.ink.append(contentsOf: h.arrow(CGPoint(x: c.x + fw / 2 + 24, y: c.y - 2), CGPoint(x: 410, y: c.y - 2)))
        p.elements.append(text(t("截止頻率\n（−3 dB）", "cutoff\n(−3 dB)"), 414, c.y - 26, w: 150, size: 19, color: red))

        // 手畫的波德圖
        h.color = black
        h.width = 1.8
        let o = CGPoint(x: 80, y: 590)
        p.ink.append(contentsOf: h.arrow(CGPoint(x: o.x - 10, y: o.y), CGPoint(x: 540, y: o.y)))
        p.ink.append(contentsOf: h.arrow(CGPoint(x: o.x, y: o.y + 10), CGPoint(x: o.x, y: 380)))
        let knee: CGFloat = 280
        h.color = blue
        h.width = 2.4
        p.ink.append(h.curve(from: o.x + 4, to: 520) { x in
            let u = (x - knee) / 130
            let db = -10 * log10(1 + pow(10, 2 * u))
            return 420 - db * 3.8
        })
        h.color = gray
        h.width = 1.4
        var y: CGFloat = 420
        while y < o.y - 4 {
            p.ink.append(h.line(CGPoint(x: knee, y: y), CGPoint(x: knee, y: min(y + 8, o.y - 4))))
            y += 14
        }
        p.elements.append(text("|H| (dB)", o.x + 6, 372, w: 120, size: 16, color: gray))
        p.elements.append(text("log f", 492, o.y + 4, w: 90, size: 16, color: gray))
        p.elements.append(text("fc", knee - 10, o.y + 4, w: 60, size: 18, color: gray))
        p.elements.append(text("−3 dB", knee + 8, 408, w: 90, size: 16, color: red))

        let key = text(t("重點：R 或 C 越大，fc 越低。", "Key point: larger R or C means a lower fc."), 36, 640, w: 540, size: 21)
        p.elements.append(key)
        let kw = width(of: t("重點：R 或 C 越大，fc 越低。", "Key point: larger R or C means a lower fc."), size: 21)
        s.drawings[p.id] = PKDrawing(strokes: [marker([CGPoint(x: 40, y: key.frame.midY + 2), CGPoint(x: 42 + kw + 4, y: key.frame.midY + 3)],
                                                      color: UIColor(hex: "#FFE14DFF"), width: 20)])

        let example = text(t("例：R = 1 kΩ、C = 100 nF\n→ fc = 1 / (2π × 10³ × 10⁻⁷) ≈ 1.6 kHz",
                             "e.g. R = 1 kΩ, C = 100 nF\n→ fc = 1 / (2π × 10³ × 10⁻⁷) ≈ 1.6 kHz"),
                           36, 700, w: 540, size: 20)
        p.elements.append(example)
        h.color = blue
        h.width = 2.4
        p.ink.append(h.check(at: CGPoint(x: 500, y: example.frame.maxY - 8)))
        return p
    }

    /// PDF 第 1 頁：反相放大器。螢光筆、旁邊的註解
    private static func decoratePDF1(_ p: inout Page, marks: [String: [CGRect]]) {
        p.highlights = [
            TextHighlight(rects: marks["vshort"] ?? [], colorHex: "#FFF176FF"),
            TextHighlight(rects: marks["gain"] ?? [], colorHex: "#B9F6CAFF"),
            TextHighlight(rects: marks["ratio"] ?? [], colorHex: "#F8BBD0FF"),
        ]
        p.elements.append(PageElement(frame: CGRect(x: 128, y: 302, width: 340, height: 200), content: .circuit(invertingAmp())))
        var h = DemoHand(seed: 2, color: red, width: 2.2)
        if let r = marks["vshort"]?.last {
            let note = CGPoint(x: 470, y: r.midY + 34)
            p.ink.append(contentsOf: h.arrow(CGPoint(x: r.maxX + 4, y: r.maxY + 2), CGPoint(x: note.x - 6, y: note.y - 6)))
            p.elements.append(text("v₊ = v₋", note.x, note.y - 16, w: 120, size: 22, color: red))
        }
        if let r = marks["gain"]?.first {
            p.ink.append(h.star(at: CGPoint(x: r.minX - 26, y: r.midY), r: 10))
        }
        h.color = blue
        if let r = marks["example"]?.first {
            p.ink.append(h.line(CGPoint(x: r.minX, y: r.maxY + 3), CGPoint(x: r.maxX, y: r.maxY + 5)))
        }
    }

    /// PDF 第 2 頁：右邊擴展出來寫補充
    private static func decoratePDF2(_ p: inout Page, marks: [String: [CGRect]]) {
        p.insets.right = 260
        p.highlights = [TextHighlight(rects: marks["gain2"] ?? [], colorHex: "#FFF176FF")]
        p.elements.append(PageElement(frame: CGRect(x: 128, y: 302, width: 340, height: 200), content: .circuit(nonInvertingAmp())))
        var h = DemoHand(seed: 3, color: red, width: 2.2)
        let note = text(t("補充\n反相：Av = −Rf / Rin\n非反相：Av = 1 + Rf / Rin\n→ 不會反相，\n　輸入阻抗很大",
                          "Compare\nInverting: Av = −Rf / Rin\nNon-inverting:\n  Av = 1 + Rf / Rin\n→ no inversion,\n  high input impedance"),
                        612, 150, w: 230, size: 19, color: blue)
        p.elements.append(note)
        if let r = marks["gain2"]?.first {
            p.ink.append(contentsOf: h.arrow(CGPoint(x: r.maxX + 8, y: r.midY), CGPoint(x: 604, y: note.frame.minY + 40)))
        }
        p.elements.append(text(t("電壓隨耦器", "Voltage follower"), 618, 400, w: 220, size: 19, color: blue))
        p.elements.append(PageElement(frame: CGRect(x: 622, y: 432, width: 200, height: 130), content: .circuit(follower())))
        h.color = blue
        p.ink.append(h.line(CGPoint(x: 616, y: note.frame.minY + 30), CGPoint(x: 700, y: note.frame.minY + 32)))
    }

    /// 電路圖：主動低通濾波器（截圖時選著 C1、旁邊是元件庫）
    private static func circuitPage() -> Page {
        var p = Page(background: .paper(width: 595, height: 842, style: .grid))
        let title = text(t("實驗 3　主動低通濾波器", "Lab 3  Active Low-pass Filter"), 36, 30, w: 520, size: 30, color: navy)
        p.elements.append(title)
        var h = DemoHand(seed: 4, color: navy, width: 2.2)
        p.ink.append(h.line(CGPoint(x: 42, y: title.frame.maxY), CGPoint(x: 380, y: title.frame.maxY + 3)))
        p.elements.append(PageElement(frame: CGRect(x: 40, y: 100, width: 500, height: 290), content: .circuit(activeFilter())))
        let notes = text(t("增益：Av = −R2 / R1 = −4.7\n截止頻率：fc = 1 / (2π R2 C1) ≈ 3.4 kHz",
                           "Gain: Av = −R2 / R1 = −4.7\nCutoff: fc = 1 / (2π R2 C1) ≈ 3.4 kHz"),
                         36, 410, w: 540, size: 21)
        p.elements.append(notes)
        h.color = red
        p.ink.append(h.box(notes.frame.insetBy(dx: -4, dy: -6)))
        return p
    }

    /// 表格：元件阻抗整理（截圖時選著）
    private static func tablePage() -> Page {
        var p = Page(background: .paper(width: 595, height: 842, style: .ruled))
        let title = text(t("元件阻抗整理", "Impedance Cheat Sheet"), 36, 30, w: 520, size: 30, color: navy)
        p.elements.append(title)
        var tb = TableData(colWidths: [120, 80, 150, 120], rowHeights: [50, 50, 50, 50],
                           cells: [[t("元件", "Part"), t("符號", "Symbol"), t("阻抗 Z", "Impedance Z"), t("相位", "Phase")],
                                   [t("電阻", "Resistor"), "R", "R", "0°"],
                                   [t("電容", "Capacitor"), "C", "1 / (jωC)", "−90°"],
                                   [t("電感", "Inductor"), "L", "jωL", "+90°"]])
        tb.fontSize = 18
        tb.fills = (0..<4).map { CellFill(row: 0, col: $0, hex: "#DCE8F7FF") }
        p.elements.append(PageElement(frame: CGRect(x: 58, y: 110, width: tb.size.width, height: tb.size.height), content: .table(tb)))
        let notes = text(t("口訣：ELI the ICE man\nL：電壓 E 領先電流 I\nC：電流 I 領先電壓 E",
                           "ELI the ICE man\nL: voltage E leads current I\nC: current I leads voltage E"),
                         56, 340, w: 500, size: 22)
        p.elements.append(notes)
        var h = DemoHand(seed: 5, color: red, width: 2.2)
        let w = width(of: "ELI the ICE man", size: 22) + (english ? 0 : width(of: "口訣：", size: 22))
        p.ink.append(h.line(CGPoint(x: 62, y: notes.frame.minY + 36), CGPoint(x: 66 + w, y: notes.frame.minY + 38)))
        h.color = blue
        p.ink.append(contentsOf: h.arrow(CGPoint(x: 480, y: 270), CGPoint(x: 420, y: 238)))
        p.elements.append(text(t("記得 j！", "don't forget j!"), 470, 270, w: 120, size: 19, color: blue))
        return p
    }

    /// 習題：寫在空白頁上，題目用截圖釘在旁邊
    private static func practicePage() -> Page {
        var p = Page(background: .paper(width: 595, height: 842, style: .grid))
        let title = text(t("習題 5-1", "Exercise 5-1"), 36, 30, w: 300, size: 30, color: navy)
        p.elements.append(title)
        let work = text("Av = −Rf / Rin\n    = −47 kΩ / 10 kΩ\n    = −4.7\nVout = Av × Vin\n        = −4.7 × 0.2 V\n        = −0.94 V",
                        48, 100, w: 330, size: 26)
        p.elements.append(work)
        var h = DemoHand(seed: 6, color: red, width: 2.4)
        let line = work.frame.height / 6
        p.ink.append(h.box(CGRect(x: work.frame.minX + 70, y: work.frame.maxY - line - 2, width: 150, height: line + 4)))
        h.color = blue
        p.ink.append(h.check(at: CGPoint(x: 260, y: work.frame.maxY - line / 2)))
        p.elements.append(text(t("負號＝輸出反相", "minus sign = inverted output"), 48, work.frame.maxY + 30, w: 400, size: 20, color: blue))
        return p
    }

    // MARK: 電路圖

    private static func part(_ kind: CircuitPart, _ x: CGFloat, _ y: CGFloat, rotation: Int = 0,
                             name: String? = nil, value: String? = nil, prefix: String? = nil) -> CircuitComponent {
        var c = CircuitComponent(part: kind, position: CGPoint(x: x, y: y))
        c.rotation = rotation
        c.name = name
        c.value = value
        c.valuePrefix = prefix
        if name != nil { c.nameOffset = CircuitComponent.defaultNameOffset(c) }
        return c
    }

    private static func wire(_ pts: [(CGFloat, CGFloat)], label: String? = nil, at: CGPoint? = nil) -> CircuitWire {
        var w = CircuitWire(points: pts.map { CGPoint(x: $0.0, y: $0.1) })
        w.label = label
        w.labelPosition = at
        return w
    }

    private static func rcFilter() -> CircuitData {
        var d = CircuitData()
        d.components = [part(.sineSource, 40, 100, rotation: 90, name: "Vin"),
                        part(.resistor, 110, 40, name: "R", value: "1", prefix: "K"),
                        part(.capacitor, 180, 100, rotation: 90, name: "C", value: "100", prefix: "n"),
                        part(.ground, 110, 170)]
        d.wires = [wire([(40, 70), (40, 40), (80, 40)]),
                   wire([(140, 40), (180, 40), (180, 70)]),
                   wire([(180, 40), (230, 40)], label: "Vout", at: CGPoint(x: 214, y: 26)),
                   wire([(40, 130), (40, 150), (180, 150), (180, 130)])]
        return d
    }

    private static func invertingAmp() -> CircuitData {
        var d = CircuitData()
        d.components = [part(.resistor, 90, 90, name: "Rin", value: "10", prefix: "K"),
                        part(.opAmp, 200, 110),
                        part(.resistor, 190, 40, name: "Rf", value: "47", prefix: "K"),
                        part(.ground, 140, 170)]
        d.wires = [wire([(20, 90), (60, 90)], label: "Vin", at: CGPoint(x: 32, y: 76)),
                   wire([(120, 90), (160, 90)]),
                   wire([(140, 90), (140, 40), (160, 40)]),
                   wire([(220, 40), (260, 40), (260, 110)]),
                   wire([(240, 110), (310, 110)], label: "Vout", at: CGPoint(x: 294, y: 96)),
                   wire([(160, 130), (140, 130), (140, 150)])]
        return d
    }

    private static func nonInvertingAmp() -> CircuitData {
        var d = CircuitData()
        d.components = [part(.opAmp, 200, 110),
                        part(.resistor, 190, 40, name: "Rf", value: "47", prefix: "K"),
                        part(.resistor, 100, 90, name: "Rin", value: "10", prefix: "K"),
                        part(.ground, 70, 120)]
        d.wires = [wire([(20, 150), (150, 150), (150, 130), (160, 130)], label: "Vin", at: CGPoint(x: 36, y: 136)),
                   wire([(130, 90), (160, 90)]),
                   wire([(140, 90), (140, 40), (160, 40)]),
                   wire([(220, 40), (260, 40), (260, 110)]),
                   wire([(240, 110), (310, 110)], label: "Vout", at: CGPoint(x: 294, y: 96)),
                   wire([(70, 90), (70, 100)])]
        return d
    }

    private static func follower() -> CircuitData {
        var d = CircuitData()
        d.components = [part(.opAmp, 90, 70)]
        d.wires = [wire([(130, 70), (185, 70)], label: "Vout", at: CGPoint(x: 168, y: 56)),
                   wire([(150, 70), (150, 20), (30, 20), (30, 50), (50, 50)]),
                   wire([(5, 90), (50, 90)], label: "Vin", at: CGPoint(x: 18, y: 104))]
        return d
    }

    private static func activeFilter() -> CircuitData {
        let dy: CGFloat = 20
        func w(_ pts: [(CGFloat, CGFloat)], label: String? = nil, at: CGPoint? = nil) -> CircuitWire {
            wire(pts.map { ($0.0, $0.1 + dy) }, label: label, at: at.map { CGPoint(x: $0.x, y: $0.y + dy) })
        }
        func c(_ kind: CircuitPart, _ x: CGFloat, _ y: CGFloat, rotation: Int = 0,
               name: String? = nil, value: String? = nil, prefix: String? = nil) -> CircuitComponent {
            part(kind, x, y + dy, rotation: rotation, name: name, value: value, prefix: prefix)
        }
        var d = CircuitData()
        let c1 = c(.capacitor, 320, 30, name: "C1", value: "1", prefix: "n")
        d.components = [c(.sineSource, 80, 190, rotation: 90, name: "Vin"),
                        c(.ground, 80, 240),
                        c(.resistor, 180, 140, name: "R1", value: "10", prefix: "K"),
                        c(.opAmp, 320, 160),
                        c(.resistor, 320, 80, name: "R2", value: "47", prefix: "K"),
                        c1,
                        c(.ground, 260, 220)]
        d.wires = [w([(80, 160), (80, 140), (150, 140)]),
                   w([(210, 140), (280, 140)]),
                   w([(240, 140), (240, 80), (290, 80)]),
                   w([(240, 80), (240, 30), (290, 30)]),
                   w([(350, 80), (390, 80), (390, 160)]),
                   w([(350, 30), (390, 30), (390, 80)]),
                   w([(360, 160), (450, 160)], label: "Vout", at: CGPoint(x: 434, y: 146)),
                   w([(280, 180), (260, 180), (260, 200)])]
        selectedPart = c1.id
        return d
    }

    // MARK: 文字框、螢光筆

    static func text(_ s: String, _ x: CGFloat, _ y: CGFloat, w: CGFloat, size: CGFloat = 20, color: String = black) -> PageElement {
        let data = TextBoxData(text: s, fontSize: size, colorHex: color, fontName: hand)
        let h = ElementRenderer.textHeight(data, width: w)
        return PageElement(frame: CGRect(x: x, y: y, width: w, height: h), content: .text(data))
    }

    static func width(of s: String, size: CGFloat) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: TextFonts.font(hand, size: size)]).width
    }

    static func marker(_ pts: [CGPoint], color: UIColor, width: CGFloat) -> PKStroke {
        var dense: [CGPoint] = []
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let n = max(2, Int(hypot(b.x - a.x, b.y - a.y) / 4))
            for k in 0..<n {
                let t = CGFloat(k) / CGFloat(n)
                dense.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        dense.append(pts[pts.count - 1])
        let points = dense.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.008, size: CGSize(width: width, height: width),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.marker, color: color), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    // MARK: 完成

    /// UI 測試等這個出現才截圖
    static func markReady(in view: UIView?, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let window: UIView? = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
            let host: UIView? = view ?? window
            guard let host else { return }
            let l = UILabel(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
            l.isAccessibilityElement = true
            l.accessibilityIdentifier = "screenshotReady"
            l.accessibilityLabel = "ready"
            host.addSubview(l)
        }
    }

    /// 截圖懸浮的那張：PDF 第 1 頁的圖和例題
    static func pinImage(_ session: NotebookSession) -> UIImage? {
        guard let id = pdfPageID, let page = session.document.pages.first(where: { $0.id == id }) else { return nil }
        let crop = CGRect(x: 44, y: 292, width: 507, height: 362)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: crop.size, format: fmt).image { rc in
            rc.cgContext.translateBy(x: -crop.minX, y: -crop.minY)
            PageRenderer.drawFullPage(page, session: session, in: rc.cgContext, inkScale: 2)
        }
    }
}

// MARK: - 講義 PDF（自己寫的內容）

private enum Handout {
    static func make() -> (data: Data, marks: [String: [CGRect]]) {
        let t = ScreenshotDemo.t
        var marks: [String: [CGRect]] = [:]
        let serif = { (size: CGFloat) in UIFont(name: "NotoSerifTC-Regular", size: size) ?? .systemFont(ofSize: size) }
        let ink = UIColor(white: 0.13, alpha: 1)
        let gray = UIColor(white: 0.45, alpha: 1)

        func run(_ parts: [(String, String?)], x: CGFloat, y: CGFloat, font: UIFont, color: UIColor = ink) {
            var cx = x
            for (s, key) in parts {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                (s as NSString).draw(at: CGPoint(x: cx, y: y), withAttributes: attrs)
                let w = (s as NSString).size(withAttributes: attrs).width
                if let key {
                    marks[key, default: []].append(CGRect(x: cx - 1, y: y + font.lineHeight * 0.06, width: w + 2, height: font.lineHeight * 0.9))
                }
                cx += w
            }
        }
        func centered(_ s: String, y: CGFloat, font: UIFont, color: UIColor = ink, key: String? = nil) {
            let w = (s as NSString).size(withAttributes: [.font: font]).width
            run([(s, key)], x: (595 - w) / 2, y: y, font: font, color: color)
        }
        func header(_ page: Int) {
            run([(t("電子學講義　第 5 章　運算放大器", "Electronics Handout  Chapter 5  Operational Amplifiers"), nil)],
                x: 56, y: 36, font: serif(10), color: gray)
            gray.setFill()
            UIRectFill(CGRect(x: 56, y: 54, width: 483, height: 0.6))
            centered("— 5-\(page) —", y: 800, font: serif(10), color: gray)
        }

        let body = serif(13.5)
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            ctx.beginPage()
            header(4)
            run([(t("5.2　反相放大器", "5.2  The Inverting Amplifier"), nil)], x: 56, y: 76, font: serif(22))
            var y: CGFloat = 122
            let lines: [[(String, String?)]] = ScreenshotDemo.english ? [
                [("An ideal op amp rests on two assumptions: its inputs", nil)],
                [("draw no current, and with negative feedback the two", nil)],
                [("inputs sit at the same voltage, a ", nil), ("virtual short", "vshort"), (".", nil)],
                [("From these, the voltage gain of the inverting amplifier is", nil)],
            ] : [
                [("理想運算放大器有兩個重要的假設：輸入端不吸收電流，", nil)],
                [("而且在負回授下，兩個輸入端的電壓相等，稱為", nil), ("虛短路", "vshort"), ("。", nil)],
                [("利用這兩個假設，可以求出反相放大器的電壓增益：", nil)],
            ]
            for l in lines {
                run(l, x: 56, y: y, font: body)
                y += 24
            }
            centered("Av = Vout / Vin = − Rf / Rin", y: y + 8, font: serif(18), key: "gain")
            y += 50
            let more: [[(String, String?)]] = ScreenshotDemo.english ? [
                [("The gain depends only on ", nil), ("the ratio of two resistors", "ratio"), (",", nil)],
                [("not on the op amp itself, which is why negative-feedback", nil)],
                [("circuits are stable and easy to design.", nil)],
            ] : [
                [("增益只由", nil), ("兩個電阻的比值", "ratio"), ("決定，和運算放大器本身無關，", nil)],
                [("這也是負回授電路穩定、容易設計的原因。", nil)],
            ]
            for l in more {
                run(l, x: 56, y: y, font: body)
                y += 24
            }
            centered(t("圖 5-3　反相放大器", "Figure 5-3  Inverting amplifier"), y: 512, font: serif(11), color: gray)
            UIColor(white: 0.55, alpha: 1).setStroke()
            let box = UIBezierPath(rect: CGRect(x: 56, y: 556, width: 483, height: 86))
            box.lineWidth = 0.8
            box.stroke()
            run([(t("例題 5-1", "Example 5-1"), "example")], x: 70, y: 568, font: serif(14))
            run([(t("Rin = 10 kΩ、Rf = 47 kΩ、Vin = 0.2 V，", "Rin = 10 kΩ, Rf = 47 kΩ and Vin = 0.2 V."), nil)], x: 70, y: 594, font: body)
            run([(t("求電壓增益 Av 與輸出電壓 Vout。", "Find the voltage gain Av and the output Vout."), nil)], x: 70, y: 616, font: body)

            ctx.beginPage()
            header(5)
            run([(t("5.3　非反相放大器", "5.3  The Non-inverting Amplifier"), nil)], x: 56, y: 76, font: serif(22))
            y = 122
            let p2: [[(String, String?)]] = ScreenshotDemo.english ? [
                [("The signal enters the positive input, while the feedback", nil)],
                [("resistor still returns to the negative input. The output", nil)],
                [("is in phase with the input, and the gain is", nil)],
            ] : [
                [("訊號從正輸入端進來，回授電阻仍然接到負輸入端。", nil)],
                [("輸出和輸入同相，電壓增益為：", nil)],
            ]
            for l in p2 {
                run(l, x: 56, y: y, font: body)
                y += 24
            }
            centered("Av = 1 + Rf / Rin", y: y + 8, font: serif(18), key: "gain2")
            y += 50
            let p3: [[(String, String?)]] = ScreenshotDemo.english ? [
                [("With Rf = 0 and Rin left open the gain is 1: the", nil)],
                [("voltage follower, often used as a buffer.", nil)],
            ] : [
                [("當 Rf = 0、Rin 開路時，增益為 1，就是電壓隨耦器，", nil)],
                [("常用來當作緩衝級。", nil)],
            ]
            for l in p3 {
                run(l, x: 56, y: y, font: body)
                y += 24
            }
            centered(t("圖 5-4　非反相放大器", "Figure 5-4  Non-inverting amplifier"), y: 512, font: serif(11), color: gray)
        }
        return (data, marks)
    }
}

// MARK: - 手寫的筆跡（固定的亂數：每次都一樣）

struct DemoHand {
    private var state: UInt64
    var color: String
    var width: CGFloat
    var wobble: CGFloat = 0.5

    init(seed: UInt64, color: String, width: CGFloat) {
        state = seed &* 0x9E3779B97F4A7C15 | 1
        self.color = color
        self.width = width
    }

    private mutating func noise() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(Double(state >> 11) / Double(UInt64(1) << 53)) * 2 - 1
    }

    /// 沿著折線每 1.5pt 一點，加一點慢慢飄的抖動，頭尾細一點
    mutating func path(_ pts: [CGPoint]) -> InkStroke {
        var dense: [CGPoint] = []
        for i in 0..<max(0, pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 1.5))
            for k in 0..<n {
                let t = CGFloat(k) / CGFloat(n)
                dense.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        if let last = pts.last { dense.append(last) }
        var dx: CGFloat = 0, dy: CGFloat = 0
        let n = CGFloat(max(dense.count - 1, 1))
        var out: [InkPoint] = []
        for (i, p) in dense.enumerated() {
            dx = dx * 0.92 + noise() * wobble * 0.25
            dy = dy * 0.92 + noise() * wobble * 0.25
            let t = CGFloat(i) / n
            let taper = min(1, t * 8, (1 - t) * 8)
            let w = width * (0.5 + 0.5 * taper) * (1 + noise() * 0.06)
            out.append(InkPoint(CGPoint(x: p.x + dx, y: p.y + dy), width: w))
        }
        return InkStroke(colorHex: color, points: out)
    }

    mutating func line(_ a: CGPoint, _ b: CGPoint) -> InkStroke { path([a, b]) }

    mutating func arrow(_ a: CGPoint, _ b: CGPoint) -> [InkStroke] {
        let ang = atan2(b.y - a.y, b.x - a.x), l: CGFloat = 11
        let h1 = CGPoint(x: b.x - l * cos(ang - 0.45), y: b.y - l * sin(ang - 0.45))
        let h2 = CGPoint(x: b.x - l * cos(ang + 0.45), y: b.y - l * sin(ang + 0.45))
        return [path([a, b]), path([h1, b, h2])]
    }

    /// 手畫的橢圓：多畫一點，頭尾不完全接上
    mutating func ellipse(_ c: CGPoint, rx: CGFloat, ry: CGFloat) -> InkStroke {
        let start = -2.4 + noise() * 0.2
        let pts = (0...72).map { i -> CGPoint in
            let a = start + (2 * .pi + 0.45) * CGFloat(i) / 72
            let k = 1 + 0.04 * CGFloat(i) / 72
            return CGPoint(x: c.x + rx * k * cos(a), y: c.y + ry * k * sin(a))
        }
        return path(pts)
    }

    mutating func box(_ r: CGRect) -> InkStroke {
        path([CGPoint(x: r.minX + 2, y: r.minY), CGPoint(x: r.maxX, y: r.minY + 1), CGPoint(x: r.maxX - 1, y: r.maxY),
              CGPoint(x: r.minX, y: r.maxY - 1), CGPoint(x: r.minX + 1, y: r.minY - 3)])
    }

    mutating func check(at p: CGPoint) -> InkStroke {
        path([CGPoint(x: p.x - 10, y: p.y - 2), CGPoint(x: p.x - 3, y: p.y + 7), CGPoint(x: p.x + 14, y: p.y - 14)])
    }

    mutating func star(at c: CGPoint, r: CGFloat) -> InkStroke {
        let pts = (0...5).map { i -> CGPoint in
            let a = -CGFloat.pi / 2 + CGFloat(i) * 4 * .pi / 5
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
        return path(pts)
    }

    mutating func curve(from x0: CGFloat, to x1: CGFloat, _ f: (CGFloat) -> CGFloat) -> InkStroke {
        path(stride(from: x0, through: x1, by: 4).map { CGPoint(x: $0, y: f($0)) })
    }
}

// MARK: - 編輯器：擺好每個場景

extension NotebookViewController {
    func scheduleScreenshotScene() {
        guard session.id == ScreenshotDemo.mainID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.applyScreenshotScene() }
    }

    private func applyScreenshotScene() {
        let demo = ScreenshotDemo.self
        PinStore.shared.removeAll()
        pinOverlay.reload()
        switch demo.scene {
        case "pdf":
            setTool(.highlighter)
        case "extend":
            setTool(.pageResize)
        case "circuit":
            setTool(.circuit)
            if let ref = demo.circuitRef, let id = demo.selectedPart {
                circuitTarget = ref
                circuitSel = .component(id)
                rebuildSubBar()
                updateCircuitChrome()
            }
        case "table":
            setTool(.select)
            select(demo.tableRef)
        case "pin":
            setTool(.pen)
            if let img = ScreenshotDemo.pinImage(session) {
                let w: CGFloat = 470
                PinStore.shared.add(image: img, center: CGPoint(x: pinOverlay.bounds.width - w / 2 - 24, y: 470),
                                    width: w, notebookID: session.id)
                pinOverlay.reload()
            }
        default:
            setTool(.pen)
        }
        if let id = demo.scenePages[demo.scene], let i = pageIndex(of: id) { scrollToPage(i, animated: false) }
        ScreenshotDemo.markReady(in: view, after: 2.0)
    }
}
#endif
