import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit

/// 畫線時停住約 0.5 秒：變直線（終點跟著筆尖），或把封閉圖形修成圓、三角形、四邊形。
enum ShapeRecognizer {
    /// 接近水平或垂直時自動拉正
    static func snappedLineEnd(from a: CGPoint, to b: CGPoint) -> CGPoint {
        var b = b
        let deg = abs(atan2(b.y - a.y, b.x - a.x) * 180 / .pi)
        if deg < 6 || deg > 174 { b.y = a.y }
        if abs(deg - 90) < 6 { b.x = a.x }
        return b
    }

    static func segment(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] {
        let n = max(2, Int(a.distance(to: b) / 3))
        return (0...n).map { i in
            let t = CGFloat(i) / CGFloat(n)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    /// 路徑是封閉圖形時回傳修正後的點，否則 nil（當成直線處理）
    static func closedShapePoints(_ input: [CGPoint]) -> [CGPoint]? {
        var pts = input
        guard pts.count >= 6 else { return nil }
        let end = pts[pts.count - 1]
        while pts.count > 6, pts[pts.count - 2].distance(to: end) < 4 { pts.removeLast() }

        var length: CGFloat = 0
        for i in 1..<pts.count { length += pts[i].distance(to: pts[i - 1]) }
        let bbox = boundingBox(pts)
        let span = max(bbox.width, bbox.height)
        guard length > 60, span > 20,
              pts[0].distance(to: pts[pts.count - 1]) < span * 0.3,
              pts[0].distance(to: pts[pts.count - 1]) / length < 0.5 else { return nil }

        let poly = simplifyClosed(pts, epsilon: max(6, hypot(bbox.width, bbox.height) * 0.07))
        if poly.count == 3 { return polygon(poly) }
        if poly.count == 4 { return polygon(axisAlignIfNeeded(poly, bbox: bbox)) }
        return ellipse(in: bbox)
    }

    /// 筆跡接近直線（偏離不大）時回傳拉直後的筆跡，否則 nil
    static func straightenIfNearlyStraight(_ stroke: PKStroke, preset: BrushPreset) -> PKStroke? {
        let pts = stroke.path.map { $0.location.applying(stroke.transform) }
        guard pts.count >= 3, let a = pts.first, let b = pts.last else { return nil }
        let chord = a.distance(to: b)
        guard chord > 30 else { return nil }
        var length: CGFloat = 0
        var maxDev: CGFloat = 0
        for i in pts.indices {
            if i > 0 { length += pts[i].distance(to: pts[i - 1]) }
            maxDev = max(maxDev, perpendicularDistance(pts[i], a, b))
        }
        guard maxDev <= max(4, chord * 0.045), length / chord < 1.08 else { return nil }
        return makeStroke(points: segment(a, snappedLineEnd(from: a, to: b)), ink: stroke.ink,
                          width: preset.width, sample: samplePoint(of: stroke))
    }

    /// 一筆的代表點（粗細排在中間的那一點）；新畫的直線沿用它的粗細、壓力，看起來和手寫的一樣
    static func samplePoint(of stroke: PKStroke) -> PKStrokePoint? {
        let pts = Array(stroke.path)
        guard !pts.isEmpty else { return nil }
        return pts.sorted { $0.size.width < $1.size.width }[pts.count / 2]
    }

    static func makeStroke(points: [CGPoint], preset: BrushPreset, sample: PKStrokePoint? = nil) -> PKStroke {
        makeStroke(points: points, ink: preset.tool.ink, width: preset.width, sample: sample)
    }

    static func makeStroke(points: [CGPoint], ink: PKInk, width: CGFloat, sample: PKStrokePoint?,
                           creationDate: Date = Date()) -> PKStroke {
        let size = sample?.size ?? CGSize(width: width, height: width)
        let strokePoints = points.enumerated().map { i, p in
            strokePoint(p, timeOffset: TimeInterval(i) * 0.005, size: size, like: sample)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: strokePoints, creationDate: creationDate))
    }

    /// iPadOS 18 起筆跡點多了 secondaryScale，用舊的建構方式在新系統上可能畫不出來
    private static func strokePoint(_ p: CGPoint, timeOffset: TimeInterval, size: CGSize, like s: PKStrokePoint?) -> PKStrokePoint {
        let opacity = s?.opacity ?? 1, force = s?.force ?? 1
        let azimuth = s?.azimuth ?? 0, altitude = s?.altitude ?? .pi / 2
        if #available(iOS 18.0, *) {
            return PKStrokePoint(location: p, timeOffset: timeOffset, size: size, opacity: opacity, force: force,
                                 azimuth: azimuth, altitude: altitude, secondaryScale: s?.secondaryScale ?? 1)
        }
        return PKStrokePoint(location: p, timeOffset: timeOffset, size: size, opacity: opacity, force: force,
                             azimuth: azimuth, altitude: altitude)
    }

    // MARK: - Helpers

    private static func boundingBox(_ pts: [CGPoint]) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in pts {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func polygon(_ corners: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for i in 0..<corners.count {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            // 角落重複一個點讓轉角更銳利
            out.append(a)
            out.append(contentsOf: segment(a, b).dropLast())
        }
        out.append(corners[0])
        out.append(corners[0])
        return out
    }

    private static func ellipse(in r: CGRect) -> [CGPoint] {
        let n = 96
        return (0...n).map { i in
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi - .pi / 2
            return CGPoint(x: r.midX + cos(a) * r.width / 2, y: r.midY + sin(a) * r.height / 2)
        }
    }

    private static func axisAlignIfNeeded(_ q: [CGPoint], bbox: CGRect) -> [CGPoint] {
        // 四條邊都接近水平/垂直 → 直接用外框矩形
        for i in 0..<4 {
            let a = q[i], b = q[(i + 1) % 4]
            let deg = abs(atan2(b.y - a.y, b.x - a.x) * 180 / .pi)
            let off = min(deg, abs(deg - 90), abs(180 - deg))
            if off > 12 { return q }
        }
        return [CGPoint(x: bbox.minX, y: bbox.minY), CGPoint(x: bbox.maxX, y: bbox.minY),
                CGPoint(x: bbox.maxX, y: bbox.maxY), CGPoint(x: bbox.minX, y: bbox.maxY)]
    }

    /// 封閉路徑簡化成多邊形的角點
    private static func simplifyClosed(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        // 以離起點最遠的點把路徑切成兩半，各自做 Douglas-Peucker
        var farIndex = 0
        var farDist: CGFloat = 0
        for (i, p) in pts.enumerated() where p.distance(to: pts[0]) > farDist {
            farDist = p.distance(to: pts[0])
            farIndex = i
        }
        guard farIndex > 0 else { return [] }
        let a = douglasPeucker(Array(pts[0...farIndex]), epsilon)
        let b = douglasPeucker(Array(pts[farIndex...]) + [pts[0]], epsilon)
        let corners = Array(a.dropLast()) + Array(b.dropLast())
        // 合併太近的角點
        var merged: [CGPoint] = []
        for c in corners where merged.last.map({ $0.distance(to: c) > epsilon * 1.5 }) ?? true {
            merged.append(c)
        }
        if merged.count > 2, let f = merged.first, let l = merged.last, f.distance(to: l) < epsilon * 1.5 {
            merged.removeLast()
        }
        return merged
    }

    private static func douglasPeucker(_ pts: [CGPoint], _ eps: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        let a = pts[0], b = pts[pts.count - 1]
        var maxD: CGFloat = 0
        var idx = 0
        for i in 1..<(pts.count - 1) {
            let d = perpendicularDistance(pts[i], a, b)
            if d > maxD { maxD = d; idx = i }
        }
        if maxD > eps {
            let left = douglasPeucker(Array(pts[0...idx]), eps)
            let right = douglasPeucker(Array(pts[idx...]), eps)
            return Array(left.dropLast()) + right
        }
        return [a, b]
    }

    private static func perpendicularDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0 else { return p.distance(to: a) }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / len
    }
}

/// 和 PencilKit 同時追蹤筆尖，偵測「停住約 1 秒」。永遠不會辨識成功，所以不會干擾書寫。
final class PencilHoldRecognizer: UIGestureRecognizer {
    var allowFinger = false
    var holdDuration: TimeInterval = 0.5
    weak var coordinateView: UIView?
    /// 停住時呼叫，參數是到目前為止的路徑（coordinateView 座標）
    var onHold: (([CGPoint]) -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onEnd: ((CGPoint, Bool) -> Void)?

    private var tracked: UITouch?
    private var points: [CGPoint] = []
    private var anchor: CGPoint = .zero
    private var timer: Timer?
    private var triggered = false
    private var lastPoint: CGPoint = .zero

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    private func location(_ t: UITouch) -> CGPoint { t.location(in: coordinateView) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil, let t = touches.first else { return }
        guard t.type == .pencil || (allowFinger && t.type == .direct) else { return }
        tracked = t
        triggered = false
        points = [location(t)]
        anchor = t.location(in: nil)
        restartTimer()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        for c in event.coalescedTouches(for: t) ?? [t] { points.append(location(c)) }
        lastPoint = location(t)
        if triggered {
            onMove?(lastPoint)
        } else {
            let p = t.location(in: nil)
            // 筆尖還在移動（超過 6pt）就重新計時；停住時的小晃動不算
            if p.distance(to: anchor) > 6 {
                anchor = p
                restartTimer()
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        finish(at: location(t), cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        finish(at: location(t), cancelled: true)
    }

    private func restartTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: holdDuration, repeats: false) { [weak self] _ in self?.fire() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func fire() {
        guard tracked != nil, !triggered else { return }
        var length: CGFloat = 0
        for i in points.indices.dropFirst() { length += points[i].distance(to: points[i - 1]) }
        guard length > 15 else { return }   // 剛下筆就停住不算
        triggered = true
        onHold?(points)
    }

    private func finish(at p: CGPoint, cancelled: Bool) {
        timer?.invalidate()
        timer = nil
        if triggered { onEnd?(p, cancelled) }
        tracked = nil
        triggered = false
        points = []
        state = .failed
    }

    override func reset() {
        super.reset()
        // 萬一被系統中斷，也要讓編輯器結束預覽、恢復書寫
        if triggered { onEnd?(lastPoint, true) }
        timer?.invalidate()
        timer = nil
        tracked = nil
        triggered = false
        points = []
    }
}

/// 被動追蹤筆尖位置（橡皮擦擦螢光標示用），永遠不會辨識成功，不干擾 PencilKit
final class TouchTracker: UIGestureRecognizer {
    var allowFinger = false
    weak var coordinateView: UIView?
    var onPoint: ((CGPoint) -> Void)?
    var onBegan: ((CGPoint) -> Void)?
    var onEnded: (() -> Void)?
    private var tracked: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil, let t = touches.first else { return }
        guard t.type == .pencil || (allowFinger && t.type == .direct) else { return }
        tracked = t
        onBegan?(t.location(in: coordinateView))
        onPoint?(t.location(in: coordinateView))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        for c in event.coalescedTouches(for: t) ?? [t] { onPoint?(c.location(in: coordinateView)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        tracked = nil
        onEnded?()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        tracked = nil
        onEnded?()
        state = .failed
    }

    override func reset() {
        super.reset()
        if tracked != nil { onEnded?() }
        tracked = nil
    }
}

/// 手掌防誤觸：判定為手掌的觸碰一出現就「辨識成功」，讓畫布的捲動、縮放無法開始。
/// 不攔截 Pencil，也不影響 PencilKit 書寫。
final class PalmBlocker: UIGestureRecognizer {
    var isPalm: ((UITouch) -> Bool)?
    private var palmTouches = Set<UITouch>()
    /// 現在有手掌壓在螢幕上（這時候頁面不能捲動）
    var holdingPalm: Bool { !palmTouches.isEmpty }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    /// 除錯：最近一次手指按下時，螢幕上總共有幾個觸碰（多出來的是沒結束的觸碰）
    private(set) static var lastTouchCount = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        Self.lastTouchCount = event.allTouches?.count ?? 0
        for t in touches {
            if isPalm?(t) == true {
                palmTouches.insert(t)
            } else if palmTouches.isEmpty {
                ignore(t, for: event)
            }
        }
        if !palmTouches.isEmpty && state == .possible { state = .began }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .began || state == .changed { state = .changed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        palmTouches.subtract(touches)
        guard palmTouches.isEmpty else { return }
        state = (state == .began || state == .changed) ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        palmTouches.subtract(touches)
        guard palmTouches.isEmpty else { return }
        state = (state == .began || state == .changed) ? .cancelled : .failed
    }

    override func reset() {
        super.reset()
        palmTouches.removeAll()
    }
}
