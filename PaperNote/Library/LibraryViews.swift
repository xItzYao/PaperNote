import SwiftUI
import UniformTypeIdentifiers

@main
struct PaperNoteApp: App {
    @StateObject private var store = LibraryStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.light)
        }
    }
}

struct FolderRoute: Hashable {
    let id: UUID
}

struct OpenRequest: Identifiable {
    let id = UUID()
    let notebookID: UUID
    let pageID: UUID?
}

struct RootView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var path: [FolderRoute] = []
    @State private var showEditor = false
    @State private var importError: String?

    var body: some View {
        NavigationStack(path: $path) {
            FolderView(folderID: nil, open: open)
                .navigationDestination(for: FolderRoute.self) { route in
                    FolderView(folderID: route.id, open: open)
                }
        }
        .fullScreenCover(isPresented: $showEditor) {
            TabsHost { showEditor = false }
                .ignoresSafeArea(.keyboard)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .onAppear { BackupManager.shared.start() }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "pdf" else { return }
            do {
                let meta = try store.importPDF(from: url, folder: path.last?.id)
                open(meta.id, nil)
            } catch {
                importError = error.localizedDescription
            }
        }
        .alert("匯入失敗", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private func open(_ notebook: UUID, _ page: UUID?) {
        TabStore.shared.open(notebook, page: page)
        showEditor = true
    }
}

// MARK: - 資料夾畫面

enum LibraryItem: Identifiable, Equatable {
    case folder(Folder)
    case notebook(NotebookMeta)

    var id: UUID {
        switch self {
        case let .folder(f): return f.id
        case let .notebook(n): return n.id
        }
    }

    var name: String {
        switch self {
        case let .folder(f): return f.name
        case let .notebook(n): return n.title
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct FolderView: View {
    @EnvironmentObject var store: LibraryStore
    let folderID: UUID?
    let open: (UUID, UUID?) -> Void

    @State private var search = ""
    @State private var showImporter = false
    @State private var showNewNotebook = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: LibraryItem?
    @State private var renameText = ""
    @State private var moveTarget: LibraryItem?
    @State private var deleteTarget: LibraryItem?
    @State private var shareItem: ShareItem?
    @State private var errorMessage: String?
    @State private var showFavorites = false
    @State private var exporting = false
    @State private var showAbout = false
    @State private var showBackup = false
    @State private var showTrash = false
    @State private var dropTarget: UUID?
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var showBatchMove = false
    @State private var confirmBatchDelete = false
    @Environment(\.dismiss) private var dismissFolder
    @AppStorage("library.viewMode") private var viewMode = "grid"
    @AppStorage("library.sort") private var sortMode = "modified"

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 28)]

    private var title: String {
        folderID.flatMap { store.folder($0)?.name } ?? "資料庫"
    }

    private var folders: [Folder] {
        guard search.isEmpty else { return [] }
        let list = store.folders(in: folderID)
        switch sortMode {
        case "name": return list
        default: return list.sorted { $0.created > $1.created }
        }
    }

    private var notebooks: [NotebookMeta] {
        let list = search.isEmpty ? store.notebooks(in: folderID)
            : store.visibleNotebooks.filter { $0.title.localizedCaseInsensitiveContains(search) }
        switch sortMode {
        case "name": return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case "created": return list.sorted { $0.created > $1.created }
        default: return list.sorted { $0.modified > $1.modified }
        }
    }

    var body: some View {
        sheets(mainView)
    }

    private var mainView: some View {
        content
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(title)
        .searchable(text: $search, prompt: "搜尋筆記本名稱")
        .safeAreaInset(edge: .bottom) {
            if selecting { batchBar }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(selecting ? "完成" : "選取") {
                    selecting.toggle()
                    selection = []
                }
                .fontWeight(selecting ? .semibold : .regular)
                Menu {
                    Section("顯示方式") {
                        Picker("顯示方式", selection: $viewMode) {
                            Label("大圖", systemImage: "square.grid.2x2").tag("grid")
                            Label("詳細資料", systemImage: "list.bullet").tag("list")
                        }
                    }
                    Section("排序") {
                        Picker("排序", selection: $sortMode) {
                            Label("修改日期", systemImage: "clock").tag("modified")
                            Label("建立日期", systemImage: "calendar").tag("created")
                            Label("名稱", systemImage: "textformat").tag("name")
                        }
                    }
                } label: {
                    Label("顯示方式", systemImage: viewMode == "list" ? "list.bullet" : "square.grid.2x2")
                }
                if let active = TabStore.shared.state.active {
                    Button { open(active, nil) } label: {
                        Label("回到分頁", systemImage: "rectangle.stack")
                    }
                }
                Button { showFavorites = true } label: {
                    Label("我的最愛頁面", systemImage: "star")
                }
                Menu {
                    Button { showTrash = true } label: { Label("垃圾桶", systemImage: "trash") }
                    Button { showBackup = true } label: { Label("雲端備份（Google Drive）", systemImage: "icloud.and.arrow.up") }
                    Button { showAbout = true } label: { Label("關於我", systemImage: "person.crop.circle") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                Menu {
                    Button { showNewNotebook = true } label: { Label("新增筆記本", systemImage: "book.closed") }
                    Button { showImporter = true } label: { Label("匯入 PDF", systemImage: "doc.richtext") }
                    Button { newFolderName = ""; showNewFolder = true } label: { Label("新增資料夾", systemImage: "folder.badge.plus") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if folders.isEmpty && notebooks.isEmpty {
            ScrollView {
                ContentUnavailableView(search.isEmpty ? "這裡還沒有東西" : "找不到符合的筆記本",
                                       systemImage: search.isEmpty ? "books.vertical" : "magnifyingglass",
                                       description: Text(search.isEmpty ? "按右上角的「＋」新增筆記本、匯入 PDF 或建立資料夾。" : ""))
                    .padding(.top, 80)
            }
        } else if viewMode == "list" {
            detailsList
        } else {
            grid
        }
    }

    /// 詳細資料：由上到下的清單
    private var detailsList: some View {
        List {
            Section {
                if let parent = parentDropID {
                    Button { dismissFolder() } label: {
                        DetailRow(cover: nil, isFolder: true, name: "上一層", kind: "", size: "", favorites: nil,
                                  modified: nil, created: Date(), isParent: true)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(dropTarget == parent ? Color.accentColor.opacity(0.15) : nil)
                    .dropDestination(for: String.self) { items, _ in
                        handleDrop(items, into: parentFolderID)
                    } isTargeted: { setDropTarget(parent, $0) }
                }
                ForEach(folders) { folder in
                    Group {
                        if selecting {
                            Button { toggleSelection(folder.id) } label: {
                                HStack(spacing: 10) {
                                    checkmark(folder.id)
                                    DetailRow(cover: nil, isFolder: true, name: folder.name, kind: "資料夾",
                                              size: "\(store.itemCount(in: folder.id)) 個項目", favorites: nil,
                                              modified: nil, created: folder.created)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink(value: FolderRoute(id: folder.id)) {
                                DetailRow(cover: nil, isFolder: true, name: folder.name, kind: "資料夾",
                                          size: "\(store.itemCount(in: folder.id)) 個項目", favorites: nil,
                                          modified: nil, created: folder.created)
                            }
                        }
                    }
                    .listRowBackground(dropTarget == folder.id ? Color.accentColor.opacity(0.15) : nil)
                    .draggable(dragPayload(folder.id, "fd"))
                    .dropDestination(for: String.self) { items, _ in
                        handleDrop(items, into: folder.id)
                    } isTargeted: { setDropTarget(folder.id, $0) }
                    .contextMenu { itemMenu(.folder(folder)) }
                }
                ForEach(notebooks) { nb in
                    Button { selecting ? toggleSelection(nb.id) : open(nb.id, nil) } label: {
                        HStack(spacing: 10) {
                            if selecting { checkmark(nb.id) }
                            DetailRow(cover: nb, isFolder: false, name: nb.title, kind: "筆記本",
                                      size: "\(nb.pageCount) 頁", favorites: nb.favorites.count,
                                      modified: nb.modified, created: nb.created,
                                      coverURL: store.coverImageURL(nb.id))
                        }
                    }
                    .buttonStyle(.plain)
                    .draggable(dragPayload(nb.id, "nb"))
                    .contextMenu { itemMenu(.notebook(nb)) }
                }
            } header: {
                DetailHeader()
            }
        }
        .listStyle(.plain)
    }

    /// 大圖：封面網格
    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 32) {
                if let parent = parentDropID {
                    Button { dismissFolder() } label: {
                        ParentFolderCell(highlighted: dropTarget == parent)
                    }
                    .buttonStyle(.plain)
                    .dropDestination(for: String.self) { items, _ in
                        handleDrop(items, into: parentFolderID)
                    } isTargeted: { setDropTarget(parent, $0) }
                }
                ForEach(folders) { folder in
                    Group {
                        if selecting {
                            Button { toggleSelection(folder.id) } label: {
                                FolderCell(folder: folder, count: store.itemCount(in: folder.id), highlighted: dropTarget == folder.id)
                                    .overlay(alignment: .topLeading) { checkmark(folder.id).padding(6) }
                            }
                        } else {
                            NavigationLink(value: FolderRoute(id: folder.id)) {
                                FolderCell(folder: folder, count: store.itemCount(in: folder.id), highlighted: dropTarget == folder.id)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .draggable(dragPayload(folder.id, "fd")) {
                        dragPreview(folder.name, symbol: "folder.fill", id: folder.id)
                    }
                    .dropDestination(for: String.self) { items, _ in
                        handleDrop(items, into: folder.id)
                    } isTargeted: { setDropTarget(folder.id, $0) }
                    .contextMenu { itemMenu(.folder(folder)) }
                }
                ForEach(notebooks) { nb in
                    Button { selecting ? toggleSelection(nb.id) : open(nb.id, nil) } label: {
                        NotebookCell(meta: nb, coverURL: store.coverImageURL(nb.id))
                            .overlay(alignment: .topLeading) {
                                if selecting { checkmark(nb.id).padding(6) }
                            }
                    }
                    .buttonStyle(.plain)
                    .draggable(dragPayload(nb.id, "nb")) {
                        dragPreview(nb.title, symbol: "book.closed.fill", id: nb.id)
                    }
                    .contextMenu { itemMenu(.notebook(nb)) }
                }
            }
            .padding(28)
        }
    }

    /// 匯入、新增、重新命名、移動、刪除等彈出視窗
    private func sheets<Content: View>(_ base: Content) -> some View {
        base
        .overlay {
            if exporting {
                ProgressView("正在匯出 PDF…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                var last: NotebookMeta?
                for url in urls {
                    do { last = try store.importPDF(from: url, folder: folderID) } catch { errorMessage = error.localizedDescription }
                }
                if urls.count == 1, let m = last { open(m.id, nil) }
            case let .failure(error):
                errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showNewNotebook) {
            NewNotebookSheet { title, paper, landscape in
                let meta = store.createNotebook(title: title, folder: folderID, paper: paper, landscape: landscape)
                showNewNotebook = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { open(meta.id, nil) }
            }
        }
        .alert("新增資料夾", isPresented: $showNewFolder) {
            TextField("資料夾名稱", text: $newFolderName)
            Button("取消", role: .cancel) {}
            Button("建立") { store.createFolder(name: newFolderName, parent: folderID) }
        }
        .alert("重新命名", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("名稱", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("確定") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                switch renameTarget {
                case let .folder(f): store.renameFolder(f.id, to: name)
                case let .notebook(n): store.renameNotebook(n.id, to: name)
                case nil: break
                }
                renameTarget = nil
            }
        }
        .sheet(item: $moveTarget) { item in
            MoveSheet(items: [item]) { dest in
                switch item {
                case let .folder(f):
                    if !store.moveFolder(f.id, to: dest) { errorMessage = "不能把資料夾移到它自己裡面。" }
                case let .notebook(n):
                    store.moveNotebook(n.id, to: dest)
                }
                moveTarget = nil
            } onCancel: {
                moveTarget = nil
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("刪除", role: .destructive) {
                switch deleteTarget {
                case let .folder(f): store.deleteFolder(f.id)
                case let .notebook(n): store.deleteNotebook(n.id)
                case nil: break
                }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteMessage)
        }
        .sheet(isPresented: $showBatchMove) {
            MoveSheet(items: selectedItems) { dest in
                for item in selectedItems {
                    switch item {
                    case let .folder(f):
                        if !store.moveFolder(f.id, to: dest) { errorMessage = "不能把資料夾移到它自己裡面。" }
                    case let .notebook(n):
                        store.moveNotebook(n.id, to: dest)
                    }
                }
                showBatchMove = false
                selection = []
                selecting = false
            } onCancel: {
                showBatchMove = false
            }
            .environmentObject(store)
        }
        .confirmationDialog("刪除 \(selection.count) 個項目？", isPresented: $confirmBatchDelete, titleVisibility: .visible) {
            Button("刪除", role: .destructive) {
                for item in selectedItems {
                    switch item {
                    case let .folder(f): store.deleteFolder(f.id)
                    case let .notebook(n): store.deleteNotebook(n.id)
                    }
                }
                selection = []
                selecting = false
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("選取的筆記本（以及資料夾裡的所有內容）會被永久刪除，無法復原。")
        }
        .sheet(isPresented: $showTrash) { TrashView().environmentObject(store) }
        .sheet(isPresented: $showAbout) { AboutView() }
        .sheet(isPresented: $showBackup) { BackupView() }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .sheet(isPresented: $showFavorites) {
            FavoritesView { nb, page in
                showFavorites = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { open(nb, page) }
            }
            .environmentObject(store)
        }
        .alert("發生問題", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// 「上一層」拖放目標的識別碼（只有在資料夾裡才有）
    private var parentDropID: UUID? {
        folderID == nil ? nil : FolderView.parentSentinel
    }

    private var parentFolderID: UUID? {
        folderID.flatMap { store.folder($0)?.parentId }
    }

    static let parentSentinel = UUID()

    private func setDropTarget(_ id: UUID, _ targeted: Bool) {
        if targeted {
            dropTarget = id
        } else if dropTarget == id {
            dropTarget = nil
        }
    }

    /// 拖曳筆記本／資料夾到資料夾（dest 為 nil 表示最上層）
    private func handleDrop(_ items: [String], into dest: UUID?) -> Bool {
        dropTarget = nil
        var moved = false
        for item in items.flatMap({ $0.split(separator: ",").map(String.init) }) {
            let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { continue }
            if parts[0] == "nb" {
                store.moveNotebook(id, to: dest)
                moved = true
            } else if parts[0] == "fd", id != dest {
                if store.moveFolder(id, to: dest) {
                    moved = true
                } else {
                    errorMessage = "不能把資料夾移到它自己裡面。"
                }
            }
        }
        return moved
    }

    // MARK: 多選

    private var selectedItems: [LibraryItem] {
        folders.filter { selection.contains($0.id) }.map { LibraryItem.folder($0) }
            + notebooks.filter { selection.contains($0.id) }.map { LibraryItem.notebook($0) }
    }

    private func toggleSelection(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func checkmark(_ id: UUID) -> some View {
        Image(systemName: selection.contains(id) ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .foregroundStyle(selection.contains(id) ? Color.accentColor : Color.secondary)
            .background(Circle().fill(Color(uiColor: .systemBackground)).padding(2))
    }

    /// 拖曳內容：選取模式下拖已勾選的項目，會把所有勾選的一起帶走
    private func dragPayload(_ id: UUID, _ prefix: String) -> String {
        if selecting && selection.contains(id) && selection.count > 1 {
            return selectedItems.map { item -> String in
                switch item {
                case let .folder(f): return "fd:\(f.id.uuidString)"
                case let .notebook(n): return "nb:\(n.id.uuidString)"
                }
            }.joined(separator: ",")
        }
        return "\(prefix):\(id.uuidString)"
    }

    private func dragPreview(_ title: String, symbol: String, id: UUID) -> some View {
        let multi = selecting && selection.contains(id) && selection.count > 1
        return Label(multi ? "\(selection.count) 個項目" : title, systemImage: multi ? "square.stack.3d.up.fill" : symbol)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var batchBar: some View {
        let all = Set(folders.map(\.id) + notebooks.map(\.id))
        return HStack(spacing: 18) {
            Button(selection == all && !all.isEmpty ? "取消全選" : "全選") {
                selection = selection == all ? [] : all
            }
            Text("已選取 \(selection.count) 項").foregroundStyle(.secondary)
            Spacer()
            Group {
            Button { showBatchMove = true } label: { Label("移動到…", systemImage: "folder") }
            Button {
                for item in selectedItems {
                    switch item {
                    case let .folder(f): store.duplicateFolder(f.id)
                    case let .notebook(n): store.duplicateNotebook(n.id)
                    }
                }
                selection = []
            } label: { Label("複製", systemImage: "plus.square.on.square") }
            Button(role: .destructive) {
                moveToTrash(selectedItems)
                selection = []
                selecting = false
            } label: { Label("刪除", systemImage: "trash") }
            }
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// 刪除＝移到垃圾桶（30 天後才永久刪除）
    private func moveToTrash(_ items: [LibraryItem]) {
        for item in items {
            switch item {
            case let .folder(f): store.trashFolder(f.id)
            case let .notebook(n):
                store.trashNotebook(n.id)
                TabStore.shared.close(n.id)
            }
        }
    }

    private var deleteTitle: String {
        guard let t = deleteTarget else { return "" }
        return "刪除「\(t.name)」？"
    }

    private var deleteMessage: String {
        switch deleteTarget {
        case .folder: return "資料夾裡的所有筆記本和子資料夾都會一起刪除，無法復原。"
        case .notebook: return "這本筆記本會被永久刪除，無法復原。"
        case nil: return ""
        }
    }

    @ViewBuilder
    private func itemMenu(_ item: LibraryItem) -> some View {
        Button { renameText = item.name; renameTarget = item } label: { Label("重新命名", systemImage: "pencil") }
        Button {
            switch item {
            case let .folder(f): store.duplicateFolder(f.id)
            case let .notebook(n): store.duplicateNotebook(n.id)
            }
        } label: { Label("複製", systemImage: "plus.square.on.square") }
        Button { moveTarget = item } label: { Label("移動到…", systemImage: "folder") }
        if case let .notebook(n) = item {
            Button { export(n.id) } label: { Label("匯出 PDF", systemImage: "square.and.arrow.up") }
        }
        Divider()
        Button(role: .destructive) { moveToTrash([item]) } label: { Label("刪除", systemImage: "trash") }
    }

    private func export(_ id: UUID) {
        exporting = true
        DispatchQueue.main.async {
            defer { exporting = false }
            do {
                let session = try NotebookSession(id: id)
                shareItem = ShareItem(url: try NotebookExporter.exportPDF(session: session))
            } catch {
                errorMessage = "匯出失敗：\(error.localizedDescription)"
            }
        }
    }
}

struct ParentFolderCell: View {
    var highlighted = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .resizable()
                .scaledToFit()
                .padding(40)
                .foregroundStyle(Color.secondary)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(highlighted ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08)))
            Text("上一層").font(.subheadline.weight(.semibold))
            Text(" ").font(.caption)
        }
    }
}

struct FolderCell: View {
    let folder: Folder
    let count: Int
    var highlighted = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: highlighted ? "folder.fill.badge.plus" : "folder.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.accentColor.opacity(highlighted ? 1 : 0.85))
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 12).fill(highlighted ? Color.accentColor.opacity(0.15) : Color.clear))
            Text(folder.name).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
            Text("\(count) 個項目").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct NotebookCell: View {
    let meta: NotebookMeta
    let coverURL: URL

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                cover
                    .frame(height: 210)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                if !meta.favorites.isEmpty {
                    Label("\(meta.favorites.count)", systemImage: "star.fill")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.yellow, in: Capsule())
                        .padding(6)
                }
            }
            Text(meta.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
            Text("\(meta.pageCount) 頁 · \(meta.modified.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let img = UIImage(contentsOfFile: coverURL.path) {
            Image(uiImage: img).resizable().scaledToFill()
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color(uiColor: UIColor(hex: meta.coverHex))).frame(width: 8)
                }
        } else {
            ZStack {
                Color(uiColor: UIColor(hex: meta.coverHex))
                Text(meta.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(12)
            }
        }
    }
}

struct NewNotebookSheet: View {
    let onCreate: (String, PaperStyle, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var paper: PaperStyle = .ruled
    @State private var landscape = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("筆記本名稱", text: $title)
                Picker("紙張", selection: $paper) {
                    ForEach(PaperStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("方向", selection: $landscape) {
                    Text("直式").tag(false)
                    Text("橫式").tag(true)
                }
                .pickerStyle(.segmented)
            }
            .navigationTitle("新增筆記本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("建立") { onCreate(title.trimmingCharacters(in: .whitespacesAndNewlines), paper, landscape) }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct MoveSheet: View {
    @EnvironmentObject var store: LibraryStore
    let items: [LibraryItem]
    let onPick: (UUID?) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Button { onPick(nil) } label: {
                    Label("資料庫（最上層）", systemImage: "books.vertical")
                }
                ForEach(store.folderTree(), id: \.folder.id) { entry in
                    let disabled = isDisabled(entry.folder)
                    Button { onPick(entry.folder.id) } label: {
                        Label(entry.folder.name, systemImage: "folder")
                            .padding(.leading, CGFloat(entry.depth) * 20)
                    }
                    .disabled(disabled)
                }
            }
            .navigationTitle(items.count == 1 ? "移動「\(items[0].name)」到…" : "移動 \(items.count) 個項目到…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: onCancel) }
            }
        }
    }

    private func isDisabled(_ f: Folder) -> Bool {
        items.contains { item in
            if case let .folder(moving) = item { return store.isFolder(f.id, inside: moving.id) }
            return false
        }
    }
}

// MARK: - 所有筆記本的我的最愛頁面

struct FavoritesView: View {
    @EnvironmentObject var store: LibraryStore
    let open: (UUID, UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var groups: [(notebook: NotebookMeta, favorites: [FavoriteRef])] {
        var result: [(notebook: NotebookMeta, favorites: [FavoriteRef])] = []
        for nb in store.visibleNotebooks.sorted(by: { $0.modified > $1.modified }) where !nb.favorites.isEmpty {
            let favs = nb.favorites
                .filter { search.isEmpty || $0.note.localizedCaseInsensitiveContains(search) || nb.title.localizedCaseInsensitiveContains(search) }
                .sorted { $0.pageNumber < $1.pageNumber }
            if !favs.isEmpty { result.append((notebook: nb, favorites: favs)) }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "還沒有我的最愛頁面" : "找不到符合的備註",
                                           systemImage: "star",
                                           description: Text(search.isEmpty ? "在筆記本裡按星號，就能把頁面加入我的最愛並寫備註。" : ""))
                } else {
                    List {
                        ForEach(groups, id: \.notebook.id) { group in
                            Section(group.notebook.title) {
                                ForEach(group.favorites, id: \.pageId) { fav in
                                    Button { open(group.notebook.id, fav.pageId) } label: {
                                        FavoriteRow(fav: fav, thumbURL: store.thumbnailURL(notebook: group.notebook.id, page: fav.pageId))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "搜尋備註")
            .navigationTitle("我的最愛頁面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } }
            }
        }
    }
}

struct FavoriteRow: View {
    let fav: FavoriteRef
    let thumbURL: URL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let img = UIImage(contentsOfFile: thumbURL.path) {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    Color.gray.opacity(0.2)
                }
            }
            .frame(width: 72, height: 96)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
            VStack(alignment: .leading, spacing: 4) {
                Text("第 \(fav.pageNumber) 頁").font(.headline)
                Text(fav.note.isEmpty ? "（沒有備註）" : fav.note)
                    .font(.subheadline)
                    .foregroundStyle(fav.note.isEmpty ? .secondary : .primary)
                    .lineLimit(4)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - 詳細資料列

private enum DetailColumns {
    static let kind: CGFloat = 64
    static let size: CGFloat = 84
    static let favorites: CGFloat = 52
    static let modified: CGFloat = 150
    static let created: CGFloat = 96
}

struct DetailHeader: View {
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 36, height: 1)
            Text("名稱")
            Spacer(minLength: 8)
            if hSize == .regular {
                Text("種類").frame(width: DetailColumns.kind, alignment: .leading)
                Text("大小").frame(width: DetailColumns.size, alignment: .trailing)
                Text("最愛").frame(width: DetailColumns.favorites, alignment: .center)
                Text("修改日期").frame(width: DetailColumns.modified, alignment: .leading)
                Text("建立日期").frame(width: DetailColumns.created, alignment: .leading)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

struct DetailRow: View {
    let cover: NotebookMeta?
    let isFolder: Bool
    let name: String
    let kind: String
    let size: String
    let favorites: Int?
    let modified: Date?
    let created: Date
    var coverURL: URL? = nil
    var isParent = false
    @Environment(\.horizontalSizeClass) private var hSize

    private var favText: String {
        guard let f = favorites, f > 0 else { return "—" }
        return "★ \(f)"
    }

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 36, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium)).lineLimit(1)
                if hSize != .regular {
                    Text([kind, size, modified?.formatted(date: .numeric, time: .omitted)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if hSize == .regular {
                Text(kind).frame(width: DetailColumns.kind, alignment: .leading)
                Text(size).monospacedDigit().frame(width: DetailColumns.size, alignment: .trailing)
                Text(favText)
                    .foregroundStyle(favText == "—" ? Color.secondary : Color.orange)
                    .frame(width: DetailColumns.favorites, alignment: .center)
                Text(modified?.formatted(date: .numeric, time: .shortened) ?? "—")
                    .monospacedDigit()
                    .frame(width: DetailColumns.modified, alignment: .leading)
                Text(created.formatted(date: .numeric, time: .omitted))
                    .monospacedDigit()
                    .frame(width: DetailColumns.created, alignment: .leading)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var icon: some View {
        if isParent {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.secondary)
                .padding(8)
        } else if isFolder {
            Image(systemName: "folder.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.accentColor.opacity(0.85))
                .padding(.vertical, 6)
        } else if let url = coverURL, let img = UIImage(contentsOfFile: url.path) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 36, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.3)))
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(uiColor: UIColor(hex: cover?.coverHex ?? Palette.covers[0])))
        }
    }
}
