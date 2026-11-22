import UIKit

/// 除錯紀錄：手指放開後的縮放（回彈）每一格畫面，頁面和捲動位置畫在哪裡。
/// 回報的問題：放到最大再放大，放開回彈時頁面閃一下（模擬器上做不出來，要看實機的紀錄）
final class ZoomTrace: NSObject {
    private weak var editor: NotebookViewController?
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    /// 開始時畫面中間對到的文件位置：每一格看它實際畫在螢幕的哪裡，跳動就是頁面和捲動沒對上
    private var anchor: CGPoint = .zero
    private var lastLine = ""

    init(editor: NotebookViewController) {
        self.editor = editor
        super.init()
    }

    var isTracing: Bool { link != nil }

    @objc func pinchChanged(_ g: UIPinchGestureRecognizer) {
        guard g.state == .ended || g.state == .cancelled, let e = editor else { return }
        DebugLog.add("zoom: fingers up \(state(e))")
        begin()
    }

    func note(_ s: @autoclosure () -> String) {
        guard isTracing, let e = editor else { return }
        DebugLog.add("zoom: \(s()) \(state(e))")
    }

    func begin() {
        guard let e = editor else { return }
        link?.invalidate()
        let c = e.canvas
        anchor = c.convert(CGPoint(x: c.bounds.midX, y: c.bounds.midY), to: e.pagesContainer)
        start = CACurrentMediaTime()
        lastLine = ""
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func state(_ e: NotebookViewController) -> String {
        let c = e.canvas
        return String(format: "z=%.3f max=%.3f off=%.0f,%.0f anim=%.2f zooming=%d bounce=%d",
                      c.zoomScale, c.maximumZoomScale, c.contentOffset.x, c.contentOffset.y,
                      UIView.inheritedAnimationDuration, c.isZooming ? 1 : 0, c.isZoomBouncing ? 1 : 0)
    }

    @objc private func tick() {
        guard let e = editor else { link?.invalidate(); link = nil; return }
        let t = CACurrentMediaTime() - start
        let canvasLayer = e.canvas.layer.presentation() ?? e.canvas.layer
        let pages = e.pagesContainer.layer.presentation() ?? e.pagesContainer.layer
        let ink = e.inkContainer.layer.presentation() ?? e.inkContainer.layer
        // 文件上的 anchor 在畫布可見範圍裡的位置（畫面座標）：頁面容器的位置、縮放減掉捲動位置
        func onScreen(_ l: CALayer) -> CGPoint {
            let s = l.transform.m11
            let p = CGPoint(x: l.position.x + (anchor.x - l.bounds.midX) * s,
                            y: l.position.y + (anchor.y - l.bounds.midY) * s)
            return CGPoint(x: p.x - canvasLayer.bounds.minX, y: p.y - canvasLayer.bounds.minY)
        }
        let p = onScreen(pages), q = onScreen(ink)
        let page = e.nearestPageIndex(to: anchor)
        let shown = e.pageViews[e.pages[min(page, e.pages.count - 1)].id] != nil
        let keys = (e.pagesContainer.layer.animationKeys() ?? []).joined(separator: ",")
        let line = String(format: "scale=%.3f page=(%.0f,%.0f) ink=(%.0f,%.0f) view=%d",
                          pages.transform.m11, p.x, p.y, q.x, q.y, shown ? 1 : 0) + " keys=\(keys)"
        if line != lastLine {
            DebugLog.add(String(format: "zoom: +%.0fms ", t * 1000) + line)
            lastLine = line
        }
        if t > 0.7 {
            link?.invalidate()
            link = nil
        }
    }
}
