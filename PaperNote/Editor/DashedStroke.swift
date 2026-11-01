import PencilKit

/// 把一筆切成虛線：沿著筆跡畫 dash 長、空 gap 長，重複到底。
/// 每一段都沿用原本那一筆的點（粗細、壓力、墨水），看起來和手寫的一樣。
enum DashedStroke {
    static func split(_ stroke: PKStroke, dash: CGFloat, gap: CGFloat) -> [PKStroke] {
        let pts = Array(stroke.path.interpolatedPoints(by: .distance(1)))
        guard pts.count > 1, dash > 0, gap > 0 else { return [stroke] }
        var pieces: [PKStroke] = []
        func emit(_ points: [PKStrokePoint]) {
            guard points.count > 1 else { return }
            pieces.append(PKStroke(ink: stroke.ink, path: PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate),
                                   transform: stroke.transform, mask: stroke.mask, randomSeed: stroke.randomSeed))
        }
        var current = [pts[0]]
        var traveled: CGFloat = 0
        var drawing = true
        for (prev, p) in zip(pts, pts.dropFirst()) {
            traveled += hypot(p.location.x - prev.location.x, p.location.y - prev.location.y)
            if drawing {
                current.append(p)
                if traveled >= dash {
                    emit(current)
                    current = []
                    drawing = false
                    traveled = 0
                }
            } else if traveled >= gap {
                current = [p]
                drawing = true
                traveled = 0
            }
        }
        if drawing { emit(current) }
        return pieces.isEmpty ? [stroke] : pieces
    }

    /// 同一條虛線切出來的每一段有一樣的建立時間和亂數種子
    private struct Key: Hashable {
        var date: Date
        var seed: UInt32
    }
    private static func key(_ s: PKStroke) -> Key { Key(date: s.path.creationDate, seed: s.randomSeed) }

    /// 套索：圈到一段就是整條虛線
    static func wholeDashes(in strokes: [PKStroke], picked: [Int]) -> [Int] {
        let keys = Set(picked.map { key(strokes[$0]) })
        return strokes.indices.filter { keys.contains(key(strokes[$0])) }
    }

    /// 貼上的是另一條：換亂數種子（同一條的每一段換成同一個），之後選取、擦除才不會連原本的一起
    static func copies(of strokes: [PKStroke]) -> [PKStroke] {
        var seeds: [Key: UInt32] = [:]
        return strokes.map { s in
            let seed = seeds[key(s)] ?? UInt32.random(in: .min ... .max)
            seeds[key(s)] = seed
            return PKStroke(ink: s.ink, path: s.path, transform: s.transform, mask: s.mask, randomSeed: seed)
        }
    }

    /// 整筆擦除：PencilKit 的橡皮擦只會擦掉碰到的那幾段。
    /// 比對擦之前的筆跡：有一段不見了，就把同一條的其他段也拿掉
    static func removingErasedDashes(from after: [PKStroke], before: [PKStroke]) -> [PKStroke] {
        var left: [Key: Int] = [:]
        for s in before { left[key(s), default: 0] += 1 }
        for s in after { left[key(s), default: 0] -= 1 }
        let erased = Set(left.filter { $0.value > 0 }.keys)
        return erased.isEmpty ? after : after.filter { !erased.contains(key($0)) }
    }

    /// 依這支筆的設定切；不是虛線就原樣回傳
    static func apply(_ stroke: PKStroke, dashed: Bool, lineWidth: CGFloat, preset: BrushPreset? = nil) -> [PKStroke] {
        guard dashed else { return [stroke] }
        let p = preset?.dashPattern(lineWidth: lineWidth) ?? BrushPreset.defaultDashPattern(lineWidth: lineWidth)
        return split(stroke, dash: p.dash, gap: p.gap)
    }
}
