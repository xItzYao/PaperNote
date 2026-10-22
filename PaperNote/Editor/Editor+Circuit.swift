import UIKit

enum CircuitMode: Equatable {
    case select, wire, place(CircuitPart)
}

enum CircuitSelection: Equatable {
    case component(UUID), wire(UUID)
}

/// 拖曳元件中的狀態
struct CircuitDrag {
    var start: CGPoint
    var ref: ElementRef
    var original: PageElement
    var componentID: UUID
}

/// 接線中的狀態（文件座標）
struct WireDraft {
    var ref: ElementRef?
    var start: CGPoint
}

// MARK: - 電路工具

extension NotebookViewController {
    // MARK: 座標與查詢

    func circuitInfo(_ ref: ElementRef) -> (pi: Int, ei: Int, element: PageElement, data: CircuitData)? {
        guard case let (pi, ei)? = locate(ref), case let .circuit(d) = pages[pi].elements[ei].content else { return nil }
        return (pi, ei, pages[pi].elements[ei], d)
    }

    func circuitOrigin(_ ref: ElementRef) -> CGPoint? {
        guard let info = circuitInfo(ref) else { return nil }
        return docFrame(of: info.element, pageIndex: info.pi).origin
    }

    func circuitLocal(_ p: CGPoint, _ ref: ElementRef) -> CGPoint {
        guard let o = circuitOrigin(ref) else { return p }
        return CGPoint(x: p.x - o.x, y: p.y - o.y)
    }

    func circuitDoc(_ p: CGPoint, _ ref: ElementRef) -> CGPoint {
        guard let o = circuitOrigin(ref) else { return p }
        return CGPoint(x: p.x + o.x, y: p.y + o.y)
    }

    /// p 附近的電路圖（目前正在編輯的優先）
    func circuitAt(_ p: CGPoint, margin: CGFloat) -> ElementRef? {
        if let t = circuitTarget, let info = circuitInfo(t),
           docFrame(of: info.element, pageIndex: info.pi).insetBy(dx: -margin, dy: -margin).contains(p) {
            return t
        }
        guard let pi = pageIndex(containing: p) else { return nil }
        for e in pages[pi].elements.reversed() {
            guard case .circuit = e.content else { continue }
            if docFrame(of: e, pageIndex: pi).insetBy(dx: -margin, dy: -margin).contains(p) {
                return ElementRef(pageID: pages[pi].id, elementID: e.id)
            }
        }
        return nil
    }

    /// 點到的元件或導線
    func circuitHit(at p: CGPoint) -> (ref: ElementRef, selection: CircuitSelection)? {
        guard let ref = circuitAt(p, margin: 10), let info = circuitInfo(ref) else { return nil }
        let local = circuitLocal(p, ref)
        let tol = max(6, 12 / canvas.zoomScale)
        for c in info.data.components.reversed() where CircuitGeometry.bounds(c).insetBy(dx: -tol / 2, dy: -tol / 2).contains(local) {
            return (ref, .component(c.id))
        }
        for w in info.data.wires {
            for i in 0..<max(0, w.points.count - 1) {
                let a = w.points[i], b = w.points[i + 1]
                let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                if r.insetBy(dx: -tol, dy: -tol).contains(local) { return (ref, .wire(w.id)) }
            }
        }
        return nil
    }

    // MARK: 存檔（整理邊界）

    /// 依內容重新計算物件外框，內容座標保持對齊格點
    func normalizedCircuit(_ e: PageElement) -> PageElement {
        guard case var .circuit(d) = e.content else { return e }
        let b = d.contentBounds
        guard !b.isNull else { return e }
        let g = CircuitData.grid, m = CircuitData.margin
        let shift = CGPoint(x: ((m - b.minX) / g).rounded() * g, y: ((m - b.minY) / g).rounded() * g)
        d.offset(by: shift)
        let nb = d.contentBounds
        var out = e
        out.frame = CGRect(x: e.frame.minX - shift.x, y: e.frame.minY - shift.y, width: nb.maxX + m, height: nb.maxY + m)
        out.content = .circuit(d)
        return out
    }

    func updateCircuit(_ ref: ElementRef, data: CircuitData, undoable: Bool = true) {
        guard let info = circuitInfo(ref) else { return }
        if data.components.isEmpty && data.wires.isEmpty {
            updatePage(info.pi, undoable: undoable) { $0.elements.removeAll { $0.id == ref.elementID } }
            circuitTarget = nil
            circuitSel = nil
        } else {
            var e = info.element
            e.content = .circuit(data)
            let n = normalizedCircuit(e)
            updatePage(info.pi, undoable: undoable) { $0.elements[info.ei] = n }
        }
        updateCircuitChrome()
    }

    /// 在 p 建立新的電路圖（p 會是內容座標 (60, 60) 的位置）
    private func createCircuit(at p: CGPoint, data: CircuitData) -> ElementRef? {
        let pi = pageIndex(containing: p) ?? nearestPageIndex(to: p)
        guard pages.indices.contains(pi) else { return nil }
        let o = contentOrigin(pi)
        let e = normalizedCircuit(PageElement(frame: CGRect(x: p.x - o.x - 60, y: p.y - o.y - 60, width: 120, height: 120),
                                              content: .circuit(data)))
        updatePage(pi) { $0.elements.append(e) }
        return ElementRef(pageID: pages[pi].id, elementID: e.id)
    }

    // MARK: 放置元件

    func placeComponent(_ part: CircuitPart, at p: CGPoint) {
        var comp = CircuitComponent(part: part, position: .zero)
        comp.inputs = circuitGateInputs[part] ?? 2
        if let ref = circuitAt(p, margin: 60), var d = circuitInfo(ref)?.data {
            comp.position = CircuitData.snap(circuitLocal(p, ref))
            d.components.append(comp)
            circuitTarget = ref
            updateCircuit(ref, data: d)
        } else {
            var d = CircuitData()
            comp.position = CGPoint(x: 60, y: 60)
            d.components = [comp]
            circuitTarget = createCircuit(at: p, data: d)
        }
        circuitSel = .component(comp.id)
        circuitMode = .select
        rebuildSubBar()
        updateCircuitChrome()
    }

    // MARK: 點選

    func handleCircuitTap(at p: CGPoint) {
        switch circuitMode {
        case let .place(part):
            placeComponent(part, at: p)
        case .wire:
            break
        case .select:
            let old = circuitSel
            if let hit = circuitHit(at: p) {
                circuitTarget = hit.ref
                circuitSel = hit.selection
            } else {
                circuitSel = nil
            }
            if old != circuitSel { rebuildSubBar() }
            updateCircuitChrome()
        }
    }

    func circuitPanShouldBegin(at p: CGPoint) -> Bool {
        switch circuitMode {
        case .wire: return true
        case .select:
            if case .component? = circuitHit(at: p)?.selection { return true }
            return false
        case .place: return false
        }
    }

    // MARK: 拖曳：移動元件／接線

    func handleCircuitPan(_ g: UIPanGestureRecognizer, _ p: CGPoint) {
        switch circuitMode {
        case .wire: handleWirePan(g, p)
        case .select: handleComponentDrag(g, p)
        case .place: break
        }
    }

    private func handleComponentDrag(_ g: UIPanGestureRecognizer, _ p: CGPoint) {
        switch g.state {
        case .began:
            guard let hit = circuitHit(at: p), case let .component(id) = hit.selection,
                  let info = circuitInfo(hit.ref) else { return }
            circuitTarget = hit.ref
            if circuitSel != .component(id) {
                circuitSel = .component(id)
                rebuildSubBar()
            }
            circuitDrag = CircuitDrag(start: p, ref: hit.ref, original: info.element, componentID: id)
        case .changed:
            guard let d = circuitDrag, let e = draggedCircuit(d, to: p), case let (pi, ei)? = locate(d.ref) else { return }
            session.document.pages[pi].elements[ei] = e
            pageViews[pages[pi].id]?.liveUpdate(e)
            updateCircuitChrome()
        case .ended:
            guard let d = circuitDrag else { return }
            circuitDrag = nil
            guard let e = draggedCircuit(d, to: p), case let (pi, ei)? = locate(d.ref) else { return }
            // 先還原再正式更新，才能復原（e 已經整理過外框，直接整個換掉）
            session.document.pages[pi].elements[ei] = d.original
            pageViews[pages[pi].id]?.liveUpdate(d.original)
            updatePage(pi) { $0.elements[ei] = e }
            updateCircuitChrome()
        default:
            if let d = circuitDrag, case let (pi, ei)? = locate(d.ref) {
                session.document.pages[pi].elements[ei] = d.original
                pageViews[pages[pi].id]?.liveUpdate(d.original)
            }
            circuitDrag = nil
            updateCircuitChrome()
        }
    }

    /// 由拖曳起點的原始資料算出移動後的電路圖（導線跟著接腳走）
    private func draggedCircuit(_ d: CircuitDrag, to p: CGPoint) -> PageElement? {
        guard case var .circuit(data) = d.original.content,
              let ci = data.components.firstIndex(where: { $0.id == d.componentID }) else { return nil }
        let delta = CGPoint(x: p.x - d.start.x, y: p.y - d.start.y)
        let oldPins = CircuitGeometry.pins(data.components[ci])
        let orig = data.components[ci].position
        data.components[ci].position = CircuitData.snap(CGPoint(x: orig.x + delta.x, y: orig.y + delta.y))
        data.reattach(from: oldPins, to: CircuitGeometry.pins(data.components[ci]))
        var e = d.original
        e.content = .circuit(data)
        return normalizedCircuit(e)
    }

    private func wireSnap(_ p: CGPoint, ref: ElementRef?) -> CGPoint {
        let tol = max(8, 16 / canvas.zoomScale)
        if let ref, let data = circuitInfo(ref)?.data {
            return circuitDoc(data.snapTarget(for: circuitLocal(p, ref), within: tol), ref)
        }
        // 沒有電路圖：對齊頁面格點
        let pi = pageIndex(containing: p) ?? nearestPageIndex(to: p)
        let o = pages.indices.contains(pi) ? contentOrigin(pi) : .zero
        let s = CircuitData.snap(CGPoint(x: p.x - o.x, y: p.y - o.y))
        return CGPoint(x: s.x + o.x, y: s.y + o.y)
    }

    /// 直角走線：水平距離比較長就先走水平
    private func wireRoute(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] {
        if a == b { return [a] }
        let corner = abs(b.x - a.x) >= abs(b.y - a.y) ? CGPoint(x: b.x, y: a.y) : CGPoint(x: a.x, y: b.y)
        return CircuitData.orthogonalize([a, corner, b])
    }

    private func handleWirePan(_ g: UIPanGestureRecognizer, _ p: CGPoint) {
        switch g.state {
        case .began:
            let ref = circuitAt(p, margin: 80)
            wireDraft = WireDraft(ref: ref, start: wireSnap(p, ref: ref))
        case .changed:
            guard let w = wireDraft else { return }
            overlay.showCircuitDraft(wireRoute(w.start, wireSnap(p, ref: w.ref ?? circuitAt(p, margin: 80))))
        case .ended:
            guard let w = wireDraft else { return }
            wireDraft = nil
            overlay.showCircuitDraft(nil)
            let endRef = w.ref ?? circuitAt(p, margin: 80)
            let end = wireSnap(p, ref: endRef)
            let route = wireRoute(w.start, end)
            guard route.count >= 2 else { return }
            if let ref = endRef, var data = circuitInfo(ref)?.data {
                let local = route.map { circuitLocal($0, ref) }
                let wire = CircuitWire(points: local)
                data.wires.append(wire)
                circuitTarget = ref
                circuitSel = .wire(wire.id)
                updateCircuit(ref, data: data)
            } else {
                // 新的電路圖：起點放在內容座標 (60, 60)
                let base = CGPoint(x: w.start.x - 60, y: w.start.y - 60)
                let wire = CircuitWire(points: route.map { CGPoint(x: $0.x - base.x, y: $0.y - base.y) })
                var data = CircuitData()
                data.wires = [wire]
                circuitTarget = createCircuit(at: w.start, data: data)
                circuitSel = .wire(wire.id)
            }
            rebuildSubBar()
        default:
            wireDraft = nil
            overlay.showCircuitDraft(nil)
        }
    }

    // MARK: 編輯選取的元件

    private func modifySelectedComponent(_ change: (inout CircuitComponent) -> Void) {
        guard let ref = circuitTarget, case let .component(id)? = circuitSel, var data = circuitInfo(ref)?.data,
              let ci = data.components.firstIndex(where: { $0.id == id }) else { return }
        let old = data.components[ci]
        change(&data.components[ci])
        let new = data.components[ci]
        let oldPins = CircuitGeometry.pins(old), newPins = CircuitGeometry.pins(new)
        if oldPins.count == newPins.count {
            data.reattach(from: oldPins, to: newPins)
        } else {
            // 輸入數量改變：對應相同編號的輸入與輸出接腳
            let n = min(oldPins.count, newPins.count) - 1
            data.reattach(from: Array(oldPins.prefix(n)) + [oldPins.last!], to: Array(newPins.prefix(n)) + [newPins.last!])
        }
        updateCircuit(ref, data: data)
    }

    func deleteCircuitSelection() {
        guard let ref = circuitTarget, var data = circuitInfo(ref)?.data else { return }
        switch circuitSel {
        case let .component(id)?: data.components.removeAll { $0.id == id }
        case let .wire(id)?: data.wires.removeAll { $0.id == id }
        case nil: return
        }
        circuitSel = nil
        updateCircuit(ref, data: data)
        rebuildSubBar()
    }

    var selectedCircuitComponent: CircuitComponent? {
        guard let ref = circuitTarget, case let .component(id)? = circuitSel else { return nil }
        return circuitInfo(ref)?.data.components.first { $0.id == id }
    }

    // MARK: 選取外框、接線預覽

    func updateCircuitChrome() {
        guard tool == .circuit, let ref = circuitTarget, let info = circuitInfo(ref) else {
            overlay.showCircuit(frame: nil, selection: nil)
            return
        }
        let frame = docFrame(of: info.element, pageIndex: info.pi)
        let o = frame.origin
        var sel: UIBezierPath?
        switch circuitSel {
        case let .component(id)?:
            if let c = info.data.components.first(where: { $0.id == id }) {
                sel = UIBezierPath(rect: CircuitGeometry.bounds(c).offsetBy(dx: o.x, dy: o.y).insetBy(dx: -4, dy: -4))
            }
        case let .wire(id)?:
            if let w = info.data.wires.first(where: { $0.id == id }), let first = w.points.first {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: first.x + o.x, y: first.y + o.y))
                for q in w.points.dropFirst() { path.addLine(to: CGPoint(x: q.x + o.x, y: q.y + o.y)) }
                sel = path
            }
        case nil:
            break
        }
        overlay.showCircuit(frame: frame, selection: sel)
    }

    // MARK: 工具列

    func buildCircuitRibbon() -> [UIView] {
        var views: [UIView] = []
        func modeButton(_ symbol: String, _ label: String, _ mode: CircuitMode) -> UIButton {
            let b = makeButton(symbol: symbol, title: nil, action: nil)
            b.accessibilityLabel = label
            var c = b.configuration ?? .plain()
            let on = circuitMode == mode
            c.background.backgroundColor = on ? UIColor.systemBlue.withAlphaComponent(0.15) : .clear
            c.background.cornerRadius = 8
            c.baseForegroundColor = on ? .systemBlue : .label
            b.configuration = c
            b.addAction(UIAction { [weak self] _ in
                self?.circuitMode = mode
                self?.rebuildSubBar()
            }, for: .touchUpInside)
            return b
        }
        views.append(modeButton("cursorarrow", "選取／移動", .select))
        views.append(modeButton("line.diagonal", "接線", .wire))

        let groups: [(String, CircuitPart, [CircuitPart])] = [
            ("被動元件", .resistor, [.resistor, .capacitor, .inductor]),
            ("電源", .voltageSource, [.voltageSource, .currentSource, .ground, .vdd]),
            ("電晶體", .nmos, [.nmos, .pmos]),
            ("邏輯閘", .andGate, [.andGate, .orGate, .notGate, .nandGate, .norGate, .xorGate, .xnorGate, .bufferGate]),
        ]
        for (title, iconPart, parts) in groups {
            var config = UIButton.Configuration.plain()
            var armed = false
            if case let .place(p) = circuitMode, parts.contains(p) { armed = true }
            config.image = CircuitRenderer.icon(iconPart, size: 26)
            config.baseForegroundColor = armed ? .systemBlue : .label
            config.background.backgroundColor = armed ? UIColor.systemBlue.withAlphaComponent(0.15) : .clear
            config.background.cornerRadius = 8
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
            let b = UIButton(configuration: config)
            b.accessibilityLabel = title
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.menu = UIMenu(title: title, children: parts.map { part in
                UIAction(title: part.title, image: CircuitRenderer.icon(part, size: 26)) { [weak self] _ in
                    self?.circuitMode = .place(part)
                    self?.circuitSel = nil
                    self?.rebuildSubBar()
                    self?.updateCircuitChrome()
                    self?.showToast("點一下頁面放置\(part.title)")
                }
            })
            b.showsMenuAsPrimaryAction = true
            views.append(b)
        }

        func action(_ symbol: String, _ label: String, _ handler: @escaping () -> Void) -> UIButton {
            let b = makeButton(symbol: symbol, title: nil, action: nil)
            b.accessibilityLabel = label
            b.addAction(UIAction { _ in handler() }, for: .touchUpInside)
            return b
        }
        if let c = selectedCircuitComponent {
            views.append(action("rotate.right", "旋轉 90°") { [weak self] in
                self?.modifySelectedComponent { $0.rotation = ($0.rotation + 90) % 360 }
            })
            views.append(action("arrow.left.and.right.righttriangle.left.righttriangle.right", "水平翻轉") { [weak self] in
                self?.modifySelectedComponent { $0.flipH.toggle() }
            })
            views.append(action("arrow.up.and.down.righttriangle.up.righttriangle.down", "垂直翻轉") { [weak self] in
                self?.modifySelectedComponent { $0.flipV.toggle() }
            })
            if c.part.hasVariableInputs {
                views.append(action("minus.circle", "減少輸入") { [weak self] in
                    self?.modifySelectedComponent { $0.inputs = max(2, $0.inputs - 1) }
                    if let n = self?.selectedCircuitComponent?.inputs { self?.circuitGateInputs[c.part] = n }
                    self?.rebuildSubBar()
                })
                let label = UILabel()
                label.text = "\(c.inputs) 輸入"
                label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
                views.append(label)
                views.append(action("plus.circle", "增加輸入") { [weak self] in
                    self?.modifySelectedComponent { $0.inputs = min(8, $0.inputs + 1) }
                    if let n = self?.selectedCircuitComponent?.inputs { self?.circuitGateInputs[c.part] = n }
                    self?.rebuildSubBar()
                })
            }
        }
        if circuitSel != nil {
            views.append(action("trash", "刪除") { [weak self] in self?.deleteCircuitSelection() })
        }
        return views
    }
}
