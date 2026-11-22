import UIKit

/// 畫完新的自訂元件按「下一步」：和元件庫一樣列出各分類和裡面已經有的元件（標題列點一下展開、收合），
/// 右邊的圓圈選要放在哪個分類；新的元件用藍框標在選好的分類最後面。按「完成」才存
final class CircuitSectionPickerViewController: UIViewController {
    struct Tile {
        var image: UIImage
        var title: String
    }

    struct Section {
        /// nil＝自訂電路圖那一區
        var key: String?
        var name: String
        var tiles: [Tile]
    }

    private let symbol: CircuitSymbol
    private let symbolName: String
    /// 按「完成」：選好的分類（nil＝自訂電路圖那一區）
    var onPick: ((String?) -> Void)?
    /// 「新增分類…」打好名字：建好分類，回傳它的 key
    var onNewSection: ((String) -> String)?

    private(set) var sections: [Section] = []
    private(set) var selectedKey: String?
    /// 收起來的分類（用名稱記，和元件庫一樣；一開始照元件庫目前的樣子）
    private(set) var collapsed: Set<String>
    /// 每個分類的標題列、圓圈、元件那一塊（測試也用）
    private(set) var headerButtons: [UIButton] = []
    private(set) var radioButtons: [UIButton] = []
    private(set) var bodies: [UIStackView] = []
    /// 新元件那一格
    private(set) var newTile: UIView?
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var builtWidth: CGFloat = 0

    init(symbol: CircuitSymbol, name: String) {
        self.symbol = symbol
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        symbolName = t.isEmpty ? L("新元件") : t
        collapsed = Set(UserDefaults.standard.stringArray(forKey: CircuitLibraryView.collapsedKey) ?? [])
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 和元件庫同樣的順序：內建分類、自己加的分類，自訂電路圖排最後
    static func librarySections() -> [Section] {
        let circuits = CustomCircuitStore.shared.circuits
        func customs(_ key: String?) -> [Tile] {
            CircuitLibraryView.customCircuits(in: key, from: circuits).map { Tile(image: CircuitRenderer.icon($0.data, size: 28), title: $0.name) }
        }
        let library = CircuitLibraryView.allSections.map { s -> Section in
            let parts = s.parts.map { Tile(image: CircuitRenderer.icon($0, size: 28), title: $0.title) }
            return Section(key: s.key, name: s.name, tiles: parts + customs(s.key))
        }
        return library + [Section(key: nil, name: CircuitLibraryView.customSectionName, tiles: customs(nil))]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = L("放在哪個分類？")
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("完成"), style: .done, target: self, action: #selector(doneTapped))

        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
        ])
        reloadSections()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 寬度變了（轉向、分割畫面）：一排放幾個要重算
        if abs(view.bounds.width - builtWidth) > 1 { rebuild() }
    }

    /// 分類有變（新增分類）：重新讀
    func reloadSections() {
        sections = Self.librarySections()
        if let key = selectedKey, !sections.contains(where: { $0.key == key }) { selectedKey = nil }
        rebuild()
    }

    private var columnCount: Int {
        let width = max(view.bounds.width - 32, 300)
        return max(4, Int((width + 6) / 82))
    }

    private func rebuild() {
        builtWidth = view.bounds.width
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        headerButtons = []
        radioButtons = []
        bodies = []
        newTile = nil
        for (i, s) in sections.enumerated() {
            let picked = s.key == selectedKey
            let header = sectionHeader(s, index: i)
            let radio = radioButton(index: i, on: picked)
            let row = UIStackView(arrangedSubviews: [header, radio])
            row.alignment = .center
            stack.addArrangedSubview(row)

            let body = UIStackView()
            body.axis = .vertical
            body.spacing = 6
            body.isHidden = collapsed.contains(s.name)
            body.clipsToBounds = true
            var tiles: [UIView] = s.tiles.map { tile(image: $0.image, title: $0.title, isNew: false) }
            if picked {
                let t = tile(image: CircuitRenderer.icon(CustomCircuit.symbolData(symbol), size: 28), title: symbolName, isNew: true)
                newTile = t
                tiles.append(t)
            }
            if tiles.isEmpty {
                let empty = UILabel()
                empty.text = L("還沒有元件")
                empty.font = .systemFont(ofSize: 13)
                empty.textColor = .tertiaryLabel
                tiles = [empty]
            }
            fill(body, tiles)
            // 點元件那一塊也是選這個分類
            body.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(bodyTapped(_:))))
            body.tag = i
            stack.addArrangedSubview(body)
            headerButtons.append(header)
            radioButtons.append(radio)
            bodies.append(body)
        }
        var c = UIButton.Configuration.plain()
        c.image = UIImage(systemName: "folder.badge.plus")
        c.title = L("新增分類…")
        c.imagePadding = 6
        c.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 4, bottom: 8, trailing: 4)
        let add = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.promptNewSection() })
        add.contentHorizontalAlignment = .leading
        stack.addArrangedSubview(add)
    }

    private func fill(_ body: UIStackView, _ tiles: [UIView]) {
        let n = columnCount
        var i = 0
        while i < tiles.count {
            let slice = Array(tiles[i..<min(i + n, tiles.count)])
            let row = UIStackView(arrangedSubviews: slice + (0..<(n - slice.count)).map { _ in UIView() })
            row.distribution = .fillEqually
            row.spacing = 6
            body.addArrangedSubview(row)
            i += n
        }
    }

    /// 標題列：點一下展開或收起底下的元件（和元件庫一樣）
    private func sectionHeader(_ s: Section, index: Int) -> UIButton {
        var c = UIButton.Configuration.plain()
        var t = AttributedString(s.name)
        t.font = .systemFont(ofSize: 15, weight: .semibold)
        c.attributedTitle = t
        c.baseForegroundColor = .label
        c.image = UIImage(systemName: collapsed.contains(s.name) ? "chevron.right" : "chevron.down",
                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        c.imagePadding = 8
        c.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 4, bottom: 6, trailing: 4)
        let b = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.toggleCollapsed(index) })
        b.contentHorizontalAlignment = .leading
        b.accessibilityHint = L("點一下展開或收合")
        return b
    }

    /// 右邊的圓圈：選這個分類
    private func radioButton(index: Int, on: Bool) -> UIButton {
        var c = UIButton.Configuration.plain()
        c.image = UIImage(systemName: on ? "checkmark.circle.fill" : "circle",
                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 22))
        c.baseForegroundColor = on ? .tintColor : .tertiaryLabel
        let b = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.select(index) })
        b.accessibilityLabel = L("放在「\(sections[index].name)」")
        if on { b.accessibilityTraits.insert(.selected) }
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return b
    }

    private func tile(image: UIImage?, title: String, isNew: Bool) -> UIView {
        let icon = UIImageView(image: image)
        icon.contentMode = .center
        icon.tintColor = .label
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 10)
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        let v = UIStackView(arrangedSubviews: [icon, label])
        v.axis = .vertical
        v.spacing = 2
        v.isLayoutMarginsRelativeArrangement = true
        v.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 2, bottom: 4, trailing: 2)
        v.heightAnchor.constraint(equalToConstant: 56).isActive = true
        v.layer.cornerRadius = 8
        v.backgroundColor = isNew ? UIColor.tintColor.withAlphaComponent(0.12) : .secondarySystemBackground
        if isNew {
            v.layer.borderWidth = 2
            v.layer.borderColor = UIColor.tintColor.cgColor
        }
        v.isAccessibilityElement = true
        v.accessibilityLabel = isNew ? L("新元件：\(title)") : title
        return v
    }

    func toggleCollapsed(_ index: Int) {
        guard sections.indices.contains(index) else { return }
        let name = sections[index].name
        if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
        let body = bodies[index]
        let hide = collapsed.contains(name)
        UIView.animate(withDuration: 0.2) {
            body.isHidden = hide
            body.alpha = hide ? 0 : 1
            self.stack.layoutIfNeeded()
        }
        headerButtons[index].configuration?.image = UIImage(systemName: hide ? "chevron.right" : "chevron.down",
                                                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
    }

    /// 選分類：新元件移到那一區的最後面，那一區打開
    func select(_ index: Int) {
        guard sections.indices.contains(index) else { return }
        selectedKey = sections[index].key
        collapsed.remove(sections[index].name)
        rebuild()
        if let t = newTile {
            view.layoutIfNeeded()
            scroll.scrollRectToVisible(t.convert(t.bounds, to: scroll).insetBy(dx: 0, dy: -40), animated: true)
        }
    }

    @objc private func bodyTapped(_ g: UITapGestureRecognizer) {
        guard let i = g.view?.tag else { return }
        select(i)
    }

    @objc func doneTapped() {
        onPick?(selectedKey)
    }

    private func promptNewSection() {
        let a = UIAlertController(title: L("新增分類…"), message: nil, preferredStyle: .alert)
        a.addTextField { tf in
            tf.placeholder = L("分類名稱")
            tf.clearButtonMode = .whileEditing
        }
        a.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        a.addAction(UIAlertAction(title: L("加入"), style: .default) { [weak self, weak a] _ in
            let name = (a?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !name.isEmpty, let key = self.onNewSection?(name) else { return }
            self.addedSection(key)
        })
        present(a, animated: true)
    }

    /// 新增的分類建好了：重新讀，選它
    func addedSection(_ key: String) {
        reloadSections()
        if let i = sections.firstIndex(where: { $0.key == key }) { select(i) }
    }
}
