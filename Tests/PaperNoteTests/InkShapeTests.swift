import XCTest
@testable import PaperNote

/// 回報的需求：自製筆刷也要停住變直線；矩形認寬鬆一點；還有直線、圓弧、圓、橢圓；大小跟著筆尖
final class InkShapeTests: XCTestCase {
    /// 手寫的晃動（固定的亂數，每次一樣）
    private func wobble(_ i: Int, _ amount: CGFloat = 2) -> CGFloat { sin(CGFloat(i) * 1.7) * amount }

    /// 圓角、有點歪的手畫矩形
    private func roughRectangle(_ r: CGRect, corner: CGFloat = 18) -> [CGPoint] {
        var pts: [CGPoint] = []
        // 沿著圓角矩形每 3pt 取一點
        let w = r.width, h = r.height, c = corner
        let perimeter = 2 * (w + h - 4 * c) + 2 * .pi * c
        let n = Int(perimeter / 3)
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n) * perimeter
            pts.append(roundedRectPoint(r, c, t))
        }
        return pts.enumerated().map { i, p in CGPoint(x: p.x + wobble(i), y: p.y + wobble(i + 3)) }
    }

    private func roundedRectPoint(_ r: CGRect, _ c: CGFloat, _ t: CGFloat) -> CGPoint {
        let top = r.width - 2 * c, side = r.height - 2 * c, arc = .pi / 2 * c
        var s = t
        let segs: [(CGFloat, (CGFloat) -> CGPoint)] = [
            (top, { CGPoint(x: r.minX + c + $0, y: r.minY) }),
            (arc, { a in let ang = -.pi / 2 + a / c; return CGPoint(x: r.maxX - c + cos(ang) * c, y: r.minY + c + sin(ang) * c) }),
            (side, { CGPoint(x: r.maxX, y: r.minY + c + $0) }),
            (arc, { a in let ang = a / c; return CGPoint(x: r.maxX - c + cos(ang) * c, y: r.maxY - c + sin(ang) * c) }),
            (top, { CGPoint(x: r.maxX - c - $0, y: r.maxY) }),
            (arc, { a in let ang = .pi / 2 + a / c; return CGPoint(x: r.minX + c + cos(ang) * c, y: r.maxY - c + sin(ang) * c) }),
            (side, { CGPoint(x: r.minX, y: r.maxY - c - $0) }),
            (arc, { a in let ang = .pi + a / c; return CGPoint(x: r.minX + c + cos(ang) * c, y: r.minY + c + sin(ang) * c) }),
        ]
        for (len, f) in segs {
            if s <= len { return f(s) }
            s -= len
        }
        return CGPoint(x: r.minX + c, y: r.minY)
    }

    private func ellipsePoints(_ r: CGRect, from a0: CGFloat = 0, to a1: CGFloat = 2 * .pi, n: Int = 120) -> [CGPoint] {
        (0...n).map { i in
            let a = a0 + (a1 - a0) * CGFloat(i) / CGFloat(n)
            return CGPoint(x: r.midX + cos(a) * r.width / 2 + wobble(i), y: r.midY + sin(a) * r.height / 2 + wobble(i + 5))
        }
    }

    private func line(_ a: CGPoint, _ b: CGPoint, n: Int = 60) -> [CGPoint] {
        (0...n).map { i in
            let t = CGFloat(i) / CGFloat(n)
            return CGPoint(x: a.x + (b.x - a.x) * t + wobble(i, 1.5), y: a.y + (b.y - a.y) * t + wobble(i + 2, 1.5))
        }
    }

    // MARK: 認圖形

    func testRoundedCornerRectangleIsARectangle() throws {
        let s = try XCTUnwrap(InkShapes.recognize(roughRectangle(CGRect(x: 100, y: 100, width: 220, height: 140))))
        XCTAssertEqual(s.kind, .rectangle, "手畫的角是圓的也要認成矩形")
    }

    func testVeryRoundedRectangleIsStillARectangle() throws {
        // 角很圓（圓角半徑是短邊的 1/4）
        let s = try XCTUnwrap(InkShapes.recognize(roughRectangle(CGRect(x: 0, y: 0, width: 240, height: 120), corner: 30)))
        XCTAssertEqual(s.kind, .rectangle, "矩形的識別範圍要寬鬆一點")
    }

    func testCircle() throws {
        let s = try XCTUnwrap(InkShapes.recognize(ellipsePoints(CGRect(x: 0, y: 0, width: 160, height: 150))))
        XCTAssertEqual(s.kind, .circle)
        let b = InkShapes.bounds(s.points)
        XCTAssertEqual(b.width, b.height, accuracy: 1, "圓要是正圓")
    }

    func testEllipse() throws {
        let s = try XCTUnwrap(InkShapes.recognize(ellipsePoints(CGRect(x: 0, y: 0, width: 240, height: 100))))
        XCTAssertEqual(s.kind, .ellipse)
    }

    func testTriangle() throws {
        let a = CGPoint(x: 100, y: 0), b = CGPoint(x: 200, y: 170), c = CGPoint(x: 0, y: 170)
        let s = try XCTUnwrap(InkShapes.recognize(line(a, b) + line(b, c) + line(c, a)))
        XCTAssertEqual(s.kind, .triangle)
    }

    func testWobblyLineIsAStraightLine() throws {
        let s = try XCTUnwrap(InkShapes.recognize(line(CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 80))))
        XCTAssertEqual(s.kind, .line)
        XCTAssertEqual(s.points.last!.x, 300, accuracy: 3)
    }

    func testArc() throws {
        // 半圓（開口朝下）
        let pts = ellipsePoints(CGRect(x: 0, y: 0, width: 200, height: 200), from: .pi, to: 2 * .pi)
        let s = try XCTUnwrap(InkShapes.recognize(pts))
        XCTAssertEqual(s.kind, .arc)
        // 弧的最高點在圓的頂端附近
        let top = s.points.map(\.y).min()!
        XCTAssertEqual(top, 0, accuracy: 5)
        XCTAssertEqual(s.points.first!.distance(to: pts.first!), 0, accuracy: 3)
        XCTAssertEqual(s.points.last!.distance(to: pts.last!), 0, accuracy: 3)
    }

    // MARK: 大小跟著筆尖

    func testLineEndFollowsThePen() throws {
        let s = try XCTUnwrap(InkShapes.recognize(line(CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 50))))
        let m = InkShapes.moved(s, to: CGPoint(x: 400, y: 220))
        XCTAssertEqual(m.points.last!.x, 400, accuracy: 0.5)
        XCTAssertEqual(m.points.last!.y, 220, accuracy: 0.5)
    }

    func testArcEndFollowsThePenAndKeepsItsCurve() throws {
        let s = try XCTUnwrap(InkShapes.recognize(ellipsePoints(CGRect(x: 0, y: 0, width: 200, height: 200), from: .pi, to: 2 * .pi)))
        let m = InkShapes.moved(s, to: CGPoint(x: 400, y: 100))
        XCTAssertEqual(m.points.last!.x, 400, accuracy: 0.5)
        let b = InkShapes.bounds(m.points)
        XCTAssertGreaterThan(b.height, 150, "拉長之後還是彎的")
    }

    func testRectangleGrowsWithThePen() throws {
        let s = try XCTUnwrap(InkShapes.recognize(roughRectangle(CGRect(x: 0, y: 0, width: 200, height: 100))))
        let before = InkShapes.bounds(s.points)
        // 往離固定角更遠的方向拉
        let m = InkShapes.moved(s, to: CGPoint(x: s.grab.x + (s.grab.x - s.anchor.x) * 0.5, y: s.grab.y + (s.grab.y - s.anchor.y) * 0.5))
        let after = InkShapes.bounds(m.points)
        XCTAssertGreaterThan(after.width, before.width + 50)
        XCTAssertGreaterThan(after.height, before.height + 20)
    }

    func testCircleStaysACircleWhenResized() throws {
        let s = try XCTUnwrap(InkShapes.recognize(ellipsePoints(CGRect(x: 0, y: 0, width: 150, height: 150))))
        let m = InkShapes.moved(s, to: CGPoint(x: s.grab.x + 120, y: s.grab.y + 10))
        let b = InkShapes.bounds(m.points)
        XCTAssertEqual(b.width, b.height, accuracy: 1, "圓放大之後還是圓")
        XCTAssertGreaterThan(b.width, 180)
    }
}

/// 自製筆刷寫一筆、停住、拖大、放開：存到頁面的是圖形
final class InkShapeFlowTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var customBefore = false
    private var snapBefore = true

    override func setUpWithError() throws {
        customBefore = EditorSettings.shared.customInk
        snapBefore = EditorSettings.shared.shapeSnap
        EditorSettings.shared.customInk = true
        EditorSettings.shared.shapeSnap = true
        let meta = LibraryStore.shared.createNotebook(title: "InkShapeFlow", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        editor.setTool(.pen)
    }

    override func tearDown() {
        EditorSettings.shared.customInk = customBefore
        EditorSettings.shared.shapeSnap = snapBefore
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    func testHoldTurnsTheStrokeIntoAShapeThatFollowsThePen() throws {
        let o = editor.contentOrigin(0)
        let corners = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 220), CGPoint(x: 100, y: 220), CGPoint(x: 100, y: 102)]
        var pts: [CGPoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            for i in 0..<40 {
                let t = CGFloat(i) / 40
                pts.append(CGPoint(x: o.x + a.x + (b.x - a.x) * t, y: o.y + a.y + (b.y - a.y) * t + sin(CGFloat(i)) * 1.5))
            }
        }
        editor.inkBegan(.init(point: pts[0], force: 0.5))
        editor.inkMoved(pts.dropFirst().map { .init(point: $0, force: 0.5) })
        // 停住 0.5 秒
        RunLoop.main.run(until: Date().addingTimeInterval(NotebookViewController.inkHoldDuration + 0.2))
        let shape = try XCTUnwrap(editor.inkDraft?.shape, "停住要變成圖形")
        XCTAssertEqual(shape.kind, .rectangle)
        // 筆不放開往外拉（離固定的角更遠）：圖形跟著變大
        let pen = CGPoint(x: shape.grab.x + (shape.grab.x - shape.anchor.x) * 0.4, y: shape.grab.y + (shape.grab.y - shape.anchor.y) * 0.4)
        editor.inkMoved([.init(point: pen, force: 0.5)])
        editor.inkEnded(cancelled: false)
        let saved = try XCTUnwrap(editor.pages[0].ink.last)
        let b = InkGeometry.bounds(of: saved)
        XCTAssertGreaterThan(b.width, 200 + 50, "存的是拉大之後的矩形")
        XCTAssertEqual(Set(saved.points.map(\.w)).count, 1, "圖形整條一樣粗")
    }

    func testNoShapeWhenTheSettingIsOff() {
        EditorSettings.shared.shapeSnap = false
        let o = editor.contentOrigin(0)
        let pts = (0..<60).map { CGPoint(x: o.x + 100 + CGFloat($0) * 4, y: o.y + 300) }
        editor.inkBegan(.init(point: pts[0], force: 0.5))
        editor.inkMoved(pts.dropFirst().map { .init(point: $0, force: 0.5) })
        RunLoop.main.run(until: Date().addingTimeInterval(NotebookViewController.inkHoldDuration + 0.2))
        XCTAssertNil(editor.inkDraft?.shape, "關掉「停住變直線／圖形」就不變")
        editor.inkEnded(cancelled: false)
    }
}
