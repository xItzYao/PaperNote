import PencilKit

/// PencilKit 筆跡點的 size 和實際畫出來的線寬不一樣（實測見 PencilKitInkStudy）：
/// pen、monoline（螢光筆也是）寬 2·size − 4；沾水筆斜的筆頭長的那邊 2·(size − 2)；
/// 舊筆記的 marker 是斜的筆頭，長的那邊約 1.1·size；鉛筆 1.45·size、蠟筆 1.25·size、水彩 1.6·size。
/// 所以沾水筆 size 1.5、原子筆 size 2 這種點完全畫不出來。自己做的筆跡（圖形、預覽圖）要從想要的線寬換回 size
enum PencilKitInkWidth {
    /// 這個 size 畫出來多寬（斜的筆頭算長的那邊）
    static func drawn(_ type: PKInk.InkType, size s: CGFloat) -> CGFloat {
        switch type {
        case .pen, .monoline: return max(0, 2 * s - 4)
        case .fountainPen: return max(0, 2 * (s - 2))
        case .marker: return 1.1 * s
        case .pencil: return 1.45 * s
        case .crayon: return 1.25 * s
        case .watercolor: return 1.6 * s
        default: return s
        }
    }

    /// 要畫出 w 寬，點的 size 要多大（drawn 的反過來）
    static func pointSize(_ type: PKInk.InkType, drawn w: CGFloat) -> CGFloat {
        switch type {
        case .pen, .monoline: return (w + 4) / 2
        case .fountainPen: return w / 2 + 2
        case .marker: return w / 1.1
        case .pencil: return w / 1.45
        case .crayon: return w / 1.25
        case .watercolor: return w / 1.6
        default: return w
        }
    }
}
