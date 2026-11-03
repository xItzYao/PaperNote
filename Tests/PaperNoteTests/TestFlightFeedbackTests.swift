import XCTest
import SwiftUI
@testable import PaperNote

/// TestFlight 回報：資料庫的橫向封面擋住旁邊的筆記本、頁數多時新增文字框頁面會閃
final class TestFlightFeedbackTests: XCTestCase {
    /// 橫向（比較寬）的封面不能把格子撐寬，蓋到隔壁那一格
    func testLandscapeCoverStaysInsideItsColumn() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let img = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image { c in
            UIColor.systemTeal.setFill()
            c.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        try XCTUnwrap(img.pngData()).write(to: url)
        let cell = NotebookCell(meta: NotebookMeta(title: "橫向講義", folderId: nil, coverHex: "#C0504DFF"), coverURL: url)
        let host = UIHostingController(rootView: cell)
        for column: CGFloat in [160, 220] {
            let size = host.sizeThatFits(in: CGSize(width: column, height: 1000))
            XCTAssertLessThanOrEqual(size.width, column + 0.5, "封面寬度不能超過這一格（\(column)）")
        }
    }

    /// 鍵盤跳出來時（系統在鍵盤的動畫裡通知），頁面不能跟著縮放一下
    func testKeyboardDoesNotAnimateThePages() throws {
        let meta = LibraryStore.shared.createNotebook(title: "KeyboardFlickerTest", folder: nil, paper: .blank, landscape: false)
        defer { LibraryStore.shared.deleteNotebook(meta.id) }
        let session = try NotebookSession(id: meta.id)
        for _ in 0..<30 { session.document.pages.append(Page(background: .paper(width: 595, height: 842, style: .grid))) }
        session.save()
        let editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        let window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNotEqual(editor.canvas.zoomScale, 1, "頁面有縮放（縮放是 1 的話測不出來）")
        let before = editor.pagesContainer.layer.animationKeys() ?? []

        let keyboard = CGRect(x: 0, y: window.bounds.height - 320, width: window.bounds.width, height: 320)
        UIView.animate(withDuration: 0.25) {
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: keyboard])
        }
        let keys = (editor.pagesContainer.layer.animationKeys() ?? []).filter { !before.contains($0) }
        XCTAssertEqual(keys, [], "頁面沒有動畫（縮放、位置都不動）")
        let children = editor.pagesContainer.subviews.flatMap { $0.layer.animationKeys() ?? [] }
        XCTAssertFalse(children.contains("bounds") || children.contains("position") || children.contains("transform"), "頁面也不動：\(children)")
        window.isHidden = true
    }
}
