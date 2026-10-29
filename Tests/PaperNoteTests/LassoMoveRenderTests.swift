import XCTest
import PencilKit
@testable import PaperNote

/// 回報的問題：套索選的筆跡移動之後，上一個位置留下殘影（畫面上還看得到，資料裡已經沒有）
final class LassoMoveRenderTests: XCTestCase {
    private final class FakePan: UIPanGestureRecognizer {
        var fake: UIGestureRecognizer.State = .possible
        override var state: UIGestureRecognizer.State {
            get { fake }
            set { fake = newValue }
        }
    }

    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "LassoMoveRender", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
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

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func doc(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let o = editor.contentOrigin(0)
        return CGPoint(x: o.x + x, y: o.y + y)
    }

    private func docRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(origin: doc(x, y), size: CGSize(width: w, height: h))
    }

    /// 用 Pencil 拖一次，每個點是分開的觸控事件
    private func drag(_ points: [CGPoint]) {
        let g = FakePan(target: nil, action: nil)
        for (i, p) in points.enumerated() {
            g.fake = i == 0 ? .began : (i == points.count - 1 ? .ended : .changed)
            editor.handleLassoPan(g, p)
            spin()
        }
    }

    /// 螢幕上這塊區域（文件座標）的墨水量：白紙上每個像素有多深的總和
    private func ink(_ r: CGRect) -> Double {
        let region = editor.pagesContainer.convert(r, to: window)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = window.screen.scale
        let img = UIGraphicsImageRenderer(size: region.size, format: fmt).image { rc in
            UIColor.white.setFill()
            rc.fill(CGRect(origin: .zero, size: region.size))
            window.drawHierarchy(in: CGRect(origin: CGPoint(x: -region.minX, y: -region.minY), size: window.bounds.size),
                                 afterScreenUpdates: true)
        }
        guard let cg = img.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        for i in 0..<(w * h) { sum += Double(255 - min(px[i * 4], px[i * 4 + 1], px[i * 4 + 2])) }
        return sum
    }

    /// 一行字（彎彎曲曲的幾筆），頁面內容座標 x 100…280、y 290…310
    private func writeLine() {
        let preset = BrushStore.shared.current
        var d = editor.canvas.drawing
        for k in 0..<6 {
            let x0 = 100 + CGFloat(k) * 30
            let pts = (0...12).map { doc(x0 + CGFloat($0) * 2, 300 + sin(CGFloat($0)) * 10) }
            d.strokes.append(ShapeRecognizer.makeStroke(points: pts, preset: preset))
        }
        editor.setDrawing(d)
        spin(0.5)
    }

    func testMovedStrokesLeaveNothingBehind() {
        let blank = ink(docRect(90, 270, 210, 60))
        writeLine()
        let strokes = editor.canvas.drawing.strokes.count
        XCTAssertGreaterThan(ink(docRect(90, 270, 210, 60)), blank + 1000, "寫好的字要看得到")

        editor.setTool(.lasso)
        drag([doc(80, 270), doc(300, 270), doc(300, 330), doc(80, 330), doc(80, 272), doc(81, 271)])
        XCTAssertEqual(editor.lassoSel?.strokeIndices.count, 6, "圈到整行")

        // 往下拖兩次（回報的情形：每次移動都在原本的位置留下一份）
        drag([doc(150, 300), doc(150, 400), doc(150, 550)])
        spin(0.5)
        drag([doc(150, 550), doc(150, 650), doc(150, 800)])
        spin(0.5)

        XCTAssertEqual(editor.canvas.drawing.strokes.count, strokes, "筆跡的數量不變")
        XCTAssertEqual(editor.lassoSel?.strokeIndices.count, 6)
        XCTAssertGreaterThan(ink(docRect(90, 770, 210, 60)), blank + 1000, "移到的位置看得到字")
        XCTAssertEqual(ink(docRect(90, 270, 210, 60)), blank, accuracy: 300, "第一個位置不能留下殘影")
        XCTAssertEqual(ink(docRect(90, 520, 210, 60)), blank, accuracy: 300, "第二個位置不能留下殘影")
    }

    /// 診斷：同一個畫面上，拿掉一筆後畫面有沒有跟著更新（PKCanvasView 本身、換成 EditorCanvasView 和 EditorUndoManager）
    func testDiagnoseCanvasRedrawAfterRemovingStrokes() {
        let host = UIViewController()
        let plain = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let custom = EditorCanvasView(frame: CGRect(x: 0, y: 320, width: 400, height: 300))
        let um = EditorUndoManager()
        um.editor = editor
        custom.editorUndoManager = um
        for c in [plain, custom] as [PKCanvasView] {
            c.backgroundColor = .white
            c.isOpaque = true
            host.view.addSubview(c)
        }
        window.rootViewController = host
        spin(0.3)
        func inkIn(_ c: PKCanvasView, _ r: CGRect) -> Double {
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = window.screen.scale
            let wr = c.convert(r, to: window)
            let img = UIGraphicsImageRenderer(size: wr.size, format: fmt).image { rc in
                UIColor.white.setFill()
                rc.fill(CGRect(origin: .zero, size: wr.size))
                window.drawHierarchy(in: CGRect(origin: CGPoint(x: -wr.minX, y: -wr.minY), size: window.bounds.size), afterScreenUpdates: true)
            }
            guard let cg = img.cgImage else { return 0 }
            let w = cg.width, h = cg.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            var sum = 0.0
            for i in 0..<(w * h) { sum += Double(255 - min(px[i * 4], px[i * 4 + 1], px[i * 4 + 2])) }
            return sum
        }
        let preset = BrushStore.shared.current
        let stroke = ShapeRecognizer.makeStroke(points: (0...20).map { CGPoint(x: 50 + CGFloat($0) * 5, y: 60 + sin(CGFloat($0)) * 10) }, preset: preset)
        let old = CGRect(x: 40, y: 40, width: 120, height: 40)
        let new = old.offsetBy(dx: 0, dy: 150)
        for (name, c) in [("plain", plain), ("custom", custom as PKCanvasView)] {
            c.drawing = PKDrawing(strokes: [stroke])
            spin(0.3)
            let drawn = inkIn(c, old)
            c.drawing = PKDrawing(strokes: [])
            spin(0.3)
            let removed = inkIn(c, old)
            var moved = stroke
            moved.transform = moved.transform.concatenating(CGAffineTransform(translationX: 0, y: 150))
            c.drawing = PKDrawing(strokes: [moved])
            spin(0.3)
            print("DIAG \(name): drawn=\(Int(drawn)) removed=\(Int(removed)) afterMove old=\(Int(inkIn(c, old))) new=\(Int(inkIn(c, new)))")
            // 同一個 PKDrawing 改來改去（編輯器的做法）
            var d = PKDrawing(strokes: [stroke])
            c.drawing = d
            spin(0.3)
            d = c.drawing
            d.strokes.removeAll()
            c.drawing = d
            spin(0.3)
            let removed2 = inkIn(c, old)
            d = c.drawing
            d.strokes.append(moved)
            c.drawing = d
            spin(0.3)
            print("DIAG \(name) same drawing: removed=\(Int(removed2)) afterMove old=\(Int(inkIn(c, old))) new=\(Int(inkIn(c, new)))")
        }
    }
}
