import XCTest

/// App Store 的截圖（13 吋 iPad、直式）。只有 screenshots 工作流程會跑（設了 PAPERNOTE_SCREENSHOTS），平常的測試直接略過。
/// 示範筆記在 App 裡建（ScreenshotDemo，只在 Debug 版）：每一張重開一次 App，擺好場景才截
final class AppStoreScreenshotUITests: XCTestCase {
    static let scenes = ["notes", "pdf", "circuit", "pin", "extend", "table", "library"]

    func testAppStoreScreenshots() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["PAPERNOTE_SCREENSHOTS"] == "1" else { throw XCTSkip("只在 App Store 截圖的工作流程跑") }
        continueAfterFailure = true
        let out = env["SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let out { try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        let langs = (env["SCREENSHOT_LANGS"].flatMap { $0.isEmpty ? nil : $0 } ?? "zh-Hant,en").split(separator: ",").map(String.init)
        let wanted = env["SCREENSHOT_SCENES"].flatMap { $0.isEmpty ? nil : $0 }.map { $0.split(separator: ",").map(String.init) } ?? Self.scenes
        XCUIDevice.shared.orientation = .portrait
        for lang in langs {
            for (i, scene) in Self.scenes.enumerated() where wanted.contains(scene) {
                let app = XCUIApplication()
                app.launchArguments = ["-appLanguage", lang, "-screenshotDemo", "-screenshotScene", scene,
                                       "-library.viewMode", "grid", "-fingerDrawing", "<false/>"]
                app.launch()
                let ready = app.descendants(matching: .any)["screenshotReady"].waitForExistence(timeout: 45)
                XCTAssertTrue(ready, "\(lang) \(scene)：場景沒有擺好（照樣截一張看看）")
                let name = "\(lang)-\(i + 1)-\(scene)"
                let shot = XCUIScreen.main.screenshot()
                let a = XCTAttachment(screenshot: shot)
                a.name = name
                a.lifetime = .keepAlways
                add(a)
                if let out { try? shot.pngRepresentation.write(to: out.appendingPathComponent(name + ".png")) }
                app.terminate()
            }
        }
    }
}
