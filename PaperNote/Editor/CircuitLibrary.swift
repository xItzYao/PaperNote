import UIKit

/// 電路元件庫（像 Visio 的圖庫）：選電路工具時浮在頁面下面（橫的兩列），「⋯」可以改放左邊（直的兩欄）。
/// 點一下元件就擺放（「⋯」的「連續放置元件」決定放完要不要繼續放）；或直接把元件往頁面拖（下面的往上、左邊的往右）放開。可以收合成一個小把手。
final class CircuitLibraryView: UIView, UIGestureRecognizerDelegate {
    /// 點了某個元件（「選取」「接線」在第二列工具列）
    var onSelectMode: ((CircuitMode) -> Void)?
    /// 元件拖到頁面上放開（點是在 superview 的座標）
    var onDrop: ((CircuitPart, CGPoint) -> Void)?
    /// 自訂電路：拖到頁面上、加入、改名（長按）、刪除（長按）
    var onDropCustom: ((UUID, CGPoint) -> Void)?
    var onAddCustom: (() -> Void)?
    /// 畫自訂元件（id：改元件庫裡已經有的）
    var onDrawSymbol: ((UUID?) -> Void)?
    var onRenameCustom: ((UUID) -> Void)?
    var onDeleteCustom: ((UUID) -> Void)?
    var currentMode: CircuitMode = .select { didSet { refreshHighlight() } }

    /// 分類參考 CircuiTikZ
    static let sections: [(String, [CircuitPart])] = [
        ("被動元件", [.resistor, .capacitor, .inductor, .potentiometer, .variableResistor, .polarCapacitor, .variableCapacitor, .transformer, .fuse]),
        ("接地、電源", [.ground, .vdd, .vss, .signalGround, .chassisGround]),
        ("訊號源", [.voltageSource, .currentSource, .battery, .sineSource, .squareSource, .controlledVoltageSource, .controlledCurrentSource]),
        ("二極體", [.diode, .schottky, .zener, .tunnelDiode, .led, .photodiode, .varicap]),
        ("電晶體", [.nmos, .pmos, .nmos4, .pmos4, .npn, .pnp, .njfet, .pjfet, .nigbt, .pigbt]),
        ("放大器", [.opAmp, .fdOpAmp, .ota]),
        ("開關、儀表", [.switchOpen, .switchClosed, .pushButton, .spdt, .ammeter, .voltmeter, .ohmmeter, .lamp]),
        ("邏輯閘", [.andGate, .orGate, .notGate, .bufferGate, .nandGate, .norGate, .xorGate, .xnorGate]),
        ("數位方塊", [.dFlipFlop, .dLatch, .mux, .decoder, .encoder, .alu, .adc, .dac]),
        ("其他", [.mixer, .antenna]),
    ]
    static let customSectionName = "自訂電路圖"
    /// 收起來的分類（記在本機）
    private static let collapsedKey = "circuitLibrary.collapsedSections"
    private static let expandedWidth: CGFloat = 148
    private static let collapsedWidth: CGFloat = 40
    /// 放下面時的高度：分類標題＋兩列元件
    private static let bottomHeight: CGFloat = 146
    private static let bottomTileWidth: CGFloat = 66
    private static let bottomMargin: CGFloat = 10

    /// 放下面時蓋住頁面多高：頁面要能多捲這麼多，最下面才不會被擋住
    var bottomOverlap: CGFloat {
        onLeft || collapsed ? 0 : Self.bottomHeight + Self.bottomMargin + (superview?.safeAreaInsets.bottom ?? 0)
    }
    var onLayoutChange: (() -> Void)?
    private(set) var onLeft = false
    /// 目前看得到的元件按鈕
    var visibleTiles: [UIButton] {
        let tiles = modeButtons.map { $0.1 }
        return tiles.filter { $0.isDescendant(of: onLeft ? scroll : bottomScroll) }
    }

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let bottomScroll = UIScrollView()
    private let bottomStack = UIStackView()
    private let header = UIStackView()
    private let titleLabel = UILabel()
    private let collapseButton = UIButton(configuration: .plain())
    private var topInHost: NSLayoutYAxisAnchor?
    private var placement: [NSLayoutConstraint] = []
    private var collapsed = false
    private var modeButtons: [(CircuitMode, UIButton)] = []
    private var ghost: UIImageView?
    /// 自訂電路圖那一區（放左邊、放下面各一份），內容會變
    private let customBody = UIStackView()
    private let customColumns = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        layer.cornerRadius = 12
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        translatesAutoresizingMaskIntoConstraints = false

        // 標題列：元件庫＋收合
        titleLabel.text = "元件庫"
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabel
        collapseButton.addAction(UIAction { [weak self] _ in self?.toggleCollapsed() }, for: .touchUpInside)
        for v in [titleLabel, UIView(), collapseButton] { header.addArrangedSubview(v) }
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

        bottomScroll.translatesAutoresizingMaskIntoConstraints = false
        bottomScroll.showsHorizontalScrollIndicator = false
        addSubview(bottomScroll)
        bottomStack.axis = .horizontal
        bottomStack.spacing = 12
        bottomStack.alignment = .top
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        bottomScroll.addSubview(bottomStack)

        NSLayoutConstraint.activate([
            bottomStack.topAnchor.constraint(equalTo: bottomScroll.contentLayoutGuide.topAnchor, constant: 6),
            bottomStack.bottomAnchor.constraint(equalTo: bottomScroll.contentLayoutGuide.bottomAnchor, constant: -6),
            bottomStack.leadingAnchor.constraint(equalTo: bottomScroll.contentLayoutGuide.leadingAnchor, constant: 10),
            bottomStack.trailingAnchor.constraint(equalTo: bottomScroll.contentLayoutGuide.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -6),
        ])
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
            bottomStack.addArrangedSubview(bottomSection(name, parts))
        }
        // 自訂電路圖：排在最後
        customBody.axis = .vertical
        customBody.spacing = 4
        customBody.clipsToBounds = true
        customBody.isHidden = collapsedNames.contains(Self.customSectionName)
        stack.addArrangedSubview(sectionHeader(Self.customSectionName, body: customBody))
        stack.addArrangedSubview(customBody)
        bottomStack.addArrangedSubview(bottomSection(Self.customSectionName, columns: customColumns))
        reloadCustomCircuits()
        NotificationCenter.default.addObserver(self, selector: #selector(customCircuitsChanged), name: .customCircuitsChanged, object: nil)
        refreshChrome()
        refreshHighlight()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 位置

    /// 加進 host 之後呼叫；top 是放左邊時對齊的上緣
    func install(in host: UIView, top: NSLayoutYAxisAnchor, onLeft: Bool) {
        host.addSubview(self)
        topInHost = top
        setOnLeft(onLeft)
    }

    func setOnLeft(_ left: Bool) {
        onLeft = left
        refreshChrome()
        applyLayout()
    }

    private func applyLayout() {
        guard let safe = superview?.safeAreaLayoutGuide, let top = topInHost else { return }
        NSLayoutConstraint.deactivate(placement)
        var c = [header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                 header.heightAnchor.constraint(equalToConstant: 34)]
        if onLeft {
            c += [leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 10),
                  topAnchor.constraint(equalTo: top, constant: 10),
                  bottomAnchor.constraint(lessThanOrEqualTo: safe.bottomAnchor, constant: -10),
                  widthAnchor.constraint(equalToConstant: collapsed ? Self.collapsedWidth : Self.expandedWidth),
                  header.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                  header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                  scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
                  scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
                  scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
                  scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)]
            if collapsed {
                c.append(heightAnchor.constraint(equalToConstant: 42))
            } else {
                // 內容不高時，面板就縮到內容高度
                // 優先權要低於內容的抗壓縮：高度不夠時讓元件庫捲動，而不是把分類標題擠扁
                let fit = heightAnchor.constraint(equalTo: stack.heightAnchor, constant: 44)
                fit.priority = .defaultLow
                c.append(fit)
            }
        } else {
            c += [bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -Self.bottomMargin),
                  trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -10),
                  header.centerYAnchor.constraint(equalTo: centerYAnchor),
                  header.widthAnchor.constraint(equalToConstant: 36)]
            if collapsed {
                c += [widthAnchor.constraint(equalToConstant: Self.collapsedWidth), heightAnchor.constraint(equalToConstant: 42)]
            } else {
                c += [leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 10),
                      heightAnchor.constraint(equalToConstant: Self.bottomHeight),
                      bottomScroll.topAnchor.constraint(equalTo: topAnchor),
                      bottomScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
                      bottomScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
                      bottomScroll.trailingAnchor.constraint(equalTo: header.leadingAnchor)]
            }
        }
        placement = c
        NSLayoutConstraint.activate(c)
        onLayoutChange?()
    }

    private func refreshChrome() {
        scroll.isHidden = collapsed || !onLeft
        bottomScroll.isHidden = collapsed || onLeft
        titleLabel.isHidden = collapsed || !onLeft
        let symbol = onLeft ? (collapsed ? "sidebar.right" : "sidebar.left") : (collapsed ? "chevron.up" : "chevron.down")
        collapseButton.configuration?.image = UIImage(systemName: symbol)
        collapseButton.accessibilityLabel = collapsed ? "展開元件庫" : "收合元件庫"
    }

    /// 放下面時的一個分類：標題，底下元件由上往下排滿兩列再換下一行
    private func bottomSection(_ name: String, _ parts: [CircuitPart]) -> UIView {
        let columns = UIStackView()
        fillBottomColumns(columns, parts.map(partButton))
        return bottomSection(name, columns: columns)
    }

    private func fillBottomColumns(_ columns: UIStackView, _ tiles: [UIView]) {
        columns.arrangedSubviews.forEach { $0.removeFromSuperview() }
        columns.spacing = 4
        var i = 0
        while i < tiles.count {
            let column = UIStackView(arrangedSubviews: Array(tiles[i..<min(i + 2, tiles.count)]))
            column.axis = .vertical
            column.spacing = 4
            column.widthAnchor.constraint(equalToConstant: Self.bottomTileWidth).isActive = true
            columns.addArrangedSubview(column)
            i += 2
        }
    }

    private func bottomSection(_ name: String, columns: UIStackView) -> UIView {
        let title = UILabel()
        title.text = name
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .tertiaryLabel
        title.heightAnchor.constraint(equalToConstant: 14).isActive = true
        columns.alignment = .top
        let section = UIStackView(arrangedSubviews: [title, columns])
        section.axis = .vertical
        section.spacing = 2
        section.alignment = .leading
        return section
    }

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

    private func partButton(_ part: CircuitPart) -> UIButton {
        let b = tile(image: CircuitRenderer.icon(part, size: 28), title: part.title)
        b.addAction(UIAction { [weak self] _ in self?.onSelectMode?(.place(part)) }, for: .touchUpInside)
        // 往頁面拖：把元件拖到頁面上
        let drag = PartDragGesture(target: self, action: #selector(dragPart(_:)))
        drag.part = part
        drag.delegate = self
        b.addGestureRecognizer(drag)
        modeButtons.append((.place(part), b))
        return b
    }

    // MARK: 自訂電路圖

    @objc private func customCircuitsChanged() {
        reloadCustomCircuits()
    }

    /// 放左邊、放下面的按鈕各做一份
    func reloadCustomCircuits() {
        modeButtons.removeAll { if case .placeCustom = $0.0 { return true }; return false }
        let circuits = CustomCircuitStore.shared.circuits
        customBody.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let left = circuits.map(customButton) + [drawSymbolButton(), addCustomButton()]
        var i = 0
        while i < left.count {
            let pair = Array(left[i..<min(i + 2, left.count)])
            customBody.addArrangedSubview(row(pair.count == 2 ? pair : pair + [UIView()]))
            i += 2
        }
        fillBottomColumns(customColumns, circuits.map(customButton) + [drawSymbolButton(), addCustomButton()])
        refreshHighlight()
    }

    private func drawSymbolButton() -> UIButton {
        let b = tile(image: UIImage(systemName: "pencil.and.outline"), title: "畫元件")
        b.accessibilityLabel = "畫自訂元件"
        b.addAction(UIAction { [weak self] _ in self?.onDrawSymbol?(nil) }, for: .touchUpInside)
        return b
    }

    private func addCustomButton() -> UIButton {
        let b = tile(image: UIImage(systemName: "plus"), title: "加入")
        b.accessibilityLabel = "加入自訂電路圖"
        b.addAction(UIAction { [weak self] _ in self?.onAddCustom?() }, for: .touchUpInside)
        return b
    }

    /// 點一下連續擺放、往頁面拖放一個、長按改名或刪除
    private func customButton(_ c: CustomCircuit) -> UIButton {
        let b = tile(image: CircuitRenderer.icon(c.data, size: 28), title: c.name)
        b.configuration?.titleLineBreakMode = .byTruncatingTail
        b.addAction(UIAction { [weak self] _ in self?.onSelectMode?(.placeCustom(c.id)) }, for: .touchUpInside)
        let drag = PartDragGesture(target: self, action: #selector(dragPart(_:)))
        drag.custom = c.id
        drag.delegate = self
        b.addGestureRecognizer(drag)
        let edit = c.symbol == nil ? [] : [UIAction(title: "編輯符號", image: UIImage(systemName: "pencil.and.outline")) { [weak self] _ in self?.onDrawSymbol?(c.id) }]
        b.menu = UIMenu(children: edit + [
            UIAction(title: "改名", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.onRenameCustom?(c.id) },
            UIAction(title: "刪除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.onDeleteCustom?(c.id) },
        ])
        modeButtons.append((.placeCustom(c.id), b))
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
        refreshChrome()
        applyLayout()
        UIView.animate(withDuration: 0.2) { self.superview?.layoutIfNeeded() }
    }

    // MARK: 拖到頁面上

    /// 往頁面拖才算拖元件（放左邊：往右；放下面：往上）；其他方向是捲動元件庫
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? PartDragGesture else { return super.gestureRecognizerShouldBegin(g) }
        let v = pan.velocity(in: self)
        return onLeft ? v.x > abs(v.y) : -v.y > abs(v.x)
    }

    @objc private func dragPart(_ g: PartDragGesture) {
        guard let host = superview else { return }
        let p = g.location(in: host)
        switch g.state {
        case .began:
            let image = g.part.map { CircuitRenderer.icon($0, size: 44) }
                ?? g.custom.flatMap { CustomCircuitStore.shared.circuit($0) }.map { CircuitRenderer.icon($0.data, size: 44) }
            let iv = UIImageView(image: image)
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
            if !frame.contains(p) {
                if let part = g.part { onDrop?(part, p) }
                if let id = g.custom { onDropCustom?(id, p) }
            }
        default:
            ghost?.removeFromSuperview()
            ghost = nil
        }
    }
}

/// 帶著元件種類的拖曳手勢
final class PartDragGesture: UIPanGestureRecognizer {
    var part: CircuitPart?
    var custom: UUID?
}
