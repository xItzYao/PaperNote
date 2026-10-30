import XCTest
@testable import PaperNote

/// 回報的問題：
/// - 電路符號太大：新的電路圖符號、線寬縮小（原本的一半再放大 25%；舊的電路圖維持原本大小）
/// - 橫線分兩筆畫、接在直線上，跨線半圓跑到直線上：存檔時兩筆接成一條
final class CircuitScaleTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "CircuitScale", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        editor.setTool(.circuit)
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private func circuits() -> [(element: PageElement, data: CircuitData)] {
        editor.pages[0].elements.compactMap { e in
            if case let .circuit(d) = e.content { return (e, d) }
            return nil
        }
    }

    func testNewCircuitIsHalfSize() throws {
        let o = editor.contentOrigin(0)
        let tap = CGPoint(x: o.x + 200, y: o.y + 300)
        editor.placeComponent(.resistor, at: tap)
        let c = try XCTUnwrap(circuits().first)
        XCTAssertEqual(c.data.symbolScale, CircuitData.newScale, "新的電路圖用新的縮放")
        // 外框：內容 + 邊界，乘上縮放
        let b = c.data.contentBounds
        XCTAssertEqual(c.element.frame.width, (b.maxX + CircuitData.margin) * CircuitData.newScale, accuracy: 0.01)
        XCTAssertEqual(c.element.frame.height, (b.maxY + CircuitData.margin) * CircuitData.newScale, accuracy: 0.01)
        // 元件放在點的位置；兩支接腳在頁面上的距離乘上縮放
        let ref = try XCTUnwrap(editor.circuitTarget)
        let comp = c.data.components[0]
        let center = editor.circuitDoc(comp.position, ref)
        XCTAssertEqual(center.x, tap.x, accuracy: 5)
        XCTAssertEqual(center.y, tap.y, accuracy: 5)
        let pins = CircuitGeometry.pins(comp).map { editor.circuitDoc($0, ref) }
        XCTAssertEqual(pins[0].distance(to: pins[1]), CircuitGeometry.pins(comp)[0].distance(to: CircuitGeometry.pins(comp)[1]) * CircuitData.newScale, accuracy: 0.01)
        // 文件座標和內容座標來回換算一致
        let back = editor.circuitLocal(pins[1], ref)
        XCTAssertEqual(back.x, CircuitGeometry.pins(comp)[1].x, accuracy: 0.001)
        XCTAssertEqual(back.y, CircuitGeometry.pins(comp)[1].y, accuracy: 0.001)

        // 再點旁邊放第二個：放進同一個電路圖，位置也是點到的地方
        let tap2 = CGPoint(x: tap.x + 40, y: tap.y + 30)
        editor.placeComponent(.capacitor, at: tap2)
        XCTAssertEqual(circuits().count, 1)
        let c2 = try XCTUnwrap(circuits().first?.data.components.last)
        let ref2 = try XCTUnwrap(editor.circuitTarget)
        let p2 = editor.circuitDoc(c2.position, ref2)
        XCTAssertEqual(p2.x, tap2.x, accuracy: 5)
        XCTAssertEqual(p2.y, tap2.y, accuracy: 5)
    }

    func testOldCircuitKeepsItsSize() throws {
        var d = CircuitData()
        d.components = [CircuitComponent(part: .resistor, position: CGPoint(x: 60, y: 60))]
        let o = editor.contentOrigin(0)
        let ref = try XCTUnwrap(editor.insertElement(.circuit(d), size: CGSize(width: 140, height: 120), at: CGPoint(x: o.x + 200, y: o.y + 200)))
        // 在舊的電路圖上加元件：還是原本大小、沒有縮放
        let tap = editor.circuitDoc(CGPoint(x: 120, y: 60), ref)
        editor.placeComponent(.capacitor, at: tap)
        let c = try XCTUnwrap(circuits().first)
        XCTAssertEqual(circuits().count, 1)
        XCTAssertNil(c.data.symbolScale, "舊的電路圖不改大小")
        XCTAssertEqual(c.data.components.count, 2)
        XCTAssertEqual(c.element.frame.width, c.data.contentBounds.maxX + CircuitData.margin, accuracy: 0.01)
        let p = editor.circuitDoc(c.data.components[1].position, ref)
        XCTAssertEqual(p.x, tap.x, accuracy: 0.01)
    }

    func testHalfSizeCircuitDrawsInsideItsFrame() throws {
        let o = editor.contentOrigin(0)
        editor.placeComponent(.resistor, at: CGPoint(x: o.x + 200, y: o.y + 300))
        let c = try XCTUnwrap(circuits().first)
        let size = c.element.frame.size
        let image = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { _ in
            CircuitRenderer.draw(c.data, in: CGRect(origin: .zero, size: size))
        }
        // 畫出來的最右邊：內容的右緣 × 縮放（沒有縮放的話會被外框切掉）
        let cg = try XCTUnwrap(image.cgImage)
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var maxX = -1
        for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 40 { maxX = max(maxX, x) } }
        XCTAssertGreaterThan(CGFloat(maxX), size.width / 2, "有畫出來")
        XCTAssertLessThan(CGFloat(maxX), size.width - 4, "符號縮放後畫在外框裡，右邊留有邊界，沒有被切掉")
    }

    func testStraightLineDrawnInTwoStrokesIsJoinedOnSave() throws {
        var d = CircuitData()
        d.wires = [CircuitWire(points: [CGPoint(x: 30, y: 130), CGPoint(x: 80, y: 130)]),
                   CircuitWire(points: [CGPoint(x: 80, y: 130), CGPoint(x: 130, y: 130)])]
        let e = editor.normalizedCircuit(PageElement(frame: CGRect(x: 100, y: 100, width: 200, height: 300), content: .circuit(d)))
        guard case let .circuit(out) = e.content else { return XCTFail() }
        XCTAssertEqual(out.wires.count, 1, "一直線的兩筆接成一條")
    }

    /// 回報：直線接在橫線中間（有打點），再從那個點往下接一段，存檔後兩段被接成一條，打點變成跨線
    func testWireContinuedFromAJunctionKeepsTheDotOnSave() throws {
        var d = CircuitData()
        d.wires = [CircuitWire(points: [CGPoint(x: 0, y: 130), CGPoint(x: 160, y: 130)]),
                   CircuitWire(points: [CGPoint(x: 80, y: 30), CGPoint(x: 80, y: 130)]),
                   CircuitWire(points: [CGPoint(x: 80, y: 130), CGPoint(x: 80, y: 230)])]
        let e = editor.normalizedCircuit(PageElement(frame: CGRect(x: 100, y: 100, width: 200, height: 300), content: .circuit(d)))
        guard case let .circuit(out) = e.content else { return XCTFail() }
        XCTAssertEqual(out.wires.count, 3, "接在別條線上的兩段不接成一條")
        XCTAssertEqual(out.junctions().count, 1, "還是打點")
        XCTAssertTrue(out.crossings().isEmpty, "沒有跨線")
    }
}
