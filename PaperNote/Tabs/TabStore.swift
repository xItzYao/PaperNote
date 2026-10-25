import Foundation

/// 開著的筆記本分頁
struct OpenTab: Codable, Equatable {
    var notebookID: UUID
    var groupID: UUID?
}

/// 分頁群組：在分頁列上只佔一格，可以展開／收合
struct TabGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var colorHex: String
    var collapsed = false
}

struct TabState: Codable {
    var tabs: [OpenTab] = []
    var groups: [TabGroup] = []
    var active: UUID?
}

final class TabStore {
    static let shared = TabStore()

    private(set) var state = TabState()
    /// 開啟時要跳到的頁面（從我的最愛點進來）
    var pendingPage: [UUID: UUID] = [:]
    private let key = "tabs.state.v1"

    static let groupColors = ["#1E88E5FF", "#43A047FF", "#FB8C00FF", "#8E24AAFF", "#E53935FF", "#00897BFF", "#6D4C41FF"]

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(TabState.self, from: data) {
            state = s
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    var hasTabs: Bool { !state.tabs.isEmpty }

    /// 移除已經被刪除的筆記本、沒有分頁的群組
    func prune(existing: Set<UUID>) {
        state.tabs.removeAll { !existing.contains($0.notebookID) }
        let usedGroups = Set(state.tabs.compactMap(\.groupID))
        state.groups.removeAll { !usedGroups.contains($0.id) }
        if let a = state.active, !state.tabs.contains(where: { $0.notebookID == a }) {
            state.active = state.tabs.first?.notebookID
        }
        persist()
    }

    /// 開啟筆記本：已經開著就切過去，否則加在目前分頁後面
    func open(_ id: UUID, page: UUID?) {
        if let page { pendingPage[id] = page }
        if !state.tabs.contains(where: { $0.notebookID == id }) {
            let insertAt = state.active.flatMap { a in state.tabs.firstIndex { $0.notebookID == a } }.map { $0 + 1 } ?? state.tabs.count
            state.tabs.insert(OpenTab(notebookID: id, groupID: nil), at: insertAt)
        }
        state.active = id
        expandGroupContaining(id)
        persist()
    }

    func activate(_ id: UUID) {
        state.active = id
        persist()
    }

    /// 關閉分頁，回傳接下來要顯示的分頁（nil 表示全部關完）
    @discardableResult
    func close(_ id: UUID) -> UUID? {
        guard let i = state.tabs.firstIndex(where: { $0.notebookID == id }) else { return state.active }
        state.tabs.remove(at: i)
        if state.active == id {
            state.active = state.tabs.isEmpty ? nil : state.tabs[min(i, state.tabs.count - 1)].notebookID
        }
        prune(existing: Set(state.tabs.map(\.notebookID)))
        return state.active
    }

    func closeOthers(than id: UUID) {
        state.tabs.removeAll { $0.notebookID != id }
        state.active = id
        prune(existing: [id])
    }

    // MARK: 群組

    func group(_ id: UUID) -> TabGroup? { state.groups.first { $0.id == id } }

    @discardableResult
    func createGroup(name: String, with tab: UUID) -> TabGroup {
        let g = TabGroup(name: name.isEmpty ? "群組 \(state.groups.count + 1)" : name,
                         colorHex: Self.groupColors[state.groups.count % Self.groupColors.count])
        state.groups.append(g)
        move(tab, to: g.id)
        return g
    }

    /// 把分頁放進群組（排到群組最後一個分頁後面）；groupID 為 nil 表示移出群組
    func move(_ tab: UUID, to groupID: UUID?) {
        guard let i = state.tabs.firstIndex(where: { $0.notebookID == tab }) else { return }
        var t = state.tabs.remove(at: i)
        t.groupID = groupID
        if let g = groupID, let last = state.tabs.lastIndex(where: { $0.groupID == g }) {
            state.tabs.insert(t, at: last + 1)
        } else if groupID == nil {
            state.tabs.append(t)
        } else {
            state.tabs.insert(t, at: min(i, state.tabs.count))
        }
        prune(existing: Set(state.tabs.map(\.notebookID)))
    }

    /// 拖曳排序：把 tab 放到 anchor 的前面（after = false）或後面；anchor 為 nil 表示放到最後。
    /// 放在同一群組的兩個分頁中間就加入那個群組；放在群組的頭尾，原本就在這個群組的留在群組裡，其他的不加入
    func reorder(_ tab: UUID, next anchor: UUID?, after: Bool) {
        guard anchor != tab, let from = state.tabs.firstIndex(where: { $0.notebookID == tab }) else { return }
        var t = state.tabs.remove(at: from)
        var insertAt = state.tabs.count
        var groupID: UUID?
        if let anchor, let ai = state.tabs.firstIndex(where: { $0.notebookID == anchor }) {
            insertAt = after ? ai + 1 : ai
            if let g = state.tabs[ai].groupID {
                let otherSide = after ? state.tabs[safe: ai + 1]?.groupID : state.tabs[safe: ai - 1]?.groupID
                if otherSide == g || t.groupID == g { groupID = g }
            }
        }
        t.groupID = groupID
        state.tabs.insert(t, at: insertAt)
        prune(existing: Set(state.tabs.map(\.notebookID)))
    }

    func toggleCollapsed(_ groupID: UUID) {
        guard let i = state.groups.firstIndex(where: { $0.id == groupID }) else { return }
        state.groups[i].collapsed.toggle()
        persist()
    }

    func expandGroupContaining(_ tab: UUID) {
        guard let g = state.tabs.first(where: { $0.notebookID == tab })?.groupID,
              let i = state.groups.firstIndex(where: { $0.id == g }) else { return }
        state.groups[i].collapsed = false
    }

    func renameGroup(_ id: UUID, to name: String) {
        guard let i = state.groups.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        state.groups[i].name = name
        persist()
    }

    func recolorGroup(_ id: UUID, hex: String) {
        guard let i = state.groups.firstIndex(where: { $0.id == id }) else { return }
        state.groups[i].colorHex = hex
        persist()
    }

    /// 解散群組：分頁留著，只是不再分組
    func ungroup(_ id: UUID) {
        for i in state.tabs.indices where state.tabs[i].groupID == id { state.tabs[i].groupID = nil }
        state.groups.removeAll { $0.id == id }
        persist()
    }

    func closeGroup(_ id: UUID) {
        state.tabs.removeAll { $0.groupID == id }
        if let a = state.active, !state.tabs.contains(where: { $0.notebookID == a }) {
            state.active = state.tabs.first?.notebookID
        }
        prune(existing: Set(state.tabs.map(\.notebookID)))
    }

    // MARK: 記住每本筆記本上次看到的頁面

    static func lastPage(for notebook: UUID) -> UUID? {
        UserDefaults.standard.string(forKey: "lastPage.\(notebook.uuidString)").flatMap(UUID.init(uuidString:))
    }

    static func setLastPage(_ page: UUID, for notebook: UUID) {
        UserDefaults.standard.set(page.uuidString, forKey: "lastPage.\(notebook.uuidString)")
    }
}
