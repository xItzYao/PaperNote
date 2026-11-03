import XCTest
import SwiftUI
import PDFKit
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

    /// 回報的問題：在 iPad「檔案」裡用「註記」寫過的 PDF，匯入後筆跡不見了（註解沒有畫出來）。
    /// 手寫的註解變成可以編輯的筆跡；其他註解（這裡是方框）畫進頁面
    func testFilesMarkupIsImported() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("markup-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = UIGraphicsPDFRenderer(bounds: pageRect).pdfData { c in
            c.beginPage()
            ("Lecture notes" as NSString).draw(at: CGPoint(x: 60, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
        let source = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(source.page(at: 0))
        // PDF 座標：左下角是原點
        let ink = PDFAnnotation(bounds: CGRect(x: 100, y: 600, width: 200, height: 100), forType: .ink, withProperties: nil)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 10, y: 10))
        path.addLine(to: CGPoint(x: 100, y: 50))
        path.addLine(to: CGPoint(x: 190, y: 90))
        ink.add(path)
        ink.color = .red
        let border = PDFBorder()
        border.lineWidth = 4
        ink.border = border
        page.addAnnotation(ink)
        let box = PDFAnnotation(bounds: CGRect(x: 300, y: 200, width: 80, height: 80), forType: .square, withProperties: nil)
        box.color = .blue
        box.interiorColor = .blue
        page.addAnnotation(box)
        XCTAssertTrue(source.write(to: url))

        let meta = try LibraryStore.shared.importPDF(from: url, folder: nil)
        defer { LibraryStore.shared.deleteNotebook(meta.id) }
        let session = try NotebookSession(id: meta.id)
        let p = try XCTUnwrap(session.document.pages.first)

        XCTAssertEqual(p.ink.count, 1, "手寫的註解變成一筆可以編輯的筆跡")
        let s = try XCTUnwrap(p.ink.first)
        XCTAssertTrue(s.colorHex.hasPrefix("#FF0000"), "顏色照註解：\(s.colorHex)")
        XCTAssertEqual(CGFloat(s.points[0].w), 4, accuracy: 0.01, "粗細照註解")
        let first = try XCTUnwrap(s.points.first?.point), last = try XCTUnwrap(s.points.last?.point)
        XCTAssertEqual(first.x, 110, accuracy: 1)
        XCTAssertEqual(first.y, 842 - 610, accuracy: 1, "上下翻成頁面座標")
        XCTAssertEqual(last.x, 290, accuracy: 1)
        XCTAssertEqual(last.y, 842 - 690, accuracy: 1)

        let pdfPage = try XCTUnwrap(session.pdfPage(for: p))
        XCTAssertFalse(pdfPage.annotations.contains { $0.type == "Ink" }, "PDF 裡的手寫註解拿掉了，不會畫兩次")

        // 方框畫進頁面了：頁面背景在方框中心（頁面座標 340, 842 - 240）是藍色
        let snap = session.backgroundSnapshot(for: p)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: snap.fullSize, format: format).image { c in
            PageRenderer.drawBackground(snap, in: c.cgContext)
        }
        let cg = try XCTUnwrap(img.cgImage)
        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            // CGContext 原點在左下：把圖片 (340, 602) 那一點移到 (0, 0)
            ctx.draw(cg, in: CGRect(x: -340, y: -(CGFloat(cg.height) - 602 - 1), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        }
        XCTAssertGreaterThan(Int(px[2]), 150, "方框是藍的：\(px)")
        XCTAssertLessThan(Int(px[0]), 100, "方框是藍的：\(px)")
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
