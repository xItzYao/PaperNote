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

/// 測試用的觸碰（只用到種類、大小、位置）
final class FakeTouch: UITouch {
    private let kind: UITouch.TouchType
    private let radius: CGFloat
    private let point: CGPoint

    init(type: UITouch.TouchType, radius: CGFloat = 10, location: CGPoint = .zero) {
        kind = type
        self.radius = radius
        point = location
        super.init()
    }

    override var type: UITouch.TouchType { kind }
    override var majorRadius: CGFloat { radius }
    override func location(in view: UIView?) -> CGPoint { point }
    override var view: UIView? { nil }
}
