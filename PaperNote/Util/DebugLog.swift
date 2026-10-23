import UIKit

/// 除錯紀錄：記下最近幾百個事件（例如停住變直線每一步的順序與結果），
/// 使用者可以從「⋯ → 拷貝除錯紀錄」拷貝出來回報問題。只在記憶體裡，關掉 App 就清掉。
enum DebugLog {
    private static var lines: [String] = []
    private static let start = CACurrentMediaTime()

    static func add(_ s: @autoclosure () -> String) {
        let t = String(format: "%7.3f", CACurrentMediaTime() - start)
        lines.append("\(t) \(s())")
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    }

    static var text: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let header = "PaperNote \(version) / \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        return ([header] + lines).joined(separator: "\n")
    }
}
