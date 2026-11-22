import XCTest
@testable import PaperNote

/// 回報的需求：
/// - 元件的接腳放在導線上要接上（共點），不是跨線
/// - 除了 SVG，也要能匯出網表（netlist）這種方便 AI 看的格式
final class CircuitNetlistTests: XCTestCase {
    /// 一條橫線 (0,100)…(200,100)，直的電阻放在線下面，上面的接腳剛好在線中間 (100,100)
    private func wireAndResistor() -> (CircuitData, [CGPoint]) {
        var d = CircuitData()
        d.wires = [CircuitWire(points: [CGPoint(x: 0, y: 100), CGPoint(x: 200, y: 100)])]
        var r = CircuitComponent(part: .resistor, position: CGPoint(x: 100, y: 130))
        r.rotation = 90
        d.components = [r]
        let pins = CircuitGeometry.pins(r)
        XCTAssertTrue(pins.contains(CGPoint(x: 100, y: 100)), "測試前提：接腳在線上 \(pins)")
        return (d, pins)
    }

    func testAPinOnAWireSplitsItAndConnects() {
        var (d, pins) = wireAndResistor()
        XCTAssertEqual(d.crossings().count, 1, "只是經過：跨線")
        XCTAssertNotEqual(d.nets().pins[pins.firstIndex(of: CGPoint(x: 100, y: 100))!], d.nets().wires[0], "沒有接上")
        d.connectPins(pins)
        XCTAssertEqual(d.wires.map(\.points), [[CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100)],
                                               [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)]], "在接腳那裡切成兩條")
        XCTAssertTrue(d.crossings().isEmpty, "不是跨線")
        XCTAssertEqual(d.junctions(), [CGPoint(x: 100, y: 100)], "分岔的地方有圓點")
        let nets = d.nets()
        let top = pins.firstIndex(of: CGPoint(x: 100, y: 100))!
        XCTAssertEqual(nets.wires[0], nets.wires[1])
        XCTAssertEqual(nets.pins[top], nets.wires[0], "接上了")
        // 整理之後也不會接回一條（那裡有接腳）
        d.joinStraightRuns()
        XCTAssertEqual(d.wires.count, 2)
    }

    func testAWireThatAlreadyPassedThroughThePinIsLeftAsACrossing() {
        // 例如 NAND 裡跨過 PMOS 接腳的輸入線：元件旋轉、移動時，原本就經過的線不切
        var (d, pins) = wireAndResistor()
        let before = pins.map(d.wiresThrough)
        d.connectPins(pins, before: before)
        XCTAssertEqual(d.wires.count, 1)
        XCTAssertEqual(d.crossings().count, 1)
        // 一起放上來的線也不切
        d.connectPins(pins, ignoring: [d.wires[0].id])
        XCTAssertEqual(d.wires.count, 1)
    }

    func testTheWireNameStaysOnOneHalf() {
        var (d, pins) = wireAndResistor()
        d.wires[0].label = "VIN"
        d.wires[0].labelPosition = CGPoint(x: 40, y: 90)
        d.connectPins(pins)
        XCTAssertEqual(d.wires.compactMap(\.label), ["VIN"])
    }

    // MARK: 接腳直接碰在一起

    /// 回報的需求：兩個元件的接腳接在一起，要當成中間有一條長度 0 的導線，拉開時才會拉出線（拉伸）
    private func touchingResistors() -> CircuitData {
        var d = CircuitData()
        d.components = [CircuitComponent(part: .resistor, position: CGPoint(x: 100, y: 100)),
                        CircuitComponent(part: .resistor, position: CGPoint(x: 160, y: 100))]
        XCTAssertEqual(CircuitGeometry.pins(d.components[0])[1], CircuitGeometry.pins(d.components[1])[0], "測試前提：接腳碰在一起")
        return d
    }

    func testPinsTouchingEachOtherStretchIntoAWireWhenMoved() {
        var d = touchingResistors()
        let n0 = d.nets()
        XCTAssertEqual(n0.pins[1], n0.pins[2], "碰在一起就是接上")
        let moving = d.components[1].id
        d.moveItems([moving], by: CGPoint(x: 0, y: 40))
        XCTAssertEqual(d.wires.map(\.points), [[CGPoint(x: 130, y: 100), CGPoint(x: 130, y: 140)]], "拉出一條線")
        let n = d.nets()
        XCTAssertEqual(n.pins[1], n.pins[2], "還是接在一起")
        XCTAssertNotEqual(n.pins[0], n.pins[3])
    }

    func testRotatingAPartKeepsItsTouchingNeighbour() {
        var d = touchingResistors()
        d.transformItems([d.components[1].id], .rotate)
        let n = d.nets()
        XCTAssertEqual(n.pins[1], n.pins[2], "轉了也還接著")
        XCTAssertEqual(d.wires.count, 1)
    }

    func testMovingBothTogetherAddsNoWire() {
        var d = touchingResistors()
        d.moveItems(Set(d.components.map(\.id)), by: CGPoint(x: 0, y: 40))
        XCTAssertTrue(d.wires.isEmpty, "一起動：還是碰在一起，不用拉線")
        d.stretchTouchingPins(from: [CGPoint(x: 130, y: 140)], to: [CGPoint(x: 130, y: 140)], moving: [d.components[1].id])
        XCTAssertTrue(d.wires.isEmpty, "沒動就是長度 0")
    }

    // MARK: 網表

    func testNetlistListsEveryComponentWithItsNodes() {
        var d = CircuitData()
        // 電源 (70,100)+ (130,100)-；電阻 (190,100)…(250,100)；電阻右邊接地；電源和電阻中間的線叫 VOUT
        let v = CircuitComponent(part: .voltageSource, position: CGPoint(x: 100, y: 100))
        let r = CircuitComponent(part: .resistor, position: CGPoint(x: 220, y: 100))
        let g = CircuitComponent(part: .ground, position: CGPoint(x: 250, y: 120))
        var m = CircuitComponent(part: .nmos, position: CGPoint(x: 400, y: 100))
        m.name = "M_{in}"
        d.components = [v, r, g, m]
        XCTAssertEqual(CircuitGeometry.pins(g), [CGPoint(x: 250, y: 100)], "測試前提：接地接在電阻右邊")
        var out = CircuitWire(points: [CGPoint(x: 130, y: 100), CGPoint(x: 190, y: 100)])
        out.label = "V_{OUT}"
        // NMOS 的汲極接到 VOUT
        let drain = CircuitGeometry.pins(m)[1]
        let toDrain = CircuitWire(points: [CGPoint(x: 160, y: 100), CGPoint(x: 160, y: drain.y), drain])
        d.wires = [out, toDrain]
        let text = d.netlist()
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("V1 voltageSource +=N1 -=VOUT"), text)
        XCTAssertTrue(lines.contains("R1 resistor 1=VOUT 2=0"), "接地是節點 0：\(text)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("Min nmos G=") && $0.contains(" D=VOUT ") }, "有名字的照名字（下標記號拿掉）：\(text)")
        XCTAssertFalse(lines.contains { !$0.hasPrefix("*") && $0.contains(" ground") }, "接地符號不是元件（說明那行的 ground 不算）")
        XCTAssertTrue(lines.contains("* VOUT: V1.-, R1.1, Min.D"), "每個節點接到哪些接腳：\(text)")
        XCTAssertEqual(lines.last, ".end")
    }

    func testNetlistPinNamesAreTheUsualOnes() {
        func names(_ p: CircuitPart, inputs: Int = 2) -> [String] {
            var c = CircuitComponent(part: p, position: .zero)
            c.inputs = inputs
            return CircuitData.netlistPinNames(c)
        }
        XCTAssertEqual(names(.nmos), ["G", "D", "S"])
        XCTAssertEqual(names(.pmos4), ["G", "D", "S", "B"])
        XCTAssertEqual(names(.npn), ["B", "C", "E"])
        XCTAssertEqual(names(.diode), ["A", "K"])
        XCTAssertEqual(names(.opAmp), ["IN-", "IN+", "OUT"])
        XCTAssertEqual(names(.capacitor), ["1", "2"])
        XCTAssertEqual(names(.nandGate, inputs: 3), ["I0", "I1", "I2", "Y"])
        // 每種元件的名稱數量都和接腳一樣
        for p in CircuitPart.builtIn {
            var c = CircuitComponent(part: p, position: .zero)
            c.inputs = p.defaultSize
            XCTAssertEqual(CircuitData.netlistPinNames(c).count, CircuitGeometry.pins(c).count, "\(p)")
        }
    }

    func testAPinThatAWireOnlyPassesThroughIsItsOwnNode() {
        let (d, pins) = wireAndResistor()
        let text = d.netlist()
        let top = pins.firstIndex(of: CGPoint(x: 100, y: 100))!
        XCTAssertNotEqual(d.nets().pins[top], d.nets().wires[0])
        XCTAssertTrue(text.contains("R1 resistor"), text)
    }
}
