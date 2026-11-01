import XCTest
import PencilKit
@testable import PaperNote

/// 回報的需求：
/// - 手指可以拖元件
/// - 選取中的元件再點一下改名（不限選取工具）；R_1 自動變下標
/// - 群組、解散群組；自訂電路圖，拉出來就是群組
/// - 套索圈到一部分就選到電路圖，不想被圈到就上鎖
/// - PMOS 預設上下鏡像
/// - 整筆擦除虛線整條刪掉
/// - 預覽模式把工具列收起來
final class CircuitGroupTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var ref: ElementRef!
    private var left: UUID!
    private var right: UUID!
    private var bridge: UUID!
    private var outside: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "CircuitGroup", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // 兩個電阻、中間一條線；右邊的電阻再接一條往外的線
        var d = CircuitData()
        let a = CircuitComponent(part: .resistor, position: CGPoint(x: 100, y: 100))
        let b = CircuitComponent(part: .resistor, position: CGPoint(x: 220, y: 100))
        let w = CircuitWire(points: [CGPoint(x: 130, y: 100), CGPoint(x: 190, y: 100)])
        let o = CircuitWire(points: [CGPoint(x: 250, y: 100), CGPoint(x: 330, y: 100), CGPoint(x: 330, y: 160)])
        d.components = [a, b]
        d.wires = [w, o]
        left = a.id
        right = b.id
        bridge = w.id
        outside = o.id
        let page = editor.contentOrigin(0)
        ref = try XCTUnwrap(editor.insertElement(.circuit(d), size: CGSize(width: 360, height: 220), at: CGPoint(x: page.x + 280, y: page.y + 300)))
        editor.setTool(.circuit)
        editor.selectCircuitMode(.select)
        editor.circuitTarget = ref
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    override func tearDown() {
        for c in CustomCircuitStore.shared.circuits { CustomCircuitStore.shared.remove(c.id) }
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private var data: CircuitData { editor.circuitInfo(ref)?.data ?? CircuitData() }
    private func part(_ id: UUID) -> CircuitComponent? { data.components.first { $0.id == id } }
    private func wire(_ id: UUID) -> CircuitWire? { data.wires.first { $0.id == id } }
    /// 元件中心的文件座標
    private func at(_ id: UUID) -> CGPoint { editor.circuitDoc(part(id)?.position ?? .zero, ref) }
    private func onWire(_ id: UUID) -> CGPoint {
        guard let w = wire(id) else { return .zero }
        return editor.circuitDoc(CGPoint(x: (w.points[0].x + w.points[1].x) / 2, y: (w.points[0].y + w.points[1].y) / 2), ref)
    }
    private func pan(_ from: CGPoint, by d: CGPoint) {
        TouchPan().drag(from: from, to: CGPoint(x: from.x + d.x, y: from.y + d.y)) { editor.handleCircuitPan($0, $0.location(in: nil)) }
    }
    /// 用 Pencil 圈一個方框（在空白處開始）
    private func marquee(_ r: CGRect) {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                   CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY + 2), CGPoint(x: r.minX + 1, y: r.minY + 1)]
        let g = TouchPan()
        for (i, p) in pts.enumerated() {
            g.point = p
            g.fake = i == 0 ? .began : (i == pts.count - 1 ? .ended : .changed)
            editor.handleCircuitPan(g, p)
        }
    }
    /// 圈住左邊的電阻、中間的線、右邊的電阻（外面那條線不完全在裡面）
    private func marqueeBothResistors() {
        let a = at(left), b = at(right)
        marquee(CGRect(x: a.x - 60, y: a.y - 40, width: b.x - a.x + 110, height: 80))
    }

    // MARK: 手指拖元件

    func testFingerDragsAComponentInEveryModeButOnlyAComponent() throws {
        editor.circuitPanByFinger = true
        defer { editor.circuitPanByFinger = false }
        XCTAssertTrue(editor.circuitAcceptsFinger(at: at(left)))
        XCTAssertFalse(editor.circuitAcceptsFinger(at: onWire(bridge)), "手指按在導線上是捲動頁面")
        XCTAssertFalse(editor.circuitAcceptsFinger(at: CGPoint(x: at(left).x - 90, y: at(left).y)), "空白處是捲動頁面")
        XCTAssertFalse(editor.circuitPanShouldBegin(at: onWire(bridge)))

        for mode: CircuitMode in [.select, .wire, .place(.capacitor)] {
            editor.selectCircuitMode(mode)
            XCTAssertTrue(editor.circuitPanShouldBegin(at: at(right)))
            let before = at(right), count = data.wires.count
            pan(before, by: CGPoint(x: 0, y: 40))
            XCTAssertEqual(at(right).y - before.y, 40, accuracy: 0.5, "元件跟著手指走")
            XCTAssertEqual(data.wires.count, count, "接線模式也不會多畫一條線")
            XCTAssertEqual(editor.circuitMode, mode, "模式不變")
            XCTAssertTrue(CircuitGeometry.pins(try XCTUnwrap(part(right))).contains(try XCTUnwrap(wire(outside)?.points[0])), "導線跟著接腳走")
        }
        editor.selectCircuitMode(.erase)
        XCTAssertFalse(editor.circuitAcceptsFinger(at: at(left)), "橡皮擦不用手指拖")
    }

    // MARK: 改名

    private func checkTapRenames(in mode: CircuitMode) throws {
        editor.selectCircuitMode(mode)
        editor.circuitSel = nil
        let count = data.components.count
        editor.handleCircuitTap(at: at(left))
        XCTAssertEqual(editor.circuitSel, .component(left))
        XCTAssertNil(editor.presentedViewController, "第一下只有選取")
        editor.handleCircuitTap(at: at(left))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let alert = try XCTUnwrap(editor.presentedViewController as? UIAlertController, "選取中再點一下：改名")
        XCTAssertEqual(alert.title, "元件名稱")
        XCTAssertEqual(data.components.count, count, "放置模式也不會多放一個")
    }

    func testTappingTheSelectedComponentRenamesItWhenSelecting() throws { try checkTapRenames(in: .select) }
    func testTappingTheSelectedComponentRenamesItWhenWiring() throws { try checkTapRenames(in: .wire) }
    func testTappingTheSelectedComponentRenamesItWhenPlacing() throws { try checkTapRenames(in: .place(.capacitor)) }

    func testDoubleTapGestureIsNotUsedInTheCircuitTool() {
        XCTAssertFalse(editor.doubleTapGesture.isEnabled, "第二下已經是改名，不要再跳一次")
    }

    // MARK: 上下標

    func testNamesBecomeSubscriptsAndSuperscripts() {
        func runs(_ s: String) -> [CircuitText.Run] { CircuitText.runs(s) }
        XCTAssertEqual(runs("R1"), [.init(text: "R1", script: .normal)])
        XCTAssertEqual(runs("R_1"), [.init(text: "R", script: .normal), .init(text: "1", script: .sub)])
        XCTAssertEqual(runs("V_DS"), [.init(text: "V", script: .normal), .init(text: "DS", script: .sub)])
        XCTAssertEqual(runs("x^2"), [.init(text: "x", script: .normal), .init(text: "2", script: .sup)])
        XCTAssertEqual(runs("V_{in+}^2 k"), [.init(text: "V", script: .normal), .init(text: "in+", script: .sub), .init(text: "2", script: .sup), .init(text: " k", script: .normal)])
        XCTAssertEqual(runs("R_"), [.init(text: "R_", script: .normal)], "後面沒有字就是一般字")
        XCTAssertEqual(runs("a_ b"), [.init(text: "a_ b", script: .normal)])

        let plain = CircuitText.bounds("R12", center: .zero, size: 16)
        let script = CircuitText.bounds("R_12", center: .zero, size: 16)
        XCTAssertLessThan(script.width, plain.width, "下標比較窄，底線不佔位置")

        let text = CircuitRenderer.nameString("R_1", size: 16, color: .black)
        XCTAssertEqual(text.string, "R1", "畫出來沒有底線")
        XCTAssertNotNil(text.attribute(.baselineOffset, at: 1, effectiveRange: nil))
    }

    func testSVGHasSubscripts() throws {
        var d = CircuitData()
        var c = CircuitComponent(part: .resistor, position: CGPoint(x: 60, y: 60))
        c.name = "R_1<2"
        c.nameOffset = CGPoint(x: 0, y: -30)
        d.components = [c]
        let svg = CircuitRenderer.svg(d)
        XCTAssertTrue(XMLParser(data: Data(svg.utf8)).parse(), "是合法的 XML")
        XCTAssertTrue(svg.contains("<tspan"))
        XCTAssertFalse(svg.contains("R_"), "底線不會出現在字裡")
    }

    // MARK: 群組

    func testMarqueeSelectsWhatIsFullyInside() throws {
        XCTAssertTrue(editor.circuitPanShouldBegin(at: CGPoint(x: at(left).x - 90, y: at(left).y - 90)), "選取模式空白處可以開始圈")
        marqueeBothResistors()
        guard case let .items(ids)? = editor.circuitSel else { return XCTFail("選到好幾個") }
        XCTAssertEqual(ids, [left, right, bridge], "外面那條線沒有整條在裡面，不算")
        XCTAssertTrue(editor.buildCircuitRibbon().contains { $0.accessibilityLabel == "群組" })
        XCTAssertNotNil(editor.circuitPartHandleCenters(), "一整組旁邊也有旋轉、翻轉、複製、刪除")
    }

    func testGroupMovesAndSelectsTogetherThenUngroup() throws {
        marqueeBothResistors()
        editor.groupCircuitSelection()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(data.isOneGroup([left, right, bridge]))
        XCTAssertTrue(editor.buildCircuitRibbon().contains { $0.accessibilityLabel == "解散群組" })

        editor.circuitSel = nil
        editor.handleCircuitTap(at: at(left))
        XCTAssertEqual(editor.circuitSel, .items([left, right, bridge]), "點其中一個就是整組")
        editor.circuitSel = nil
        editor.handleCircuitTap(at: onWire(bridge))
        XCTAssertEqual(editor.circuitSel, .items([left, right, bridge]), "點導線也是")

        // 拖其中一個：整組一起走，外面的線接著
        let a = at(left), b = at(right)
        pan(a, by: CGPoint(x: 0, y: 40))
        XCTAssertEqual(at(left).y - a.y, 40, accuracy: 0.5)
        XCTAssertEqual(at(right).y - b.y, 40, accuracy: 0.5)
        XCTAssertEqual(wire(bridge)?.points.first, CircuitGeometry.pins(try XCTUnwrap(part(left)))[1], "裡面的線一起走")
        XCTAssertTrue(CircuitGeometry.pins(try XCTUnwrap(part(right))).contains(try XCTUnwrap(wire(outside)?.points[0])), "外面的線接著接腳")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        editor.undoTapped()
        XCTAssertEqual(at(left).y, a.y, accuracy: 0.5, "一次復原整組回去")
        XCTAssertEqual(at(right).y, b.y, accuracy: 0.5)

        // 解散：又可以一個一個選
        editor.circuitSel = .items([left, right, bridge])
        editor.ungroupCircuitSelection()
        XCTAssertNil(data.groupMembers(of: left))
        editor.circuitSel = nil
        editor.handleCircuitTap(at: at(left))
        XCTAssertEqual(editor.circuitSel, .component(left))
    }

    func testTappingInsideASelectedGroupRenamesThatPart() throws {
        marqueeBothResistors()
        editor.groupCircuitSelection()
        editor.handleCircuitTap(at: at(right))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let alert = try XCTUnwrap(editor.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, "元件名稱")
        alert.dismiss(animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    func testEraserAndDeleteTakeTheWholeGroup() throws {
        marqueeBothResistors()
        editor.groupCircuitSelection()
        editor.selectCircuitMode(.erase)
        editor.handleCircuitTap(at: at(left))
        XCTAssertEqual(data.components.count, 0, "點到一個就刪整組")
        XCTAssertNil(wire(bridge))
        XCTAssertNotNil(wire(outside), "外面的線留著")
    }

    func testCopyingAGroupIsANewGroupBelow() throws {
        marqueeBothResistors()
        editor.groupCircuitSelection()
        let bottom = data.subset([left, right, bridge]).contentBounds.maxY
        editor.copySelectedComponent()
        guard case let .items(ids)? = editor.circuitSel else { return XCTFail("選起新的那組") }
        XCTAssertEqual(ids.count, 3)
        XCTAssertTrue(ids.isDisjoint(with: [left, right, bridge]))
        XCTAssertTrue(data.isOneGroup(ids), "新的也是一個群組")
        XCTAssertNotEqual(data.groupMembers(of: ids.first!), data.groupMembers(of: left), "和原本的不是同一組")
        XCTAssertGreaterThan(data.subset(ids).contentBounds.minY - (data.subset([left, right, bridge]).contentBounds.maxY - bottom), bottom - 1, "放在下面、不重疊")
    }

    func testGroupWiresAreNotJoinedWithOutsideWires() {
        var d = CircuitData()
        var a = CircuitWire(points: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0)])
        a.groupID = UUID()
        let b = CircuitWire(points: [CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 0)])
        d.wires = [a, b]
        d.joinStraightRuns()
        XCTAssertEqual(d.wires.count, 2)
    }

    /// 整組旋轉、翻轉：接腳的位置要剛好是原本的位置轉過去，外面的線還接著
    func testTransformingAGroupKeepsEverythingConnected() throws {
        var d = CircuitData()
        var mos = CircuitComponent(part: .nmos, position: CGPoint(x: 100, y: 100))
        mos.rotation = 90
        mos.nameOffset = CGPoint(x: 0, y: -40)
        mos.name = "M1"
        let pin = CircuitGeometry.pins(mos)[1]
        let inner = CircuitWire(points: [pin, CGPoint(x: pin.x, y: pin.y - 60)])
        let outer = CircuitWire(points: [CircuitGeometry.pins(mos)[0], CGPoint(x: 300, y: 300)])
        d.components = [mos]
        d.wires = [inner, outer]
        let ids: Set<UUID> = [mos.id, inner.id]
        let box = d.subset(ids).contentBounds
        let o = CircuitData.snap(CGPoint(x: box.midX, y: box.midY))
        let before = CircuitGeometry.pins(mos)

        var flipped = d
        flipped.transformItems(ids, .flipH)
        let f = try XCTUnwrap(flipped.components.first)
        for (p, q) in zip(before, CircuitGeometry.pins(f)) {
            XCTAssertEqual(q.x, 2 * o.x - p.x, accuracy: 0.5, "左右鏡像")
            XCTAssertEqual(q.y, p.y, accuracy: 0.5)
        }
        var flippedV = d
        flippedV.transformItems(ids, .flipV)
        for (p, q) in zip(before, CircuitGeometry.pins(try XCTUnwrap(flippedV.components.first))) {
            XCTAssertEqual(q.x, p.x, accuracy: 0.5)
            XCTAssertEqual(q.y, 2 * o.y - p.y, accuracy: 0.5, "上下鏡像")
        }
        var rotated = d
        rotated.transformItems(ids, .rotate)
        let r = try XCTUnwrap(rotated.components.first)
        for (p, q) in zip(before, CircuitGeometry.pins(r)) {
            XCTAssertEqual(q.x, o.x - (p.y - o.y), accuracy: 0.5, "轉 90 度")
            XCTAssertEqual(q.y, o.y + (p.x - o.x), accuracy: 0.5)
        }
        let outerAfter = try XCTUnwrap(rotated.wires.first { $0.id == outer.id })
        XCTAssertEqual(outerAfter.points.first, CircuitGeometry.pins(r)[0], "外面的線跟著接腳")
        let innerAfter = try XCTUnwrap(rotated.wires.first { $0.id == inner.id })
        XCTAssertEqual(innerAfter.points.first, CircuitGeometry.pins(r)[1], "裡面的線一起轉")

        var four = d
        for _ in 0..<4 { four.transformItems(ids, .rotate) }
        XCTAssertEqual(four.components.first?.position, mos.position, "轉四次回到原位")
    }

    // MARK: 自訂電路

    func testCustomCircuitComesOutAsAGroup() throws {
        marqueeBothResistors()
        guard case let .items(ids)? = editor.circuitSel else { return XCTFail() }
        let stored = data.extracted(ids)
        XCTAssertEqual(stored.components.count, 2)
        XCTAssertEqual(stored.wires.count, 1)
        XCTAssertNil(stored.groupMembers(of: left))
        editor.saveCustomCircuit(name: " OTA ", data: stored)
        let custom = try XCTUnwrap(CustomCircuitStore.shared.circuits.last)
        XCTAssertEqual(custom.name, "OTA")

        // 拉到遠一點的地方：獨立的電路圖，是一個群組、整組選著
        editor.circuitSel = nil
        let page = editor.contentOrigin(0)
        editor.placeCustomCircuit(custom.id, at: CGPoint(x: page.x + 280, y: page.y + 700))
        let newRef = try XCTUnwrap(editor.circuitTarget)
        XCTAssertNotEqual(newRef, ref)
        let placed = try XCTUnwrap(editor.circuitInfo(newRef)?.data)
        XCTAssertEqual(placed.components.count, 2)
        XCTAssertEqual(placed.wires.count, 1)
        XCTAssertTrue(placed.isOneGroup(placed.itemIDs), "拉出來就是群組")
        XCTAssertEqual(editor.circuitSel, .items(placed.itemIDs))
        XCTAssertFalse(placed.itemIDs.contains(left), "是新的元件")

        // 再放一個到同一張電路圖：兩組互不相干
        editor.placeCustomCircuit(custom.id, at: editor.circuitDoc(CGPoint(x: 150, y: 150), newRef))
        let twice = try XCTUnwrap(editor.circuitInfo(editor.circuitTarget ?? newRef)?.data)
        XCTAssertEqual(twice.components.count, 4)
        XCTAssertEqual(Set(twice.components.compactMap(\.groupID)).count, 2)

        // 存檔再讀回來
        let json = try JSONEncoder().encode(CustomCircuitStore.shared.circuits)
        XCTAssertEqual(try JSONDecoder().decode([CustomCircuit].self, from: json), CustomCircuitStore.shared.circuits)
    }

    func testLibraryHasACustomSectionThatFollowsTheStore() throws {
        let library = editor.circuitLibrary
        let before = library.visibleTiles.count
        let c = CustomCircuitStore.shared.add(name: "OTA", data: data.extracted([left]))
        XCTAssertEqual(library.visibleTiles.count, before + 1, "加了就出現在元件庫")
        let tile = try XCTUnwrap(library.visibleTiles.last)
        XCTAssertEqual(tile.accessibilityLabel, "OTA")
        XCTAssertNotNil(tile.menu, "長按可以改名、刪除")
        tile.sendActions(for: .touchUpInside)
        XCTAssertEqual(editor.circuitMode, .placeCustom(c.id), "點一下是連續放置")
        editor.deleteCustomCircuit(c.id)
        XCTAssertEqual(editor.circuitMode, .select, "刪掉正在放的：回到選取")
        XCTAssertEqual(library.visibleTiles.count, before)
    }

    // MARK: 套索、上鎖

    private func lasso(_ r: CGRect) {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                   CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY + 2), CGPoint(x: r.minX + 1, y: r.minY + 1)]
        let g = TouchPan()
        for (i, p) in pts.enumerated() {
            g.fake = i == 0 ? .began : (i == pts.count - 1 ? .ended : .changed)
            editor.handleLassoPan(g, p)
        }
    }

    func testLockKeepsTheCircuitOutOfTheLassoAndFromEditing() throws {
        let f = try XCTUnwrap(editor.circuitInfo(ref).map { editor.docFrame(of: $0.element, pageIndex: $0.pi) })
        let part1 = at(left)
        // 工具列切到電路工具時，正在編輯的電路圖旁邊有鎖頭
        let icon = try XCTUnwrap(editor.lockIconTargets().first { $0.ref == ref })
        XCTAssertFalse(icon.locked)
        XCTAssertFalse(f.contains(icon.point), "鎖頭在電路圖外面，不會蓋住元件")

        editor.handleCircuitTap(at: icon.point)
        XCTAssertEqual(editor.circuitInfo(ref)?.element.locked, true)
        XCTAssertNil(editor.circuitTarget, "鎖住就不能編輯")
        XCTAssertNil(editor.circuitHit(at: part1), "點不到")
        XCTAssertEqual(editor.lockIconTargets().first { $0.ref == ref }?.locked, true, "鎖頭還在，才解得開")

        let count = data.components.count
        editor.placeComponent(.capacitor, at: part1)
        XCTAssertEqual(data.components.count, count, "放不進鎖住的電路圖")
        if let other = editor.circuitTarget { editor.circuitTarget = nil; _ = other }

        editor.setTool(.lasso)
        lasso(f.insetBy(dx: -30, dy: -30))
        XCTAssertFalse(editor.lassoSel?.elements.contains(ref) ?? false, "鎖住就圈不到")
        editor.clearLassoSelection()

        // 解鎖
        let l = try XCTUnwrap(editor.lockIconTargets().first { $0.ref == ref })
        XCTAssertTrue(l.locked)
        editor.toggleLock(ref)
        lasso(f.insetBy(dx: -30, dy: -30))
        XCTAssertEqual(editor.lassoSel?.elements.contains(ref), true)
    }

    // MARK: PMOS

    func testPMOSIsMirroredByDefault() throws {
        let page = editor.contentOrigin(0)
        editor.placeComponent(.pmos, at: CGPoint(x: page.x + 280, y: page.y + 650))
        let target = try XCTUnwrap(editor.circuitTarget)
        let p = try XCTUnwrap(editor.circuitInfo(target)?.data.components.last)
        XCTAssertEqual(p.part, .pmos)
        XCTAssertTrue(p.flipV, "源極（有箭頭那支）在上面")
        XCTAssertLessThan(CircuitGeometry.pins(p)[2].y, CircuitGeometry.pins(p)[1].y)

        editor.placeComponent(.nmos, at: CGPoint(x: page.x + 280, y: page.y + 750))
        let n = try XCTUnwrap(editor.circuitTarget.flatMap { editor.circuitInfo($0)?.data.components.last })
        XCTAssertFalse(n.flipV, "NMOS 不變")

        // 使用者翻回來之後，接下來放的照使用者的
        editor.circuitPartStyle[.pmos] = (0, false, false)
        editor.placeComponent(.pmos, at: CGPoint(x: page.x + 100, y: page.y + 750))
        XCTAssertEqual(editor.circuitTarget.flatMap { editor.circuitInfo($0)?.data.components.last }?.flipV, false)
    }

    // MARK: 新元件

    func testEveryPartHasASymbolPinsOnTheGridAndAPlaceInTheLibrary() {
        let listed = CircuitLibraryView.sections.flatMap(\.1)
        XCTAssertEqual(listed.count, Set(listed).count, "不重複")
        XCTAssertEqual(Set(listed), Set(CircuitPart.allCases), "每個元件都在元件庫裡")
        for part in CircuitPart.allCases {
            var c = CircuitComponent(part: part, position: CGPoint(x: 200, y: 200))
            c.inputs = part.defaultSize
            let (stroke, fill) = CircuitRenderer.symbol(c)
            XCTAssertFalse(stroke.isEmpty && fill.isEmpty, "\(part) 有符號")
            XCTAssertFalse(part.title.isEmpty)
            let box = CircuitGeometry.localBounds(c).insetBy(dx: -0.5, dy: -0.5)
            let pins = CircuitGeometry.localPins(c)
            XCTAssertFalse(pins.isEmpty, "\(part)")
            for p in pins {
                XCTAssertEqual(p.x.truncatingRemainder(dividingBy: 10), 0, "\(part) 接腳在格點上")
                XCTAssertEqual(p.y.truncatingRemainder(dividingBy: 10), 0, "\(part) 接腳在格點上")
                XCTAssertTrue(box.contains(p), "\(part) 接腳在外框裡（點得到）")
            }
            XCTAssertTrue(box.insetBy(dx: -8, dy: -8).contains(stroke.bounds), "\(part) 符號沒有跑出外框太多：\(stroke.bounds) / \(box)")
            XCTAssertGreaterThan(CircuitRenderer.icon(part).size.width, 0)
        }
        var all = CircuitData()
        all.components = CircuitPart.allCases.enumerated().map { CircuitComponent(part: $1, position: CGPoint(x: 100 * $0, y: 0)) }
        XCTAssertTrue(XMLParser(data: Data(CircuitRenderer.svg(all).utf8)).parse(), "全部都能匯出")
    }

    // MARK: 虛線整條擦掉

    func testWholeStrokeEraserTakesTheWholeDashedLine() throws {
        let line = InkStroke(colorHex: "#000000FF", points: [InkPoint(.zero, width: 2), InkPoint(CGPoint(x: 200, y: 0), width: 2)])
        let dashes = InkGeometry.dashed(line, dash: 10, gap: 5)
        XCTAssertGreaterThan(dashes.count, 5)
        let other = InkStroke(colorHex: "#000000FF", points: [InkPoint(CGPoint(x: 0, y: 50), width: 2), InkPoint(CGPoint(x: 200, y: 50), width: 2)])
        let another = InkGeometry.dashed(InkGeometry.offset(line, by: CGPoint(x: 0, y: 100)), dash: 10, gap: 5)
        let whole = try XCTUnwrap(InkGeometry.erase(dashes + [other] + another, at: CGPoint(x: 5, y: 0), radius: 4, partial: false))
        XCTAssertEqual(whole.count, another.count + 1, "碰到一段就整條不見；別的線留著")
        XCTAssertFalse(whole.contains { $0.dashGroup == dashes[0].dashGroup })

        let partial = try XCTUnwrap(InkGeometry.erase(dashes, at: CGPoint(x: 5, y: 0), radius: 4, partial: true))
        XCTAssertGreaterThan(partial.count, dashes.count - 2, "局部擦除只擦碰到的地方")
        XCTAssertTrue(partial.allSatisfy { $0.dashGroup == dashes[0].dashGroup }, "切開的還是同一條")
    }

    func testPasteMakesADifferentDashedLine() throws {
        let line = InkStroke(colorHex: "#000000FF", points: [InkPoint(.zero, width: 2), InkPoint(CGPoint(x: 100, y: 0), width: 2)])
        let dashes = InkGeometry.dashed(line, dash: 10, gap: 5)
        let clip = LassoClipboard(strokes: [], elements: [], highlights: [], bounds: CGRect(x: 0, y: 0, width: 100, height: 4), changeCount: 0, ink: dashes)
        editor.pasteLasso(clip, center: CGPoint(x: 300, y: 500))
        let groups = Set(editor.pages[0].ink.compactMap(\.dashGroup))
        XCTAssertEqual(groups.count, 1, "貼上的整條是同一組")
        XCTAssertFalse(groups.contains(try XCTUnwrap(dashes[0].dashGroup)), "和原本的不同組")
    }

    func testPencilKitEraserTakesTheWholeDashedLine() {
        func stroke(y: CGFloat, date: Date) -> PKStroke {
            let pts = (0...200).map { PKStrokePoint(location: CGPoint(x: CGFloat($0), y: y), timeOffset: TimeInterval($0) / 100, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: date))
        }
        let pieces = DashedStroke.split(stroke(y: 0, date: Date(timeIntervalSince1970: 1000)), dash: 10, gap: 5)
        let solid = stroke(y: 50, date: Date(timeIntervalSince1970: 2000))
        let before = pieces + [solid]
        XCTAssertGreaterThan(pieces.count, 3)
        let rest = DashedStroke.removingErasedDashes(from: Array(before.dropFirst()), before: before)
        XCTAssertEqual(rest.count, 1, "PencilKit 擦掉一段，其他段也拿掉")
        XCTAssertEqual(rest.first?.path.creationDate, solid.path.creationDate, "實線留著")
        XCTAssertEqual(DashedStroke.removingErasedDashes(from: before, before: before).count, before.count, "沒擦到就不動")
    }

    // MARK: 預覽模式

    func testPreviewModeHidesTheBarsAndOnlyAllowsViewing() throws {
        editor.setTool(.pen)
        let top = editor.canvas.frame.minY
        XCTAssertFalse(editor.makeSettingsMenuItems().isEmpty)
        editor.setPreviewMode(true)
        XCTAssertTrue(editor.topBar.isHidden)
        XCTAssertTrue(editor.subBar.isHidden)
        XCTAssertLessThan(editor.canvas.frame.minY, top, "頁面往上佔滿")
        XCTAssertFalse(editor.previewExitButton.isHidden)
        XCTAssertTrue(editor.pinOverlay.isHidden)
        XCTAssertFalse(editor.canvas.drawingGestureRecognizer.isEnabled, "不能寫")
        XCTAssertFalse(editor.inkRecognizer.isEnabled)
        XCTAssertFalse(editor.toolPan.isEnabled)
        XCTAssertFalse(editor.tapGesture.isEnabled, "不能選")
        XCTAssertTrue(editor.canvas.panGestureRecognizer.isEnabled, "可以捲動")
        XCTAssertTrue(editor.circuitLibrary.isHidden)

        editor.previewExitButton.sendActions(for: .touchUpInside)
        XCTAssertFalse(editor.topBar.isHidden)
        XCTAssertFalse(editor.subBar.isHidden)
        XCTAssertEqual(editor.canvas.frame.minY, top, accuracy: 0.5)
        XCTAssertEqual(editor.tool, .pen, "回到原本的工具")
        XCTAssertTrue(editor.tapGesture.isEnabled)
        XCTAssertTrue(editor.previewExitButton.isHidden)
    }
}
