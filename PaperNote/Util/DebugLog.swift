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

    private static var watchdog: Timer?
    private static var lastTick = CACurrentMediaTime()

    /// 主執行緒卡住（畫面停住）超過 150ms 就記下來：頁面捲不動、寫字卡一下時看是不是主執行緒在忙
    static func watchMainThread() {
        guard watchdog == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 0.05, repeats: true) { _ in
            let now = CACurrentMediaTime()
            let gap = now - lastTick
            lastTick = now
            if gap > 0.15 { add("main thread stalled \(Int(gap * 1000))ms") }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    static var text: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let ink = EditorSettings.shared.customInk ? "開" : "關"
        let header = "PaperNote \(version) (\(BuildInfo.commit)) / \(UIDevice.current.systemName) \(UIDevice.current.systemVersion) / 自製筆刷 \(ink)"
        return ([header] + lines).joined(separator: "\n")
    }
}
