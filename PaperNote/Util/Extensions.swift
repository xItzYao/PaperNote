import UIKit

extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xFF) / 255
            g = CGFloat((v >> 16) & 0xFF) / 255
            b = CGFloat((v >> 8) & 0xFF) / 255
            a = CGFloat(v & 0xFF) / 255
        } else {
            r = CGFloat((v >> 16) & 0xFF) / 255
            g = CGFloat((v >> 8) & 0xFF) / 255
            b = CGFloat(v & 0xFF) / 255
            a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let c = resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        if !c.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var w: CGFloat = 0
            c.getWhite(&w, alpha: &a)
            r = w; g = w; b = w
        }
        func clamp(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", clamp(r), clamp(g), clamp(b), clamp(a))
    }

    /// 與白色混合，用來做在文字底下的螢光色
    func lightened(_ amount: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r + (1 - r) * amount, green: g + (1 - g) * amount, blue: b + (1 - b) * amount, alpha: 1)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension UIScrollView {
    /// 還在慣性捲動就停在目前的位置
    func stopMomentum() {
        guard isDecelerating else { return }
        setContentOffset(contentOffset, animated: false)
    }
}

extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

enum Palette {
    static let covers = ["#2654A0FF", "#2E7D5BFF", "#B5523BFF", "#6A4C93FF", "#C08A1EFF", "#3A6073FF", "#8E3B5FFF", "#4A4A4AFF"]
    static let highlights: [(name: String, hex: String)] = [
        ("黃色", "#FFF176FF"), ("綠色", "#B9F6CAFF"), ("粉紅", "#F8BBD0FF"), ("藍色", "#B3E5FCFF"), ("橘色", "#FFCC80FF"),
    ]
}

extension UIViewController {
    func showMessage(_ title: String, _ message: String? = nil) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }
}
