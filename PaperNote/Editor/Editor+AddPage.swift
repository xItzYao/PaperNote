import UIKit

/// 捲到最後一頁底下再往上拉放開會怎樣
enum AddPagePullStage: Equatable {
    case none
    /// 新增一張和最後一頁一樣大的空白紙
    case blankPage
    /// 跳出選紙張的小視窗
    case paperPicker
}

/// 捲到最後一頁底下再往上拉：出現＋，拉夠了放開就加一張空白紙，再拉遠一點放開才跳出選紙張的小視窗
final class AddPagePullView: UIView {
    private let icon = UIImageView(image: UIImage(systemName: "plus.circle.fill"))
    let label = UILabel()
    private(set) var stage = AddPagePullStage.none

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 220, height: 64))
        isUserInteractionEnabled = false
        icon.tintColor = .systemBlue
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        icon.contentMode = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.spacing = 4
        stack.alignment = .center
        stack.frame = bounds
        stack.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(stack)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// over：拉過最後一頁底部多少（螢幕點）
    func update(over: CGFloat) {
        let progress = over / NotebookViewController.addPagePullThreshold
        let now: AddPagePullStage = over >= NotebookViewController.addPagePullMenuThreshold ? .paperPicker : progress >= 1 ? .blankPage : .none
        if now != stage && now != .none { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        stage = now
        alpha = min(1, max(0, progress))
        icon.transform = CGAffineTransform(rotationAngle: min(progress, 1) * .pi / 2)
        switch stage {
        case .none: label.text = L("繼續往上拉，新增頁面")
        case .blankPage: label.text = L("放開新增空白頁，再拉選紙張")
        case .paperPicker: label.text = L("放開選紙張")
        }
    }
}

extension NotebookViewController {
    /// 拉多遠（螢幕點）放開才新增空白頁
    static let addPagePullThreshold: CGFloat = 80
    /// 拉多遠（螢幕點）放開才問要新增哪種頁面
    static let addPagePullMenuThreshold: CGFloat = 150

    /// 拉過最後一頁底部多少（螢幕點）；沒有拉過是 0 或負的
    var bottomOverscroll: CGFloat {
        let inset = canvas.adjustedContentInset
        let maxY = max(canvas.contentSize.height + inset.bottom - canvas.bounds.height, -inset.top)
        return canvas.contentOffset.y - maxY
    }

    /// 捲動時更新底下的＋（放在拉出來的空白中間）
    func updateAddPagePull() {
        let over = bottomOverscroll
        // 擴展頁面時拉到底是要拉控制點，不是新增頁面；預覽模式不新增頁面
        guard over > 1, !pages.isEmpty, tool != .pageResize, !previewMode else {
            addPagePull.isHidden = true
            addPagePull.update(over: 0)
            return
        }
        if addPagePull.superview !== canvas { canvas.addSubview(addPagePull) }
        addPagePull.isHidden = false
        addPagePull.update(over: over)
        let bottom = canvas.contentOffset.y + canvas.bounds.height - canvas.adjustedContentInset.bottom
        addPagePull.center = CGPoint(x: canvas.contentOffset.x + canvas.bounds.width / 2, y: bottom - over / 2)
    }

    /// 手指放開：看拉多遠，加一張空白紙或問要新增哪種頁面。
    /// 在 scrollViewWillEndDragging 裡呼叫（target 是放開後捲動畫面要停的位置）：這時候捲動畫面還沒決定怎麼動。
    /// 拉過頭放開，捲動畫面本來會彈回舊的底部；到 didEndDragging 才加頁、開始捲到新頁的話，
    /// 回彈也已經排好了，兩段動畫一起跑，畫面會先往下、跳回來、再往下捲。
    /// 所以加完頁先叫它停在原地（不回彈），等放開的處理都做完了才捲到新的一頁：只有一段捲動
    func addPagePullEnded(target: UnsafeMutablePointer<CGPoint>?) {
        let stage = addPagePull.isHidden ? .none : addPagePull.stage
        addPagePull.update(over: 0)
        switch stage {
        case .none: break
        case .blankPage:
            guard let i = addBlankPageAtEnd(scroll: false) else { break }
            target?.pointee = canvas.contentOffset
            DispatchQueue.main.async { [weak self] in self?.scrollToPage(i, animated: true) }
        case .paperPicker: presentAddPageMenu()
        }
    }

    /// 加在最後面：大小、方向和最後一頁一樣的空白紙。回傳新的那一頁
    @discardableResult
    func addBlankPageAtEnd(scroll: Bool = true) -> Int? {
        guard let last = pages.last else { return nil }
        let size = session.baseSize(of: last)
        insertPage(at: pages.count, style: .blank, landscape: size.width > size.height, scroll: scroll)
        return pages.count - 1
    }

    /// 拉過最後一頁放開：中間跳出選紙張的小視窗，選好加在最後面
    func presentAddPageMenu() {
        presentPaperPicker(title: L("新增頁面"), insertAt: pages.count)
    }
}

// MARK: - 不超出頁面

extension NotebookViewController {
    /// 把 r（文件座標）推回它所在的那一頁裡面（中心所在的頁；比頁面大時對齊左上）
    func clampToPage(_ r: CGRect) -> CGRect {
        guard !pageFrames.isEmpty else { return r }
        let c = CGPoint(x: r.midX, y: r.midY)
        let f = pageFrames[pageIndex(containing: c) ?? nearestPageIndex(to: c)]
        var out = r
        out.origin.x = max(f.minX, min(r.minX, f.maxX - r.width))
        out.origin.y = max(f.minY, min(r.minY, f.maxY - r.height))
        return out
    }

    /// 拖曳 rect 時的位移，改成不會讓它超出頁面的位移
    func clampedDelta(moving r: CGRect, by d: CGPoint) -> CGPoint {
        let moved = clampToPage(r.offsetBy(dx: d.x, dy: d.y))
        return CGPoint(x: moved.minX - r.minX, y: moved.minY - r.minY)
    }
}
