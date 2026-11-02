import XCTest
import CoreText
@testable import PaperNote

/// 回報的需求：
/// - 電路圖「連續放置元件」：沒勾的話放完回到選取
/// - 自訂元件：Node、筆刷畫符號
/// - 每種筆寫起來一樣、只有粗細不同；筆芯要能更細（鉛筆最細只到 2.4pt）
/// - 喜歡的顏色加進固定的 12 色
/// - 文字框有更多字體可以選（沒有版權問題的）
final class PenFontSymbolTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "PenFontSymbol", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    override func tearDown() {
        for c in CustomCircuitStore.shared.circuits { CustomCircuitStore.shared.remove(c.id) }
        for hex in FavoriteColors.all { FavoriteColors.remove(hex) }
        TextFonts.lastUsed = nil
        editor.settings.circuitContinuousPlace = true
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private func page(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let o = editor.contentOrigin(0)
        return CGPoint(x: o.x + x, y: o.y + y)
    }

    // MARK: 連續放置

    func testPlacingStaysInTheModeOnlyWhenContinuous() throws {
        XCTAssertTrue(editor.settings.circuitContinuousPlace, "預設和以前一樣")
        editor.setTool(.circuit)
        editor.selectCircuitMode(.place(.resistor))
        editor.handleCircuitTap(at: page(200, 300))
        XCTAssertEqual(editor.circuitMode, .place(.resistor), "勾著：留在放置模式")

        editor.settings.circuitContinuousPlace = false
        editor.selectCircuitMode(.place(.capacitor))
        editor.handleCircuitTap(at: page(400, 300))
        XCTAssertEqual(editor.circuitMode, .select, "沒勾：放好回到選取")
        let target = try XCTUnwrap(editor.circuitTarget)
        let placed = try XCTUnwrap(editor.circuitInfo(target)?.data.components.last)
        XCTAssertEqual(placed.part, .capacitor)
        XCTAssertEqual(editor.circuitSel, .component(placed.id), "剛放的選著，可以馬上旋轉")
        XCTAssertEqual(editor.circuitLibrary.currentMode, .select, "元件庫的反白也回去")
        let count = editor.circuitInfo(target)?.data.components.count
        editor.handleCircuitTap(at: page(500, 500))
        XCTAssertEqual(editor.circuitInfo(target)?.data.components.count, count, "再點不會多放一個")
    }

    func testPlacingACustomCircuitAlsoFollowsTheOption() {
        editor.settings.circuitContinuousPlace = false
        editor.setTool(.circuit)
        let c = CustomCircuitStore.shared.add(name: "A", data: CustomCircuit.symbolData(symbol))
        editor.selectCircuitMode(.placeCustom(c.id))
        editor.handleCircuitTap(at: page(300, 300))
        XCTAssertEqual(editor.circuitMode, .select)
    }

    func testTheOptionIsInTheMenu() {
        func item(_ elements: [UIMenuElement]) -> UIAction? {
            for e in elements {
                if let a = e as? UIAction, a.title == "連續放置元件" { return a }
                if let m = e as? UIMenu, let a = item(m.children) { return a }
            }
            return nil
        }
        XCTAssertEqual(item(editor.makeSettingsMenuItems())?.state, .on)
        editor.settings.circuitContinuousPlace = false
        XCTAssertEqual(item(editor.makeSettingsMenuItems())?.state, .off)
    }

    // MARK: 自訂元件

    /// 一個方塊，左右各一隻腳
    private var symbol: CircuitSymbol {
        CircuitSymbol(strokes: [.init(points: [CGPoint(x: -30, y: 0), CGPoint(x: -10, y: 0), CGPoint(x: -10, y: -20), CGPoint(x: 30, y: -20)])],
                      pins: [CGPoint(x: -30, y: 0), CGPoint(x: 30, y: -20)])
    }

    func testNodeToolDrawsStraightLinesOnTheGrid() {
        var d = CircuitSymbolDraft()
        d.tapNode(at: CGPoint(x: 1, y: 2))
        d.tapNode(at: CGPoint(x: 42, y: -1))
        d.tapNode(at: CGPoint(x: 41, y: 38))
        XCTAssertEqual(d.symbol.strokes.first?.points, [.zero, CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 40)], "對齊格點、連成線")
        XCTAssertNotNil(d.openLine)

        d.tapNode(at: CGPoint(x: 40, y: 40))
        XCTAssertNil(d.openLine, "點最後一個節點：結束")
        d.tapNode(at: CGPoint(x: 100, y: 100))
        XCTAssertEqual(d.symbol.strokes.count, 2, "再點是新的一條")
        d.finishLine()
        XCTAssertEqual(d.symbol.strokes.count, 1, "只有一個節點不算一條線")

        // 封閉
        var box = CircuitSymbolDraft()
        for p in [CGPoint.zero, CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 40), .zero] { box.tapNode(at: p) }
        XCTAssertNil(box.openLine)
        XCTAssertEqual(box.symbol.strokes[0].points.first, box.symbol.strokes[0].points.last)
        // 封閉的線：頭尾一起動
        let hit = box.nodeHit(at: CGPoint(x: 1, y: 1), tolerance: 5)
        XCTAssertEqual(hit?.stroke, 0)
        box.beginMovingNode()
        box.moveNode(stroke: 0, point: hit?.point ?? 0, to: CGPoint(x: -18, y: -21))
        XCTAssertEqual(box.symbol.strokes[0].points.first, CGPoint(x: -20, y: -20))
        XCTAssertEqual(box.symbol.strokes[0].points.last, CGPoint(x: -20, y: -20))
        box.undo()
        XCTAssertEqual(box.symbol.strokes[0].points.first, .zero, "可以復原")
    }

    func testBrushKeepsTheShapeWithFewerPoints() {
        var d = CircuitSymbolDraft()
        d.beginBrush(at: .zero)
        for i in 1...50 { d.continueBrush(to: CGPoint(x: CGFloat(i), y: 0.02 * CGFloat(i % 2))) }
        d.continueBrush(to: CGPoint(x: 50, y: 30))
        d.endBrush()
        let points = d.symbol.strokes[0].points
        XCTAssertTrue(d.symbol.strokes[0].freehand)
        XCTAssertLessThan(points.count, 6, "抖動的點拿掉")
        XCTAssertEqual(points.first, .zero)
        XCTAssertEqual(points.last, CGPoint(x: 50, y: 30))

        var dot = CircuitSymbolDraft()
        dot.beginBrush(at: .zero)
        dot.endBrush()
        XCTAssertTrue(dot.symbol.strokes.isEmpty)
        XCTAssertFalse(dot.canUndo, "沒畫到東西就不算一步")
    }

    func testPinsAndEraser() {
        var d = CircuitSymbolDraft()
        d.togglePin(at: CGPoint(x: 21, y: 19))
        XCTAssertEqual(d.symbol.pins, [CGPoint(x: 20, y: 20)], "接腳在格點上")
        d.togglePin(at: CGPoint(x: 19, y: 22))
        XCTAssertTrue(d.symbol.pins.isEmpty, "再點拿掉")
        d.togglePin(at: CGPoint(x: 20, y: 20))
        d.tapNode(at: CGPoint(x: -40, y: 0))
        d.tapNode(at: CGPoint(x: 40, y: 0))
        d.finishLine()
        XCTAssertFalse(d.erase(at: CGPoint(x: 0, y: 15), tolerance: 5))
        XCTAssertTrue(d.erase(at: CGPoint(x: 0, y: 2), tolerance: 5), "線上任何地方都擦得到")
        XCTAssertTrue(d.symbol.strokes.isEmpty)
        XCTAssertTrue(d.erase(at: CGPoint(x: 20, y: 20), tolerance: 5))
        XCTAssertTrue(d.symbol.pins.isEmpty)
    }

    func testFinishedSymbolIsCenteredWithPinsOnTheGrid() throws {
        var d = CircuitSymbolDraft()
        XCTAssertNil(d.finished(), "什麼都沒畫")
        d.tapNode(at: CGPoint(x: 100, y: 100))
        d.tapNode(at: CGPoint(x: 170, y: 100))
        XCTAssertNil(d.finished(), "沒有接腳不能完成：導線接不上去")
        d.togglePin(at: CGPoint(x: 100, y: 100))
        d.togglePin(at: CGPoint(x: 170, y: 100))
        let s = try XCTUnwrap(d.finished())
        XCTAssertLessThan(abs(s.bounds.midX), 10, "中心在原點附近")
        for p in s.pins {
            XCTAssertEqual(p.x.truncatingRemainder(dividingBy: 10), 0)
            XCTAssertEqual(p.y.truncatingRemainder(dividingBy: 10), 0)
            XCTAssertTrue(s.bounds.contains(p))
        }
    }

    func testEditorWithoutPinsAsksForThem() throws {
        var saved: CircuitSymbol?
        let vc = CircuitSymbolEditorViewController(name: "", symbol: nil) { _, s in saved = s }
        window.rootViewController = vc
        vc.loadViewIfNeeded()
        vc.handleTap(at: .zero)
        vc.handleTap(at: CGPoint(x: 40, y: 0))
        vc.finish()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(saved)
        XCTAssertNotNil(vc.presentedViewController as? UIAlertController)
        vc.presentedViewController?.dismiss(animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        vc.setTool(.pin)
        vc.handleTap(at: .zero)
        vc.handleTap(at: CGPoint(x: 40, y: 0))
        vc.setTool(.brush)
        vc.handlePan(.began, at: CGPoint(x: 10, y: 20))
        vc.handlePan(.changed, at: CGPoint(x: 20, y: 25))
        vc.handlePan(.ended, at: CGPoint(x: 30, y: 20))
        vc.undoTapped()
        XCTAssertEqual(vc.draft.symbol.strokes.count, 1, "筆刷一筆一次復原")
        vc.handlePan(.began, at: CGPoint(x: 10, y: 20))
        vc.handlePan(.ended, at: CGPoint(x: 30, y: 20))
        vc.finish()
        XCTAssertEqual(saved?.strokes.count, 2)
        XCTAssertEqual(saved?.pins.count, 2)
    }

    func testCustomSymbolWorksLikeAPart() throws {
        let c = CustomCircuitStore.shared.add(name: "X", data: CustomCircuit.symbolData(symbol))
        XCTAssertEqual(c.symbol, symbol)
        editor.setTool(.circuit)
        editor.placeCustomCircuit(c.id, at: page(300, 300))
        let ref = try XCTUnwrap(editor.circuitTarget)
        let info = try XCTUnwrap(editor.circuitInfo(ref))
        let comp = try XCTUnwrap(info.data.components.first)
        XCTAssertEqual(comp.part, .customSymbol)
        XCTAssertNil(comp.groupID, "是一個元件，不是群組")
        XCTAssertEqual(editor.circuitSel, .component(comp.id))

        var rotated = comp
        rotated.rotation = 90
        XCTAssertEqual(CircuitGeometry.localPins(comp), symbol.pins)
        let before = CircuitGeometry.pins(comp), after = CircuitGeometry.pins(rotated)
        XCTAssertEqual(before.count, 2)
        XCTAssertNotEqual(before, after, "可以旋轉")
        XCTAssertFalse(CircuitRenderer.symbol(comp).0.isEmpty, "畫得出來")
        XCTAssertGreaterThan(CircuitRenderer.icon(c.data).size.width, 0)
        let svg = CircuitRenderer.svg(info.data)
        XCTAssertTrue(XMLParser(data: Data(svg.utf8)).parse())
        XCTAssertTrue(svg.contains("<path"), "SVG 有符號")

        // 存進筆記再讀回來
        let json = try JSONEncoder().encode(info.data)
        XCTAssertEqual(try JSONDecoder().decode(CircuitData.self, from: json), info.data)

        // 改元件庫裡的：放好的不動
        editor.saveCustomSymbol(id: c.id, name: "Y", symbol: CircuitSymbol(strokes: [.init(points: [.zero, CGPoint(x: 10, y: 0)])], pins: [.zero]))
        XCTAssertEqual(CustomCircuitStore.shared.circuit(c.id)?.name, "Y")
        XCTAssertEqual(CustomCircuitStore.shared.circuit(c.id)?.symbol?.pins, [.zero])
        XCTAssertEqual(editor.circuitInfo(ref)?.data.components.first?.symbol, symbol)
    }

    func testLibraryCanDrawAndEditSymbols() throws {
        let library = editor.circuitLibrary
        CustomCircuitStore.shared.add(name: "存的電路", data: {
            var d = CircuitData()
            d.components = [CircuitComponent(part: .resistor, position: .zero)]
            return d
        }())
        CustomCircuitStore.shared.add(name: "畫的", data: CustomCircuit.symbolData(symbol))
        let tiles = library.visibleTiles
        let savedTile = try XCTUnwrap(tiles.first { $0.accessibilityLabel == "存的電路" })
        let drawnTile = try XCTUnwrap(tiles.first { $0.accessibilityLabel == "畫的" })
        XCTAssertFalse(savedTile.menu?.children.contains { ($0 as? UIAction)?.title == "編輯符號" } ?? true, "存的電路沒有符號可以編輯")
        XCTAssertTrue(drawnTile.menu?.children.contains { ($0 as? UIAction)?.title == "編輯符號" } ?? false)
        var opened: UUID??
        library.onDrawSymbol = { opened = $0 }
        let draw = try XCTUnwrap(library.allDescendants.first { $0.accessibilityLabel == "畫自訂元件" } as? UIButton)
        draw.sendActions(for: .touchUpInside)
        XCTAssertEqual(opened, .some(nil))
    }

    // MARK: 每種筆不一樣

    /// 把一筆畫成圖，回傳每個有墨水的像素的不透明度
    private func coverage(_ s: InkStroke, scale: CGFloat = 2) -> [UInt8] {
        let size = CGSize(width: 240, height: 80)
        let w = Int(size.width * scale), h = Int(size.height * scale)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.scaleBy(x: scale, y: scale)
            InkRenderer.draw([s], in: ctx)
        }
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }.filter { $0 > 0 }
    }

    private func line(_ style: InkStyle?, width: CGFloat = 6) -> InkStroke {
        InkStroke(colorHex: "#000000FF", points: (0...40).map { InkPoint(CGPoint(x: 20 + CGFloat($0) * 5, y: 40), width: width) }, style: style)
    }

    func testEveryInkLooksDifferent() {
        func solidity(_ a: [UInt8]) -> Double { Double(a.filter { $0 >= 250 }.count) / Double(max(a.count, 1)) }
        func average(_ a: [UInt8]) -> Double { Double(a.reduce(0) { $0 + Int($1) }) / Double(max(a.count, 1)) }
        let plain = coverage(line(nil))
        XCTAssertGreaterThan(solidity(plain), 0.8, "原子筆：不透明的實線")

        let pencil = coverage(line(.pencil))
        XCTAssertLessThan(average(pencil), average(plain) * 0.9, "鉛筆比較淡")
        XCTAssertGreaterThan(Set(pencil).count, 8, "鉛筆有顆粒，深淺不一")
        let crayon = coverage(line(.crayon))
        XCTAssertNotEqual(pencil, crayon)
        XCTAssertGreaterThan(Set(crayon).count, 8)
        let water = coverage(line(.watercolor))
        XCTAssertLessThan(average(water), average(pencil), "水彩最透明")
        XCTAssertGreaterThan(water.count, plain.count, "水彩有外暈，比較寬")
        XCTAssertLessThan(solidity(water), 0.01)
    }

    func testTranslucentInkDoesNotGetDarkerAtEverySegment() {
        // 一段一段畫的話接縫會變深：同一筆裡面的底色要一致
        let water = coverage(line(.watercolor))
        let counts = Dictionary(grouping: water, by: { $0 }).mapValues(\.count)
        XCTAssertLessThan(Double(water.max() ?? 0), 255 * (0.32 + 0.16) + 8, "最深的地方也只有底色加外暈")
        XCTAssertGreaterThan(counts.values.max() ?? 0, water.count / 3, "大部分是同一個深淺")
    }

    func testWidthBehavesDifferentlyPerInk() {
        let base: CGFloat = 4
        for style: InkStyle in [.monoline, .pencil, .crayon] {
            XCTAssertEqual(style.inkWidth(base: base, force: 1, direction: 0.3, previous: nil), base, "\(style) 固定粗細")
        }
        let thin = InkStyle.fountainPen.inkWidth(base: base, force: 0.05, direction: nil, previous: nil)
        let thick = InkStyle.fountainPen.inkWidth(base: base, force: 1, direction: nil, previous: nil)
        XCTAssertGreaterThan(thick / thin, 3, "毛筆看筆壓，差很多")
        let along = InkStyle.pen.inkWidth(base: base, force: 0.5, direction: -.pi / 4, previous: nil)
        let across = InkStyle.pen.inkWidth(base: base, force: 0.5, direction: .pi / 4, previous: nil)
        XCTAssertGreaterThan(across / along, 1.5, "鋼筆看方向")
        XCTAssertEqual(InkStyle.pen.inkWidth(base: base, force: 0, direction: 0.5, previous: nil),
                       InkStyle.pen.inkWidth(base: base, force: 1, direction: 0.5, previous: nil), "鋼筆不看筆壓，線尾不會變細")
        let eased = InkStyle.fountainPen.inkWidth(base: base, force: 1, direction: nil, previous: thin)
        XCTAssertLessThan(eased, thick, "線寬慢慢變")
        XCTAssertGreaterThan(eased, thin)
    }

    func testBrushTipTapersWhenLifted() {
        let points = (0..<30).map { InkPoint(CGPoint(x: CGFloat($0), y: 0), width: 6) }
        let tapered = InkStyle.taperedEnd(points)
        XCTAssertEqual(tapered[0].width, 6)
        XCTAssertLessThan(tapered[29].width, 2.5)
        XCTAssertEqual(tapered.map(\.point), points.map(\.point), "只改粗細")
    }

    func testStyleSurvivesEraserDashesAndSaving() throws {
        let s = line(.pencil)
        let pieces = try XCTUnwrap(InkGeometry.cut(s, at: CGPoint(x: 100, y: 40), radius: 10))
        XCTAssertTrue(pieces.allSatisfy { $0.style == .pencil }, "局部擦除切開還是鉛筆")
        XCTAssertTrue(InkGeometry.dashed(s, dash: 10, gap: 5).allSatisfy { $0.style == .pencil })
        XCTAssertEqual(InkGeometry.offset(s, by: CGPoint(x: 1, y: 1)).style, .pencil)
        XCTAssertEqual(try JSONDecoder().decode(InkStroke.self, from: JSONEncoder().encode(s)).style, .pencil)
        let old = #"{"id":"6F3B1A10-1111-4A11-8A11-111111111111","colorHex":"#000000FF","points":[]}"#
        XCTAssertNil(try JSONDecoder().decode(InkStroke.self, from: Data(old.utf8)).style, "舊筆跡照舊")
        XCTAssertGreaterThan(InkGeometry.bounds(of: line(.watercolor)).height, InkGeometry.bounds(of: line(nil)).height, "外暈也算在範圍內，擦的時候才清得乾淨")
    }

    func testCustomInkWritesWithTheChosenStyle() throws {
        let store = BrushStore.shared
        let old = store.current
        defer { store.update(old) }
        var p = old
        p.style = .pencil
        p.width = 0.6
        store.update(p)
        editor.setTool(.pen)
        let o = page(100, 500)
        editor.inkBegan(.init(point: o, force: 0.5))
        editor.inkMoved((1...20).map { .init(point: CGPoint(x: o.x + CGFloat($0) * 5, y: o.y), force: 0.5) })
        editor.inkEnded(cancelled: false)
        let s = try XCTUnwrap(editor.pages[0].ink.last)
        XCTAssertEqual(s.style, .pencil)
        XCTAssertEqual(s.points[5].width, 0.6, accuracy: 0.001, "比 PencilKit 的 2.4pt 細")
    }

    func testPensCanGoMuchThinner() {
        for style in InkStyle.allCases where style != .marker {
            XCTAssertLessThanOrEqual(style.widthRange.lowerBound, 0.3, "\(style)")
            XCTAssertLessThanOrEqual(style.styleWidths[0], style == .watercolor ? 4 : (style == .crayon ? 3 : 1), "\(style) 的「細」真的細")
        }
        XCTAssertLessThan(InkStyle.pencil.styleWidths[0], 1)
        // PencilKit 畫不出來的就不讓它調
        XCTAssertGreaterThanOrEqual(InkStyle.pencil.pencilKitWidthRange.lowerBound, InkStyle.pencil.inkType.validWidthRange.lowerBound - 0.001)
    }

    func testSampleStrokeShowsTheDifference() {
        let size = CGSize(width: 200, height: 44)
        func widths(_ s: InkStyle) -> Set<Float> { Set(s.sampleStroke(colorHex: "#000000FF", width: 4, in: size).points.map(\.w)) }
        XCTAssertEqual(widths(.monoline).count, 1)
        XCTAssertGreaterThan(widths(.fountainPen).count, 5)
        XCTAssertGreaterThan(widths(.pen).count, 5)
        XCTAssertEqual(InkStyle.pencil.sampleStroke(colorHex: "#000000FF", width: 4, in: size).style, .pencil)
    }

    // MARK: 色票

    func testFavoriteColors() {
        XCTAssertTrue(FavoriteColors.all.isEmpty)
        XCTAssertEqual(BrushSettingsView.swatches.count, 12, "固定的 12 色不變")
        XCTAssertTrue(FavoriteColors.add("#123456FF"))
        XCTAssertFalse(FavoriteColors.add("#123456FF"), "不重複")
        XCTAssertFalse(FavoriteColors.add(BrushSettingsView.swatches[0]), "已經在固定色裡")
        XCTAssertTrue(FavoriteColors.add("#ABCDEFFF"))
        XCTAssertEqual(FavoriteColors.all, ["#123456FF", "#ABCDEFFF"], "照加入的順序")
        FavoriteColors.remove("#123456FF")
        XCTAssertEqual(FavoriteColors.all, ["#ABCDEFFF"])
        for i in 0..<FavoriteColors.limit { FavoriteColors.add(String(format: "#%06XFF", i)) }
        XCTAssertEqual(FavoriteColors.all.count, FavoriteColors.limit, "有上限")
    }

    // MARK: 字體

    func testBundledFontsLoadWithChineseGlyphsAndLicenses() throws {
        for name in TextFonts.bundled {
            let font = try XCTUnwrap(UIFont(name: name, size: 20), "\(name) 要載入得到")
            var chars = Array("永字".utf16)
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            XCTAssertTrue(CTFontGetGlyphsForCharacters(font as CTFont, &chars, &glyphs, chars.count), "\(name) 有中文字")
        }
        for license in ["OFL-LXGWWenKaiTC", "OFL-Iansui", "OFL-NotoSerifTC"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: license, withExtension: "txt"), "授權檔要跟著 App")
            XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("SIL Open Font License"))
        }
    }

    func testChoicesExistAndUnknownFontsFallBack() {
        let all = TextFonts.sections.flatMap(\.1)
        XCTAssertGreaterThanOrEqual(all.count, 10, "選擇夠多")
        XCTAssertEqual(all.count, Set(all.map(\.id)).count)
        XCTAssertNil(all.first?.name, "第一個是系統預設")
        for b in TextFonts.bundled { XCTAssertTrue(all.contains { $0.name == b }, b) }
        XCTAssertEqual(TextFonts.font(nil, size: 18), .systemFont(ofSize: 18))
        XCTAssertEqual(TextFonts.font("沒有這個字體", size: 18), .systemFont(ofSize: 18), "找不到不會變空白")
    }

    func testTextBoxKeepsItsFont() throws {
        let ref = try XCTUnwrap(editor.insertElement(.text(TextBoxData(text: "測試")), size: CGSize(width: 260, height: 60), at: page(200, 200)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        editor.setTextBoxFont(ref, name: "LXGWWenKaiTC-Regular")
        func box() -> TextBoxData? {
            guard case let (pi, ei)? = editor.locate(ref), case let .text(t) = editor.pages[pi].elements[ei].content else { return nil }
            return t
        }
        XCTAssertEqual(box()?.fontName, "LXGWWenKaiTC-Regular")
        let font = try XCTUnwrap(ElementRenderer.textAttributes(try XCTUnwrap(box()))[.font] as? UIFont)
        XCTAssertEqual(font.fontName, "LXGWWenKaiTC-Regular", "畫面和匯出都用這個字體")
        editor.undoTapped()
        XCTAssertNil(box()?.fontName, "可以復原")

        XCTAssertEqual(TextFonts.lastUsed, "LXGWWenKaiTC-Regular")
        editor.insertTextBox(at: page(200, 500), text: "新的")
        guard case let .text(new)? = editor.pages[0].elements.last?.content else { return XCTFail() }
        XCTAssertEqual(new.fontName, "LXGWWenKaiTC-Regular", "新的文字框沿用")

        // 舊存檔沒有這個欄位
        let old = #"{"text":"a","fontSize":18,"colorHex":"#000000FF"}"#
        XCTAssertNil(try JSONDecoder().decode(TextBoxData.self, from: Data(old.utf8)).fontName)
    }

    func testEditingATextBoxUsesItsFont() throws {
        var t = TextBoxData(text: "測試")
        t.fontName = "Iansui-Regular"
        let ref = try XCTUnwrap(editor.insertElement(.text(t), size: CGSize(width: 260, height: 60), at: page(200, 200)))
        editor.beginTextEditing(ref, cell: nil)
        let tv = try XCTUnwrap(editor.canvas.allDescendants.first { $0 is UITextView } as? UITextView)
        XCTAssertEqual(tv.font?.fontName, "Iansui-Regular")
        editor.endTextEditing()
    }

    func testFontPickerShowsFromTheTextBoxMenu() throws {
        let ref = try XCTUnwrap(editor.insertElement(.text(TextBoxData(text: "a")), size: CGSize(width: 260, height: 60), at: page(200, 200)))
        editor.presentFontPicker(ref)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNotNil(editor.presentedViewController, "跳出字體清單")
    }
}

private extension UIView {
    var allDescendants: [UIView] { subviews + subviews.flatMap(\.allDescendants) }
}
