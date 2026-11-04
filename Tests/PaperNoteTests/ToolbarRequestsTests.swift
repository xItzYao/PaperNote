import XCTest
import PencilKit
import SwiftUI
@testable import PaperNote

/// 回報的需求：
/// - 筆和螢光筆的常用筆刷右邊就是「新增」，五支不夠用可以一直加；筆刷可以刪除
/// - 工具列的小視窗（筆刷、顏色）點旁邊的頁面就關掉
/// - 螢光筆不蓋住筆跡
/// - Pencil Pro 按壓可以自訂成工具列的工具或調色盤
/// - Pencil 點兩下顯示調色盤預設關閉
final class ToolbarRequestsTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var savedCurrent: [BrushCategory: UUID] = [:]
    private var savedCategory: BrushCategory = .pen
    private var added: [UUID] = []

    override func setUpWithError() throws {
        let store = BrushStore.shared
        savedCategory = store.activeCategory
        for c in [BrushCategory.pen, .highlighter] {
            store.activeCategory = c
            savedCurrent[c] = store.currentID
        }
        store.activeCategory = savedCategory
        let meta = LibraryStore.shared.createNotebook(title: "ToolbarRequests", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    override func tearDown() {
        // 筆刷存在 App 裡（UI 測試也用同一份）：加的拿掉，目前的筆改回來
        editor.dismissToolPopover()
        let store = BrushStore.shared
        for id in added { store.remove(id) }
        for (_, id) in savedCurrent { store.select(id) }
        store.activeCategory = savedCategory
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private var addButton: UIButton? {
        editor.subBarStack.arrangedSubviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "新增常用筆刷" }
    }

    private func wait(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// 小視窗出現的動畫跑完（動畫中 UIKit 不收關掉的要求）
    private func waitForPopover() {
        wait { editor.presentedViewController.map { !$0.isBeingPresented } ?? false }
    }

    /// 按「新增」：多一支筆刷（打開它的設定）
    private func addPreset() throws {
        try XCTUnwrap(addButton, "要有新增").sendActions(for: .touchUpInside)
        added.append(BrushStore.shared.currentID)
        waitForPopover()
    }

    func testAddSitsRightAfterTheBrushes() throws {
        for t in [EditorTool.pen, .highlighter] {
            editor.setTool(t)
            let items = editor.subBarStack.arrangedSubviews
            XCTAssertTrue(items.first is UIScrollView, "\(t)：最左邊是常用筆刷")
            XCTAssertEqual((items[safe: 1] as? UIButton)?.accessibilityLabel, "新增常用筆刷", "\(t)：新增就在筆刷右邊，不在最右邊")
        }
    }

    func testManyBrushesStillFit() throws {
        editor.setTool(.pen)
        let before = BrushStore.shared.presets.count
        // 加到一排一定放不下
        for _ in 0..<30 {
            try addPreset()
            editor.dismissToolPopover()
        }
        XCTAssertEqual(BrushStore.shared.presets.count, before + 30, "筆刷沒有數量上限")
        editor.view.layoutIfNeeded()
        let row = editor.subBarStack.frame
        XCTAssertGreaterThanOrEqual(row.minX, 0, "第二列沒有超出畫面：\(row)")
        XCTAssertLessThanOrEqual(row.maxX, editor.pageLabel.frame.minX, "第二列不蓋到頁碼：\(row)")
        let strip = try XCTUnwrap(editor.presetStrip)
        XCTAssertGreaterThan(strip.contentSize.width, strip.bounds.width + 1, "放不下的筆刷可以捲動")
        let current = try XCTUnwrap(editor.presetButtons[BrushStore.shared.currentID])
        let r = current.convert(current.bounds, to: strip)
        XCTAssertTrue(strip.bounds.insetBy(dx: -0.5, dy: -0.5).contains(r), "剛新增的筆刷捲到看得到：\(r) / \(strip.bounds)")
        XCTAssertNotNil(addButton, "新增還在")
    }

    func testDeletingABrushFromItsSettings() throws {
        editor.setTool(.highlighter)
        try addPreset()
        let id = BrushStore.shared.currentID
        let host = try XCTUnwrap(editor.presentedViewController as? UIHostingController<BrushSettingsView>, "新增後打開它的設定")
        let delete = try XCTUnwrap(host.rootView.onDelete, "筆刷設定裡可以刪除")
        delete()
        added.removeAll { $0 == id }
        XCTAssertFalse(BrushStore.shared.presets.contains { $0.id == id }, "刪掉了")
        XCTAssertNil(editor.presetButtons[id], "工具列也拿掉了")
        wait { editor.presentedViewController == nil }
        XCTAssertNil(editor.presentedViewController, "設定關掉了")
    }

    /// 回報的需求：小視窗開著時，用筆點或畫旁邊的頁面都當作點旁邊：關掉（系統的關閉動畫）、這一下不寫字，
    /// 等小視窗關好了才照常寫
    func testTouchingThePageClosesThePopoverWithoutWriting() throws {
        editor.setTool(.pen)
        let b = try XCTUnwrap(editor.presetButtons[BrushStore.shared.currentID])
        editor.presentBrushSettings(BrushStore.shared.current, from: b)
        waitForPopover()
        let popover = try XCTUnwrap(editor.presentedViewController)
        let canvas = editor.canvas
        let p = canvas.convert(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: window)
        let hit = window.hitTest(p, with: nil)
        XCTAssertTrue(hit === editor.popoverShield, "小視窗開著：頁面上的觸碰被接下來，到不了畫布（不會寫字），而是 \(String(describing: hit))")

        editor.popoverShield.touchesBegan([FakeTouch(type: .pencil, location: p)], with: nil)
        XCTAssertTrue(popover.isBeingDismissed, "一碰到就開始關（有動畫）")
        XCTAssertTrue(window.hitTest(p, with: nil) === editor.popoverShield, "正在關的時候也還不能寫")
        wait { editor.presentedViewController == nil }
        XCTAssertNil(editor.presentedViewController, "碰到頁面就關掉")
        let after = window.hitTest(p, with: nil)
        XCTAssertTrue(after?.isDescendant(of: canvas) ?? false, "關好了，筆照常寫在頁面上，而是 \(String(describing: after))")
    }

    // MARK: 筆型在工具列最左邊

    private var penStyleButton: UIButton? { editor.subBarStack.arrangedSubviews.first as? UIButton }

    func testThePenStylePickerIsLeftmost() throws {
        let original = BrushStore.shared.current
        defer { BrushStore.shared.update(original); editor.applyTool() }
        editor.setTool(.pen)
        let picker = try XCTUnwrap(penStyleButton, "筆工具列最左邊是筆型")
        XCTAssertEqual(picker.accessibilityLabel, "筆型")
        XCTAssertEqual(picker.accessibilityValue, original.style.title)
        XCTAssertNotNil(picker.configuration?.image, "有用目前顏色畫的預覽")
        let actions = try XCTUnwrap(picker.menu?.children.compactMap { $0 as? UIAction })
        XCTAssertEqual(actions.map(\.title), InkStyle.allCases.filter { $0 != .marker }.map(\.title), "每種筆型都可以選（螢光筆不在這裡）")
        XCTAssertTrue(actions.allSatisfy { $0.image != nil }, "每種筆型都有預覽")
        XCTAssertEqual(actions.filter { $0.state == .on }.map(\.title), [original.style.title], "勾著目前的筆型")

        let slot = BrushStore.shared.styleWidths(original.style).firstIndex { abs($0 - original.width) < 0.01 }
        let target: InkStyle = original.style == .watercolor ? .pencil : .watercolor
        editor.setPenStyle(target)
        let now = BrushStore.shared.current
        XCTAssertEqual(now.id, original.id, "改的是目前這支筆")
        XCTAssertEqual(now.style, target)
        XCTAssertEqual(now.colorHex, original.colorHex, "顏色不變")
        if let slot { XCTAssertEqual(now.width, BrushStore.shared.styleWidths(target)[slot], accuracy: 0.01, "粗細留在同一格") }
        XCTAssertEqual(penStyleButton?.accessibilityValue, target.title, "工具列的筆型跟著換")
        XCTAssertEqual(penStyleButton?.menu?.children.compactMap { ($0 as? UIAction)?.state == .on ? $0.title : nil }, [target.title])
    }

    func testTheHighlighterHasNoPenStylePicker() {
        editor.setTool(.highlighter)
        XCTAssertFalse(editor.subBarStack.arrangedSubviews.contains { $0.accessibilityLabel == "筆型" })
    }

    // MARK: 螢光筆不蓋住筆跡

    func testCustomInkIsAbovePencilKit() throws {
        editor.view.layoutIfNeeded()
        let v = try XCTUnwrap(editor.pageViews.values.first)
        XCTAssertTrue(v.inkView.superview === editor.inkContainer, "自製筆刷的筆跡放在 PencilKit 上面那一層")
        XCTAssertTrue(editor.canvas.subviews.last === editor.inkContainer, "那一層在畫布最上面")
        XCTAssertEqual(v.inkView.frame, v.frame, "和頁面對齊")
        XCTAssertEqual(editor.inkContainer.frame, editor.pagesContainer.frame, "跟著縮放、捲動")
        editor.canvas.zoomScale = 1.5
        editor.updateZoomLayout()
        XCTAssertEqual(editor.inkContainer.frame, editor.pagesContainer.frame, "放大後也對齊")
    }

    private func pixel(_ img: UIImage, _ p: CGPoint) throws -> [UInt8] {
        let cg = try XCTUnwrap(img.cgImage)
        let s = CGFloat(cg.width) / img.size.width
        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: -p.x * s, y: -(CGFloat(cg.height) - p.y * s - 1), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        }
        return px
    }

    /// 匯出（縮圖）也一樣：黑色的字上面畫螢光筆，字還是黑的
    func testExportedHighlighterStaysUnderCustomInk() throws {
        let size = CGSize(width: 400, height: 200)
        var page = Page(background: .paper(width: size.width, height: size.height, style: .blank))
        page.ink = [InkStroke(colorHex: "#000000FF", points: [InkPoint(CGPoint(x: 100, y: 100), width: 8), InkPoint(CGPoint(x: 300, y: 100), width: 8)])]
        let marker = ShapeRecognizer.makeStroke(points: [CGPoint(x: 200, y: 40), CGPoint(x: 200, y: 160)],
                                                ink: PKInk(.marker, color: .systemYellow), width: 40, sample: nil)
        let snap = BackgroundSnapshot(fullSize: size, insets: PageInsets(), baseSize: size, paper: .blank,
                                      pdfPage: nil, pdfTransform: .identity, highlights: [])
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { c in
            PageRenderer.drawFullPage(page, snapshot: snap, drawing: PKDrawing(strokes: [marker]), image: { _ in nil }, in: c.cgContext, inkScale: 1)
        }
        let yellow = try pixel(img, CGPoint(x: 200, y: 60))
        XCTAssertGreaterThan(Int(yellow[0]), 150, "螢光筆有畫：\(yellow)")
        XCTAssertLessThan(Int(yellow[2]), 150, "螢光筆有畫：\(yellow)")
        let ink = try pixel(img, CGPoint(x: 200, y: 100))
        XCTAssertLessThan(Int(ink[0]), 60, "字是黑的，沒被螢光筆蓋住：\(ink)")
        XCTAssertLessThan(Int(ink[1]), 60, "字是黑的，沒被螢光筆蓋住：\(ink)")
    }

    /// PencilKit 的筆（鉛筆、鋼筆…）：螢光筆排到前面，畫在底下
    func testHighlighterStrokesGoUnderPencilKitInk() {
        let pen = ShapeRecognizer.makeStroke(points: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0)], ink: PKInk(.pencil, color: .black), width: 3, sample: nil)
        let pen2 = ShapeRecognizer.makeStroke(points: [CGPoint(x: 0, y: 10), CGPoint(x: 50, y: 10)], ink: PKInk(.pen, color: .blue), width: 3, sample: nil)
        // 螢光筆真正畫出來的墨水：半透明的 monoline（不是 PencilKit 的 marker）
        let highlighter = BrushPreset(style: .marker, colorHex: "#FFE14DFF", width: 18).tool.ink
        let marker = ShapeRecognizer.makeStroke(points: [CGPoint(x: 0, y: 5), CGPoint(x: 50, y: 5)], ink: highlighter, width: 20, sample: nil)
        let sorted = NotebookViewController.highlightsBelowInk([pen, marker, pen2])
        XCTAssertEqual(sorted?.map(\.ink.inkType), [.monoline, .pencil, .pen], "螢光筆在最前面，其他順序不變")
        let monoline = ShapeRecognizer.makeStroke(points: [CGPoint(x: 0, y: 20), CGPoint(x: 50, y: 20)],
                                                  ink: BrushPreset(style: .monoline, colorHex: "#000000FF", width: 2).tool.ink, width: 2, sample: nil)
        XCTAssertNil(NotebookViewController.highlightsBelowInk([monoline, pen]), "不透明的原子筆不是螢光筆")
        let legacy = ShapeRecognizer.makeStroke(points: [CGPoint(x: 0, y: 5), CGPoint(x: 50, y: 5)], ink: PKInk(.marker, color: .yellow), width: 20, sample: nil)
        XCTAssertTrue(NotebookViewController.isHighlighterStroke(legacy), "舊筆記的 PencilKit marker 也算")
        XCTAssertNil(NotebookViewController.highlightsBelowInk([marker, pen, pen2]), "已經排好就不動")
        XCTAssertNil(NotebookViewController.highlightsBelowInk([pen, pen2]))
    }

    // MARK: Pencil

    func testSqueezeCanSwitchToAnyToolbarTool() {
        let s = editor.settings
        let saved = s.squeezeAction
        defer { s.squeezeAction = saved }

        XCTAssertEqual(editor.squeezeMenuItems().map(\.title), ["調色盤"] + NotebookViewController.toolbarTools.map(\.2),
                       "可以選調色盤或工具列的每個工具")

        s.squeezeAction = "palette"
        editor.setTool(.pen)
        editor.handlePencilSqueeze(at: nil)
        XCTAssertNotNil(editor.paletteOverlay, "預設叫出調色盤")
        editor.handlePencilSqueeze(at: nil)
        XCTAssertNil(editor.paletteOverlay, "再按一次收起")

        s.squeezeAction = EditorSettings.squeezeKey(.lasso)
        editor.handlePencilSqueeze(at: nil)
        XCTAssertEqual(editor.tool, .lasso)
        XCTAssertNil(editor.paletteOverlay, "改成工具就不叫出調色盤")
        editor.handlePencilSqueeze(at: nil)
        XCTAssertEqual(editor.tool, .pen, "再按一次切回原本的工具")

        s.squeezeAction = EditorSettings.squeezeKey(.highlighter)
        editor.setTool(.eraser)
        editor.handlePencilSqueeze(at: nil)
        XCTAssertEqual(editor.tool, .highlighter)
        editor.handlePencilSqueeze(at: nil)
        XCTAssertEqual(editor.tool, .eraser)
    }

    func testDoubleTapPaletteIsOffByDefault() {
        let d = UserDefaults.standard
        let saved = d.object(forKey: "paletteOnDoubleTap")
        defer { d.set(saved, forKey: "paletteOnDoubleTap") }
        d.removeObject(forKey: "paletteOnDoubleTap")
        XCTAssertFalse(EditorSettings.shared.paletteOnDoubleTap, "沒設定過：點兩下不顯示調色盤圖示")
    }
}
