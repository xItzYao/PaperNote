import XCTest
@testable import PaperNote

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

/// 測試用的拖曳：位置、已移動的距離可以設定（真的拖曳要移動一小段才開始，開始時位置已經離開按下的點）
final class TouchPan: UIPanGestureRecognizer {
    var fake: UIGestureRecognizer.State = .possible
    var point: CGPoint = .zero
    var moved: CGPoint = .zero
    override var state: UIGestureRecognizer.State {
        get { fake }
        set { fake = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { point }
    override func translation(in view: UIView?) -> CGPoint { moved }

    convenience init() { self.init(target: nil, action: nil) }

    /// 從 start 拖到 end：一開始就已經移動了 slop（還沒到 slop 手勢不會開始）
    func drag(from start: CGPoint, to end: CGPoint, slop: CGPoint = .zero, steps: Int = 3, _ handle: (TouchPan) -> Void) {
        for i in 0...steps {
            let k = CGFloat(i) / CGFloat(steps)
            moved = i == 0 ? slop : CGPoint(x: (end.x - start.x) * k, y: (end.y - start.y) * k)
            point = CGPoint(x: start.x + moved.x, y: start.y + moved.y)
            fake = i == 0 ? .began : (i == steps ? .ended : .changed)
            handle(self)
        }
    }
}

/// 測 PencilKit 筆的測試用：body 執行期間把「筆」切回 PencilKit，結束後還原（App 預設用自製筆刷）
func withPencilKitPen(_ body: () -> Void) {
    let before = EditorSettings.shared.customInk
    EditorSettings.shared.customInk = false
    defer { EditorSettings.shared.customInk = before }
    body()
}
