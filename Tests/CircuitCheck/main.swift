// 在 macOS 上驗證電路圖的幾何邏輯（接腳、旋轉、接點、交叉、導線跟著元件移動）
import Foundation
import CoreGraphics

var failures = 0
func check(_ name: String, _ cond: Bool) {
    print((cond ? "PASS " : "FAIL ") + name)
    if !cond { failures += 1 }
}
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

// 1. 電阻接腳與旋轉
var r = CircuitComponent(part: .resistor, position: P(100, 100))
check("resistor pins", CircuitGeometry.pins(r) == [P(70, 100), P(130, 100)])
r.rotation = 90
check("resistor rotated 90", Set(CircuitGeometry.pins(r).map(PointKey.init)) == Set([P(100, 70), P(100, 130)].map(PointKey.init)))
r.rotation = 0
r.flipH = true
check("resistor flipH swaps pins", CircuitGeometry.pins(r) == [P(130, 100), P(70, 100)])

// 2. 三輸入 AND：輸入 y = -20, 0, 20
let g = CircuitComponent(part: .andGate, position: P(0, 0), inputs: 3)
let gp = CircuitGeometry.pins(g)
check("3-input AND has 4 pins", gp.count == 4)
check("AND inputs at -20,0,20", gp.prefix(3).map(\.y) == [-20, 0, 20] && gp.prefix(3).allSatisfy { $0.x == -30 })
check("AND output on the right", gp[3].y == 0 && gp[3].x >= 30)

// 3. T 字接點要有圓點
var t = CircuitData()
t.wires = [CircuitWire(points: [P(0, 0), P(100, 0)]), CircuitWire(points: [P(50, 0), P(50, 50)])]
check("T junction gets a dot", t.junctions().map(PointKey.init) == [PointKey(P(50, 0))])
check("T junction is not a crossing", t.crossings().isEmpty)

// 4. 單純交叉：沒有圓點，要畫跨線
var x = CircuitData()
x.wires = [CircuitWire(points: [P(0, 0), P(100, 0)]), CircuitWire(points: [P(50, -50), P(50, 50)])]
check("crossing has no dot", x.junctions().isEmpty)
check("crossing detected once at x=50", x.crossings().count == 1 && x.crossings()[0].at == 50)

// 5. 導線接到元件接腳：兩個連接，不畫圓點
var w = CircuitData()
w.components = [CircuitComponent(part: .resistor, position: P(100, 100))]
w.wires = [CircuitWire(points: [P(130, 100), P(200, 100)])]
check("wire to pin has no dot", w.junctions().isEmpty)
// 一個接腳接兩條線：三個連接，要有圓點
w.wires.append(CircuitWire(points: [P(130, 100), P(130, 200)]))
check("pin with two wires gets a dot", w.junctions().map(PointKey.init) == [PointKey(P(130, 100))])

// 6. 斜線改成直角
let o = CircuitData.orthogonalize([P(0, 0), P(50, 30)])
check("orthogonalize inserts a corner", o == [P(0, 0), P(50, 0), P(50, 30)])

// 7. 元件移動後，接在接腳上的導線跟著走、仍然是直角
var m = CircuitData()
m.components = [CircuitComponent(part: .resistor, position: P(100, 100))]
m.wires = [CircuitWire(points: [P(130, 100), P(200, 100)])]
let oldPins = CircuitGeometry.pins(m.components[0])
m.components[0].position = P(100, 150)
m.reattach(from: oldPins, to: CircuitGeometry.pins(m.components[0]))
let pts = m.wires[0].points
check("wire start follows pin", pts.first == P(130, 150))
check("wire end stays", pts.last == P(200, 100))
var allOrtho = true
for i in 0..<(pts.count - 1) where pts[i].x != pts[i + 1].x && pts[i].y != pts[i + 1].y { allOrtho = false }
check("wire stays orthogonal after move", allOrtho)

// 8. 外框
check("content bounds include wire", m.contentBounds.maxX >= 200)

// 9. 依筆跡走線
// 手抖的水平線 → 一段直線
let wobble = stride(from: 0, through: 100, by: 5).map { P(CGFloat($0), CGFloat($0 % 10 == 0 ? 2 : -2)) }
check("wobbly horizontal ink → straight wire", CircuitData.penRoute(wobble, from: P(0, 0), to: P(100, 0)) == [P(0, 0), P(100, 0)])
// 先垂直再水平（直接算 L 形會先走水平）
let vFirst = CircuitData.penRoute([P(0, 0), P(1, 40), P(-1, 80), P(50, 81), P(100, 79)], from: P(0, 0), to: P(100, 80))
check("ink going down first routes down first", vFirst == [P(0, 0), P(0, 80), P(100, 80)])
// 階梯：轉角落在筆跡轉彎的格點
let stairs = CircuitData.penRoute([P(0, 0), P(52, 2), P(48, 61), P(120, 60)], from: P(0, 0), to: P(120, 60))
check("staircase ink keeps its corners", stairs == [P(0, 0), P(50, 0), P(50, 60), P(120, 60)])
// 短短的抖動段不會變成轉角
let jitter = CircuitData.penRoute([P(0, 0), P(60, 0), P(62, 6), P(120, 4)], from: P(0, 0), to: P(120, 0))
check("tiny jitter is ignored", jitter == [P(0, 0), P(120, 0)])
// 終點和筆跡一直線但不同高：最後補一小段
let jog = CircuitData.penRoute([P(0, 0), P(100, 3)], from: P(0, 0), to: P(100, 20))
check("end pin off the line gets a jog", jog == [P(0, 0), P(100, 0), P(100, 20)])

// 10. 編輯導線
check("drag a two-point wire's segment adds stubs",
      CircuitData.moveSegment([P(0, 0), P(100, 0)], index: 0, by: 30) == [P(0, 0), P(0, 30), P(100, 30), P(100, 0)])
check("drag a middle segment stretches neighbours",
      CircuitData.moveSegment([P(0, 0), P(50, 0), P(50, 60), P(120, 60)], index: 1, by: 20) == [P(0, 0), P(70, 0), P(70, 60), P(120, 60)])
check("drag a corner",
      CircuitData.moveCorner([P(0, 0), P(50, 0), P(50, 60)], index: 1, by: P(20, 10)) == [P(0, 0), P(0, 10), P(70, 10), P(70, 60), P(50, 60)])
check("drag an end keeps the wire orthogonal",
      CircuitData.movingEnd([P(0, 0), P(50, 0), P(50, 60)], first: true, to: P(0, 20)) == [P(0, 20), P(50, 20), P(50, 60)])
check("drag a segment back to zero is a no-op",
      CircuitData.moveSegment([P(0, 0), P(50, 0), P(50, 60)], index: 0, by: 0) == [P(0, 0), P(50, 0), P(50, 60)])

// 11. 吸到格點：偏掉 3pt 的電路整個對齊，導線仍接在接腳上
var off = CircuitData()
off.components = [CircuitComponent(part: .andGate, position: P(103, 97), inputs: 2)]
let offPins = CircuitGeometry.pins(off.components[0])
off.wires = [CircuitWire(points: [offPins[0], P(offPins[0].x - 40, offPins[0].y)])]
off.snapToGrid()
let snappedPins = CircuitGeometry.pins(off.components[0])
check("component snapped to grid", off.components[0].position == P(100, 100))
check("wire still on pin after snapping", off.wires[0].points.first == snappedPins[0])

// 12. 從導線中間接出去
var mid = CircuitData()
mid.wires = [CircuitWire(points: [P(0, 100), P(300, 100)])]
check("snap onto middle of a horizontal wire", mid.snapTarget(for: P(143, 108), within: 12) == P(140, 100))
check("far from the wire falls back to grid", mid.snapTarget(for: P(143, 130), within: 12) == P(140, 130))
check("snap clamps to the wire's end", mid.snapTarget(for: P(306, 104), within: 12) == P(300, 100))
var vmid = CircuitData()
vmid.wires = [CircuitWire(points: [P(50, 0), P(50, 200)])]
check("snap onto middle of a vertical wire", vmid.snapTarget(for: P(45, 77), within: 12) == P(50, 80))
// 從中間拉下去再往右：起點落在線上，會出現接點圓點
let s0 = mid.snapTarget(for: P(142, 104), within: 12)
mid.wires.append(CircuitWire(points: CircuitData.penRoute([s0, P(141, 150), P(140, 200), P(250, 201)], from: s0, to: P(250, 200))))
check("branch wire starts on the line", mid.wires[1].points == [P(140, 100), P(140, 200), P(250, 200)])
check("branch from mid-wire gets a dot", mid.junctions().map(PointKey.init) == [PointKey(P(140, 100))])
check("branch from mid-wire is not a crossing", mid.crossings().isEmpty)

// 13. 手繪 VDD／接地：線尾左右畫一小橫
let downThenBar = stride(from: 0, through: 60, by: 4).map { P(100, CGFloat($0)) } + [P(88, 61), P(112, 60), P(100, 60)]
let gnd = CircuitData.terminalGesture(downThenBar)
check("down + bar is ground", gnd?.part == .ground)
check("ground corner at the bar", gnd.map { abs($0.corner.y - 60) < 3 && abs($0.corner.x - 100) < 3 } == true)
let upThenBar = stride(from: 0, through: 60, by: 4).map { P(100, CGFloat(100 - $0)) } + [P(112, 39), P(88, 40), P(100, 40)]
check("up + bar is VDD", CircuitData.terminalGesture(upThenBar)?.part == .vdd)
// 一般往下再往右的 L 形導線不是符號
let lShape = stride(from: 0, through: 60, by: 4).map { P(100, CGFloat($0)) } + [P(130, 60), P(160, 60)]
check("L-shaped wire is not a terminal", CircuitData.terminalGesture(lShape) == nil)
check("straight wire is not a terminal", CircuitData.terminalGesture(stride(from: 0, through: 80, by: 4).map { P(100, CGFloat($0)) }) == nil)

// 14. 拖動元件：接在導線中段的分支（T 字接點）也要跟著接上
var tee = CircuitData()
tee.components = [CircuitComponent(part: .resistor, position: P(100, 100))]
tee.wires = [CircuitWire(points: [P(130, 100), P(200, 100), P(200, 200)]),
             CircuitWire(points: [P(160, 100), P(160, 50)])]
let teeOld = CircuitGeometry.pins(tee.components[0])
tee.components[0].position = P(100, 150)
tee.reattach(from: teeOld, to: CircuitGeometry.pins(tee.components[0]))
check("attached wire follows the pin", tee.wires[0].points.first == P(130, 150))
check("T branch re-attaches to the moved wire", tee.wires.count == 2 && tee.wires[1].points.first == P(160, 150))
check("T branch is still a junction", tee.junctions().map(PointKey.init).contains(PointKey(P(160, 150))))

// 15. 導線從接腳中間經過不算接上：拖動元件時那條線留在原地
var through = CircuitData()
through.components = [CircuitComponent(part: .resistor, position: P(100, 100))]
through.wires = [CircuitWire(points: [P(130, 50), P(130, 150)])]
let thOld = CircuitGeometry.pins(through.components[0])
through.components[0].position = P(120, 100)
through.reattach(from: thOld, to: CircuitGeometry.pins(through.components[0]))
check("wire through a pin is not split", through.wires.count == 1)
check("wire through a pin stays put", through.wires[0].points == [P(130, 50), P(130, 150)])

// 16. 方塊元件：接腳數量、名字、都在格點上、都在外框裡
func onGrid(_ p: CGPoint) -> Bool { p.x.truncatingRemainder(dividingBy: 10) == 0 && p.y.truncatingRemainder(dividingBy: 10) == 0 }
let mux4 = CircuitComponent(part: .mux, position: P(200, 200), inputs: 4)
check("4-input MUX has 4 inputs + 2 selects + 1 output", CircuitGeometry.pins(mux4).count == 7)
check("MUX pin names", CircuitGeometry.pinNames(mux4) == ["I0", "I1", "I2", "I3", "S0", "S1", "Y"])
let dec3 = CircuitComponent(part: .decoder, position: P(0, 0), inputs: 3)
check("3-bit decoder has 3 inputs and 8 outputs", CircuitGeometry.pins(dec3).count == 11)
let enc2 = CircuitComponent(part: .encoder, position: P(0, 0), inputs: 2)
check("2-bit encoder has 4 inputs and 2 outputs", CircuitGeometry.pinNames(enc2) == ["I0", "I1", "I2", "I3", "Y0", "Y1"])
let dff = CircuitComponent(part: .dFlipFlop, position: P(0, 0))
check("D flip-flop pins", CircuitGeometry.pinNames(dff) == ["D", "CLK", "Q", "~Q"])
var allBlocksOK = true
for part in [CircuitPart.dFlipFlop, .dLatch, .mux, .decoder, .encoder] {
    for n in part.sizeRange {
        for rot in [0, 90, 180, 270] {
            let c = CircuitComponent(part: part, position: P(100, 100), rotation: rot, inputs: n)
            let b = CircuitGeometry.bounds(c).insetBy(dx: -0.5, dy: -0.5)
            for p in CircuitGeometry.pins(c) where !onGrid(p) || !b.contains(p) { allBlocksOK = false }
        }
    }
}
check("block pins on grid and inside bounds for every size and rotation", allBlocksOK)
check("gate pin names keep I/Y", CircuitGeometry.pinNames(CircuitComponent(part: .andGate, position: .zero, inputs: 3)) == ["I0", "I1", "I2", "Y"])

// 17. 線從中間經過不算接上（NAND：B 輸入橫線經過 PMOS 源極接腳，那裡往下接了一條輸出線）
var nand = CircuitData()
nand.components = [CircuitComponent(part: .pmos, position: P(100, 100))]
let src = CircuitGeometry.pins(nand.components[0])[2]
check("PMOS source pin at (110, 130)", src == P(110, 130))
nand.wires = [CircuitWire(points: [src, P(110, 200)]),
              CircuitWire(points: [P(0, 130), P(200, 130)])]
check("wire passing through a pin with a wire on it gets no dot", nand.junctions().isEmpty)
check("wire passing through a pin hops over it", nand.crossings().count == 1 && nand.crossings()[0].wire == 1 && nand.crossings()[0].at == 110)
// 接腳上接兩條往不同方向的線：分岔，要有圓點
var pin2 = CircuitData()
pin2.components = nand.components
pin2.wires = [CircuitWire(points: [src, P(110, 200)]), CircuitWire(points: [src, P(160, 130)])]
check("pin branching two ways gets a dot", pin2.junctions().map(PointKey.init) == [PointKey(src)])

// 兩條線的線頭停在另一條線中間（剛好接成一直線也一樣）：線頭停下來就是接上，要打點、不畫跨線
var twoStrokes = CircuitData()
twoStrokes.wires = [CircuitWire(points: [P(50, 0), P(50, 100)]), CircuitWire(points: [P(50, 100), P(50, 200)]),
                    CircuitWire(points: [P(0, 100), P(100, 100)])]
check("two wire ends on the middle of a wire get a dot", twoStrokes.junctions().map(PointKey.init) == [PointKey(P(50, 100))])
check("two wire ends on the middle of a wire do not hop", twoStrokes.crossings().isEmpty)
var twoH = CircuitData()
twoH.wires = [CircuitWire(points: [P(0, 100), P(50, 100)]), CircuitWire(points: [P(50, 100), P(100, 100)]),
              CircuitWire(points: [P(50, 0), P(50, 200)])]
check("horizontal wire ends on a vertical wire get a dot", twoH.junctions().map(PointKey.init) == [PointKey(P(50, 100))])
check("horizontal wire ends on a vertical wire do not hop", twoH.crossings().isEmpty)
// 三條線的頭尾在同一點：真的接在一起
var bend = CircuitData()
bend.wires = [CircuitWire(points: [P(50, 0), P(50, 100)]), CircuitWire(points: [P(50, 100), P(50, 150), P(100, 150)]),
              CircuitWire(points: [P(50, 100), P(120, 100)])]
check("three wire ends at one point still get a dot", bend.junctions().map(PointKey.init) == [PointKey(P(50, 100))])

// 18. 圓點打在分岔的地方，不是線頭：從線中間接出去、沿著線走一段再轉彎
var along = CircuitData()
along.wires = [CircuitWire(points: [P(0, 100), P(200, 100)]),
               CircuitWire(points: [P(50, 100), P(120, 100), P(120, 200)])]
check("dot where the overlapping wire turns away", along.junctions().map(PointKey.init) == [PointKey(P(120, 100))])
check("overlapping wire is not a crossing", along.crossings().isEmpty)
// 從接腳拉兩條線，先重疊一段再分開
var fork = CircuitData()
fork.components = [CircuitComponent(part: .resistor, position: P(100, 100))]
fork.wires = [CircuitWire(points: [P(130, 100), P(300, 100)]),
              CircuitWire(points: [P(130, 100), P(200, 100), P(200, 200)])]
check("no dot on the pin when both wires leave the same way", !fork.junctions().map(PointKey.init).contains(PointKey(P(130, 100))))
check("dot where the two wires split", fork.junctions().map(PointKey.init) == [PointKey(P(200, 100))])
// 兩條線頭成直角接在一起（L 形）：只有兩個方向，不是分岔
var ell = CircuitData()
ell.wires = [CircuitWire(points: [P(0, 0), P(50, 0)]), CircuitWire(points: [P(50, 0), P(50, 50)])]
check("L corner from two wires has no dot", ell.junctions().isEmpty)
// 引腳方向
let pm = CircuitComponent(part: .pmos, position: P(100, 100))
check("PMOS leads point into the part", CircuitGeometry.pinLeads(pm) == [P(1, 0), P(0, 1), P(0, -1)])
var pmR = pm
pmR.rotation = 90
check("rotated PMOS leads rotate too", CircuitGeometry.pinLeads(pmR) == [P(0, 1), P(-1, 0), P(1, 0)])

// 19. 一直線分兩筆畫（那點沒有別的線）：存檔時接成一條
var freeTwo = CircuitData()
freeTwo.wires = [CircuitWire(points: [P(0, 100), P(50, 100)]), CircuitWire(points: [P(50, 100), P(100, 100)])]
var freeJoined = freeTwo
freeJoined.joinStraightRuns()
check("two strokes in a straight line become one wire", freeJoined.wires.count == 1 && freeJoined.wires[0].points == [P(0, 100), P(100, 100)])
var joinKeep = freeTwo
joinKeep.joinStraightRuns(keeping: freeTwo.wires[1].id)
check("joined wire keeps the selected wire's id", joinKeep.wires[0].id == freeTwo.wires[1].id)
var twoHJoined = twoH
twoHJoined.joinStraightRuns()
check("ends meeting on another wire are not joined", twoHJoined.wires.count == 3 && twoHJoined.crossings().isEmpty)
var towardEachOther = CircuitData()
towardEachOther.wires = [CircuitWire(points: [P(50, 0), P(50, 100)]), CircuitWire(points: [P(50, 200), P(50, 100)])]
towardEachOther.joinStraightRuns()
check("strokes drawn toward each other join too", towardEachOther.wires.count == 1 && towardEachOther.wires[0].points == [P(50, 0), P(50, 200)])
var bendJoin = bend
bendJoin.joinStraightRuns()
check("three wire ends at one point are not joined", bendJoin.wires.count == 3)
var ellJoin = ell
ellJoin.joinStraightRuns()
check("an L corner from two wires is not joined", ellJoin.wires.count == 2)
// 接腳上剛好接成一直線的兩條線不接（接腳也是接點）
var atPin = CircuitData()
atPin.components = [CircuitComponent(part: .resistor, position: P(100, 100))]
let pinPoint = CircuitGeometry.pins(atPin.components[0])[1]
atPin.wires = [CircuitWire(points: [P(pinPoint.x, pinPoint.y - 50), pinPoint]), CircuitWire(points: [pinPoint, P(pinPoint.x, pinPoint.y + 50)])]
atPin.joinStraightRuns()
check("wires meeting on a pin are not joined", atPin.wires.count == 2)

// 20. 回報：直線接在橫線中間（T 字接點、有打點），再從同一點往下接一段直線，存檔時兩段直線被接成一條，
// 接點變成跨線（沒接上）。端點在別條線的線段中間也是接點，不能接
var teeJoin = CircuitData()
teeJoin.wires = [CircuitWire(points: [P(0, 100), P(200, 100)]),
                 CircuitWire(points: [P(50, 0), P(50, 100)]),
                 CircuitWire(points: [P(50, 100), P(50, 200)])]
check("before saving, the meeting point on the horizontal wire has a dot", teeJoin.junctions().map(PointKey.init) == [PointKey(P(50, 100))])
teeJoin.joinStraightRuns()
check("wires meeting in the middle of another wire are not joined", teeJoin.wires.count == 3)
check("the meeting point still has a dot, not a hop", teeJoin.junctions().map(PointKey.init) == [PointKey(P(50, 100))] && teeJoin.crossings().isEmpty)

// 21. 導線名稱：預設放在最近那段旁邊（橫的上面、直的右邊）；接成一條時名稱留著；外框包含名稱
let ell2 = [P(0, 100), P(100, 100), P(100, 200)]
let abovePos = CircuitWire.defaultLabelPosition(on: ell2, near: P(40, 104))
check("label on a horizontal run sits above it", abovePos.x == 40 && abovePos.y < 100)
let besidePos = CircuitWire.defaultLabelPosition(on: ell2, near: P(97, 160))
check("label on a vertical run sits to its right", besidePos.y == 160 && besidePos.x > 100)
var named = freeTwo
named.wires[1].label = "Vout"
named.wires[1].labelPosition = P(75, 85)
named.joinStraightRuns()
check("joining wires keeps the name", named.wires.count == 1 && named.wires[0].label == "Vout" && named.wires[0].labelPosition == P(75, 85))
var far = CircuitData()
far.wires = [CircuitWire(points: [P(0, 100), P(100, 100)], label: "CLK", labelPosition: P(50, 300))]
check("content bounds include the name", far.contentBounds.maxY > 300)
far.offset(by: P(10, -20))
check("moving the circuit moves the name", far.wires[0].labelPosition == P(60, 280))

// 22. 名稱的字級：外框跟著變大
var sized = CircuitWire(points: [P(0, 100), P(100, 100)], label: "Vo", labelPosition: P(50, 80))
let normalBox = sized.labelBounds!
sized.labelSize = 32
check("a bigger name has a bigger box around the same center", sized.labelBounds!.width == normalBox.width * 2 && sized.labelBounds!.midX == normalBox.midX && sized.labelBounds!.midY == normalBox.midY)

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
