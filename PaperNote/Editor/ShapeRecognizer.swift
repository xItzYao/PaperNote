import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit

/// 筆跡的幾何處理：螢光筆拉直、用程式建立筆跡。
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

    private static func perpendicularDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0 else { return p.distance(to: a) }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / len
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

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
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
