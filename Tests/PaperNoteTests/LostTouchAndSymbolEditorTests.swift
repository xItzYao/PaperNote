import XCTest
import PencilKit
@testable import PaperNote

/// 回報的問題：螢光筆畫不出來。除錯紀錄：工具列的選單開著時下筆，PencilKit 開始寫了，
/// 這一筆的「結束」卻沒送到追蹤筆尖的辨識器；之後每一筆 Pencil 都被當成「上一筆還沒放開」而忽略，
/// 卡住的 PencilKit 書寫手勢也就一直沒有重設（自製筆刷有自己的辨識器，還寫得出來）
final class LostPencilTouchTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "LostPencilTouch", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    func testAPencilTouchWhoseEndNeverArrivedDoesNotBlockTheNextStroke() throws {
        editor.setTool(.highlighter)
        let tracker = try XCTUnwrap(editor.pencilPointTracker)
        let lost = FakeTouch(type: .pencil, location: CGPoint(x: 200, y: 300))
        tracker.touchesBegan([lost], with: UIEvent())
        XCTAssertTrue(editor.pencilDown)
        // 選單開著時下筆：PencilKit 開始寫了（之後沒收到結束），筆放開了但辨識器沒收到
        editor.pkUsingSince = CACurrentMediaTime() - 5
        lost.fakePhase = .ended

        editor.pencilDown = false
        let next = FakeTouch(type: .pencil, location: CGPoint(x: 220, y: 320))
        tracker.touchesBegan([next], with: UIEvent())
        XCTAssertTrue(editor.pencilDown, "下一筆要收到")
        XCTAssertNil(editor.pkUsingSince, "卡在書寫中的 PencilKit 手勢重設了，螢光筆才畫得出來")
        XCTAssertTrue(editor.canvas.drawingGestureRecognizer.isEnabled)
    }

    func testAStrokeStillInProgressKeepsItsTouch() throws {
        let tracker = try XCTUnwrap(editor.pencilPointTracker)
        var began = 0
        let saved = tracker.onBegan
        defer { tracker.onBegan = saved }
        tracker.onBegan = { _ in began += 1 }
        let first = FakeTouch(type: .pencil)
        tracker.touchesBegan([first], with: UIEvent())
        first.fakePhase = .moved
        tracker.touchesBegan([FakeTouch(type: .pencil)], with: UIEvent())
        XCTAssertEqual(began, 1, "還沒放開的那一筆不會被換掉")
        tracker.touchesEnded([first], with: UIEvent())
    }
}

/// 回報的問題：畫元件的筆刷有點延遲（拖曳手勢要先移動一小段才開始）；橡皮擦想要局部擦除
final class SymbolEditorStrokeTests: XCTestCase {
    private var savedPartial = false

    override func setUp() {
        savedPartial = EditorSettings.shared.symbolPartialErase
    }

    override func tearDown() {
        EditorSettings.shared.symbolPartialErase = savedPartial
        super.tearDown()
    }

    private func editorVC() -> CircuitSymbolEditorViewController {
        let vc = CircuitSymbolEditorViewController(name: "", symbol: nil) { _, _ in }
        vc.loadViewIfNeeded()
        vc.canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        vc.canvas.layoutIfNeeded()
        return vc
    }

    /// 畫面座標（canvas）對到的元件座標
    private func view(_ vc: CircuitSymbolEditorViewController, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: vc.canvas.bounds.midX + x * vc.canvas.scale, y: vc.canvas.bounds.midY + y * vc.canvas.scale)
    }

    func testTheBrushStartsDrawingOnTouchDown() {
        let vc = editorVC()
        vc.setTool(.brush)
        XCTAssertTrue(vc.strokeTouch.isEnabled)
        XCTAssertFalse(vc.panGesture.isEnabled, "筆刷不用拖曳手勢（要先移動一小段才開始）")
        let t = FakeTouch(type: .pencil, location: view(vc, 10, 20))
        vc.strokeTouch.touchesBegan([t], with: UIEvent())
        XCTAssertEqual(vc.draft.symbol.strokes.count, 1, "一碰到就開始畫")
        XCTAssertEqual(vc.draft.symbol.strokes.first?.points.count, 1)
        XCTAssertEqual(vc.draft.symbol.strokes.first?.points.first?.x ?? .nan, 10, accuracy: 0.01)
        XCTAssertEqual(vc.draft.symbol.strokes.first?.points.first?.y ?? .nan, 20, accuracy: 0.01)
        t.point = view(vc, 30, 20)
        vc.strokeTouch.touchesMoved([t], with: UIEvent())
        XCTAssertEqual(vc.draft.symbol.strokes.first?.points.count, 2)
        XCTAssertFalse(vc.canvas.strokeLayer.path?.isEmpty ?? true, "畫的時候線條圖層跟著更新")
        t.fakePhase = .ended
        vc.strokeTouch.touchesEnded([t], with: UIEvent())
        XCTAssertEqual(vc.draft.symbol.strokes.first?.points.last?.x ?? .nan, 30, accuracy: 0.01)

        vc.setTool(.line)
        XCTAssertFalse(vc.strokeTouch.isEnabled)
        XCTAssertTrue(vc.panGesture.isEnabled, "線條照舊用拖曳（兩端吸到格點）")
    }

    /// 回報的問題：橡皮擦沒有小圓圈，看不出擦的範圍
    func testTheEraserShowsItsCircle() {
        let vc = editorVC()
        vc.setTool(.eraser)
        XCTAssertTrue(vc.canvas.eraserLayer.isHidden)
        let t = FakeTouch(type: .pencil, location: view(vc, 50, 50))
        vc.strokeTouch.touchesBegan([t], with: UIEvent())
        XCTAssertFalse(vc.canvas.eraserLayer.isHidden, "擦的時候看得到範圍")
        let box = vc.canvas.eraserLayer.path?.boundingBox ?? .zero
        XCTAssertEqual(box.width, CircuitSymbolEditorViewController.eraserRadius * 2, accuracy: 0.01, "圓圈就是擦到的範圍")
        XCTAssertEqual(box.midX, view(vc, 50, 50).x, accuracy: 0.01)
        t.point = view(vc, 60, 50)
        vc.strokeTouch.touchesMoved([t], with: UIEvent())
        XCTAssertEqual(vc.canvas.eraserLayer.path?.boundingBox.midX ?? 0, view(vc, 60, 50).x, accuracy: 0.01, "跟著筆尖")
        t.fakePhase = .ended
        vc.strokeTouch.touchesEnded([t], with: UIEvent())
        XCTAssertTrue(vc.canvas.eraserLayer.isHidden, "放開收起來")

        vc.setTool(.brush)
        let b = FakeTouch(type: .pencil, location: view(vc, 0, 0))
        vc.strokeTouch.touchesBegan([b], with: UIEvent())
        XCTAssertTrue(vc.canvas.eraserLayer.isHidden, "筆刷沒有圓圈")
        vc.strokeTouch.touchesEnded([b], with: UIEvent())
    }

    func testPartialEraseCutsOnlyThePartItTouches() {
        var d = CircuitSymbolDraft()
        d.beginLine(at: CGPoint(x: -40, y: 0))
        d.endLine(at: CGPoint(x: 40, y: 0))
        d.beginErase()
        XCTAssertTrue(d.erase(at: .zero, tolerance: 5, partial: true))
        XCTAssertTrue(d.erase(at: CGPoint(x: 20, y: 0), tolerance: 5, partial: true))
        XCTAssertFalse(d.erase(at: CGPoint(x: 0, y: 20), tolerance: 5, partial: true), "沒碰到不算")
        d.endErase()
        let xs = d.symbol.strokes.map { $0.points.map(\.x) }
        XCTAssertEqual(xs.count, 3, "擦掉兩段，剩三條")
        let expected: [[CGFloat]] = [[-40, -5], [5, 15], [25, 40]]
        for (got, want) in zip(xs, expected) {
            XCTAssertEqual(got.first ?? .nan, want[0], accuracy: 0.01)
            XCTAssertEqual(got.last ?? .nan, want[1], accuracy: 0.01)
        }
        d.undo()
        XCTAssertEqual(d.symbol.strokes.map(\.points), [[CGPoint(x: -40, y: 0), CGPoint(x: 40, y: 0)]], "一路擦算一步")

        var f = CircuitSymbolDraft()
        f.beginBrush(at: CGPoint(x: 0, y: 0))
        for i in 1...10 { f.continueBrush(to: CGPoint(x: CGFloat(i) * 5, y: CGFloat(i % 2) * 3)) }
        f.endBrush()
        XCTAssertTrue(f.erase(at: CGPoint(x: 25, y: 1.5), tolerance: 4, partial: true))
        XCTAssertEqual(f.symbol.strokes.count, 2)
        XCTAssertTrue(f.symbol.strokes.allSatisfy(\.freehand), "筆刷畫的切開還是筆刷線")
        XCTAssertTrue(f.erase(at: CGPoint(x: 0, y: 0), tolerance: 100, partial: true))
        XCTAssertTrue(f.symbol.strokes.isEmpty, "整條都在圓裡就整條擦掉")
    }

    func testErasingInTheEditorIsOneStepPerTouch() {
        let vc = editorVC()
        vc.setTool(.line)
        vc.handlePan(.began, at: CGPoint(x: -40, y: 0))
        vc.handlePan(.ended, at: CGPoint(x: 40, y: 0))
        vc.handlePan(.began, at: CGPoint(x: -40, y: 20))
        vc.handlePan(.ended, at: CGPoint(x: 40, y: 20))
        XCTAssertEqual(vc.draft.symbol.strokes.count, 2)

        vc.setTool(.eraser)
        XCTAssertFalse(vc.eraseKind.isHidden, "橡皮擦可以選整條或局部")
        XCTAssertTrue(vc.strokeTouch.isEnabled, "橡皮擦也是一碰到就擦")
        EditorSettings.shared.symbolPartialErase = true
        let t = FakeTouch(type: .pencil, location: view(vc, 0, -5))
        vc.strokeTouch.touchesBegan([t], with: UIEvent())
        for y in stride(from: 0, through: 25, by: 5) {
            t.point = view(vc, 0, CGFloat(y))
            vc.strokeTouch.touchesMoved([t], with: UIEvent())
        }
        t.fakePhase = .ended
        vc.strokeTouch.touchesEnded([t], with: UIEvent())
        XCTAssertEqual(vc.draft.symbol.strokes.count, 4, "兩條線都從中間切開")
        vc.undoTapped()
        XCTAssertEqual(vc.draft.symbol.strokes.count, 2, "劃過一次算一步")

        EditorSettings.shared.symbolPartialErase = false
        let tap = FakeTouch(type: .pencil, location: view(vc, 0, 0))
        vc.strokeTouch.touchesBegan([tap], with: UIEvent())
        tap.fakePhase = .ended
        vc.strokeTouch.touchesEnded([tap], with: UIEvent())
        XCTAssertEqual(vc.draft.symbol.strokes.count, 1, "整條擦除：點一下擦掉一整條")
    }
}

/// 畫元件的文字工具：符號上的字（+、−、A、VCC），AI 的 JSON 也能寫字
final class SymbolTextTests: XCTestCase {
    func testAddingEditingMovingAndErasingText() {
        var d = CircuitSymbolDraft()
        d.addText("  ", at: .zero, size: 12)
        XCTAssertTrue(d.symbol.texts.isEmpty, "空白不算")
        XCTAssertFalse(d.canUndo)
        d.addText("+", at: CGPoint(x: -14, y: -10), size: 12)
        XCTAssertEqual(d.symbol.texts, [CircuitSymbol.Label(text: "+", center: CGPoint(x: -14, y: -10), size: 12)])
        XCTAssertEqual(d.textIndex(at: CGPoint(x: -14, y: -9), tolerance: 2), 0)
        XCTAssertNil(d.textIndex(at: CGPoint(x: 30, y: 30), tolerance: 2))
        d.updateText(0, text: "V_{in}", size: 16)
        XCTAssertEqual(d.symbol.texts.first?.text, "V_{in}")
        XCTAssertEqual(d.symbol.texts.first?.size, 16, "可以換大小")
        d.beginMovingText(0)
        d.moveText(0, to: CGPoint(x: 0, y: 20))
        d.moveText(0, to: CGPoint(x: 0, y: 30))
        d.undo()
        XCTAssertEqual(d.symbol.texts.first?.center, CGPoint(x: -14, y: -10), "拖一次算一步")
        XCTAssertTrue(d.erase(at: CGPoint(x: -14, y: -10), tolerance: 6, partial: true), "橡皮擦擦得到字")
        XCTAssertTrue(d.symbol.texts.isEmpty)
        d.undo()
        d.updateText(0, text: "", size: 12)
        XCTAssertTrue(d.symbol.texts.isEmpty, "改成空白就刪掉")
    }

    func testTextCountsForTheSymbolsSizeAndCentering() throws {
        var d = CircuitSymbolDraft()
        d.beginLine(at: CGPoint(x: 100, y: 100))
        d.endLine(at: CGPoint(x: 160, y: 100))
        d.togglePin(at: CGPoint(x: 100, y: 100))
        d.addText("GND", at: CGPoint(x: 130, y: 130), size: 12)
        let raw = d.symbol
        XCTAssertTrue(raw.bounds.contains(CGPoint(x: 130, y: 134)), "字也在元件的範圍裡（才點得到、框得到）")
        let s = try XCTUnwrap(d.finished())
        let shift = CGPoint(x: s.pins[0].x - 100, y: s.pins[0].y - 100)
        XCTAssertEqual(s.texts[0].center, CGPoint(x: 130 + shift.x, y: 130 + shift.y), "置中時字跟著移")

        var textOnly = CircuitSymbolDraft()
        textOnly.addText("IC", at: .zero, size: 16)
        textOnly.togglePin(at: CGPoint(x: 20, y: 0))
        XCTAssertNotNil(textOnly.finished(), "只有字、接腳也可以")
    }

    func testOldSymbolsWithoutTextStillLoad() throws {
        let json = #"{"strokes":[{"points":[[0,0],[10,0]],"freehand":false}],"pins":[[0,0]]}"#
        let s = try JSONDecoder().decode(CircuitSymbol.self, from: Data(json.utf8))
        XCTAssertEqual(s.strokes.count, 1)
        XCTAssertTrue(s.texts.isEmpty)
        let again = try JSONDecoder().decode(CircuitSymbol.self, from: JSONEncoder().encode(
            CircuitSymbol(strokes: s.strokes, texts: [.init(text: "A", center: .zero, size: 10)], pins: s.pins)))
        XCTAssertEqual(again.texts.map(\.text), ["A"], "存檔再讀回來字還在")
    }

    func testTextOnThePageFollowsRotationButStaysUpright() {
        var c = CircuitComponent(part: .customSymbol, position: CGPoint(x: 100, y: 100))
        c.symbol = CircuitSymbol(strokes: [.init(points: [CGPoint(x: -30, y: 0), CGPoint(x: 30, y: 0)])],
                                 texts: [.init(text: "+", center: CGPoint(x: 20, y: 0), size: 12)],
                                 pins: [CGPoint(x: -30, y: 0)])
        XCTAssertEqual(CircuitRenderer.symbolTexts(c).first?.center, CGPoint(x: 120, y: 100))
        c.rotation = 90
        let p = CircuitRenderer.symbolTexts(c).first?.center ?? .zero
        XCTAssertEqual(p.x, 100, accuracy: 0.01, "轉 90 度：字的位置跟著轉")
        XCTAssertEqual(abs(p.y - 100), 20, accuracy: 0.01)
        let svg = CircuitRenderer.svg(CircuitData(components: [c]))
        XCTAssertTrue(svg.contains(">+</text>"), "匯出 SVG 也有字")
    }

    func testJSONCarriesTexts() throws {
        let file = try CircuitSymbolJSON.parse(#"{"strokes":[{"points":[[-30,0],[30,0]]}],"texts":[{"text":" A ","center":[0,-12]},{"text":"x","center":[0,0],"size":999},{"text":"","center":[5,5]}],"pins":[[-30,0]]}"#)
        XCTAssertEqual(file.symbol.texts.map(\.text), ["A", "x"], "空白的字不收")
        XCTAssertEqual(file.symbol.texts[0].size, CircuitSymbol.Label.defaultSize, "沒寫大小用預設")
        XCTAssertEqual(file.symbol.texts[1].size, CircuitSymbol.Label.sizeRange.upperBound, "太大的字縮回範圍內")
        XCTAssertThrowsError(try CircuitSymbolJSON.parse(#"{"strokes":[{"points":[[0,0],[10,0]]}],"texts":[{"text":"A","center":[0]}],"pins":[[0,0]]}"#))
        let back = try CircuitSymbolJSON.parse(CircuitSymbolJSON.export(file.symbol, name: "表"))
        XCTAssertEqual(back.symbol, file.symbol, "拷貝出去再貼回來字還在")
    }

    /// 給 AI 的說明裡每個範例都要能直接貼上；有一個示範文字
    func testEveryAIPromptExampleImports() throws {
        let prompt = CircuitSymbolJSON.aiPrompt
        XCTAssertTrue(prompt.contains("\"texts\""), "說明有寫文字方塊的格式")
        var rest = prompt[...]
        var names: [String] = []
        var withText = 0
        while let start = rest.range(of: "```json\n") {
            let end = try XCTUnwrap(rest.range(of: "```", range: start.upperBound..<rest.endIndex))
            let file = try CircuitSymbolJSON.parse(String(rest[start.upperBound..<end.lowerBound]))
            names.append(file.name ?? "")
            if !file.symbol.texts.isEmpty { withText += 1 }
            rest = rest[end.upperBound...]
        }
        XCTAssertEqual(names, ["電解電容", "電阻"])
        XCTAssertEqual(withText, 1)
    }

    func testTheTextToolInTheEditor() throws {
        let window = try TestWindow.make()
        defer { window.isHidden = true }
        let vc = CircuitSymbolEditorViewController(name: "", symbol: nil) { _, _ in }
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc.loadViewIfNeeded()
        vc.setTool(.text)
        XCTAssertTrue(vc.tapGesture.isEnabled)
        XCTAssertTrue(vc.panGesture.isEnabled, "文字用點一下新增、拖曳移動")
        // 等畫面真的變了再往下（不靠固定的時間：模擬器卡住時輸入框還沒關完，下一個就跳不出來）
        func waitUntil(_ done: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        vc.handleTap(at: CGPoint(x: 10, y: 10))
        waitUntil { vc.presentedViewController is UIAlertController }
        let alert = try XCTUnwrap(vc.presentedViewController as? UIAlertController, "點一下輸入字")
        XCTAssertEqual(alert.textFields?.count, 1)
        XCTAssertEqual(alert.actions.filter { $0.style == .default }.count, CircuitSymbolEditorViewController.textSizes.count, "選大小")
        alert.dismiss(animated: false)
        waitUntil { vc.presentedViewController == nil }

        vc.commitText("A", size: 16, editing: nil, at: CGPoint(x: 10, y: 10))
        XCTAssertEqual(vc.draft.symbol.texts.map(\.text), ["A"])
        XCTAssertEqual(vc.canvas.drawnTexts.map(\.text), ["A"], "畫布畫出字")
        vc.handlePan(.began, at: CGPoint(x: 10, y: 10))
        vc.handlePan(.changed, at: CGPoint(x: 30, y: 10))
        vc.handlePan(.ended, at: CGPoint(x: 40, y: 20))
        XCTAssertEqual(vc.draft.symbol.texts.first?.center, CGPoint(x: 40, y: 20), "拖曳移動")
        vc.handleTap(at: CGPoint(x: 40, y: 20))
        waitUntil { vc.presentedViewController is UIAlertController }
        let edit = try XCTUnwrap(vc.presentedViewController as? UIAlertController)
        XCTAssertEqual(edit.textFields?.first?.text, "A", "點已經有的字：修改")
        XCTAssertTrue(edit.actions.contains { $0.style == .destructive }, "可以刪除")
        edit.dismiss(animated: false)
        waitUntil { vc.presentedViewController == nil }
    }
}
