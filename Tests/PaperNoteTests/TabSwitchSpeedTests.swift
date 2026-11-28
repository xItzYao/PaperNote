import XCTest
import PencilKit
@testable import PaperNote

/// 回報的問題（11/28）：切換分頁延遲嚴重，大概要一秒分頁才切過去。
/// 切走的那一本每次都會存檔：之前什麼都沒改也要把整本（自製筆刷的每個點）編成 JSON 再比對，
/// PencilKit 的筆跡也要整本重新分頁、一筆一筆算指紋。寫得越多，切分頁越慢
final class TabSwitchSpeedTests: XCTestCase {
    private var window: UIWindow!
    private var ids: [UUID] = []

    private func spin(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    override func setUpWithError() throws {
        window = try TestWindow.make()
    }

    override func tearDown() {
        (window.rootViewController as? TabsViewController)?.exitToLibrary()
        window.isHidden = true
        window = nil
        for id in ids {
            TabStore.shared.close(id)
            LibraryStore.shared.deleteNotebook(id)
        }
        super.tearDown()
    }

    /// 寫得很滿的一本：24 頁自製筆刷（每頁 300 筆、每筆 40 點），另外 6 頁是以前用 PencilKit 寫的
    private func heavyNotebook(_ title: String) throws -> UUID {
        let meta = LibraryStore.shared.createNotebook(title: title, folder: nil, paper: .ruled, landscape: false)
        ids.append(meta.id)
        let session = try NotebookSession(id: meta.id)
        var pages = [session.document.pages[0]]
        for _ in 1..<30 { pages.append(Page(background: .paper(width: 595, height: 842, style: .ruled))) }
        for k in pages.indices {
            var ink: [InkStroke] = [], pk: [PKStroke] = []
            for i in 0..<300 {
                let x = CGFloat(30 + (i % 30) * 18), y = CGFloat(40 + (i / 30) * 70)
                let pts = (0..<40).map { CGPoint(x: x + sin(CGFloat($0) / 3) * 6 + CGFloat(k) * 0.01, y: y + CGFloat($0) * 0.9) }
                if k < 24 {
                    ink.append(InkStroke(colorHex: "#1A1A1AFF", points: pts.map { InkPoint($0, width: 1.2) }))
                } else if i < 200 {
                    pk.append(ShapeRecognizer.makeStroke(points: pts, preset: BrushStore.shared.current))
                }
            }
            pages[k].ink = ink
            if !pk.isEmpty { session.drawings[pages[k].id] = PKDrawing(strokes: pk) }
        }
        session.document.pages = pages
        session.save()
        return meta.id
    }

    /// 切到 id 那一本（和點分頁一樣），回傳到畫面畫好為止花的時間
    private func switchTab(to id: UUID, _ tabs: TabsViewController) -> Double {
        let t = CACurrentMediaTime()
        TabStore.shared.open(id, page: nil)
        tabs.view.layoutIfNeeded()
        CATransaction.flush()
        return CACurrentMediaTime() - t
    }

    func testSwitchingBetweenTwoFullNotebooksIsQuick() throws {
        let a = try heavyNotebook("A"), b = try heavyNotebook("B")
        TabStore.shared.open(a, page: nil)
        TabStore.shared.open(b, page: nil)
        TabStore.shared.activate(a)
        let tabs = TabsViewController()
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        tabs.view.layoutIfNeeded()
        spin(0.5)
        XCTAssertEqual(tabs.shownNotebookID, a)
        // 第一次打開 B（要從磁碟讀進來），不算在切換裡
        let first = switchTab(to: b, tabs)
        spin(0.5)
        XCTAssertEqual(tabs.shownNotebookID, b)

        var switches = FrameTimes()
        for k in 0..<8 {
            let to = k % 2 == 0 ? a : b
            let s = switchTab(to: to, tabs)
            switches.add(s)
            // 每一段花多久（切分頁本身寫進除錯紀錄；剩下的是之後的排版、畫面更新）
            let laps = DebugLog.text.components(separatedBy: "
").last { $0.contains("tab switch ms") } ?? ""
            print("TABSWITCH \(k) total=\(String(format: "%.0f", s * 1000)) \(laps)")
            spin(0.2)
            XCTAssertEqual(tabs.shownNotebookID, to)
        }
        print("TABSWITCH first-open=\(String(format: "%.1f", first * 1000))ms switches \(switches.summary)")
        assertFast(switches, under: 0.15, "兩本都寫滿的筆記本之間切換")
    }

    /// 切走之前剛寫了一筆（自動存檔還沒跑）：這次要存，存好的內容要對
    func testSwitchingRightAfterWritingStillSavesTheNewStroke() throws {
        let a = try heavyNotebook("A"), b = try heavyNotebook("B")
        TabStore.shared.open(b, page: nil)
        TabStore.shared.open(a, page: nil)
        let tabs = TabsViewController()
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        tabs.view.layoutIfNeeded()
        spin(0.5)
        let editor = try XCTUnwrap(tabs.children.compactMap { $0 as? NotebookViewController }.first)
        XCTAssertEqual(editor.session.id, a)
        let pageID = editor.pages[0].id
        editor.updatePage(0) { $0.ink.append(InkStroke(colorHex: "#FF0000FF", points: [InkPoint(CGPoint(x: 5, y: 5), width: 2), InkPoint(CGPoint(x: 80, y: 90), width: 2)])) }
        let o = editor.contentOrigin(25)
        let pk = ShapeRecognizer.makeStroke(points: (0..<10).map { CGPoint(x: o.x + 300 + CGFloat($0) * 9, y: o.y + 500) }, preset: BrushStore.shared.current)
        var d = editor.canvas.drawing
        d.strokes.append(pk)
        editor.canvas.drawing = d

        let t = switchTab(to: b, tabs)
        print("TABSWITCH after-edit=\(String(format: "%.1f", t * 1000))ms")
        spin(0.3)
        let saved = try NotebookSession(id: a)
        XCTAssertEqual(saved.document.pages[0].ink.last?.colorHex, "#FF0000FF", "剛寫的自製筆刷那一筆有存到")
        let p25 = saved.document.pages[25].id
        XCTAssertEqual(saved.drawings[p25]?.strokes.count, 201, "剛寫的 PencilKit 那一筆存到第 26 頁")
        XCTAssertEqual(saved.document.pages[0].id, pageID)
    }

    /// 沒改的話存檔什麼都不用做；改了才寫
    func testSavingWithoutChangesDoesNotRewriteTheDocument() throws {
        let a = try heavyNotebook("A")
        let s = try NotebookSession(id: a)
        let url = NotebookSession.documentURL(in: s.directory)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        spin(0.05)
        let t = CACurrentMediaTime()
        s.save()
        let quiet = CACurrentMediaTime() - t
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "沒改就不重寫")
        print("TABSWITCH quiet-save=\(String(format: "%.1f", quiet * 1000))ms")
        XCTAssertLessThan(quiet, 0.05, "沒改的存檔不用把整本編碼一次")

        s.document.pages[3].note = "改了"
        s.save()
        XCTAssertEqual(try NotebookSession(id: a).document.pages[3].note, "改了")
    }
}
