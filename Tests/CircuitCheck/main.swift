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
check("crossing detected once at x=50", x.crossings().count == 1 && x.crossings()[0].x == 50)

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

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
