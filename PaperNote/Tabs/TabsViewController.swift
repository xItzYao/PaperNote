import UIKit
import SwiftUI

/// 多分頁容器：上方分頁列（含群組），下方是目前的筆記本
final class TabsViewController: UIViewController {
    var onExit: (() -> Void)?

    private let store = TabStore.shared
    private let tabBar = UIView()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let container = UIView()
    private var editors: [UUID: NotebookViewController] = [:]
    private var recent: [UUID] = []
    private let maxLoaded = 4
    /// 拖曳排序時的插入位置提示
    private let dropMarker = UIView()
    private weak var dropHighlighted: UIView?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.92, alpha: 1)
        overrideUserInterfaceStyle = .light

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.backgroundColor = UIColor(white: 0.93, alpha: 1)
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)
        view.addSubview(container)

        let library = UIButton(type: .system)
        library.setImage(UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        library.tintColor = .label
        library.accessibilityLabel = "資料庫"
        library.translatesAutoresizingMaskIntoConstraints = false
        library.addAction(UIAction { [weak self] _ in self?.exitToLibrary() }, for: .touchUpInside)
        tabBar.addSubview(library)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        tabBar.addSubview(scroll)
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        // 整條分頁列接受拖曳：放在分頁左右邊緣＝排序，放在分頁中間＝組成群組
        scroll.addInteraction(UIDropInteraction(delegate: self))
        dropMarker.backgroundColor = .systemBlue
        dropMarker.layer.cornerRadius = 1.5
        dropMarker.isHidden = true

        // 安全區頂端也塗上分頁列的底色
        let topFill = UIView()
        topFill.translatesAutoresizingMaskIntoConstraints = false
        topFill.backgroundColor = tabBar.backgroundColor
        view.addSubview(topFill)

        NSLayoutConstraint.activate([
            topFill.topAnchor.constraint(equalTo: view.topAnchor),
            topFill.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topFill.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topFill.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
            tabBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 40),
            library.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor, constant: 10),
            library.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            library.widthAnchor.constraint(equalToConstant: 36),
            scroll.leadingAnchor.constraint(equalTo: library.trailingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: tabBar.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // 在編輯畫面改了筆記本名稱：分頁上的名稱跟著改
        NotificationCenter.default.addObserver(forName: .notebookRenamed, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildTabs()
        }

        store.prune(existing: Set(LibraryStore.shared.visibleNotebooks.map(\.id)))
        if let a = store.state.active {
            show(a)
        } else {
            exitToLibrary()
        }
    }

    // MARK: - 切換分頁

    private func show(_ id: UUID) {
        guard let vc = editor(for: id) else {
            store.close(id)
            if let next = store.state.active { show(next) } else { exitToLibrary() }
            return
        }
        for (other, e) in editors where other != id && e.parent != nil {
            e.saveAndRememberPage()
            e.willMove(toParent: nil)
            e.view.removeFromSuperview()
            e.removeFromParent()
        }
        if vc.parent == nil {
            addChild(vc)
            vc.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(vc.view)
            NSLayoutConstraint.activate([
                vc.view.topAnchor.constraint(equalTo: container.topAnchor),
                vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                vc.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                vc.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            vc.didMove(toParent: self)
        }
        if let page = store.pendingPage.removeValue(forKey: id) { vc.jump(toPageID: page) }
        vc.didBecomeActiveTab()
        store.activate(id)
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        evictIfNeeded()
        rebuildTabs()
    }

    private func editor(for id: UUID) -> NotebookViewController? {
        if let e = editors[id] { return e }
        guard let session = try? NotebookSession(id: id) else { return nil }
        let page = store.pendingPage.removeValue(forKey: id) ?? TabStore.lastPage(for: id)
        let vc = NotebookViewController(session: session, initialPageID: page) { [weak self] in
            self?.exitToLibrary()
        }
        editors[id] = vc
        return vc
    }

    /// 只保留最近用過的幾本在記憶體中，其他存檔後釋放
    private func evictIfNeeded() {
        while recent.count > maxLoaded, let old = recent.popLast() {
            if let e = editors.removeValue(forKey: old) { e.prepareForClose() }
        }
    }

    private func closeTab(_ id: UUID) {
        if let e = editors.removeValue(forKey: id) {
            e.prepareForClose()
            if e.parent != nil {
                e.willMove(toParent: nil)
                e.view.removeFromSuperview()
                e.removeFromParent()
            }
        }
        recent.removeAll { $0 == id }
        if let next = store.close(id) {
            show(next)
        } else {
            exitToLibrary()
        }
    }

    func exitToLibrary() {
        for e in editors.values { e.prepareForClose() }
        for e in editors.values where e.parent != nil {
            e.willMove(toParent: nil)
            e.view.removeFromSuperview()
            e.removeFromParent()
        }
        editors = [:]
        recent = []
        onExit?()
    }

    // MARK: - 分頁列

    private func title(_ id: UUID) -> String {
        LibraryStore.shared.notebook(id)?.title ?? "筆記本"
    }

    private func rebuildTabs() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        hideDropFeedback()
        let s = store.state
        var shownGroups = Set<UUID>()
        var activeChip: UIView?
        for tab in s.tabs {
            if let gid = tab.groupID, let g = store.group(gid) {
                if !shownGroups.contains(gid) {
                    shownGroups.insert(gid)
                    let count = s.tabs.filter { $0.groupID == gid }.count
                    let containsActive = s.tabs.contains { $0.groupID == gid && $0.notebookID == s.active }
                    let chip = groupChip(g, count: count, highlighted: containsActive && g.collapsed)
                    stack.addArrangedSubview(chip)
                    if containsActive && g.collapsed { activeChip = chip }
                }
                if g.collapsed { continue }
                let chip = tabChip(tab.notebookID, color: UIColor(hex: g.colorHex), active: tab.notebookID == s.active)
                stack.addArrangedSubview(chip)
                if tab.notebookID == s.active { activeChip = chip }
            } else {
                let chip = tabChip(tab.notebookID, color: nil, active: tab.notebookID == s.active)
                stack.addArrangedSubview(chip)
                if tab.notebookID == s.active { activeChip = chip }
            }
        }
        if let chip = activeChip {
            view.layoutIfNeeded()
            scroll.scrollRectToVisible(chip.frame.insetBy(dx: -40, dy: 0), animated: false)
        }
    }

    private func tabChip(_ id: UUID, color: UIColor?, active: Bool) -> UIView {
        var config = UIButton.Configuration.plain()
        config.title = title(id)
        config.titleLineBreakMode = .byTruncatingTail
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 13, weight: active ? .semibold : .regular)
            return a
        }
        config.baseForegroundColor = active ? .label : .secondaryLabel
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 4)
        let titleButton = UIButton(configuration: config)
        titleButton.addAction(UIAction { [weak self] _ in self?.show(id) }, for: .touchUpInside)
        titleButton.widthAnchor.constraint(lessThanOrEqualToConstant: 190).isActive = true

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)), for: .normal)
        close.tintColor = .secondaryLabel
        close.accessibilityLabel = "關閉分頁"
        close.widthAnchor.constraint(equalToConstant: 26).isActive = true
        close.addAction(UIAction { [weak self] _ in self?.closeTab(id) }, for: .touchUpInside)

        let chip = TabChip(arrangedSubviews: [titleButton, close])
        chip.notebookID = id
        // 長按出現選單；長按後拖曳：放到別的分頁左右邊緣＝排序，放到分頁或群組中間＝組成／加入群組
        chip.addInteraction(UIContextMenuInteraction(delegate: self))
        chip.addInteraction(UIDragInteraction(delegate: self))
        chip.axis = .horizontal
        chip.alignment = .center
        chip.spacing = 0
        chip.isLayoutMarginsRelativeArrangement = true
        chip.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 4)
        chip.backgroundColor = active ? .white : UIColor(white: 0.88, alpha: 1)
        chip.layer.cornerRadius = 8
        chip.heightAnchor.constraint(equalToConstant: 32).isActive = true
        if let color {
            // 群組內的分頁：底下一條群組顏色
            let bar = UIView()
            bar.backgroundColor = color
            bar.translatesAutoresizingMaskIntoConstraints = false
            chip.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 6),
                bar.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -6),
                bar.bottomAnchor.constraint(equalTo: chip.bottomAnchor),
                bar.heightAnchor.constraint(equalToConstant: 3),
            ])
        }
        return chip
    }

    private func groupChip(_ g: TabGroup, count: Int, highlighted: Bool) -> UIView {
        var config = UIButton.Configuration.filled()
        config.title = "\(g.name)  \(count)"
        config.image = UIImage(systemName: g.collapsed ? "chevron.right" : "chevron.down",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.baseBackgroundColor = UIColor(hex: g.colorHex).withAlphaComponent(highlighted ? 1 : 0.85)
        config.baseForegroundColor = .white
        config.cornerStyle = .medium
        config.titleLineBreakMode = .byTruncatingTail
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
            return a
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
        let b = UIButton(configuration: config)
        b.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        b.addAction(UIAction { [weak self] _ in
            self?.store.toggleCollapsed(g.id)
            self?.rebuildTabs()
        }, for: .touchUpInside)
        let wrap = TabChip(arrangedSubviews: [b])
        wrap.groupID = g.id
        wrap.layer.cornerRadius = 8
        wrap.addInteraction(UIContextMenuInteraction(delegate: self))
        return wrap
    }

    // MARK: - 選單（長按）

    private func tabMenu(_ id: UUID) -> UIMenu {
        let tab = store.state.tabs.first { $0.notebookID == id }
        var groupItems: [UIMenuElement] = store.state.groups.filter { $0.id != tab?.groupID }.map { g in
            UIAction(title: g.name, image: UIImage(systemName: "circle.fill")?.withTintColor(UIColor(hex: g.colorHex), renderingMode: .alwaysOriginal)) { [weak self] _ in
                self?.store.move(id, to: g.id)
                self?.rebuildTabs()
            }
        }
        groupItems.append(UIAction(title: "新增群組…", image: UIImage(systemName: "plus")) { [weak self] _ in
            self?.promptNewGroup(with: id)
        })
        var items: [UIMenuElement] = [UIMenu(title: "加入群組", image: UIImage(systemName: "folder.badge.plus"), children: groupItems)]
        if tab?.groupID != nil {
            items.append(UIAction(title: "移出群組", image: UIImage(systemName: "folder.badge.minus")) { [weak self] _ in
                self?.store.move(id, to: nil)
                self?.rebuildTabs()
            })
        }
        items.append(UIAction(title: "關閉其他分頁", image: UIImage(systemName: "xmark.square")) { [weak self] _ in
            guard let self else { return }
            for (other, e) in self.editors where other != id {
                e.prepareForClose()
                if e.parent != nil { e.willMove(toParent: nil); e.view.removeFromSuperview(); e.removeFromParent() }
                self.editors[other] = nil
            }
            self.recent = self.recent.filter { $0 == id }
            self.store.closeOthers(than: id)
            self.show(id)
        })
        items.append(UIAction(title: "關閉分頁", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
            self?.closeTab(id)
        })
        return UIMenu(title: title(id), children: items)
    }

    private func groupMenu(_ g: TabGroup) -> UIMenu {
        let colors = TabStore.groupColors.map { hex in
            UIAction(title: " ", image: UIImage(systemName: "circle.fill")?.withTintColor(UIColor(hex: hex), renderingMode: .alwaysOriginal)) { [weak self] _ in
                self?.store.recolorGroup(g.id, hex: hex)
                self?.rebuildTabs()
            }
        }
        return UIMenu(title: g.name, children: [
            UIAction(title: "重新命名…", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.promptRename(g) },
            UIMenu(title: "顏色", image: UIImage(systemName: "paintpalette"), options: .displayInline, children: [UIMenu(options: .displayInline, children: colors)]),
            UIAction(title: "解散群組（保留分頁）", image: UIImage(systemName: "rectangle.stack.badge.minus")) { [weak self] _ in
                self?.store.ungroup(g.id)
                self?.rebuildTabs()
            },
            UIAction(title: "關閉群組內所有分頁", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                guard let self else { return }
                let ids = self.store.state.tabs.filter { $0.groupID == g.id }.map(\.notebookID)
                for id in ids {
                    if let e = self.editors.removeValue(forKey: id) {
                        e.prepareForClose()
                        if e.parent != nil { e.willMove(toParent: nil); e.view.removeFromSuperview(); e.removeFromParent() }
                    }
                }
                self.recent.removeAll { ids.contains($0) }
                self.store.closeGroup(g.id)
                if let a = self.store.state.active { self.show(a) } else { self.exitToLibrary() }
            },
        ])
    }

    private func promptNewGroup(with tab: UUID) {
        let a = UIAlertController(title: "新增群組", message: nil, preferredStyle: .alert)
        a.addTextField { tf in tf.placeholder = "群組名稱（例如：電子學）" }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "建立", style: .default) { [weak self, weak a] _ in
            self?.store.createGroup(name: a?.textFields?.first?.text ?? "", with: tab)
            self?.rebuildTabs()
        })
        present(a, animated: true)
    }

    private func promptRename(_ g: TabGroup) {
        let a = UIAlertController(title: "重新命名群組", message: nil, preferredStyle: .alert)
        a.addTextField { tf in tf.text = g.name }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "確定", style: .default) { [weak self, weak a] _ in
            self?.store.renameGroup(g.id, to: a?.textFields?.first?.text ?? "")
            self?.rebuildTabs()
        })
        present(a, animated: true)
    }
}

/// 分頁列上的一格（分頁或群組）
final class TabChip: UIStackView {
    var notebookID: UUID?
    var groupID: UUID?
}

// MARK: - 長按選單、拖曳分頁組成群組

extension TabsViewController: UIContextMenuInteractionDelegate, UIDragInteractionDelegate, UIDropInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let chip = interaction.view as? TabChip else { return nil }
        if let id = chip.notebookID {
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in self?.tabMenu(id) }
        }
        if let gid = chip.groupID, let g = store.group(gid) {
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in self?.groupMenu(g) }
        }
        return nil
    }

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        guard let chip = interaction.view as? TabChip, let id = chip.notebookID else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider(object: id.uuidString as NSString))
        item.localObject = id
        return [item]
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.localDragSession != nil
    }

    /// 放開時會怎樣：加入群組、插到某個分頁前後、或沒有變化
    private enum TabDrop {
        case join(TabChip)
        case insert(anchor: UUID?, after: Bool, markerX: CGFloat)
        case none
    }

    private func dropPlan(_ session: UIDropSession) -> TabDrop {
        guard let dragged = session.localDragSession?.items.first?.localObject as? UUID else { return .none }
        let chips = stack.arrangedSubviews.compactMap { $0 as? TabChip }
        guard let first = chips.first, let last = chips.last else { return .none }
        let x = session.location(in: stack).x
        let half = stack.spacing / 2
        if x > last.frame.maxX + half { return .insert(anchor: nil, after: false, markerX: last.frame.maxX + half) }
        guard let chip = chips.first(where: { x >= $0.frame.minX - half && x <= $0.frame.maxX + half }) ?? (x < first.frame.minX ? first : nil)
        else { return .none }
        if chip.notebookID == dragged { return .none }
        let f = (x - chip.frame.minX) / max(chip.frame.width, 1)
        let before = chip.frame.minX - half, after = chip.frame.maxX + half
        if let id = chip.notebookID {
            if f < 0.3 { return .insert(anchor: id, after: false, markerX: before) }
            if f > 0.7 { return .insert(anchor: id, after: true, markerX: after) }
            return .join(chip)
        }
        if let gid = chip.groupID, let g = store.group(gid) {
            let ids = store.state.tabs.filter { $0.groupID == gid }.map(\.notebookID)
            if f < 0.3, let firstID = ids.first { return .insert(anchor: firstID, after: false, markerX: before) }
            // 收合的群組：右邊緣放到整個群組後面；展開的群組右邊緊接著群組裡的分頁，所以算加入
            if g.collapsed, f > 0.7, let lastID = ids.last { return .insert(anchor: lastID, after: true, markerX: after) }
            return .join(chip)
        }
        return .none
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        autoScrollTabs(session)
        hideDropFeedback()
        switch dropPlan(session) {
        case let .join(chip):
            chip.layer.borderWidth = 2
            chip.layer.borderColor = UIColor.systemBlue.cgColor
            dropHighlighted = chip
        case let .insert(_, _, x):
            if dropMarker.superview !== stack { stack.addSubview(dropMarker) }
            dropMarker.frame = CGRect(x: x - 1.5, y: (stack.bounds.height - 28) / 2, width: 3, height: 28)
            dropMarker.isHidden = false
        case .none:
            return UIDropProposal(operation: .cancel)
        }
        return UIDropProposal(operation: .move)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        hideDropFeedback()
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        hideDropFeedback()
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let dragged = session.localDragSession?.items.first?.localObject as? UUID else { return }
        switch dropPlan(session) {
        case let .join(chip):
            if let gid = chip.groupID {
                // 拖到群組上 → 加入群組
                store.move(dragged, to: gid)
            } else if let target = chip.notebookID {
                if let gid = store.state.tabs.first(where: { $0.notebookID == target })?.groupID {
                    store.move(dragged, to: gid)
                } else {
                    // 拖到另一個分頁中間 → 兩個組成新群組
                    let g = store.createGroup(name: "", with: target)
                    store.move(dragged, to: g.id)
                }
            }
        case let .insert(anchor, after, _):
            store.reorder(dragged, next: anchor, after: after)
        case .none:
            return
        }
        rebuildTabs()
    }

    private func hideDropFeedback() {
        dropHighlighted?.layer.borderWidth = 0
        dropHighlighted = nil
        dropMarker.isHidden = true
    }

    /// 拖到分頁列左右兩端時自動捲動，才能排到畫面外的位置
    private func autoScrollTabs(_ session: UIDropSession) {
        let x = session.location(in: scroll).x - scroll.contentOffset.x
        let maxX = max(0, scroll.contentSize.width - scroll.bounds.width)
        var off = scroll.contentOffset.x
        if x < 36 { off -= 12 } else if x > scroll.bounds.width - 36 { off += 12 }
        off = min(max(off, 0), maxX)
        if off != scroll.contentOffset.x { scroll.contentOffset.x = off }
    }
}

struct TabsHost: UIViewControllerRepresentable {
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> TabsViewController {
        let vc = TabsViewController()
        vc.onExit = onExit
        return vc
    }

    func updateUIViewController(_ vc: TabsViewController, context: Context) {}
}
