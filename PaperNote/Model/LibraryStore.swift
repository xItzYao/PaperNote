import Foundation
import PDFKit
import UIKit

enum LibraryError: LocalizedError {
    case unreadablePDF
    case lockedPDF

    var errorDescription: String? {
        switch self {
        case .unreadablePDF: return "無法讀取這個 PDF 檔。"
        case .lockedPDF: return "這個 PDF 有密碼保護，請先解除密碼再匯入。"
        }
    }
}

/// 管理資料夾與筆記本清單（Documents/library.json）。
/// 每本筆記本的內容放在 Documents/Notebooks/<id>/，可在「檔案」App 直接備份。
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var index = LibraryIndex()

    let documentsURL: URL
    var notebooksURL: URL { documentsURL.appendingPathComponent("Notebooks", isDirectory: true) }
    private var indexURL: URL { documentsURL.appendingPathComponent("library.json") }
    private let fm = FileManager.default

    private init() {
        documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: notebooksURL, withIntermediateDirectories: true)
        load()
    }

    // MARK: Persistence

    private func load() {
        if let data = try? Data(contentsOf: indexURL),
           let idx = try? JSONDecoder.app.decode(LibraryIndex.self, from: data) {
            index = idx
        }
        recoverOrphans()
    }

    private func save() {
        guard let data = try? JSONEncoder.app.encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// 如果 library.json 遺失或損毀，把磁碟上的筆記本找回來
    private func recoverOrphans() {
        let known = Set(index.notebooks.map(\.id))
        guard let dirs = try? fm.contentsOfDirectory(at: notebooksURL, includingPropertiesForKeys: nil) else { return }
        var changed = false
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent), !known.contains(id),
                  let data = try? Data(contentsOf: NotebookSession.documentURL(in: dir)),
                  let doc = try? JSONDecoder.app.decode(NotebookDocument.self, from: data) else { continue }
            var meta = NotebookMeta(title: "復原的筆記本", folderId: nil, coverHex: Palette.covers[0])
            meta.id = id
            meta.pageCount = doc.pages.count
            index.notebooks.append(meta)
            changed = true
        }
        if changed { save() }
    }

    /// 從雲端還原後：補上資料夾與筆記本清單
    func mergeRestored(_ remote: LibraryIndex?) {
        if let remote {
            for f in remote.folders where folder(f.id) == nil { index.folders.append(f) }
            for nb in remote.notebooks where notebook(nb.id) == nil
                && fm.fileExists(atPath: NotebookSession.documentURL(in: notebookURL(nb.id)).path) {
                index.notebooks.append(nb)
            }
            save()
        }
        recoverOrphans()
    }

    func notebookURL(_ id: UUID) -> URL {
        notebooksURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func coverImageURL(_ id: UUID) -> URL {
        notebookURL(id).appendingPathComponent("thumbs/cover.jpg")
    }

    func thumbnailURL(notebook: UUID, page: UUID) -> URL {
        notebookURL(notebook).appendingPathComponent("thumbs/\(page.uuidString).jpg")
    }

    // MARK: Queries

    func folders(in parent: UUID?) -> [Folder] {
        index.folders.filter { $0.parentId == parent }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func notebooks(in folder: UUID?) -> [NotebookMeta] {
        index.notebooks.filter { $0.folderId == folder }.sorted { $0.modified > $1.modified }
    }

    func folder(_ id: UUID) -> Folder? { index.folders.first { $0.id == id } }
    func notebook(_ id: UUID) -> NotebookMeta? { index.notebooks.first { $0.id == id } }

    /// f 是否等於 ancestor 或在 ancestor 底下
    func isFolder(_ f: UUID, inside ancestor: UUID) -> Bool {
        var cur: UUID? = f
        var guardCount = 0
        while let c = cur, guardCount < 1000 {
            if c == ancestor { return true }
            cur = folder(c)?.parentId
            guardCount += 1
        }
        return false
    }

    /// 所有資料夾，依樹狀順序攤平（給「移動到」選單用）
    func folderTree() -> [(folder: Folder, depth: Int)] {
        var result: [(folder: Folder, depth: Int)] = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for f in folders(in: parent) {
                result.append((folder: f, depth: depth))
                walk(f.id, depth + 1)
            }
        }
        walk(nil, 0)
        return result
    }

    func itemCount(in folder: UUID) -> Int {
        folders(in: folder).count + notebooks(in: folder).count
    }

    // MARK: Folders

    @discardableResult
    func createFolder(name: String, parent: UUID?) -> Folder {
        let f = Folder(name: name.isEmpty ? "新資料夾" : name, parentId: parent)
        index.folders.append(f)
        save()
        return f
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let i = index.folders.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        index.folders[i].name = name
        save()
    }

    @discardableResult
    func moveFolder(_ id: UUID, to parent: UUID?) -> Bool {
        if let p = parent, isFolder(p, inside: id) { return false }
        guard let i = index.folders.firstIndex(where: { $0.id == id }) else { return false }
        index.folders[i].parentId = parent
        save()
        return true
    }

    func deleteFolder(_ id: UUID) {
        for sub in folders(in: id) { deleteFolder(sub.id) }
        for nb in notebooks(in: id) { deleteNotebook(nb.id) }
        index.folders.removeAll { $0.id == id }
        save()
    }

    func duplicateFolder(_ id: UUID) {
        guard let f = folder(id) else { return }
        copyFolder(f, into: f.parentId, name: f.name + " 複本")
        save()
    }

    private func copyFolder(_ f: Folder, into parent: UUID?, name: String) {
        let newFolder = Folder(name: name, parentId: parent)
        index.folders.append(newFolder)
        for sub in folders(in: f.id) where sub.id != newFolder.id {
            copyFolder(sub, into: newFolder.id, name: sub.name)
        }
        for nb in notebooks(in: f.id) {
            copyNotebook(nb, into: newFolder.id, title: nb.title)
        }
    }

    // MARK: Notebooks

    @discardableResult
    func createNotebook(title: String, folder: UUID?, paper: PaperStyle, landscape: Bool, coverHex: String? = nil) -> NotebookMeta {
        var meta = NotebookMeta(title: title.isEmpty ? "未命名筆記本" : title, folderId: folder,
                                coverHex: coverHex ?? Palette.covers.randomElement()!)
        let dir = notebookURL(meta.id)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let size = landscape ? CGSize(width: 842, height: 595) : CGSize(width: 595, height: 842)
        let doc = NotebookDocument(pages: [Page(background: .paper(width: size.width, height: size.height, style: paper))])
        try? NotebookSession.writeDocument(doc, to: dir)
        meta.pageCount = 1
        index.notebooks.append(meta)
        save()
        return meta
    }

    func importPDF(from url: URL, folder: UUID?) throws -> NotebookMeta {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        var meta = NotebookMeta(title: url.deletingPathExtension().lastPathComponent, folderId: folder,
                                coverHex: Palette.covers.randomElement()!)
        let dir = notebookURL(meta.id)
        let files = dir.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        let fileName = "pdf-\(UUID().uuidString.prefix(8)).pdf"
        let dest = files.appendingPathComponent(fileName)
        do {
            try fm.copyItem(at: url, to: dest)
            guard let pdf = PDFDocument(url: dest) else { throw LibraryError.unreadablePDF }
            if pdf.isLocked { throw LibraryError.lockedPDF }
            guard pdf.pageCount > 0 else { throw LibraryError.unreadablePDF }
            let pages = (0..<pdf.pageCount).map { Page(background: .pdf(file: fileName, index: $0)) }
            try NotebookSession.writeDocument(NotebookDocument(pages: pages), to: dir)
            meta.pageCount = pages.count
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        index.notebooks.append(meta)
        save()
        return meta
    }

    func renameNotebook(_ id: UUID, to title: String) {
        guard !title.isEmpty else { return }
        updateMeta(id) { $0.title = title }
    }

    func moveNotebook(_ id: UUID, to folder: UUID?) {
        updateMeta(id) { $0.folderId = folder }
    }

    func duplicateNotebook(_ id: UUID) {
        guard let nb = notebook(id) else { return }
        copyNotebook(nb, into: nb.folderId, title: nb.title + " 複本")
        save()
    }

    private func copyNotebook(_ nb: NotebookMeta, into folder: UUID?, title: String) {
        var copy = nb
        copy.id = UUID()
        copy.title = title
        copy.folderId = folder
        copy.created = Date()
        copy.modified = Date()
        do {
            try fm.copyItem(at: notebookURL(nb.id), to: notebookURL(copy.id))
            index.notebooks.append(copy)
        } catch {
            print("Duplicate failed: \(error)")
        }
    }

    func deleteNotebook(_ id: UUID) {
        try? fm.removeItem(at: notebookURL(id))
        index.notebooks.removeAll { $0.id == id }
        save()
    }

    func updateMeta(_ id: UUID, _ change: (inout NotebookMeta) -> Void) {
        guard let i = index.notebooks.firstIndex(where: { $0.id == id }) else { return }
        change(&index.notebooks[i])
        save()
    }

    func allFavorites() -> [(notebook: NotebookMeta, favorite: FavoriteRef)] {
        var result: [(notebook: NotebookMeta, favorite: FavoriteRef)] = []
        for nb in index.notebooks.sorted(by: { $0.modified > $1.modified }) {
            for fav in nb.favorites.sorted(by: { $0.pageNumber < $1.pageNumber }) {
                result.append((notebook: nb, favorite: fav))
            }
        }
        return result
    }
}
