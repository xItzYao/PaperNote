import XCTest

enum TestWindow {
    /// 接在 App 的 window scene 上的視窗。沒接上的視窗不會真的顯示：CATiledLayer 不會畫、截圖是空白，
    /// 只在畫面上才會出現的問題（例如兩層筆跡疊在一起）就測不出來
    static func make() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "測試需要 App 的 window scene")
        let w = UIWindow(windowScene: scene)
        w.frame = scene.coordinateSpace.bounds
        return w
    }
}
