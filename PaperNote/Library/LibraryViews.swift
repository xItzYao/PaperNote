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
    @State private var importSummary: String?
    /// 從別的 App 分享進來、還沒選好要放哪個資料夾的檔案
    @State private var pendingImport: ShareItem?

    var body: some View {
        NavigationStack(path: $path) {
            FolderView(folderID: nil, open: open)
                .navigationDestination(for: FolderRoute.self) { route in
                    FolderView(folderID: route.id, open: open)
                }
        }
        .sheet(isPresented: importPickerShown(inEditor: false)) { importPicker }
        .fullScreenCover(isPresented: $showEditor) {
            TabsHost { showEditor = false }
                .ignoresSafeArea(.keyboard)
                .ignoresSafeArea(.container, edges: .bottom)
                // 筆記本開著的時候分享進來：選資料夾的視窗從筆記本上面跳出來
                .sheet(isPresented: importPickerShown(inEditor: true)) { importPicker }
        }
        .onAppear {
            BackupManager.shared.start()
            // UI 測試：直接打開一本有好幾頁的新筆記本
            if ProcessInfo.processInfo.arguments.contains("-uiTestNotebook") {
                let meta = store.createNotebook(title: "UI Test", folder: nil, paper: .blank, landscape: false)
                if let s = try? NotebookSession(id: meta.id) {
                    for _ in 0..<9 { s.document.pages.append(Page(background: .paper(width: 595, height: 842, style: .grid))) }
                    s.save()
                }
                open(meta.id, nil)
            }
        }
        .onOpenURL { url in
            guard ["pdf", "zip", "papernote"].contains(url.pathExtension.lowercased()) else { return }
            // 先讓使用者選要放在哪個資料夾，選好才匯入
            pendingImport = ShareItem(url: url)
        }
        .alert(L("匯入完成"), isPresented: Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })) {
            Button(L("好"), role: .cancel) {}
        } message: {
            Text(importSummary ?? "")
        }
        .alert(L("匯入失敗"), isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button(L("好"), role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private func open(_ notebook: UUID, _ page: UUID?) {
        TabStore.shared.open(notebook, page: page)
        showEditor = true
    }

    private func importPickerShown(inEditor: Bool) -> Binding<Bool> {
        Binding(get: { pendingImport != nil && showEditor == inEditor }, set: { if !$0 { pendingImport = nil } })
    }

    @ViewBuilder
    private var importPicker: some View {
        if let item = pendingImport {
            FolderPickerSheet(title: L("匯入「\(item.url.deletingPathExtension().lastPathComponent)」到…"), confirmTitle: L("匯入")) { dest in
                pendingImport = nil
                // 等選資料夾的視窗收起來再打開筆記本
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { importShared(item.url, into: dest) }
            } onCancel: {
                pendingImport = nil
            }
            .environmentObject(store)
        }
    }

    private func importShared(_ url: URL, into folder: UUID?) {
        do {
            switch url.pathExtension.lowercased() {
            case "pdf":
                open(try store.importPDF(from: url, folder: folder).id, nil)
            case "zip":
                importSummary = try store.importZip(from: url, folder: folder).summary
            default:
                open(try store.importPaperNote(from: url, folder: folder).id, nil)
            }
        } catch {
            importError = error.localizedDescription
        }
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

    /// 不用全螢幕視窗從下面滑上來的動畫，小視窗自己淡入
    private func setNewNotebookShown(_ shown: Bool) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { showNewNotebook = shown }
    }
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: LibraryItem?
    @State private var renameText = ""
    @State private var moveTarget: LibraryItem?
    @State private var shareItem: ShareItem?
    @State private var errorMessage: String?
    @State private var importSummary: String?
    @State private var importing = false
    @State private var exportTarget: NotebookMeta?
    /// 匯出的頁面（見 PageSelection），空白＝全部
    @State private var exportPages = ""
    /// 我的最愛文件（畫面中間的視窗）；在視窗裡點的筆記本，等視窗關掉再打開
    @State private var showFavorites = false
    @State private var openAfterFavorites: UUID?
    @State private var exporting = false
    @State private var showAbout = false
    @State private var language = AppLanguage.current
    @State private var languageNeedsRestart = false
    @State private var showBackup = false
    @State private var showTrash = false
    @State private var dropTarget: UUID?
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var showBatchMove = false
    @Environment(\.dismiss) private var dismissFolder
    @Environment(\.horizontalSizeClass) private var hSize
    @AppStorage("library.viewMode") private var viewMode = "list"
    @AppStorage("library.sort") private var sortMode = "modified"

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 28)]

    private var title: String {
        folderID.flatMap { store.folder($0)?.name } ?? L("資料庫")
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
        var list = search.isEmpty ? store.notebooks(in: folderID) : store.visibleNotebooks
        if !search.isEmpty { list = list.filter { $0.title.localizedCaseInsensitiveContains(search) } }
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
        .safeAreaInset(edge: .bottom) {
            if selecting { batchBar }
        }
        .toolbar {
            // 左邊：找文件、回到筆記本、我的最愛文件、新增（文件的操作）
            ToolbarItemGroup(placement: .topBarLeading) {
                searchField
                if let active = TabStore.shared.state.active {
                    Button { open(active, nil) } label: {
                        Label(L("回到分頁"), systemImage: "rectangle.stack")
                    }
                }
                Button { showFavorites = true } label: {
                    Label(L("我的最愛文件"), systemImage: "star")
                }
                Menu {
                    Button { setNewNotebookShown(true) } label: { Label(L("新增筆記本"), systemImage: "book.closed") }
                    Button { showImporter = true } label: { Label(L("匯入 PDF、zip 或 PaperNote 檔"), systemImage: "doc.richtext") }
                    Button { newFolderName = ""; showNewFolder = true } label: { Label(L("新增資料夾"), systemImage: "folder.badge.plus") }
                } label: {
                    Image(systemName: "plus")
                }
            }
            // 右邊：檢視方式（在修改日期那一欄上面）、⋯、選取
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Section(L("檢視方式")) {
                        Picker(L("檢視方式"), selection: $viewMode) {
                            Label(L("大圖"), systemImage: "square.grid.2x2").tag("grid")
                            Label(L("詳細資料"), systemImage: "list.bullet").tag("list")
                        }
                    }
                    Section(L("排序方式")) {
                        Picker(L("排序方式"), selection: $sortMode) {
                            Label(L("修改日期"), systemImage: "clock").tag("modified")
                            Label(L("建立日期"), systemImage: "calendar").tag("created")
                            Label(L("名稱"), systemImage: "textformat").tag("name")
                        }
                    }
                } label: {
                    Label(L("檢視方式"), systemImage: viewMode == "list" ? "list.bullet" : "square.grid.2x2")
                }
                Menu {
                    Button { showTrash = true } label: { Label(L("垃圾桶"), systemImage: "trash") }
                    Button { showBackup = true } label: { Label(L("雲端備份（Google Drive）"), systemImage: "icloud.and.arrow.up") }
                    Button { showAbout = true } label: { Label(L("關於我"), systemImage: "person.crop.circle") }
                    Picker(selection: Binding(get: { language }, set: { chooseLanguage($0) })) {
                        ForEach(AppLanguage.allCases, id: \.self) { Text($0.menuTitle).tag($0) }
                    } label: {
                        // 中英並列：看不懂目前語言的人也找得到
                        Label("語言 Language", systemImage: "globe")
                    }
                    .pickerStyle(.menu)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                Button(selecting ? L("完成") : L("選取")) {
                    selecting.toggle()
                    selection = []
                }
                .fontWeight(selecting ? .semibold : .regular)
            }
        }
    }

    /// 語言存起來，下次開 App 生效；畫面上的語言真的會變才提醒重開
    private func chooseLanguage(_ new: AppLanguage) {
        language = new
        AppLanguage.current = new
        languageNeedsRestart = new.usesEnglish() != Loc.isEnglish
    }

    /// 搜尋筆記本名稱（放在左上角，和其他文件操作在一起）
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("搜尋筆記本名稱"), text: $search)
                .textFieldStyle(.plain)
                .submitLabel(.search)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("清除搜尋"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 220)
        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }

    @ViewBuilder
    private var content: some View {
        if folders.isEmpty && notebooks.isEmpty {
            ScrollView {
                if !search.isEmpty {
                    ContentUnavailableView(L("找不到符合的筆記本"), systemImage: "magnifyingglass")
                        .padding(.top, 80)
                } else {
                    ContentUnavailableView(L("這裡還沒有東西"), systemImage: "books.vertical",
                                           description: Text(L("按左上角的「＋」新增筆記本、匯入 PDF 或建立資料夾。")))
                        .padding(.top, 80)
                }
            }
        } else if viewMode == "list" {
            detailsList
        } else {
            grid
        }
    }

    /// 詳細資料：由上到下的清單（名稱、修改日期）。
    /// 長按＝拖曳（拖到資料夾上放開＝移進去）；選單在修改日期旁邊的 ⌄。
    /// 不用 List：List 的列接不到拖放，資料夾列還會多一個箭頭讓欄位對不齊
    private var detailsList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                Section {
                    if let parent = parentDropID {
                        detailLine(dropID: parent, item: nil) {
                            Button { dismissFolder() } label: {
                                DetailRow(cover: nil, isFolder: true, name: L("上一層"), modified: nil, isParent: true,
                                          checked: selecting ? false : nil)
                            }
                        }
                        .dropDestination(for: String.self) { items, _ in
                            handleDrop(items, into: parentFolderID)
                        } isTargeted: { setDropTarget(parent, $0) }
                    }
                    ForEach(folders) { folder in
                        detailLine(dropID: folder.id, item: .folder(folder)) {
                            if selecting {
                                Button { toggleSelection(folder.id) } label: {
                                    DetailRow(cover: nil, isFolder: true, name: folder.name, modified: nil,
                                              checked: selection.contains(folder.id))
                                }
                            } else {
                                NavigationLink(value: FolderRoute(id: folder.id)) {
                                    DetailRow(cover: nil, isFolder: true, name: folder.name, modified: nil)
                                }
                            }
                        }
                        .draggable(dragPayload(folder.id, "fd")) {
                            dragPreview(folder.name, symbol: "folder.fill", id: folder.id)
                        }
                        .dropDestination(for: String.self) { items, _ in
                            handleDrop(items, into: folder.id)
                        } isTargeted: { setDropTarget(folder.id, $0) }
                    }
                    ForEach(notebooks) { nb in
                        detailLine(dropID: nil, item: .notebook(nb)) {
                            Button { selecting ? toggleSelection(nb.id) : open(nb.id, nil) } label: {
                                DetailRow(cover: nb, isFolder: false, name: nb.title, modified: nb.modified,
                                          coverURL: store.coverImageURL(nb.id), checked: selecting ? selection.contains(nb.id) : nil)
                            }
                        }
                        .draggable(dragPayload(nb.id, "nb")) {
                            dragPreview(nb.title, symbol: "book.closed.fill", id: nb.id)
                        }
                    }
                } header: {
                    DetailHeader(selecting: selecting)
                        .padding(.horizontal, DetailColumns.inset)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .systemGroupedBackground))
                        .overlay(alignment: .bottom) { Divider() }
                }
            }
        }
    }

    /// 詳細資料的一列：整列點了打開（選取模式是勾選）；選單 ⌄、星星疊在修改日期左邊預留的位置（item 是 nil：「上一層」，沒有選單）
    private func detailLine<Main: View>(dropID: UUID?, item: LibraryItem?, @ViewBuilder _ main: () -> Main) -> some View {
        main()
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) {
                if let item, !selecting {
                    HStack(spacing: 0) {
                        itemMenuButton(item)
                        if case let .notebook(nb) = item {
                            starButton(nb)
                        } else {
                            Color.clear.frame(width: DetailColumns.star, height: 1)
                        }
                    }
                    .padding(.trailing, hSize == .regular ? DetailColumns.modified + DetailColumns.spacing : 0)
                }
            }
        .padding(.horizontal, DetailColumns.inset)
        .background(dropID != nil && dropTarget == dropID ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(alignment: .bottom) { Divider().padding(.leading, DetailColumns.inset) }
        .contentShape(Rectangle())
    }

    /// ⌄：點一下打開選單（重新命名、複製、移動、匯出、刪除）
    private func itemMenuButton(_ item: LibraryItem) -> some View {
        Menu { itemMenu(item) } label: {
            Image(systemName: "chevron.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: DetailColumns.menu, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L("「\(item.name)」的選單"))
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
                    VStack(spacing: 8) {
                        Group {
                            if selecting {
                                Button { toggleSelection(folder.id) } label: {
                                    FolderCell(folder: folder, highlighted: dropTarget == folder.id)
                                        .overlay(alignment: .topLeading) { checkmark(folder.id).padding(6) }
                                }
                            } else {
                                NavigationLink(value: FolderRoute(id: folder.id)) {
                                    FolderCell(folder: folder, highlighted: dropTarget == folder.id)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        gridCaption(L("\(store.itemCount(in: folder.id)) 個項目"), .folder(folder))
                    }
                    .draggable(dragPayload(folder.id, "fd")) {
                        dragPreview(folder.name, symbol: "folder.fill", id: folder.id)
                    }
                    .dropDestination(for: String.self) { items, _ in
                        handleDrop(items, into: folder.id)
                    } isTargeted: { setDropTarget(folder.id, $0) }
                }
                ForEach(notebooks) { nb in
                    VStack(spacing: 8) {
                        Button { selecting ? toggleSelection(nb.id) : open(nb.id, nil) } label: {
                            NotebookCell(meta: nb, coverURL: store.coverImageURL(nb.id))
                                .overlay(alignment: .topLeading) {
                                    if selecting { checkmark(nb.id).padding(6) }
                                }
                        }
                        .buttonStyle(.plain)
                        gridCaption(L("\(nb.pageCount) 頁 · \(LibraryDate.day(nb.modified))"), .notebook(nb))
                    }
                    .draggable(dragPayload(nb.id, "nb")) {
                        dragPreview(nb.title, symbol: "book.closed.fill", id: nb.id)
                    }
                }
            }
            .padding(28)
        }
    }

    /// ☆：加入／移出我的最愛文件
    private func starButton(_ nb: NotebookMeta) -> some View {
        Button { store.setStarred(nb.id, !nb.starred) } label: {
            Image(systemName: nb.starred ? "star.fill" : "star")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(nb.starred ? Color.orange : Color.secondary)
                .frame(width: DetailColumns.star, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(nb.starred ? L("從我的最愛文件移除「\(nb.title)」") : L("把「\(nb.title)」加入我的最愛文件"))
    }

    /// 大圖底下那行小字，左邊是選單 ⌄（筆記本還有星星）
    private func gridCaption(_ text: String, _ item: LibraryItem) -> some View {
        HStack(spacing: 0) {
            if !selecting {
                itemMenuButton(item).frame(height: GridCaption.height)
                if case let .notebook(nb) = item { starButton(nb).frame(height: GridCaption.height) }
            }
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: GridCaption.height)
    }

    /// 匯入 PDF 與 zip；只匯入一個 PDF 時直接打開它
    private func importFiles(_ urls: [URL]) {
        importing = true
        // 先讓「正在匯入…」顯示出來（大的 zip 要一點時間）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            var last: NotebookMeta?
            var summaries: [String] = []
            for url in urls {
                do {
                    switch url.pathExtension.lowercased() {
                    case "zip": summaries.append(try store.importZip(from: url, folder: folderID).summary)
                    case "papernote": last = try store.importPaperNote(from: url, folder: folderID)
                    default: last = try store.importPDF(from: url, folder: folderID)
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            importing = false
            if !summaries.isEmpty {
                importSummary = summaries.joined(separator: "\n\n")
            } else if urls.count == 1, let m = last {
                open(m.id, nil)
            }
        }
    }

    /// 匯入、新增、重新命名、移動、刪除等彈出視窗
    private func sheets<Content: View>(_ base: Content) -> some View {
        base
        .overlay {
            if exporting || importing {
                ProgressView(exporting ? L("正在匯出 PDF…") : L("正在匯入…"))
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .zip, .paperNote], allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls):
                importFiles(urls)
            case let .failure(error):
                errorMessage = error.localizedDescription
            }
        }
        .alert(L("匯入完成"), isPresented: Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })) {
            Button(L("好"), role: .cancel) {}
        } message: {
            Text(importSummary ?? "")
        }
        .alert(L("匯出「\(exportTarget?.title ?? "")」"), isPresented: Binding(get: { exportTarget != nil }, set: { if !$0 { exportTarget = nil } }),
               presenting: exportTarget) { nb in
            TextField(PageSelection.hint, text: $exportPages)
                .keyboardType(.numbersAndPunctuation)
                .accessibilityLabel(L("匯出的頁面"))
            Button(L("PDF（給別人看、列印）")) { export(nb.id, paperNote: false, pages: exportPages) }
            Button(L("PaperNote（可以繼續編輯筆跡）")) { export(nb.id, paperNote: true, pages: exportPages) }
            Button(L("取消"), role: .cancel) {}
        } message: { _ in
            Text(L("要匯出成哪一種格式？可以只匯出部分頁面。"))
        }
        // 畫面中間的小視窗（和新增頁面同一個）：點旁邊取消
        .fullScreenCover(isPresented: $showNewNotebook) {
            PaperPickerOverlay(title: L("新增筆記本"), confirmTitle: L("建立"), askName: true, style: .ruled, landscape: false,
                               onConfirm: { title, paper, landscape, size in
                                   let meta = store.createNotebook(title: title, folder: folderID, paper: paper, landscape: landscape, size: size)
                                   setNewNotebookShown(false)
                                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { open(meta.id, nil) }
                               },
                               onCancel: { setNewNotebookShown(false) })
                .presentationBackground(.clear)
        }
        .alert(L("新增資料夾"), isPresented: $showNewFolder) {
            TextField(L("資料夾名稱"), text: $newFolderName)
            Button(L("取消"), role: .cancel) {}
            Button(L("建立")) { store.createFolder(name: newFolderName, parent: folderID) }
        }
        .alert(L("重新命名"), isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField(L("名稱"), text: $renameText)
            Button(L("取消"), role: .cancel) { renameTarget = nil }
            Button(L("確定")) {
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
                    if !store.moveFolder(f.id, to: dest) { errorMessage = L("不能把資料夾移到它自己裡面。") }
                case let .notebook(n):
                    store.moveNotebook(n.id, to: dest)
                }
                moveTarget = nil
            } onCancel: {
                moveTarget = nil
            }
        }
        .sheet(isPresented: $showBatchMove) {
            MoveSheet(items: selectedItems) { dest in
                for item in selectedItems {
                    switch item {
                    case let .folder(f):
                        if !store.moveFolder(f.id, to: dest) { errorMessage = L("不能把資料夾移到它自己裡面。") }
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
        .sheet(isPresented: $showTrash) { TrashView().environmentObject(store) }
        .sheet(isPresented: $showAbout) { AboutView() }
        .alert(L("重新開啟 App 後換成新的語言"), isPresented: $languageNeedsRestart) {
            Button(L("好"), role: .cancel) {}
        } message: {
            Text(L("從多工畫面把 PaperNote 往上滑關掉，再重新打開。"))
        }
        .sheet(isPresented: $showFavorites, onDismiss: {
            if let id = openAfterFavorites {
                openAfterFavorites = nil
                open(id, nil)
            }
        }) {
            FavoriteDocumentsSheet { openAfterFavorites = $0 }.environmentObject(store)
        }
        .sheet(isPresented: $showBackup) { BackupView() }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .alert(L("發生問題"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(L("好"), role: .cancel) {}
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
                    errorMessage = L("不能把資料夾移到它自己裡面。")
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
        return Label(multi ? L("\(selection.count) 個項目") : title, systemImage: multi ? "square.stack.3d.up.fill" : symbol)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var batchBar: some View {
        let all = Set(folders.map(\.id) + notebooks.map(\.id))
        return HStack(spacing: 18) {
            Button(selection == all && !all.isEmpty ? L("取消全選") : L("全選")) {
                selection = selection == all ? [] : all
            }
            Text(L("已選取 \(selection.count) 項")).foregroundStyle(.secondary)
            Spacer()
            Group {
            Button { showBatchMove = true } label: { Label(L("移動到…"), systemImage: "folder") }
            Button {
                for item in selectedItems {
                    switch item {
                    case let .folder(f): store.duplicateFolder(f.id)
                    case let .notebook(n): store.duplicateNotebook(n.id)
                    }
                }
                selection = []
            } label: { Label(L("複製"), systemImage: "plus.square.on.square") }
            Button(role: .destructive) {
                moveToTrash(selectedItems)
                selection = []
                selecting = false
            } label: { Label(L("刪除"), systemImage: "trash") }
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

    @ViewBuilder
    private func itemMenu(_ item: LibraryItem) -> some View {
        Button { renameText = item.name; renameTarget = item } label: { Label(L("重新命名"), systemImage: "pencil") }
        Button {
            switch item {
            case let .folder(f): store.duplicateFolder(f.id)
            case let .notebook(n): store.duplicateNotebook(n.id)
            }
        } label: { Label(L("複製"), systemImage: "plus.square.on.square") }
        Button { moveTarget = item } label: { Label(L("移動到…"), systemImage: "folder") }
        if case let .notebook(n) = item {
            Button { exportPages = ""; exportTarget = n } label: { Label(L("匯出…"), systemImage: "square.and.arrow.up") }
        }
        Divider()
        Button(role: .destructive) { moveToTrash([item]) } label: { Label(L("刪除"), systemImage: "trash") }
    }

    private func export(_ id: UUID, paperNote: Bool, pages text: String) {
        exporting = true
        DispatchQueue.main.async {
            defer { exporting = false }
            do {
                let session = try NotebookSession(id: id)
                let pages = try PageSelection.parse(text, pageCount: session.document.pages.count)
                let url = paperNote ? try NotebookExporter.exportPaperNote(session: session, pages: pages)
                                    : try NotebookExporter.exportPDF(session: session, pages: pages)
                shareItem = ShareItem(url: url)
            } catch {
                errorMessage = L("匯出失敗：\(error.localizedDescription)")
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
            Text(L("上一層")).font(.subheadline.weight(.semibold))
            Color.clear.frame(height: GridCaption.height)
        }
    }
}

/// 大圖底下那行小字（和選單 ⌄）的高度
enum GridCaption {
    static let height: CGFloat = 24
}

struct FolderCell: View {
    let folder: Folder
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
        }
    }
}

struct NotebookCell: View {
    let meta: NotebookMeta
    let coverURL: URL

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // 格子的大小由外框決定，封面填滿後裁掉多的：橫向的封面圖比較寬，直接放的話會把格子撐寬、蓋到隔壁
                Color.clear
                    .frame(height: 210)
                    .frame(maxWidth: .infinity)
                    .overlay { cover }
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

struct MoveSheet: View {
    @EnvironmentObject var store: LibraryStore
    let items: [LibraryItem]
    let onPick: (UUID?) -> Void
    let onCancel: () -> Void

    var body: some View {
        FolderPickerSheet(title: items.count == 1 ? L("移動「\(items[0].name)」到…") : L("移動 \(items.count) 個項目到…"),
                          confirmTitle: L("移動"), isDisabled: isDisabled, onPick: onPick, onCancel: onCancel)
    }

    private func isDisabled(_ f: Folder) -> Bool {
        items.contains { item in
            if case let .folder(moving) = item { return store.isFolder(f.id, inside: moving.id) }
            return false
        }
    }
}

/// 選資料夾（移動、匯入）：一開始只列出最上層，點最左邊的 ＞ 展開（展開後朝下），點名稱選這個資料夾
/// 選資料夾的視窗目前選了哪一個、展開了哪些
struct FolderPickerState {
    /// nil：資料庫（最上層）
    var selected: UUID?
    var expanded: Set<UUID> = []

    /// 點一個資料夾：選它，有子資料夾就展開（只是想看裡面有什麼也不會馬上匯入）；
    /// 點已經選著的資料夾：收合／展開
    mutating func tap(_ id: UUID?, hasChildren: Bool) {
        guard let id else { selected = nil; return }
        if selected == id {
            if hasChildren { toggle(id) }
        } else {
            selected = id
            if hasChildren { expanded.insert(id) }
        }
    }

    mutating func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

struct FolderPickerSheet: View {
    @EnvironmentObject var store: LibraryStore
    let title: String
    /// 右上角確定的按鈕（匯入、移動）
    var confirmTitle = L("選擇")
    var isDisabled: (Folder) -> Bool = { _ in false }
    let onPick: (UUID?) -> Void
    let onCancel: () -> Void
    @State var state = FolderPickerState()

    private static let chevronWidth: CGFloat = 28

    /// 選著的那一列：比較深的灰色
    private func background(_ id: UUID?) -> Color? {
        state.selected == id ? Color(uiColor: .systemGray4) : nil
    }

    private func tap(_ id: UUID?, hasChildren: Bool) {
        withAnimation(.easeInOut(duration: 0.15)) { state.tap(id, hasChildren: hasChildren) }
    }

    var body: some View {
        NavigationStack {
            List {
                HStack(spacing: 6) {
                    Color.clear.frame(width: Self.chevronWidth)
                    Button { tap(nil, hasChildren: false) } label: {
                        Label(L("資料庫（最上層）"), systemImage: "books.vertical")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityAddTraits(state.selected == nil ? .isSelected : [])
                }
                .listRowBackground(background(nil))
                ForEach(store.folderRows(expanded: state.expanded), id: \.folder.id) { row in
                    HStack(spacing: 6) {
                        if row.hasChildren {
                            let open = state.expanded.contains(row.folder.id)
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) { state.toggle(row.folder.id) }
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.subheadline.weight(.semibold))
                                    .rotationEffect(.degrees(open ? 90 : 0))
                                    .frame(width: Self.chevronWidth, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(open ? L("收合「\(row.folder.name)」") : L("展開「\(row.folder.name)」"))
                        } else {
                            Color.clear.frame(width: Self.chevronWidth)
                        }
                        Button { tap(row.folder.id, hasChildren: row.hasChildren) } label: {
                            Label(row.folder.name, systemImage: "folder")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .disabled(isDisabled(row.folder))
                        .accessibilityAddTraits(state.selected == row.folder.id ? .isSelected : [])
                    }
                    .padding(.leading, CGFloat(row.depth) * 20)
                    .listRowBackground(background(row.folder.id))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("取消"), action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) { onPick(state.selected) }
                        .fontWeight(.semibold)
                }
            }
        }
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

/// 詳細資料的欄寬：表頭和每一列都用這些，欄位才對得齊
enum DetailColumns {
    static let inset: CGFloat = 20
    static let check: CGFloat = 30
    static let icon: CGFloat = 50
    static let iconHeight: CGFloat = 66
    static let modified: CGFloat = 170
    static let menu: CGFloat = 36
    static let star: CGFloat = 36
    static let spacing: CGFloat = 12
}

/// 資料庫的日期：24 小時制、固定格式（一行放得下，不會換行）
enum LibraryDate {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
    private static let dayFormatter = formatter("yyyy/MM/dd")
    private static let dateTimeFormatter = formatter("yyyy/MM/dd HH:mm")

    static func day(_ d: Date) -> String { dayFormatter.string(from: d) }
    static func dateTime(_ d: Date) -> String { dateTimeFormatter.string(from: d) }
}

struct DetailHeader: View {
    var selecting = false
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        HStack(spacing: DetailColumns.spacing) {
            if selecting { Color.clear.frame(width: DetailColumns.check, height: 1) }
            Color.clear.frame(width: DetailColumns.icon, height: 1)
            Text(L("名稱"))
            Spacer(minLength: 8)
            // 選單 ⌄、星星那一欄（在修改日期左邊）
            Color.clear.frame(width: DetailColumns.menu + DetailColumns.star, height: 1)
            if hSize == .regular {
                Text(L("修改日期")).frame(width: DetailColumns.modified, alignment: .leading)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

/// 我的最愛文件：畫面中間的視窗，只列出打星號的筆記本，點了打開。
/// 不在資料庫裡切換，才不會以為資料庫的工具（選取、新增、檢視方式）在這裡也有作用
struct FavoriteDocumentsSheet: View {
    @EnvironmentObject var store: LibraryStore
    let onOpen: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.favoriteNotebooks.isEmpty {
                    ContentUnavailableView(L("還沒有我的最愛文件"), systemImage: "star",
                                           description: Text(L("點筆記本旁邊的星星，就會加到這裡。")))
                } else {
                    List(store.favoriteNotebooks) { nb in
                        HStack(spacing: 12) {
                            Button {
                                onOpen(nb.id)
                                dismiss()
                            } label: { row(nb) }
                            .buttonStyle(.plain)
                            Button { store.setStarred(nb.id, false) } label: {
                                Image(systemName: "star.fill").foregroundStyle(.orange)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L("把「\(nb.title)」移出我的最愛文件"))
                        }
                    }
                }
            }
            .navigationTitle(L("我的最愛文件"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() } }
            }
        }
        .presentationSizing(.form)
    }

    private func row(_ nb: NotebookMeta) -> some View {
        HStack(spacing: 12) {
            Group {
                if let img = UIImage(contentsOfFile: store.coverImageURL(nb.id).path) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Color(uiColor: UIColor(hex: nb.coverHex))
                }
            }
            .frame(width: 36, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.3)))
            VStack(alignment: .leading, spacing: 3) {
                Text(nb.title).font(.headline).lineLimit(1)
                Text([nb.folderId.flatMap { store.folder($0)?.name } ?? L("資料庫"), LibraryDate.dateTime(nb.modified)]
                    .joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// 詳細資料的一列（不含右邊的選單 ⌄）。checked：選取模式的勾勾（nil＝不在選取模式）
struct DetailRow: View {
    let cover: NotebookMeta?
    let isFolder: Bool
    let name: String
    let modified: Date?
    var coverURL: URL? = nil
    var isParent = false
    var checked: Bool? = nil
    @Environment(\.horizontalSizeClass) private var hSize

    private var modifiedText: String { modified.map(LibraryDate.dateTime) ?? "—" }

    var body: some View {
        HStack(spacing: DetailColumns.spacing) {
            if let checked {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                    .frame(width: DetailColumns.check)
                    .opacity(isParent ? 0 : 1)
            }
            icon.frame(width: DetailColumns.icon, height: DetailColumns.iconHeight)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.title3.weight(.medium)).lineLimit(1)
                if hSize != .regular, modified != nil {
                    Text(modifiedText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            // 選單 ⌄、星星的位置（疊在上面，不放在按鈕裡）
            Color.clear.frame(width: DetailColumns.menu + DetailColumns.star, height: 1)
            if hSize == .regular {
                Text(isParent ? "" : modifiedText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(modified == nil ? Color.secondary : Color.primary)
                    .frame(width: DetailColumns.modified, alignment: .leading)
            }
        }
        .font(.body)
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        .padding(.vertical, 10)
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
                .frame(width: DetailColumns.icon, height: DetailColumns.iconHeight)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.3)))
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(uiColor: UIColor(hex: cover?.coverHex ?? Palette.covers[0])))
        }
    }
}
