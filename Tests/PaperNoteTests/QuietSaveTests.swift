import XCTest
import PencilKit
@testable import PaperNote

/// 回報的問題：打開筆記本、什麼都沒改就關掉，備份也會上傳；畫幾筆就要更新好幾個檔案。
/// 存檔只能動真的改過的檔案，修改日期也只在有改的時候更新（雲端清單才不會跟著變）
final class QuietSaveTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var dir: URL { LibraryStore.shared.notebookURL(notebookID) }

    private struct FileState: Equatable {
        let data: Data
        let modified: Date
    }

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "QuietSave", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        // 用過一陣子的筆記本：兩頁都有筆跡（座標有小數）、第二頁是我的最愛、縮圖都畫好了
        let s = try NotebookSession(id: meta.id)
        s.document.pages.append(Page(background: .paper(width: 595, height: 842, style: .grid)))
        s.document.pages[1].favorite = true
        for (i, page) in s.document.pages.enumerated() {
            let pts = (0...20).map { CGPoint(x: 100.123 + CGFloat($0) * 7.37, y: 200.457 + CGFloat(i) * 33.3 + sin(CGFloat($0)) * 3.1) }
            s.drawings[page.id] = PKDrawing(strokes: [ShapeRecognizer.makeStroke(points: pts, preset: BrushStore.shared.current)])
        }
        s.save()
        s.writeLibraryThumbnails()

        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        spin(0.3)
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// 筆記本資料夾裡每個檔案的內容和修改時間
    private func snapshot() -> [String: FileState] {
        var out: [String: FileState] = [:]
        let base = dir.resolvingSymlinksInPath().path + "/"
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: Array(keys))
        while let url = en?.nextObject() as? URL {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true,
                  let data = try? Data(contentsOf: url) else { continue }
            out[String(url.resolvingSymlinksInPath().path.dropFirst(base.count))] = FileState(data: data, modified: v.contentModificationDate ?? .distantPast)
        }
        return out
    }

    private func changed(from before: [String: FileState], to after: [String: FileState]) -> Set<String> {
        Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
    }

    /// 只是打開看、螢幕變暗、關掉：一個檔案都不動，修改日期不變
    func testOpeningAndClosingWithoutEditsChangesNothing() throws {
        let before = snapshot()
        let modified = try XCTUnwrap(LibraryStore.shared.notebook(notebookID)).modified
        spin(1.1)   // 有重寫的話，修改時間一定不一樣

        editor.saveNow()            // 螢幕變暗、切出 App
        editor.prepareForClose()    // 關掉筆記本

        XCTAssertEqual(changed(from: before, to: snapshot()), [])
        XCTAssertEqual(LibraryStore.shared.notebook(notebookID)?.modified, modified)
    }

    /// 畫一筆：只有那一頁的筆跡（和封面）改變；別頁的筆跡和 document.json 不動
    func testOneStrokeOnlyTouchesThatPage() throws {
        let before = snapshot()
        let modified = try XCTUnwrap(LibraryStore.shared.notebook(notebookID)).modified
        let first = editor.pages[0].id
        spin(1.1)

        editor.setTool(.pen)
        let o = editor.contentOrigin(0)
        editor.canvasViewDidBeginUsingTool(editor.canvas)
        var d = editor.canvas.drawing
        let pts = (0...20).map { CGPoint(x: o.x + 300 + CGFloat($0) * 4, y: o.y + 500 + CGFloat($0) * 2) }
        d.strokes.append(ShapeRecognizer.makeStroke(points: pts, preset: BrushStore.shared.current))
        editor.canvas.drawing = d
        editor.canvasViewDidEndUsingTool(editor.canvas)
        spin(0.3)
        editor.prepareForClose()

        let after = snapshot()
        let content = changed(from: before, to: after).filter { !$0.hasPrefix("thumbs/") }
        XCTAssertEqual(content, ["drawings/\(first.uuidString).drawing"])
        XCTAssertNotEqual(after["thumbs/cover.jpg"]?.data, before["thumbs/cover.jpg"]?.data, "封面是第一頁，要更新")
        XCTAssertGreaterThan(try XCTUnwrap(LibraryStore.shared.notebook(notebookID)).modified, modified)
    }
}
