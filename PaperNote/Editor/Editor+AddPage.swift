import UIKit

/// 捲到最後一頁底下再往上拉：出現＋，拉夠了放開就問要新增哪種頁面
final class AddPagePullView: UIView {
    private let icon = UIImageView(image: UIImage(systemName: "plus.circle.fill"))
    let label = UILabel()
    /// 拉夠了（放開就會問要新增哪種頁面）
    private(set) var armed = false

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

    /// progress：拉的距離 ÷ 門檻
    func update(progress: CGFloat) {
        let nowArmed = progress >= 1
        if nowArmed && !armed { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        armed = nowArmed
        alpha = min(1, max(0, progress))
        icon.transform = CGAffineTransform(rotationAngle: min(progress, 1) * .pi / 2)
        label.text = armed ? "放開新增頁面" : "繼續往上拉，新增頁面"
    }
}

extension NotebookViewController {
    /// 拉多遠（螢幕點）放開才問要新增頁面
    static let addPagePullThreshold: CGFloat = 80

    /// 拉過最後一頁底部多少（螢幕點）；沒有拉過是 0 或負的
    var bottomOverscroll: CGFloat {
        let inset = canvas.adjustedContentInset
        let maxY = max(canvas.contentSize.height + inset.bottom - canvas.bounds.height, -inset.top)
        return canvas.contentOffset.y - maxY
    }

    /// 捲動時更新底下的＋（放在拉出來的空白中間）
    func updateAddPagePull() {
        let over = bottomOverscroll
        guard over > 1, !pages.isEmpty else {
            addPagePull.isHidden = true
            addPagePull.update(progress: 0)
            return
        }
        if addPagePull.superview !== canvas { canvas.addSubview(addPagePull) }
        addPagePull.isHidden = false
        addPagePull.update(progress: over / Self.addPagePullThreshold)
        let bottom = canvas.contentOffset.y + canvas.bounds.height - canvas.adjustedContentInset.bottom
        addPagePull.center = CGPoint(x: canvas.contentOffset.x + canvas.bounds.width / 2, y: bottom - over / 2)
    }

    /// 手指放開：拉夠了就問要新增哪種頁面
    func addPagePullEnded() {
        let armed = addPagePull.armed && !addPagePull.isHidden
        guard armed else { return }
        addPagePull.update(progress: 0)
        presentAddPageMenu()
    }

    func presentAddPageMenu() {
        guard let last = pageFrames.last else { return }
        let actions = PaperStyle.allCases.map { style in
            UIAction(title: style.title, image: UIImage(systemName: Self.paperSymbol(style))) { [weak self] _ in
                self?.appendPage(style: style)
            }
        }
        let menu = UIMenu(title: "新增頁面", children: actions)
        presentMenu(menu, atDocPoint: CGPoint(x: last.midX, y: last.maxY))
    }

    static func paperSymbol(_ style: PaperStyle) -> String {
        switch style {
        case .blank: return "doc"
        case .ruled: return "line.3.horizontal"
        case .grid: return "squareshape.split.3x3"
        case .dotted: return "circle.grid.3x3"
        }
    }

    /// 在最後面加一頁（大小和最後一頁一樣）
    func appendPage(style: PaperStyle) {
        guard let ref = pages.last else { return }
        let size = session.baseSize(of: ref)
        let newPage = Page(background: .paper(width: size.width, height: size.height, style: style))
        let index = pages.count
        performLayoutChange {
            session.document.pages.insert(newPage, at: index)
        }
        scrollToPage(index, animated: true)
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
