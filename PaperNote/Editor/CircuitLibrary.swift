import UIKit

/// 電路元件庫（像 Visio 的圖庫）：選電路工具時浮在頁面左邊。
/// 點一下元件就連續擺放；或直接把元件往右拖到頁面上放開。可以收合成一個小把手。
final class CircuitLibraryView: UIView, UIGestureRecognizerDelegate {
    /// 點了「選取」「接線」或某個元件
    var onSelectMode: ((CircuitMode) -> Void)?
    /// 元件拖到頁面上放開（點是在 superview 的座標）
    var onDrop: ((CircuitPart, CGPoint) -> Void)?
    var currentMode: CircuitMode = .select { didSet { refreshHighlight() } }

    private static let sections: [(String, [CircuitPart])] = [
        ("被動元件", [.resistor, .capacitor, .inductor]),
        ("電源", [.voltageSource, .currentSource, .ground, .vdd]),
        ("電晶體", [.nmos, .pmos]),
        ("邏輯閘", [.andGate, .orGate, .notGate, .bufferGate, .nandGate, .norGate, .xorGate, .xnorGate]),
        ("其他", [.dFlipFlop, .dLatch, .mux, .decoder, .encoder, .alu]),
    ]
    /// 收起來的分類（記在本機）
    private static let collapsedKey = "circuitLibrary.collapsedSections"
    private static let expandedWidth: CGFloat = 148
    private static let collapsedWidth: CGFloat = 40

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let collapseButton = UIButton(configuration: .plain())
    private var widthConstraint: NSLayoutConstraint!
    private var collapsedHeight: NSLayoutConstraint!
    private var collapsed = false
    private var modeButtons: [(CircuitMode, UIButton)] = []
    private var ghost: UIImageView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        layer.cornerRadius = 12
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: Self.expandedWidth)
        widthConstraint.isActive = true
        collapsedHeight = heightAnchor.constraint(equalToConstant: 42)

        // 標題列：元件庫＋收合
        let title = UILabel()
        title.text = "元件庫"
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabel
        collapseButton.configuration?.image = UIImage(systemName: "sidebar.left")
        collapseButton.accessibilityLabel = "收合元件庫"
        collapseButton.addAction(UIAction { [weak self] _ in self?.toggleCollapsed() }, for: .touchUpInside)
        let header = UIStackView(arrangedSubviews: [title, UIView(), collapseButton])
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = false
        addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            header.heightAnchor.constraint(equalToConstant: 34),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -6),
        ])
        // 內容不高時，面板就縮到內容高度
        // 優先權要低於內容的抗壓縮：高度不夠時讓元件庫捲動，而不是把分類標題擠扁
        let fit = heightAnchor.constraint(equalTo: stack.heightAnchor, constant: 44)
        fit.priority = .defaultLow
        fit.isActive = true

        // 選取、接線
        let modes = row([modeButton("cursorarrow", "選取", .select), modeButton("line.diagonal", "接線", .wire)])
        stack.addArrangedSubview(modes)
        // 各分類：標題列可以點開、收起，元件兩欄
        let collapsedNames = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? [])
        for (name, parts) in Self.sections {
            let body = UIStackView()
            body.axis = .vertical
            body.spacing = 4
            var i = 0
            while i < parts.count {
                let pair = parts[i..<min(i + 2, parts.count)].map(partButton)
                body.addArrangedSubview(row(pair.count == 2 ? pair : pair + [UIView()]))
                i += 2
            }
            body.isHidden = collapsedNames.contains(name)
            // 動畫中途內容不要畫到下面的分類上
            body.clipsToBounds = true
            stack.addArrangedSubview(sectionHeader(name, body: body))
            stack.addArrangedSubview(body)
        }
        refreshHighlight()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 按鈕

    private func row(_ views: [UIView]) -> UIStackView {
        let r = UIStackView(arrangedSubviews: views)
        r.distribution = .fillEqually
        r.spacing = 4
        return r
    }

    /// 分類標題列：點一下展開或收起底下的元件
    private func sectionHeader(_ name: String, body: UIView) -> UIButton {
        var c = UIButton.Configuration.plain()
        c.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 4, bottom: 4, trailing: 4)
        c.baseForegroundColor = .tertiaryLabel
        let b = UIButton(configuration: c)
        b.contentHorizontalAlignment = .leading
        b.setContentCompressionResistancePriority(.required, for: .vertical)
        func refresh(_ collapsed: Bool) {
            var cfg = b.configuration ?? .plain()
            var t = AttributedString(name)
            t.font = .systemFont(ofSize: 11, weight: .semibold)
            cfg.attributedTitle = t
            cfg.image = UIImage(systemName: collapsed ? "chevron.right" : "chevron.down",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            cfg.imagePlacement = .trailing
            cfg.imagePadding = 6
            b.configuration = cfg
        }
        refresh(body.isHidden)
        b.addAction(UIAction { [weak self, weak body] _ in
            guard let body else { return }
            let collapse = !body.isHidden
            refresh(collapse)
            let host = self?.stack
            if collapse {
                // 收起：元件先淡出，再把下面的分類往上收
                UIView.animate(withDuration: 0.12, animations: { body.alpha = 0 }) { _ in
                    UIView.animate(withDuration: 0.2) {
                        body.isHidden = true
                        host?.layoutIfNeeded()
                    }
                }
            } else {
                // 展開：先撐開空間，再讓元件淡入
                body.alpha = 0
                UIView.animate(withDuration: 0.2, animations: {
                    body.isHidden = false
                    host?.layoutIfNeeded()
                }) { _ in
                    UIView.animate(withDuration: 0.12) { body.alpha = 1 }
                }
            }
            var collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? [])
            if collapse { collapsed.insert(name) } else { collapsed.remove(name) }
            UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedKey)
        }, for: .touchUpInside)
        return b
    }

    private func tile(image: UIImage?, title: String) -> UIButton {
        var c = UIButton.Configuration.plain()
        c.image = image
        c.imagePlacement = .top
        c.imagePadding = 2
        var t = AttributedString(title)
        t.font = .systemFont(ofSize: 10)
        c.attributedTitle = t
        c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 2, bottom: 4, trailing: 2)
        c.background.cornerRadius = 8
        let b = UIButton(configuration: c)
        b.accessibilityLabel = title
        b.heightAnchor.constraint(equalToConstant: 56).isActive = true
        return b
    }

    private func modeButton(_ symbol: String, _ title: String, _ mode: CircuitMode) -> UIButton {
        let b = tile(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18)), title: title)
        b.addAction(UIAction { [weak self] _ in self?.onSelectMode?(mode) }, for: .touchUpInside)
        modeButtons.append((mode, b))
        return b
    }

    private func partButton(_ part: CircuitPart) -> UIButton {
        let b = tile(image: CircuitRenderer.icon(part, size: 28), title: part.title)
        b.addAction(UIAction { [weak self] _ in self?.onSelectMode?(.place(part)) }, for: .touchUpInside)
        // 往右拖：把元件拖到頁面上
        let drag = PartDragGesture(target: self, action: #selector(dragPart(_:)))
        drag.part = part
        drag.delegate = self
        b.addGestureRecognizer(drag)
        modeButtons.append((.place(part), b))
        return b
    }

    private func refreshHighlight() {
        for (mode, b) in modeButtons {
            var c = b.configuration ?? .plain()
            let on = mode == currentMode
            c.baseForegroundColor = on ? .systemBlue : .label
            c.background.backgroundColor = on ? UIColor.systemBlue.withAlphaComponent(0.15) : .clear
            b.configuration = c
        }
    }

    private func toggleCollapsed() {
        collapsed.toggle()
        scroll.isHidden = collapsed
        collapseButton.configuration?.image = UIImage(systemName: collapsed ? "sidebar.right" : "sidebar.left")
        collapseButton.accessibilityLabel = collapsed ? "展開元件庫" : "收合元件庫"
        (collapseButton.superview as? UIStackView)?.arrangedSubviews.first?.isHidden = collapsed
        widthConstraint.constant = collapsed ? Self.collapsedWidth : Self.expandedWidth
        collapsedHeight.isActive = collapsed
        UIView.animate(withDuration: 0.2) { self.superview?.layoutIfNeeded() }
    }

    // MARK: 拖到頁面上

    /// 往右拖才算拖元件；上下滑是捲動元件庫
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? PartDragGesture else { return super.gestureRecognizerShouldBegin(g) }
        let v = pan.velocity(in: self)
        return v.x > abs(v.y)
    }

    @objc private func dragPart(_ g: PartDragGesture) {
        guard let host = superview, let part = g.part else { return }
        let p = g.location(in: host)
        switch g.state {
        case .began:
            let iv = UIImageView(image: CircuitRenderer.icon(part, size: 44))
            iv.tintColor = .systemBlue
            iv.alpha = 0.85
            iv.frame.size = CGSize(width: 44, height: 44)
            iv.center = p
            host.addSubview(iv)
            ghost = iv
        case .changed:
            ghost?.center = p
        case .ended:
            ghost?.removeFromSuperview()
            ghost = nil
            // 放在元件庫上就不算
            if !frame.contains(p) { onDrop?(part, p) }
        default:
            ghost?.removeFromSuperview()
            ghost = nil
        }
    }
}

/// 帶著元件種類的拖曳手勢
final class PartDragGesture: UIPanGestureRecognizer {
    var part: CircuitPart?
}
