import UIKit

enum CircuitMode: Equatable {
    case select, wire, place(CircuitPart)
}

enum CircuitSelection: Equatable {
    case component(UUID), wire(UUID)
}

/// 選取模式下拖曳的對象
enum CircuitDragKind: Equatable {
    case component(UUID)
    case wireSegment(UUID, Int)
    case wireCorner(UUID, Int)
    case wireEnd(UUID, first: Bool)
}

/// 拖曳中的狀態
struct CircuitDrag {
    var start: CGPoint
    var ref: ElementRef
    var original: PageElement
    /// 開始拖曳時電路圖內容座標的原點（文件座標）
    var origin: CGPoint
    var kind: CircuitDragKind
}

/// 接線中的狀態（文件座標）
struct WireDraft {
    var ref: ElementRef?
    /// 筆跡
    var ink: [CGPoint]
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

    /// p 附近所有的電路圖（目前正在編輯的排第一，其餘由上往下）
    func circuitsAt(_ p: CGPoint, margin: CGFloat) -> [ElementRef] {
        var out: [ElementRef] = []
        if let t = circuitTarget, let info = circuitInfo(t),
           docFrame(of: info.element, pageIndex: info.pi).insetBy(dx: -margin, dy: -margin).contains(p) {
            out.append(t)
        }
        guard let pi = pageIndex(containing: p) else { return out }
        for e in pages[pi].elements.reversed() {
            guard case .circuit = e.content else { continue }
            let ref = ElementRef(pageID: pages[pi].id, elementID: e.id)
            if ref != circuitTarget, docFrame(of: e, pageIndex: pi).insetBy(dx: -margin, dy: -margin).contains(p) {
                out.append(ref)
            }
        }
        return out
    }

    /// p 附近的電路圖（目前正在編輯的優先）
    func circuitAt(_ p: CGPoint, margin: CGFloat) -> ElementRef? {
        circuitsAt(p, margin: margin).first
    }

    /// 點到的元件或導線：重疊的電路圖都找，元件優先於導線
    func circuitHit(at p: CGPoint) -> (ref: ElementRef, selection: CircuitSelection)? {
        let refs = circuitsAt(p, margin: 10)
        let tol = max(6, 12 / canvas.zoomScale)
        for ref in refs {
            guard let info = circuitInfo(ref) else { continue }
            let local = circuitLocal(p, ref)
            for c in info.data.components.reversed() where CircuitGeometry.bounds(c).insetBy(dx: -tol / 2, dy: -tol / 2).contains(local) {
                return (ref, .component(c.id))
            }
        }
        for ref in refs {
            guard let info = circuitInfo(ref) else { continue }
            if case let (id, _)? = wireSegmentHit(circuitLocal(p, ref), in: info.data, tolerance: tol) { return (ref, .wire(id)) }
        }
        return nil
    }

    /// 點到的導線與段編號（內容座標）
    func wireSegmentHit(_ local: CGPoint, in data: CircuitData, tolerance tol: CGFloat) -> (UUID, Int)? {
        for w in data.wires.reversed() {
            for i in 0..<max(0, w.points.count - 1) {
                let a = w.points[i], b = w.points[i + 1]
                let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                if r.insetBy(dx: -tol, dy: -tol).contains(local) { return (w.id, i) }
            }
        }
        return nil
    }

    /// 選取中導線的控制點：頭尾、轉角
    private func wireHandleHit(at p: CGPoint) -> (ElementRef, CircuitDragKind)? {
        guard let ref = circuitTarget, case let .wire(id)? = circuitSel,
              let w = circuitInfo(ref)?.data.wires.first(where: { $0.id == id }), w.points.count >= 2 else { return nil }
        let local = circuitLocal(p, ref)
        let r = max(10, 20 / canvas.zoomScale)
        func near(_ q: CGPoint) -> Bool { hypot(q.x - local.x, q.y - local.y) <= r }
        if near(w.points[0]) { return (ref, .wireEnd(id, first: true)) }
        if near(w.points[w.points.count - 1]) { return (ref, .wireEnd(id, first: false)) }
        for k in 1..<(w.points.count - 1) where near(w.points[k]) { return (ref, .wireCorner(id, k)) }
        return nil
    }

    /// 選取模式下，從這個位置拖曳會動到什麼
    private func circuitDragTarget(at p: CGPoint) -> (ElementRef, CircuitDragKind)? {
        if let h = wireHandleHit(at: p) { return h }
        guard let hit = circuitHit(at: p), let info = circuitInfo(hit.ref) else { return nil }
        switch hit.selection {
        case let .component(id):
            return (hit.ref, .component(id))
        case .wire:
            let tol = max(6, 12 / canvas.zoomScale)
            guard case let (id, i)? = wireSegmentHit(circuitLocal(p, hit.ref), in: info.data, tolerance: tol) else { return nil }
            return (hit.ref, .wireSegment(id, i))
        }
    }

    // MARK: 存檔（整理邊界）

    /// 依內容重新計算物件外框，內容座標保持對齊格點
    func normalizedCircuit(_ e: PageElement) -> PageElement {
        guard case var .circuit(d) = e.content else { return e }
        // 外框原點對齊頁面格點；舊資料若沒對齊，內容先平移回原位再整個吸到格點
        var base = e.frame
        let aligned = CircuitData.snap(base.origin)
        if aligned != base.origin {
            d.offset(by: CGPoint(x: base.minX - aligned.x, y: base.minY - aligned.y))
            base.origin = aligned
        }
        d.snapToGrid()
        let b = d.contentBounds
        guard !b.isNull else { return e }
        let g = CircuitData.grid, m = CircuitData.margin
        let shift = CGPoint(x: ((m - b.minX) / g).rounded() * g, y: ((m - b.minY) / g).rounded() * g)
        d.offset(by: shift)
        let nb = d.contentBounds
        var out = e
        out.frame = CGRect(x: base.minX - shift.x, y: base.minY - shift.y, width: nb.maxX + m, height: nb.maxY + m)
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
            commitCircuit(normalizedCircuit(e), pageIndex: info.pi, undoable: undoable)
        }
        updateCircuitChrome()
    }

    /// 把和 e 外框重疊（含接上線）的其他電路圖併進來，回傳合併後的電路圖與被併掉的物件
    private func mergingOverlaps(_ e: PageElement, pageIndex pi: Int) -> (PageElement, Set<UUID>) {
        var merged = e
        var absorbed = Set<UUID>()
        var grew = true
        while grew {
            grew = false
            guard case var .circuit(d) = merged.content else { break }
            for other in pages[pi].elements where other.id != e.id && !absorbed.contains(other.id) && !other.locked {
                guard case var .circuit(od) = other.content, other.frame.intersects(merged.frame) else { continue }
                od.offset(by: CGPoint(x: other.frame.minX - merged.frame.minX, y: other.frame.minY - merged.frame.minY))
                d.components += od.components
                d.wires += od.wires
                absorbed.insert(other.id)
                grew = true
            }
            if grew {
                merged.content = .circuit(d)
                merged = normalizedCircuit(merged)
            }
        }
        return (merged, absorbed)
    }

    /// 存回頁面（一次復原），順便合併重疊的電路圖
    private func commitCircuit(_ e: PageElement, pageIndex pi: Int, undoable: Bool = true) {
        let (merged, absorbed) = mergingOverlaps(e, pageIndex: pi)
        updatePage(pi, undoable: undoable) { page in
            page.elements.removeAll { absorbed.contains($0.id) }
            if let i = page.elements.firstIndex(where: { $0.id == merged.id }) { page.elements[i] = merged }
        }
    }

    /// 在 p 建立新的電路圖（p 會是內容座標 (60, 60) 的位置）
    private func createCircuit(at p: CGPoint, data: CircuitData) -> ElementRef? {
        let pi = pageIndex(containing: p) ?? nearestPageIndex(to: p)
        guard pages.indices.contains(pi) else { return nil }
        let o = contentOrigin(pi)
        let q = CircuitData.snap(CGPoint(x: p.x - o.x, y: p.y - o.y))
        let e = normalizedCircuit(PageElement(frame: CGRect(x: q.x - 60, y: q.y - 60, width: 120, height: 120),
                                              content: .circuit(data)))
        let (merged, absorbed) = mergingOverlaps(e, pageIndex: pi)
        updatePage(pi) { page in
            page.elements.removeAll { absorbed.contains($0.id) }
            page.elements.append(merged)
        }
        return ElementRef(pageID: pages[pi].id, elementID: merged.id)
    }

    // MARK: 放置元件

    func placeComponent(_ part: CircuitPart, at p: CGPoint) {
        var comp = CircuitComponent(part: part, position: .zero)
        comp.inputs = circuitGateInputs[part] ?? 2
        // 沿用這種元件上次的方向與翻轉
        if let style = circuitPartStyle[part] {
            comp.rotation = style.rotation
            comp.flipH = style.flipH
            comp.flipV = style.flipV
        }
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
        // 停在放置模式，可以連續點著放；剛放的這個先選起來，方便旋轉、翻轉
        circuitSel = .component(comp.id)
        rebuildSubBar()
        updateCircuitChrome()
    }

    // MARK: 點選

    func handleCircuitTap(at p: CGPoint) {
        if handleCircuitPartHandleTap(p) { return }
        switch circuitMode {
        case let .place(part):
            // 點到已經有的元件就選它，不在上面再疊一個
            if let hit = circuitHit(at: p), case .component = hit.selection {
                circuitTarget = hit.ref
                circuitSel = hit.selection
                rebuildSubBar()
                updateCircuitChrome()
            } else {
                placeComponent(part, at: p)
            }
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
        // 點在小圓鈕上：當成點擊
        if let h = circuitPartHandleCenters(), [h.rotate, h.flip, h.delete].contains(where: { p.distance(to: $0) <= h.radius }) { return false }
        switch circuitMode {
        case .wire: return true
        case .select, .place:
            return circuitDragTarget(at: p) != nil
        }
    }

    // MARK: 拖曳：移動元件／接線

    func handleCircuitPan(_ g: UIPanGestureRecognizer, _ p: CGPoint) {
        if g.state == .began {
            // 起點用筆尖剛碰到的位置，接線才會從碰到的那條線開始
            let start = panTouchDownPoint(g)
            switch circuitMode {
            case .wire:
                wireDraft = WireDraft(ref: circuitAt(start, margin: 80), ink: [start])
                handleWirePan(g, p)
            case .select, .place: handleSelectDrag(g, start)
            }
            return
        }
        switch circuitMode {
        case .wire: handleWirePan(g, p)
        case .select, .place: handleSelectDrag(g, p)
        }
    }

    private func handleSelectDrag(_ g: UIPanGestureRecognizer, _ p: CGPoint) {
        switch g.state {
        case .began:
            guard case let (ref, kind)? = circuitDragTarget(at: p), let info = circuitInfo(ref),
                  let origin = circuitOrigin(ref) else { return }
            circuitTarget = ref
            let sel: CircuitSelection
            switch kind {
            case let .component(id): sel = .component(id)
            case let .wireSegment(id, _), let .wireCorner(id, _), let .wireEnd(id, _): sel = .wire(id)
            }
            if circuitSel != sel {
                circuitSel = sel
                rebuildSubBar()
            }
            circuitDrag = CircuitDrag(start: p, ref: ref, original: info.element, origin: origin, kind: kind)
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
            commitCircuit(e, pageIndex: pi)
            if case let .wire(id)? = circuitSel, case let .circuit(data) = e.content, !data.wires.contains(where: { $0.id == id }) {
                circuitSel = nil
                rebuildSubBar()
            }
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

    /// 由拖曳起點的原始資料算出拖曳後的電路圖
    private func draggedCircuit(_ d: CircuitDrag, to p: CGPoint) -> PageElement? {
        guard case var .circuit(data) = d.original.content else { return nil }
        let delta = CGPoint(x: p.x - d.start.x, y: p.y - d.start.y)
        let g = CircuitData.grid
        let gridDelta = CGPoint(x: (delta.x / g).rounded() * g, y: (delta.y / g).rounded() * g)
        switch d.kind {
        case let .component(id):
            // 導線跟著接腳走
            guard let ci = data.components.firstIndex(where: { $0.id == id }) else { return nil }
            let oldPins = CircuitGeometry.pins(data.components[ci])
            let orig = data.components[ci].position
            data.components[ci].position = CircuitData.snap(CGPoint(x: orig.x + delta.x, y: orig.y + delta.y))
            data.reattach(from: oldPins, to: CircuitGeometry.pins(data.components[ci]))
        case let .wireSegment(id, i):
            guard let wi = data.wires.firstIndex(where: { $0.id == id }), i + 1 < data.wires[wi].points.count else { return nil }
            let pts = data.wires[wi].points
            let horizontal = pts[i].y == pts[i + 1].y
            data.wires[wi].points = CircuitData.moveSegment(pts, index: i, by: horizontal ? gridDelta.y : gridDelta.x)
        case let .wireCorner(id, k):
            guard let wi = data.wires.firstIndex(where: { $0.id == id }) else { return nil }
            data.wires[wi].points = CircuitData.moveCorner(data.wires[wi].points, index: k, by: gridDelta)
        case let .wireEnd(id, first):
            guard let wi = data.wires.firstIndex(where: { $0.id == id }) else { return nil }
            // 吸附到接腳或其他導線（不吸自己）
            var others = data
            others.wires.remove(at: wi)
            let local = CGPoint(x: p.x - d.origin.x, y: p.y - d.origin.y)
            let target = others.snapTarget(for: local, within: max(10, 20 / canvas.zoomScale))
            data.wires[wi].points = CircuitData.movingEnd(data.wires[wi].points, first: first, to: target)
        }
        data.wires.removeAll { $0.points.count < 2 }
        var e = d.original
        e.content = .circuit(data)
        return normalizedCircuit(e)
    }

    /// ref 的電路圖，加上 p 附近其他電路圖的元件與導線（換算到 ref 的座標），吸附用
    private func circuitSnapData(near p: CGPoint, in ref: ElementRef) -> CircuitData? {
        guard var d = circuitInfo(ref)?.data, let o = circuitOrigin(ref) else { return nil }
        for other in circuitsAt(p, margin: 40) where other != ref {
            guard var od = circuitInfo(other)?.data, let oo = circuitOrigin(other) else { continue }
            od.offset(by: CGPoint(x: oo.x - o.x, y: oo.y - o.y))
            d.components += od.components
            d.wires += od.wires
        }
        return d
    }

    private func wireSnap(_ p: CGPoint, ref: ElementRef?) -> CGPoint {
        let tol = max(10, 20 / canvas.zoomScale)
        if let ref, let data = circuitSnapData(near: p, in: ref) {
            return circuitDoc(data.snapTarget(for: circuitLocal(p, ref), within: tol), ref)
        }
        // 沒有電路圖：對齊頁面格點
        let pi = pageIndex(containing: p) ?? nearestPageIndex(to: p)
        let o = pages.indices.contains(pi) ? contentOrigin(pi) : .zero
        let s = CircuitData.snap(CGPoint(x: p.x - o.x, y: p.y - o.y))
        return CGPoint(x: s.x + o.x, y: s.y + o.y)
    }

    /// 接線用的電路圖與格點原點（沒有電路圖就用頁面內容的原點）
    private func wireFrame(_ w: WireDraft) -> (ref: ElementRef?, origin: CGPoint)? {
        guard let first = w.ink.first, let last = w.ink.last else { return nil }
        let ref = w.ref ?? circuitAt(last, margin: 80)
        if let ref, let origin = circuitOrigin(ref) { return (ref, origin) }
        let pi = pageIndex(containing: first) ?? nearestPageIndex(to: first)
        return (ref, pages.indices.contains(pi) ? contentOrigin(pi) : .zero)
    }

    /// 依筆跡排出直角導線（文件座標），轉角對齊電路圖（或頁面）的格點
    private func wireRoute(_ w: WireDraft) -> (ref: ElementRef?, points: [CGPoint])? {
        guard let first = w.ink.first, let last = w.ink.last, case let (ref, o)? = wireFrame(w) else { return nil }
        func local(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x - o.x, y: q.y - o.y) }
        let s = local(wireSnap(first, ref: ref)), e = local(wireSnap(last, ref: ref))
        let z = canvas.zoomScale
        let route = CircuitData.penRoute(w.ink.map(local), from: s, to: e,
                                         tolerance: max(4, 8 / z), minRun: max(10, 20 / z))
        return (ref, route.map { CGPoint(x: $0.x + o.x, y: $0.y + o.y) })
    }

    private func handleWirePan(_ g: UIPanGestureRecognizer, _ p: CGPoint) {
        switch g.state {
        case .began, .changed:
            guard var w = wireDraft else { return }
            w.ink.append(p)
            wireDraft = w
            overlay.showCircuitDraft(wireRoute(w)?.points, ink: w.ink)
        case .ended:
            guard var w = wireDraft else { return }
            w.ink.append(p)
            wireDraft = nil
            overlay.showCircuitDraft(nil, ink: nil)
            // 線尾左右畫一小橫：手繪的 VDD／接地
            if let t = terminalPlacement(w) {
                commitWire(ref: t.ref, route: t.route, terminal: (t.part, t.position))
                return
            }
            guard case let (endRef, route)? = wireRoute(w), route.count >= 2 else { return }
            commitWire(ref: endRef, route: route)
        default:
            wireDraft = nil
            overlay.showCircuitDraft(nil, ink: nil)
        }
    }

    /// 手繪 VDD／接地：回傳到轉角為止的導線、元件種類與位置（文件座標）
    private func terminalPlacement(_ w: WireDraft) -> (ref: ElementRef?, route: [CGPoint], part: CircuitPart, position: CGPoint)? {
        guard let first = w.ink.first, case let (ref, o)? = wireFrame(w) else { return nil }
        let z = canvas.zoomScale
        let ink = w.ink.map { CGPoint(x: $0.x - o.x, y: $0.y - o.y) }
        guard let t = CircuitData.terminalGesture(ink, tolerance: max(4, 8 / z)) else { return nil }
        let corner = CircuitData.snap(t.corner)
        let s = CGPoint(x: wireSnap(first, ref: ref).x - o.x, y: wireSnap(first, ref: ref).y - o.y)
        guard let cut = ink.indices.min(by: { ink[$0].distance(to: t.corner) < ink[$1].distance(to: t.corner) }) else { return nil }
        let route = CircuitData.penRoute(Array(ink[...cut]), from: s, to: corner, tolerance: max(4, 8 / z), minRun: max(10, 20 / z))
        // 接地的接腳在元件上方 20、VDD 的在下方 20：讓接腳剛好落在轉角
        let pos = t.part == .ground ? CGPoint(x: corner.x, y: corner.y + 20) : CGPoint(x: corner.x, y: corner.y - 20)
        func doc(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x + o.x, y: q.y + o.y) }
        return (ref, route.map(doc), t.part, doc(pos))
    }

    /// 把導線（和手繪的 VDD／接地）放進電路圖；點都是文件座標
    private func commitWire(ref endRef: ElementRef?, route: [CGPoint], terminal: (part: CircuitPart, position: CGPoint)? = nil) {
        var comp = terminal.map { CircuitComponent(part: $0.part, position: .zero) }
        let hasWire = route.count >= 2
        if let ref = endRef, var data = circuitInfo(ref)?.data {
            var wire: CircuitWire?
            if hasWire {
                let w = CircuitWire(points: route.map { circuitLocal($0, ref) })
                data.wires.append(w)
                wire = w
            }
            if var c = comp, let t = terminal {
                c.position = CircuitData.snap(circuitLocal(t.position, ref))
                data.components.append(c)
                comp = c
            }
            circuitTarget = ref
            circuitSel = comp.map { .component($0.id) } ?? wire.map { .wire($0.id) }
            updateCircuit(ref, data: data)
        } else {
            // 新的電路圖：起點放在內容座標 (60, 60)
            guard let start = route.first ?? terminal?.position else { return }
            let base = CGPoint(x: start.x - 60, y: start.y - 60)
            func rel(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x - base.x, y: q.y - base.y) }
            var data = CircuitData()
            if hasWire { data.wires = [CircuitWire(points: route.map(rel))] }
            if var c = comp, let t = terminal {
                c.position = rel(t.position)
                data.components = [c]
                comp = c
            }
            circuitTarget = createCircuit(at: start, data: data)
            circuitSel = comp.map { .component($0.id) } ?? data.wires.first.map { .wire($0.id) }
        }
        rebuildSubBar()
    }

    // MARK: 編輯選取的元件

    private func modifySelectedComponent(_ change: (inout CircuitComponent) -> Void) {
        guard let ref = circuitTarget, case let .component(id)? = circuitSel, var data = circuitInfo(ref)?.data,
              let ci = data.components.firstIndex(where: { $0.id == id }) else { return }
        let old = data.components[ci]
        change(&data.components[ci])
        let new = data.components[ci]
        // 記住這種元件的方向、翻轉、輸入數量，之後放的同種元件都照這樣
        circuitPartStyle[new.part] = (new.rotation, new.flipH, new.flipV)
        if new.part.hasVariableInputs { circuitGateInputs[new.part] = new.inputs }
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
        let h = circuitPartHandleCenters()
        overlay.showCircuitPartHandles(rotate: h?.rotate, flip: h?.flip, delete: h?.delete)
        guard tool == .circuit, let ref = circuitTarget, let info = circuitInfo(ref) else {
            overlay.showCircuit(frame: nil, selection: nil)
            return
        }
        let frame = docFrame(of: info.element, pageIndex: info.pi)
        let o = frame.origin
        var sel: UIBezierPath?
        var wirePath: UIBezierPath?
        var handles: UIBezierPath?
        switch circuitSel {
        case let .component(id)?:
            if let c = info.data.components.first(where: { $0.id == id }) {
                sel = UIBezierPath(rect: CircuitGeometry.bounds(c).offsetBy(dx: o.x, dy: o.y).insetBy(dx: -4, dy: -4))
            }
        case let .wire(id)?:
            if let w = info.data.wires.first(where: { $0.id == id }), w.points.count >= 2 {
                let pts = w.points.map { CGPoint(x: $0.x + o.x, y: $0.y + o.y) }
                let path = UIBezierPath()
                path.move(to: pts[0])
                for q in pts.dropFirst() { path.addLine(to: q) }
                wirePath = path
                // 頭尾、轉角畫圓點；每段中間畫小方塊（拖曳整段）
                let h = UIBezierPath()
                let r = 6 / canvas.zoomScale
                for q in pts {
                    h.append(UIBezierPath(ovalIn: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)))
                }
                let m = 4 / canvas.zoomScale
                for i in 0..<(pts.count - 1) where hypot(pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y) > 6 * r {
                    let c = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                    h.append(UIBezierPath(roundedRect: CGRect(x: c.x - m, y: c.y - m, width: 2 * m, height: 2 * m), cornerRadius: m / 3))
                }
                handles = h
            }
        case nil:
            break
        }
        overlay.showCircuit(frame: frame, selection: sel, wire: wirePath, handles: handles)
    }

    // MARK: 工具列

    func buildCircuitRibbon() -> [UIView] {
        var views: [UIView] = []
        circuitLibrary.currentMode = circuitMode
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
        if views.isEmpty {
            views.append(hintLabel("從左邊的元件庫點一下元件連續擺放，或直接拖到頁面上；「接線」模式畫導線"))
        }
        return views
    }

    // MARK: 元件庫

    func selectCircuitMode(_ mode: CircuitMode) {
        circuitMode = mode
        if case let .place(part) = mode {
            circuitSel = nil
            showToast("連續點頁面放置\(part.title)，按「選取」結束")
        }
        rebuildSubBar()
        updateCircuitChrome()
    }

    /// 從元件庫拖到頁面上放開（點是 view 座標）：放好後選起來
    func dropCircuitPart(_ part: CircuitPart, at p: CGPoint) {
        guard canvas.frame.contains(p), !circuitLibrary.frame.contains(p) else { return }
        circuitMode = .select
        placeComponent(part, at: pagesContainer.convert(p, from: view))
    }

    // MARK: 元件旁的旋轉、翻轉小圓鈕

    /// 選取元件時，旋轉與水平翻轉按鈕的位置（文件座標）
    func circuitPartHandleCenters() -> (rotate: CGPoint, flip: CGPoint, delete: CGPoint, radius: CGFloat)? {
        guard tool == .circuit, let ref = circuitTarget, case let .component(id)? = circuitSel,
              let info = circuitInfo(ref), let c = info.data.components.first(where: { $0.id == id }) else { return nil }
        let o = docFrame(of: info.element, pageIndex: info.pi).origin
        let b = CircuitGeometry.bounds(c).offsetBy(dx: o.x, dy: o.y)
        let s = 30 / canvas.zoomScale
        let x = b.maxX + s * 0.9
        return (CGPoint(x: x, y: b.minY + s * 0.3), CGPoint(x: x, y: b.minY + s * 1.5), CGPoint(x: x, y: b.minY + s * 2.7), s * 0.7)
    }

    /// 點到旋轉或翻轉按鈕就處理，回傳 true
    private func handleCircuitPartHandleTap(_ p: CGPoint) -> Bool {
        guard let h = circuitPartHandleCenters() else { return false }
        if p.distance(to: h.rotate) <= h.radius {
            modifySelectedComponent { $0.rotation = ($0.rotation + 90) % 360 }
            return true
        }
        if p.distance(to: h.flip) <= h.radius {
            modifySelectedComponent { $0.flipH.toggle() }
            return true
        }
        if p.distance(to: h.delete) <= h.radius {
            deleteCircuitSelection()
            return true
        }
        return false
    }
}
