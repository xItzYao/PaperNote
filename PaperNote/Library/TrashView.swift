import SwiftUI

/// 永久刪除前的確認文字
enum PermanentDeleteText {
    static let message = L("此操作將會把本機檔案永久刪除，且無法復原；雲端檔案會移到 Google Drive 的垃圾桶")

    static func title(_ name: String) -> String { L("確認刪除\(name)?") }
}

/// 垃圾桶：被刪除的資料夾、筆記本，以及各筆記本最近刪除的頁面（30 天後自動永久刪除）
struct TrashView: View {
    private enum Target {
        case folder(Folder)
        case notebook(NotebookMeta)

        var name: String {
            switch self {
            case let .folder(f): return f.name
            case let .notebook(nb): return nb.title
            }
        }
    }

    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEmpty = false
    @State private var deleteTarget: Target?
    @State private var pagesOf: NotebookMeta?

    var body: some View {
        NavigationStack {
            List {
                if store.trashedFolders.isEmpty && store.trashedNotebooks.isEmpty && store.notebooksWithTrashedPages.isEmpty {
                    ContentUnavailableView(L("垃圾桶是空的"), systemImage: "trash",
                                           description: Text(L("刪除的筆記本、資料夾和頁面會在這裡保留 \(Trash.retentionDays) 天。")))
                }
                if !store.trashedFolders.isEmpty || !store.trashedNotebooks.isEmpty {
                    Section(L("筆記本與資料夾")) {
                        ForEach(store.trashedFolders) { f in
                            row(icon: "folder.fill", title: f.name,
                                detail: L("\(store.index.notebooks.filter { $0.folderId == f.id }.count) 本筆記本"),
                                deletedAt: f.deletedAt)
                                .swipeActions(edge: .trailing) {
                                    Button(L("永久刪除")) { deleteTarget = .folder(f) }.tint(.red)
                                }
                                .swipeActions(edge: .leading) {
                                    Button(L("還原")) { store.restoreFolder(f.id) }.tint(.blue)
                                }
                                .contextMenu {
                                    Button { store.restoreFolder(f.id) } label: { Label(L("還原"), systemImage: "arrow.uturn.backward") }
                                    Button(role: .destructive) { deleteTarget = .folder(f) } label: { Label(L("永久刪除"), systemImage: "trash") }
                                }
                        }
                        ForEach(store.trashedNotebooks) { nb in
                            row(icon: "book.closed.fill", title: nb.title, detail: L("\(nb.pageCount) 頁"), deletedAt: nb.deletedAt)
                                .swipeActions(edge: .trailing) {
                                    Button(L("永久刪除")) { deleteTarget = .notebook(nb) }.tint(.red)
                                }
                                .swipeActions(edge: .leading) {
                                    Button(L("還原")) { store.restoreNotebook(nb.id) }.tint(.blue)
                                }
                                .contextMenu {
                                    Button { store.restoreNotebook(nb.id) } label: { Label(L("還原"), systemImage: "arrow.uturn.backward") }
                                    Button(role: .destructive) { deleteTarget = .notebook(nb) } label: { Label(L("永久刪除"), systemImage: "trash") }
                                }
                        }
                    }
                }
                if !store.notebooksWithTrashedPages.isEmpty {
                    Section(L("最近刪除的頁面")) {
                        ForEach(store.notebooksWithTrashedPages) { nb in
                            Button { pagesOf = nb } label: {
                                HStack {
                                    Label(nb.title, systemImage: "doc.on.doc")
                                    Spacer()
                                    Text(L("\(nb.trashedPageCount) 頁")).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(L("垃圾桶"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("完成")) { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button(L("清空"), role: .destructive) { confirmEmpty = true }
                        .disabled(store.trashedFolders.isEmpty && store.trashedNotebooks.isEmpty && store.notebooksWithTrashedPages.isEmpty)
                }
            }
            .alert(PermanentDeleteText.title(L("垃圾桶裡的全部項目")), isPresented: $confirmEmpty) {
                Button(L("永久刪除全部"), role: .destructive) { emptyAll() }
                Button(L("取消"), role: .cancel) {}
            } message: {
                Text(PermanentDeleteText.message)
            }
            .alert(PermanentDeleteText.title(deleteTarget?.name ?? ""),
                   isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                   presenting: deleteTarget) { target in
                Button(L("永久刪除"), role: .destructive) {
                    switch target {
                    case let .folder(f): store.deleteFolder(f.id)
                    case let .notebook(nb): store.deleteNotebook(nb.id)
                    }
                }
                Button(L("取消"), role: .cancel) {}
            } message: { _ in
                Text(PermanentDeleteText.message)
            }
            .sheet(item: $pagesOf) { nb in
                TrashedPagesSheet(notebookID: nb.id, title: nb.title)
            }
        }
        .onAppear { store.purgeExpiredTrash() }
    }

    private func row(icon: String, title: String, detail: String, deletedAt: Date?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let d = deletedAt {
                Text(L("\(Trash.daysLeft(d)) 天後刪除")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func emptyAll() {
        for nb in store.notebooksWithTrashedPages {
            guard let s = try? NotebookSession(id: nb.id) else { continue }
            s.emptyPageTrash()
            s.save()
        }
        store.emptyTrash()
    }
}

/// 某本筆記本最近刪除的頁面（在資料庫的垃圾桶打開）
struct TrashedPagesSheet: View {
    let notebookID: UUID
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var session: NotebookSession?
    @State private var items: [TrashedPageItem] = []

    var body: some View {
        NavigationStack {
            TrashedPagesList(items: items) { id in
                guard let s = session else { return }
                s.restoreTrashedPage(id)
                s.save()
                reload()
            } onDelete: { id in
                guard let s = session else { return }
                s.deleteTrashedPage(id)
                s.save()
                reload()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() } }
            }
        }
        .onAppear {
            session = try? NotebookSession(id: notebookID)
            reload()
        }
    }

    private func reload() {
        guard let s = session else { return }
        items = TrashedPageItem.make(from: s)
    }
}

struct TrashedPageItem: Identifiable {
    let id: UUID
    let originalNumber: Int
    let deletedAt: Date
    let thumbnail: UIImage?

    static func make(from s: NotebookSession) -> [TrashedPageItem] {
        s.trashedPages.map {
            TrashedPageItem(id: $0.page.id, originalNumber: $0.originalIndex + 1, deletedAt: $0.deletedAt,
                            thumbnail: s.trashedPageThumbnail($0.page.id))
        }
    }
}

/// 最近刪除的頁面清單（編輯畫面和資料庫共用）
struct TrashedPagesList: View {
    let items: [TrashedPageItem]
    let onRestore: (UUID) -> Void
    let onDelete: (UUID) -> Void
    @State private var deleteTarget: TrashedPageItem?

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView(L("沒有最近刪除的頁面"), systemImage: "doc",
                                       description: Text(L("刪除的頁面會在這裡保留 \(Trash.retentionDays) 天。")))
            }
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 12) {
                    Group {
                        if let img = item.thumbnail {
                            Image(uiImage: img).resizable().scaledToFit()
                        } else {
                            Color.gray.opacity(0.2)
                        }
                    }
                    .frame(width: 72, height: 96)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("原本的第 \(item.originalNumber) 頁")).font(.headline)
                        Text(L("\(Trash.daysLeft(item.deletedAt)) 天後永久刪除")).font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button { onRestore(item.id) } label: { Label(L("還原"), systemImage: "arrow.uturn.backward") }
                                .buttonStyle(.bordered)
                            Button(role: .destructive) { deleteTarget = item } label: { Label(L("永久刪除"), systemImage: "trash") }
                                .buttonStyle(.bordered)
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .alert(PermanentDeleteText.title(deleteTarget.map { L("原本的第 \($0.originalNumber) 頁") } ?? ""),
               isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
               presenting: deleteTarget) { item in
            Button(L("永久刪除"), role: .destructive) { onDelete(item.id) }
            Button(L("取消"), role: .cancel) {}
        } message: { _ in
            Text(PermanentDeleteText.message)
        }
    }
}
