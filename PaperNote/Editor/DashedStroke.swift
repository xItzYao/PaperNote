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

    /// 依這支筆的設定切；不是虛線就原樣回傳
    static func apply(_ stroke: PKStroke, dashed: Bool, lineWidth: CGFloat) -> [PKStroke] {
        guard dashed else { return [stroke] }
        let p = BrushPreset.dashPattern(lineWidth: lineWidth)
        return split(stroke, dash: p.dash, gap: p.gap)
    }
}
