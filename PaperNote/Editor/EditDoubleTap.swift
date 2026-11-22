import UIKit

/// 手指的兩下算不算「點兩下」（螢幕座標、秒）。系統的點兩下容許每一下移動四十幾點、按很久：
/// 用手指寫很短的兩筆、寫字時手靠在螢幕上，都會被當成點兩下
struct FingerTaps {
    static let slop: CGFloat = 10
    static let spread: CGFloat = 30
    static let longest: TimeInterval = 0.35

    private(set) var first: CGPoint?
    private var down: (point: CGPoint, time: TimeInterval)?

    /// 按下。離第一下太遠就不算
    mutating func began(at p: CGPoint, time: TimeInterval) -> Bool {
        if let f = first, f.distance(to: p) > Self.spread { return false }
        if first == nil { first = p }
        down = (p, time)
        return true
    }

    /// 按著的時候移動：移開了就是在寫、在捲動
    func moved(to p: CGPoint) -> Bool {
        guard let d = down else { return true }
        return d.point.distance(to: p) <= Self.slop
    }

    /// 放開：按太久不算點
    func ended(at time: TimeInterval) -> Bool {
        guard let d = down else { return true }
        return time - d.time <= Self.longest
    }
}

/// 點兩下編輯。Pencil 照系統的判斷；手指照 FingerTaps
final class EditDoubleTapRecognizer: UITapGestureRecognizer {
    private var taps = FingerTaps()
    /// 第一下已經按下、還在等結果
    var inProgress: Bool { taps.first != nil }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        numberOfTapsRequired = 2
        // 筆、橡皮擦也開著這個手勢：不能讓畫布晚一點才知道手指放開
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        for t in touches where t.type == .direct && !taps.began(at: t.location(in: nil), time: t.timestamp) {
            state = .failed
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        for t in touches where t.type == .direct && !taps.moved(to: t.location(in: nil)) {
            state = .failed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        // 要在系統認定是點兩下之前判斷
        for t in touches where t.type == .direct && !taps.ended(at: t.timestamp) {
            state = .failed
            return
        }
        super.touchesEnded(touches, with: event)
    }

    override func reset() {
        super.reset()
        taps = FingerTaps()
    }
}
