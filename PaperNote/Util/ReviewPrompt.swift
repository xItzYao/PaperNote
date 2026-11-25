import Foundation

/// 第二次打開 App 時請使用者到 App Store 寫評論（只問一次；系統一年最多也只會顯示三次）
enum ReviewPrompt {
    static let launchesKey = "review.launches"
    static let askedKey = "review.asked"

    /// 每次打開 App 呼叫一次：記下開了幾次，該問的那一次回傳 true（之後不會再回傳 true）
    static func recordLaunch(_ defaults: UserDefaults = .standard) -> Bool {
        let launches = defaults.integer(forKey: launchesKey) + 1
        defaults.set(launches, forKey: launchesKey)
        guard launches >= 2, !defaults.bool(forKey: askedKey) else { return false }
        defaults.set(true, forKey: askedKey)
        return true
    }

    /// 測試（單元測試、UI 測試、截圖）跑起來的 App 不問，不然視窗會擋住測試
    static var isTestRun: Bool {
        let info = ProcessInfo.processInfo
        return info.environment["XCTestConfigurationFilePath"] != nil || info.arguments.contains("-appLanguage")
    }
}
