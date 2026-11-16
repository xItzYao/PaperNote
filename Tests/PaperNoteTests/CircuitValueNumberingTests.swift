import XCTest
@testable import PaperNote

/// 回報的需求：
/// - 元件自動編號：每一頁各自編，預設關，在工具列下面那排打開；自訂元件可以設定用什麼開頭編號
/// - 元件除了名稱還有數值，數值後面的下拉選單選 m u n p K M G，預設沒有
/// - 圈選像 AutoCAD：順時針要完整圈到才選，逆時針碰到就選
final class CircuitValueNumberingTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var ref: ElementRef!
    private var savedAutoNumber = false

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "CircuitValueNumbering", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        savedAutoNumber = editor.settings.circuitAutoNumber
        var d = CircuitData()
        d.components = [CircuitComponent(part: .resistor, position: CGPoint(x: 120, y: 160))]
        let o = editor.contentOrigin(0)
        ref = try XCTUnwrap(editor.insertElement(.circuit(d), size: CGSize(width: 260, height: 220), at: CGPoint(x: o.x + 250, y: o.y + 300)))
        editor.setTool(.circuit)
        editor.selectCircuitMode(.select)
        editor.circuitTarget = ref
        editor.history.endGroup()
    }

    override func tearDown() {
        editor.settings.circuitAutoNumber = savedAutoNumber
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private var data: CircuitData? { editor.circuitInfo(ref)?.data }
    private var frame: CGRect {
        guard let info = editor.circuitInfo(ref) else { return .zero }
        return editor.docFrame(of: info.element, pageIndex: info.pi)
    }

    // MARK: 自動編號

    func testAutoNumberContinuesFromTheUsedNames() {
        var comps = [CircuitComponent(part: .resistor, position: .zero), CircuitComponent(part: .resistor, position: .zero),
                     CircuitComponent(part: .capacitor, position: .zero), CircuitComponent(part: .ground, position: .zero),
                     CircuitComponent(part: .nmos, position: .zero)]
        comps[1].name = "R1"   // 複製出來的：換成下一個號碼
        comps[4].name = "M_{in}"   // 自己取的：不動
        CircuitData.autoNumber(&comps, used: ["R1", "R_{3}", "C1", "Rload"])
        XCTAssertEqual(comps.map(\.name), ["R4", "R5", "C2", nil, "M_{in}"])
        XCTAssertNotNil(comps[0].nameOffset, "名稱放在元件上方")
        XCTAssertNil(comps[3].nameOffset, "接地不編號")
    }

    func testCustomSymbolsUseTheirOwnPrefix() {
        var symbol = CircuitSymbol(strokes: [.init(points: [CGPoint(x: -20, y: 0), CGPoint(x: 20, y: 0)])], pins: [CGPoint(x: -20, y: 0)])
        var plain = CircuitComponent(part: .customSymbol, position: .zero)
        plain.symbol = symbol
        symbol.numberPrefix = "OTA"
        var ota = CircuitComponent(part: .customSymbol, position: .zero)
        ota.symbol = symbol
        var comps = [ota, ota, plain]
        CircuitData.autoNumber(&comps, used: ["OTA1"])
        XCTAssertEqual(comps.map(\.name), ["OTA2", "OTA3", "U1"], "沒設定開頭的是 U")
        // 存起來、讀回來還在
        let decoded = try? JSONDecoder().decode(CircuitSymbol.self, from: JSONEncoder().encode(symbol))
        XCTAssertEqual(decoded?.numberPrefix, "OTA")
    }

    func testTheSymbolEditorAsksForTheNumberPrefix() throws {
        var saved: CircuitSymbol?
        let symbol = CircuitSymbol(strokes: [.init(points: [CGPoint(x: -20, y: 0), CGPoint(x: 20, y: 0)])], pins: [CGPoint(x: -20, y: 0)])
        let vc = CircuitSymbolEditorViewController(name: "OTA", symbol: symbol) { _, s in saved = s }
        vc.loadViewIfNeeded()
        XCTAssertEqual(vc.prefixField.text ?? "", "")
        vc.prefixField.text = " OTA "
        vc.finish()
        XCTAssertEqual(saved?.numberPrefix, "OTA")
    }

    func testAutoNumberingIsOffByDefaultAndCountsPerPage() throws {
        UserDefaults.standard.removeObject(forKey: "circuitAutoNumber")
        XCTAssertFalse(editor.settings.circuitAutoNumber, "預設關")
        let spot = CGPoint(x: frame.maxX + 30, y: frame.midY)
        editor.placeComponent(.capacitor, at: spot)
        XCTAssertNil(data?.components.last?.name, "關著不編號")

        // 工具列下面那排的「自動編號」
        let button = try XCTUnwrap(editor.buildCircuitRibbon().compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "自動編號" })
        XCTAssertEqual(button.accessibilityValue, "0")
        button.sendActions(for: .touchUpInside)
        XCTAssertTrue(editor.settings.circuitAutoNumber)
        XCTAssertEqual(editor.buildCircuitRibbon().compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "自動編號" }?.accessibilityValue, "1")

        editor.placeComponent(.resistor, at: CGPoint(x: frame.maxX + 30, y: frame.minY + 20))
        let r = try XCTUnwrap(data?.components.last)
        XCTAssertEqual(r.name, "R1")
        // 複製：接著編
        editor.circuitSel = .component(r.id)
        editor.copySelectedComponent()
        XCTAssertEqual(data?.components.last?.name, "R2")
        editor.placeComponent(.capacitor, at: CGPoint(x: frame.maxX + 30, y: frame.maxY - 20))
        XCTAssertEqual(data?.components.last?.name, "C1")

        // 另一頁從 1 開始
        editor.insertPage(at: 1, style: .blank, landscape: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        var d = CircuitData()
        d.components = [CircuitComponent(part: .capacitor, position: CGPoint(x: 100, y: 100))]
        let o = editor.contentOrigin(1)
        let other = try XCTUnwrap(editor.insertElement(.circuit(d), size: CGSize(width: 200, height: 200), at: CGPoint(x: o.x + 250, y: o.y + 300)))
        XCTAssertEqual(editor.circuitInfo(other)?.pi, 1)
        let f = try XCTUnwrap(editor.circuitInfo(other).map { editor.docFrame(of: $0.element, pageIndex: $0.pi) })
        editor.placeComponent(.resistor, at: CGPoint(x: f.maxX + 30, y: f.midY))
        XCTAssertEqual(editor.circuitInfo(other)?.data.components.last?.name, "R1", "每一頁各自編")
    }

    // MARK: 數值

    func testValueWithAUnitPrefix() throws {
        let c = try XCTUnwrap(data?.components.first)
        editor.setComponentLabel(ref, component: c.id, name: "R1", value: " 10 ", prefix: "K")
        let r = try XCTUnwrap(data?.components.first)
        XCTAssertEqual(r.value, "10")
        XCTAssertEqual(r.valuePrefix, "K")
        XCTAssertEqual(r.valueText, "10K")
        XCTAssertEqual(r.labelLines.map(\.text), ["R1", "10K"], "名稱下面一行是數值")
        let b = try XCTUnwrap(r.nameBounds)
        XCTAssertLessThan(b.maxY, CircuitGeometry.bounds(r).minY + 1, "不會壓到元件")
        XCTAssertTrue(data?.netlist().split(separator: "\n").contains { $0.hasPrefix("R1 resistor") && $0.hasSuffix(" 10k") } == true,
                      "網表用 SPICE 的寫法：\(data?.netlist() ?? "")")
        XCTAssertTrue(CircuitRenderer.svg(try XCTUnwrap(data)).contains(">10K<"), "SVG 也有數值")

        // 改名稱不會動到數值；µ
        editor.setComponentName(ref, component: c.id, to: "R2")
        XCTAssertEqual(data?.components.first?.valueText, "10K")
        editor.setComponentLabel(ref, component: c.id, name: "", value: "4.7", prefix: "u")
        XCTAssertEqual(data?.components.first?.labelLines.map(\.text), ["4.7µ"], "只有數值也可以")
        XCTAssertEqual(CircuitValuePrefix.spice("M"), "Meg", "SPICE 的 M 是 milli")
        editor.setComponentLabel(ref, component: c.id, name: "", value: "", prefix: "u")
        XCTAssertNil(data?.components.first?.valuePrefix)
        XCTAssertNil(data?.components.first?.nameOffset, "都拿掉了")
    }

    func testTheNameEditorHasAValueFieldWithAPrefixMenu() throws {
        let c = try XCTUnwrap(data?.components.first)
        editor.promptComponentName(ref, component: c.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let vc = try XCTUnwrap(editor.presentedNameEditor)
        XCTAssertFalse(vc.valueField.superview?.isHidden ?? true, "元件有數值這一欄")
        XCTAssertEqual(vc.prefixButton.configuration?.title, "無", "預設沒有前綴")
        let options = vc.prefixButton.menu?.children.compactMap { ($0 as? UIAction)?.title }
        XCTAssertEqual(options, ["無", "p", "n", "µ", "m", "K", "M", "G"])
        vc.setValuePrefix("n")
        vc.valueField.text = "100"
        vc.finish()
        // 關掉視窗的動畫結束才存（模擬器慢的時候要等久一點）
        let deadline = Date().addingTimeInterval(3)
        while data?.components.first?.valueText == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(data?.components.first?.valueText, "100n")
    }

    func testWireNamesHaveNoValueField() throws {
        let vc = CircuitNameEditorViewController(title: "導線名稱", text: "", placeholder: "Vout")
        vc.loadViewIfNeeded()
        XCTAssertTrue(vc.valueField.superview?.isHidden ?? false)
    }

    // MARK: 圈選的方向

    func testLassoDirection() {
        // 畫面座標 y 往下：左上 → 右上 → 右下 是順時針
        let cw = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]
        XCTAssertTrue(CircuitData.lassoIsClockwise(cw))
        XCTAssertFalse(CircuitData.lassoIsClockwise(cw.reversed()))
    }

    func testCounterclockwiseLassoSelectsWhatItTouches() {
        var d = CircuitData()
        let r = CircuitComponent(part: .resistor, position: CGPoint(x: 100, y: 100))   // 70…130
        let far = CircuitComponent(part: .resistor, position: CGPoint(x: 300, y: 100))
        let w = CircuitWire(points: [CGPoint(x: 130, y: 100), CGPoint(x: 130, y: 200), CGPoint(x: 400, y: 200)])
        d.components = [r, far]
        d.wires = [w]
        // 只圈到電阻右半邊和導線的一段
        // 左上 → 左下 → 右下 → 右上：逆時針
        let box = [CGPoint(x: 110, y: 80), CGPoint(x: 110, y: 160), CGPoint(x: 150, y: 160), CGPoint(x: 150, y: 80)]
        XCTAssertFalse(CircuitData.lassoIsClockwise(box))
        XCTAssertEqual(d.touched(byLasso: box), [r.id, w.id])
        // 圈在元件裡面（沒有碰到外框）也算
        let inside = [CGPoint(x: 95, y: 98), CGPoint(x: 95, y: 102), CGPoint(x: 105, y: 102), CGPoint(x: 105, y: 98)]
        XCTAssertEqual(d.touched(byLasso: inside), [r.id])
    }
}
