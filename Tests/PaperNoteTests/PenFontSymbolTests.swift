import XCTest
import CoreText
import SwiftUI
import PencilKit
@testable import PaperNote

/// 回報的需求：
/// - 電路圖「連續放置元件」：沒勾的話放完回到選取
/// - 自訂元件：線條、筆刷畫符號，或貼上 AI 產生的 JSON
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

    func testLineToolSnapsBothEndsToTheGrid() {
        var d = CircuitSymbolDraft()
        d.beginLine(at: CGPoint(x: 1, y: 2))
        d.moveLine(to: CGPoint(x: 23, y: -1))
        XCTAssertEqual(d.symbol.strokes.first?.points, [.zero, CGPoint(x: 20, y: 0)], "拖的時候終點就吸到格點")
        d.endLine(at: CGPoint(x: 42, y: -1))
        XCTAssertEqual(d.symbol.strokes.first?.points, [.zero, CGPoint(x: 40, y: 0)], "兩端都在格點上")
        XCTAssertNil(d.drawingLine)

        // 從端點接著畫：連在一起
        d.beginLine(at: CGPoint(x: 38, y: 3))
        d.endLine(at: CGPoint(x: 41, y: 38))
        XCTAssertEqual(d.symbol.strokes[1].points, [CGPoint(x: 40, y: 0), CGPoint(x: 40, y: 40)])
        XCTAssertFalse(d.symbol.strokes[1].freehand)

        // 兩端吸到同一個格點：不算一條線，也不算一步
        d.beginLine(at: CGPoint(x: 100, y: 100))
        d.endLine(at: CGPoint(x: 102, y: 98))
        XCTAssertEqual(d.symbol.strokes.count, 2)
        d.undo()
        XCTAssertEqual(d.symbol.strokes.count, 1, "復原的是上一條線")
    }

    func testHoldingTheBrushMakesAPerfectShape() throws {
        // 停住：歪歪的線變直線，之後終點跟著筆尖（接近水平就拉正）
        var d = CircuitSymbolDraft()
        d.beginBrush(at: .zero)
        for i in 1...25 { d.continueBrush(to: CGPoint(x: CGFloat(i) * 2, y: CGFloat(i % 3) * 0.6)) }
        let line = try XCTUnwrap(d.holdBrush(scale: 3))
        XCTAssertEqual(line.kind, .line)
        XCTAssertEqual(d.symbol.strokes[0].points, [.zero, CGPoint(x: 50, y: 0)], "變成直線")
        _ = d.moveHeldShape(line, to: CGPoint(x: 80, y: 40), scale: 3)
        XCTAssertEqual(d.symbol.strokes[0].points, [.zero, CGPoint(x: 80, y: 40)], "終點跟著筆尖")
        d.endBrush(held: true)
        XCTAssertEqual(d.symbol.strokes[0].points.count, 2)

        // 封閉的圖形：修成圓
        var c = CircuitSymbolDraft()
        let circle = (0...40).map { i -> CGPoint in
            let t = CGFloat(i) / 40 * 2 * .pi
            return CGPoint(x: 20 * cos(t) + (i % 2 == 0 ? 0.8 : -0.8), y: 20 * sin(t))
        }
        c.beginBrush(at: circle[0])
        for p in circle.dropFirst() { c.continueBrush(to: p) }
        XCTAssertEqual(c.holdBrush(scale: 3)?.kind, .circle)
        c.endBrush(held: true)
        let pts = c.symbol.strokes[0].points
        let r = pts.map { hypot($0.x, $0.y) }
        XCTAssertLessThan((r.max() ?? 0) - (r.min() ?? 0), 0.5, "修成正圓（不是橢圓）：\(r)")
        XCTAssertGreaterThan(pts.count, 40, "放開後還是圓，不會被簡化成多邊形")
        // 每一段都很短：看起來是圓滑的圓
        let longest = zip(pts, pts.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }.max() ?? 0
        XCTAssertLessThan(longest, 3)

        // 停住畫成圓弧，不會被拉成直線
        var a = CircuitSymbolDraft()
        let arc = (0...30).map { i -> CGPoint in
            let t = .pi * CGFloat(i) / 30
            return CGPoint(x: -20 * cos(t), y: -20 * sin(t) + (i % 2 == 0 ? 0.4 : -0.4))
        }
        a.beginBrush(at: arc[0])
        for p in arc.dropFirst() { a.continueBrush(to: p) }
        XCTAssertEqual(a.holdBrush(scale: 3)?.kind, .arc, "半圓停住：圓弧")
        a.endBrush(held: true)
        let ap = a.symbol.strokes[0].points
        XCTAssertGreaterThan(ap.count, 10, "圓弧不是直線")
        let ar = ap.map { hypot($0.x, $0.y) }
        XCTAssertLessThan((ar.max() ?? 0) - (ar.min() ?? 0), 1.5, "點都在同一個圓上：\(ar)")
    }

    /// 回報的問題：筆刷普通畫（沒有停住）的圓，放開後變成多邊形（折線簡化把點拿到只剩幾個）
    func testBrushStaysSmoothAfterLettingGo() {
        var d = CircuitSymbolDraft()
        let circle = (0...120).map { i -> CGPoint in
            let t = CGFloat(i) / 120 * 2 * .pi
            return CGPoint(x: 20 * cos(t), y: 20 * sin(t))
        }
        d.beginBrush(at: circle[0])
        for p in circle.dropFirst() { d.continueBrush(to: p) }
        d.endBrush()
        let stroke = d.symbol.strokes[0]
        XCTAssertTrue(stroke.freehand)
        let longest = zip(stroke.points, stroke.points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }.max() ?? 0
        XCTAssertLessThan(longest, 2, "放開後不會只剩幾個點（變成多邊形）")
        var curves = 0, lines = 0
        stroke.path().applyWithBlock { e in
            if e.pointee.type == .addQuadCurveToPoint { curves += 1 }
            if e.pointee.type == .addLineToPoint { lines += 1 }
        }
        XCTAssertGreaterThan(curves, 100, "筆刷畫的線用平滑的曲線連，不是折線")
        XCTAssertLessThanOrEqual(lines, 1)
        var straight = 0
        CircuitSymbol.Stroke(points: [.zero, CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]).path().applyWithBlock { e in
            if e.pointee.type == .addQuadCurveToPoint { straight += 1 }
        }
        XCTAssertEqual(straight, 0, "線條工具的直線照點連（轉角是尖的）")

        // 擠在一起的點拿掉（存起來比較輕），頭尾不變
        var e = CircuitSymbolDraft()
        e.beginBrush(at: .zero)
        for i in 1...100 { e.continueBrush(to: CGPoint(x: CGFloat(i) * 0.05, y: 0)) }
        e.endBrush()
        let points = e.symbol.strokes[0].points
        XCTAssertLessThan(points.count, 25)
        XCTAssertEqual(points.first, .zero)
        XCTAssertEqual(points.last, CGPoint(x: 5, y: 0))

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
        d.beginLine(at: CGPoint(x: -40, y: 0))
        d.endLine(at: CGPoint(x: 40, y: 0))
        XCTAssertFalse(d.erase(at: CGPoint(x: 0, y: 15), tolerance: 5))
        XCTAssertTrue(d.erase(at: CGPoint(x: 0, y: 2), tolerance: 5), "線上任何地方都擦得到")
        XCTAssertTrue(d.symbol.strokes.isEmpty)
        XCTAssertTrue(d.erase(at: CGPoint(x: 20, y: 20), tolerance: 5))
        XCTAssertTrue(d.symbol.pins.isEmpty)
    }

    func testFinishedSymbolIsCenteredWithPinsOnTheGrid() throws {
        var d = CircuitSymbolDraft()
        XCTAssertNil(d.finished(), "什麼都沒畫")
        d.beginLine(at: CGPoint(x: 100, y: 100))
        d.endLine(at: CGPoint(x: 170, y: 100))
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
        XCTAssertEqual(vc.tool, .line, "一開始是線條")
        vc.handlePan(.began, at: .zero)
        vc.handlePan(.changed, at: CGPoint(x: 20, y: 1))
        vc.handlePan(.ended, at: CGPoint(x: 40, y: 0))
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

    /// 筆身點兩下、Pencil Pro 按壓：畫元件裡切換它自己的橡皮擦，筆記本的工具不跟著切
    func testPencilTogglesTheSymbolEditorsEraser() throws {
        let vc = CircuitSymbolEditorViewController(name: "", symbol: nil) { _, _ in }
        vc.loadViewIfNeeded()
        XCTAssertTrue(vc.view.interactions.contains { $0 is UIPencilInteraction }, "畫元件自己接 Pencil 的點兩下、按壓")
        vc.setTool(.brush)
        vc.toggleEraser()
        XCTAssertEqual(vc.tool, .eraser)
        vc.toggleEraser()
        XCTAssertEqual(vc.tool, .brush, "再切回原本的工具")

        editor.setTool(.circuit)
        XCTAssertFalse(editor.pencilActionsGoElsewhere)
        editor.presentSymbolEditor()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(editor.pencilActionsGoElsewhere, "畫元件開著：筆記本不處理 Pencil 點兩下、按壓")
        editor.dismiss(animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    // MARK: JSON（AI 產生的自訂元件）

    /// 說明裡的範例要能直接貼上
    func testTheAIPromptExampleImports() throws {
        let prompt = CircuitSymbolJSON.aiPrompt
        let start = try XCTUnwrap(prompt.range(of: "```json\n", options: .backwards))
        let end = try XCTUnwrap(prompt.range(of: "```", range: start.upperBound..<prompt.endIndex))
        let file = try CircuitSymbolJSON.parse(String(prompt[start.upperBound..<end.lowerBound]))
        XCTAssertEqual(file.name, "電阻")
        XCTAssertEqual(file.symbol.pins, [CGPoint(x: -30, y: 0), CGPoint(x: 30, y: 0)])
        XCTAssertEqual(file.symbol.strokes.first?.points.first, CGPoint(x: -30, y: 0), "引線接到接腳")
        // AI 回覆前後有說明文字也讀得到
        let reply = "好的，以下是結果：\n```json\n" + CircuitSymbolJSON.export(file.symbol, name: "R") + "\n```\n有需要再調整 {大小}。"
        XCTAssertEqual(try CircuitSymbolJSON.parse(reply).symbol, file.symbol)
    }

    func testSymbolJSONRoundTripsAndChecksInput() throws {
        let file = try CircuitSymbolJSON.parse(CircuitSymbolJSON.export(symbol, name: "方塊"))
        XCTAssertEqual(file.symbol, symbol, "拷貝出去再貼回來一樣")
        XCTAssertEqual(file.name, "方塊")

        let loose = try CircuitSymbolJSON.parse(#"{"strokes":[{"points":[[-30,0],[30,0]]}],"circles":[{"center":[0,0],"radius":15}],"pins":[[-31,2],[29,-1],[-30,0]]}"#)
        XCTAssertEqual(loose.symbol.pins, [CGPoint(x: -30, y: 0), CGPoint(x: 30, y: 0)], "接腳吸到格點、重複的拿掉")
        XCTAssertEqual(loose.symbol.strokes.count, 2, "圓變成一條線")
        let r = loose.symbol.strokes[1].points.map { hypot($0.x, $0.y) }
        XCTAssertEqual(r.min() ?? 0, 15, accuracy: 0.01)
        XCTAssertEqual(r.max() ?? 0, 15, accuracy: 0.01)

        XCTAssertThrowsError(try CircuitSymbolJSON.parse(#"{"strokes":[{"points":[[0,0],[10,0]]}]}"#)) {
            XCTAssertEqual($0 as? CircuitSymbolJSON.ParseError, .noPins)
        }
        XCTAssertThrowsError(try CircuitSymbolJSON.parse(#"{"pins":[[0,0]]}"#)) {
            XCTAssertEqual($0 as? CircuitSymbolJSON.ParseError, .noLines)
        }
        XCTAssertThrowsError(try CircuitSymbolJSON.parse(#"{"strokes":[{"points":[[0,0,1],[10,0]]}],"pins":[[0,0]]}"#)) {
            XCTAssertEqual($0 as? CircuitSymbolJSON.ParseError, .badPoint)
        }
        XCTAssertThrowsError(try CircuitSymbolJSON.parse(#"{"strokes":[{"points":[[0,0],[1000,0]]}],"pins":[[0,0]]}"#)) {
            XCTAssertEqual($0 as? CircuitSymbolJSON.ParseError, .tooBig)
        }
        XCTAssertThrowsError(try CircuitSymbolJSON.parse("畫不出來"))
    }

    func testPastingJSONIntoTheEditor() throws {
        var saved: (String, CircuitSymbol)?
        let vc = CircuitSymbolEditorViewController(name: "", symbol: nil) { saved = ($0, $1) }
        window.rootViewController = vc
        vc.loadViewIfNeeded()
        vc.importJSON(CircuitSymbolJSON.export(symbol, name: "貼上的"))
        XCTAssertEqual(vc.draft.symbol, symbol)
        XCTAssertEqual(vc.nameField.text, "貼上的", "名稱還沒打就用 JSON 裡的")
        vc.undoTapped()
        XCTAssertTrue(vc.draft.symbol.strokes.isEmpty, "貼上可以復原")
        vc.importJSON(CircuitSymbolJSON.export(symbol, name: "貼上的"))
        vc.finish()
        XCTAssertEqual(saved?.0, "貼上的")
        XCTAssertEqual(saved?.1.pins.count, 2)

        let other = CircuitSymbolEditorViewController(name: "", symbol: nil) { _, _ in }
        window.rootViewController = other
        other.loadViewIfNeeded()
        other.importJSON("{}")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotNil(other.presentedViewController as? UIAlertController, "讀不了就說原因")
        other.presentedViewController?.dismiss(animated: false)
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

    func testStyleSurvivesEraserDashesAndSaving() throws {
        let s = line(.pencil)
        let pieces = try XCTUnwrap(InkGeometry.cut(s, at: CGPoint(x: 100, y: 40), radius: 10))
        XCTAssertTrue(pieces.allSatisfy { $0.style == .pencil }, "局部擦除切開還是鉛筆")
        XCTAssertTrue(InkGeometry.dashed(s, dash: 10, gap: 5).allSatisfy { $0.style == .pencil })
        XCTAssertEqual(InkGeometry.offset(s, by: CGPoint(x: 1, y: 1)).style, .pencil)
        XCTAssertEqual(try JSONDecoder().decode(InkStroke.self, from: JSONEncoder().encode(s)).style, .pencil)
        let old = ##"{"id":"6F3B1A10-1111-4A11-8A11-111111111111","colorHex":"#000000FF","points":[]}"##
        XCTAssertNil(try JSONDecoder().decode(InkStroke.self, from: Data(old.utf8)).style, "舊筆跡照舊")
        XCTAssertGreaterThan(InkGeometry.bounds(of: line(.watercolor)).height, InkGeometry.bounds(of: line(nil)).height, "外暈也算在範圍內，擦的時候才清得乾淨")
    }

    /// 回報的問題：原子筆以外的自製筆刷寫起來很怪，不像 PencilKit。
    /// 這些筆交給 PencilKit 畫（寫的時候、放開後都是 PencilKit 自己畫的），自製筆刷只畫原子筆
    func testOnlyMonolineUsesCustomInk() throws {
        let store = BrushStore.shared
        let old = store.current
        defer {
            store.update(old)
            editor.applyTool()
        }
        XCTAssertTrue(editor.settings.customInk, "預設開著自製筆刷")
        for style in InkStyle.allCases where style != .marker {
            var p = old
            p.style = style
            p.dashed = false
            store.update(p)
            editor.setTool(.select)
            editor.setTool(.pen)
            let custom = style == .monoline
            XCTAssertEqual(editor.customInkActive, custom, "\(style.title)")
            XCTAssertEqual(editor.inkRecognizer.isEnabled, custom, "\(style.title)：自製筆刷的手勢")
            XCTAssertTrue(editor.canvas.drawingGestureRecognizer.isEnabled, "\(style.title)：PencilKit 可以寫")
            let tool = try XCTUnwrap(editor.canvas.tool as? PKInkingTool, "\(style.title)")
            XCTAssertEqual(tool.inkType, style.inkType, "\(style.title)：PencilKit 用同一種墨水")
            XCTAssertEqual(style.usableWidthRange, custom ? style.widthRange : style.pencilKitWidthRange, "\(style.title)：可以調的粗細")
        }
    }

    /// 在筆刷設定裡把原子筆改成鉛筆（或改回來）：馬上換成 PencilKit 畫（或換回自製筆刷）
    func testChangingTheStyleSwitchesTheEngine() throws {
        let store = BrushStore.shared
        let old = store.current
        defer {
            store.update(old)
            editor.applyTool()
        }
        var p = old
        p.style = .monoline
        store.update(p)
        editor.setTool(.pen)
        XCTAssertTrue(editor.customInkActive)
        editor.presentBrushSettings(store.current, from: editor.view)
        let host = try XCTUnwrap(editor.presentedViewController as? UIHostingController<BrushSettingsView>)
        p.style = .pencil
        host.rootView.onChange(p)
        XCTAssertFalse(editor.customInkActive, "改成鉛筆：PencilKit 畫")
        XCTAssertFalse(editor.inkRecognizer.isEnabled)
        XCTAssertEqual((editor.canvas.tool as? PKInkingTool)?.inkType, .pencil)
        p.style = .monoline
        host.rootView.onChange(p)
        XCTAssertTrue(editor.inkRecognizer.isEnabled, "改回原子筆：自製筆刷")
        editor.dismissToolPopover()
    }

    func testPensCanGoMuchThinner() {
        // 自製筆刷（原子筆）可以很細；PencilKit 畫的筆最細是 PencilKit 畫得出來的最細值
        XCTAssertLessThanOrEqual(InkStyle.monoline.widthRange.lowerBound, 0.3)
        XCTAssertLessThan(InkStyle.monoline.styleWidths[0], 1)
        for style in InkStyle.allCases where !style.usesCustomInk {
            XCTAssertGreaterThanOrEqual(style.pencilKitWidthRange.lowerBound, style.inkType.validWidthRange.lowerBound - 0.001, "\(style)：PencilKit 畫不出來的就不讓它調")
        }
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
        let old = ##"{"text":"a","fontSize":18,"colorHex":"#000000FF"}"##
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
