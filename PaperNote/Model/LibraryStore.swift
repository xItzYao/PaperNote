import Foundation
import PDFKit
import UIKit

import UniformTypeIdentifiers

enum LibraryError: LocalizedError {
    case unreadablePDF
    case lockedPDF
    case notPaperNote
    case newerPaperNote

    var errorDescription: String? {
        switch self {
        case .unreadablePDF: return "無法讀取這個 PDF 檔。"
        case .lockedPDF: return "這個 PDF 有密碼保護，請先解除密碼再匯入。"
        case .notPaperNote: return "這不是 PaperNote 筆記本檔，或檔案已經損壞。"
        case .newerPaperNote: return "這個筆記本檔是用比較新的 PaperNote 匯出的，請先更新 App。"
        }
    }
}

extension UTType {
    /// PaperNote 筆記本檔（.papernote）：可以繼續編輯的筆記本
    static let paperNote = UTType(exportedAs: "com.papernote.notebook")
}

/// .papernote 檔裡的說明（papernote.json）；筆記本的內容放在 notebook/ 底下，和 App 裡存的一樣
struct PaperNoteManifest: Codable {
    static let currentFormat = 1
    var format = PaperNoteManifest.currentFormat
    var title: String
    var coverHex: String
}

extension Notification.Name {
    /// 筆記本改名了（object：筆記本的 UUID）
    static let notebookRenamed = Notification.Name("PaperNote.notebookRenamed")
}

/// zip 匯入的結果
struct ZipImportResult {
    var notebooks: [NotebookMeta] = []
    /// 放匯入筆記本的資料夾名稱（zip 裡沒有 PDF 時是 nil）
    var folderName: String?
    /// 不是 PDF、沒有匯入的檔案
    var skipped: [String] = []
    /// 讀不出來的 PDF：檔名、原因
    var failed: [(name: String, reason: String)] = []

    /// 給使用者看的說明
    var summary: String {
        var lines: [String] = []
        if notebooks.isEmpty {
            lines.append("zip 裡沒有可以匯入的 PDF。")
        } else {
            lines.append("已匯入 \(notebooks.count) 本筆記本，放在「\(folderName ?? "")」資料夾。")
        }
        if !skipped.isEmpty {
            lines.append("有 \(skipped.count) 個檔案不是 PDF，沒有匯入。")
            if skipped.contains(where: { $0.lowercased().hasSuffix(".goodnotes") }) {
                lines.append("其中有 GoodNotes 格式的檔案：請在 GoodNotes 匯出時選「PDF」格式。")
            }
        }
        for f in failed { lines.append("「\(f.name)」沒有匯入：\(f.reason)") }
        return lines.joined(separator: "\n")
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
        purgeExpiredTrash()
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
        index.folders.filter { $0.parentId == parent && $0.deletedAt == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func notebooks(in folder: UUID?) -> [NotebookMeta] {
        index.notebooks.filter { $0.folderId == folder && $0.deletedAt == nil }.sorted { $0.modified > $1.modified }
    }

    /// 資料夾本身或上層資料夾在垃圾桶裡
    func isFolderTrashed(_ id: UUID?) -> Bool {
        var cur = id
        var guardCount = 0
        while let c = cur, guardCount < 1000 {
            guard let f = folder(c) else { return false }
            if f.deletedAt != nil { return true }
            cur = f.parentId
            guardCount += 1
        }
        return false
    }

    /// 筆記本在垃圾桶裡（自己被刪，或所在資料夾被刪）
    func isHidden(_ nb: NotebookMeta) -> Bool { nb.deletedAt != nil || isFolderTrashed(nb.folderId) }

    /// 資料庫看得到的筆記本（不含垃圾桶）
    var visibleNotebooks: [NotebookMeta] { index.notebooks.filter { !isHidden($0) } }

    /// 我的最愛文件：所有資料夾裡打星號的筆記本，最近修改的在上面
    var favoriteNotebooks: [NotebookMeta] {
        visibleNotebooks.filter(\.starred).sorted { $0.modified > $1.modified }
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

    /// 選資料夾的清單：一開始只有最上層，展開（expanded）的資料夾才列出底下的子資料夾
    func folderRows(expanded: Set<UUID>) -> [(folder: Folder, depth: Int, hasChildren: Bool)] {
        var result: [(folder: Folder, depth: Int, hasChildren: Bool)] = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for f in folders(in: parent) {
                let children = !folders(in: f.id).isEmpty
                result.append((folder: f, depth: depth, hasChildren: children))
                if children && expanded.contains(f.id) { walk(f.id, depth + 1) }
            }
        }
        walk(nil, 0)
        return result
    }

    /// 放進 folder 時不和裡面同類的東西重名：重名就加上 (1)、(2)…（except：自己不算）
    func availableName(_ name: String, forFolder: Bool, in folder: UUID?, except id: UUID? = nil) -> String {
        let taken = Set(forFolder ? folders(in: folder).filter { $0.id != id }.map(\.name)
                                  : notebooks(in: folder).filter { $0.id != id }.map(\.title))
        guard taken.contains(name) else { return name }
        var n = 1
        while taken.contains("\(name) (\(n))") { n += 1 }
        return "\(name) (\(n))"
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
        guard index.folders[i].parentId != parent else { return true }
        index.folders[i].name = availableName(index.folders[i].name, forFolder: true, in: parent, except: id)
        index.folders[i].parentId = parent
        save()
        return true
    }

    // MARK: 垃圾桶

    func trashFolder(_ id: UUID) {
        guard let i = index.folders.firstIndex(where: { $0.id == id }) else { return }
        index.folders[i].deletedAt = Date()
        save()
    }

    func trashNotebook(_ id: UUID) {
        updateMeta(id) { $0.deletedAt = Date() }
    }

    /// 還原；原本的資料夾不在了就放回最上層
    func restoreFolder(_ id: UUID) {
        guard let i = index.folders.firstIndex(where: { $0.id == id }) else { return }
        index.folders[i].deletedAt = nil
        if let p = index.folders[i].parentId, folder(p) == nil || isFolderTrashed(p) { index.folders[i].parentId = nil }
        save()
    }

    func restoreNotebook(_ id: UUID) {
        guard let nb = notebook(id) else { return }
        // 先判斷好，避免在修改 index 的同時又讀取它
        let folderGone = nb.folderId.map { folder($0) == nil || isFolderTrashed($0) } ?? false
        updateMeta(id) { meta in
            meta.deletedAt = nil
            if folderGone { meta.folderId = nil }
        }
    }

    /// 垃圾桶裡最上層的項目（資料夾裡的東西跟著資料夾，不另外列）
    var trashedFolders: [Folder] {
        index.folders.filter { $0.deletedAt != nil && !isFolderTrashed($0.parentId) }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    var trashedNotebooks: [NotebookMeta] {
        index.notebooks.filter { $0.deletedAt != nil && !isFolderTrashed($0.folderId) }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// 有「最近刪除的頁面」的筆記本
    var notebooksWithTrashedPages: [NotebookMeta] {
        visibleNotebooks.filter { $0.trashedPageCount > 0 }.sorted { $0.modified > $1.modified }
    }

    /// 超過 30 天的項目永久刪除（頁面的部分在打開筆記本時處理）
    func purgeExpiredTrash() {
        for f in index.folders where f.deletedAt.map(Trash.isExpired) == true { deleteFolder(f.id) }
        for nb in index.notebooks where nb.deletedAt.map(Trash.isExpired) == true { deleteNotebook(nb.id) }
    }

    func emptyTrash() {
        for f in trashedFolders { deleteFolder(f.id) }
        for nb in trashedNotebooks { deleteNotebook(nb.id) }
    }

    // MARK: 永久刪除

    func deleteFolder(_ id: UUID) {
        // 包含已經在垃圾桶裡的子項目
        for sub in index.folders where sub.parentId == id { deleteFolder(sub.id) }
        for nb in index.notebooks where nb.folderId == id { deleteNotebook(nb.id) }
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
    func createNotebook(title: String, folder: UUID?, paper: PaperStyle, landscape: Bool, size paperSize: PaperSize = .a4,
                        coverHex: String? = nil) -> NotebookMeta {
        var meta = NotebookMeta(title: title.isEmpty ? "未命名筆記本" : title, folderId: folder,
                                coverHex: coverHex ?? Palette.covers.randomElement()!)
        let dir = notebookURL(meta.id)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let size = PaperSize.oriented(paperSize.size, landscape: landscape)
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

    /// 匯入 PaperNote 筆記本檔：變成一本新的筆記本，筆跡都可以繼續編輯
    func importPaperNote(from url: URL, folder: UUID?) throws -> NotebookMeta {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let archive: ZipArchive
        do { archive = try ZipArchive(url: url) } catch { throw LibraryError.notPaperNote }
        guard let m = archive.entries.first(where: { $0.path == "papernote.json" }),
              let manifest = try? JSONDecoder.app.decode(PaperNoteManifest.self, from: archive.contents(of: m))
        else { throw LibraryError.notPaperNote }
        guard manifest.format <= PaperNoteManifest.currentFormat else { throw LibraryError.newerPaperNote }

        var meta = NotebookMeta(title: manifest.title, folderId: folder, coverHex: manifest.coverHex)
        let dir = notebookURL(meta.id)
        do {
            for e in archive.entries where e.path.hasPrefix("notebook/") && !e.isDirectory {
                // 只解到這本筆記本的資料夾裡（擋掉「..」這種會跑到外面的路徑）
                let rel = String(e.path.dropFirst("notebook/".count))
                let comps = rel.split(separator: "/", omittingEmptySubsequences: false)
                guard !comps.isEmpty, !comps.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                    throw LibraryError.notPaperNote
                }
                let dest = dir.appendingPathComponent(rel)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try archive.extract(e, to: dest)
            }
            let doc = try JSONDecoder.app.decode(NotebookDocument.self,
                                                 from: Data(contentsOf: NotebookSession.documentURL(in: dir)))
            meta.pageCount = doc.pages.count
            meta.trashedPageCount = doc.trash?.count ?? 0
        } catch {
            try? fm.removeItem(at: dir)
            throw (error as? LibraryError) ?? LibraryError.notPaperNote
        }
        index.notebooks.append(meta)
        save()
        return meta
    }

    /// 匯入 zip（例如從 GoodNotes 一次匯出好幾本的 PDF）：每個 PDF 變成一本筆記本，
    /// 全部放進一個新資料夾，zip 裡的資料夾照樣建立；不是 PDF 的檔案略過
    func importZip(from url: URL, folder: UUID?) throws -> ZipImportResult {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let archive = try ZipArchive(url: url)
        func isJunk(_ e: ZipArchive.Entry) -> Bool {
            e.path.hasPrefix("__MACOSX/") || e.name.hasPrefix("._") || e.name == ".DS_Store"
        }
        let files = archive.entries.filter { !$0.isDirectory && !isJunk($0) }
        let pdfs = files.filter { $0.name.lowercased().hasSuffix(".pdf") }
        var result = ZipImportResult()
        result.skipped = files.filter { !$0.name.lowercased().hasSuffix(".pdf") }.map(\.name)
        guard !pdfs.isEmpty else { return result }

        // 外層資料夾：zip 裡只有一個最上層資料夾就用它的名字，否則用 zip 的檔名
        var dirs: [[String]] = pdfs.map { e in Array(e.path.split(separator: "/").map(String.init).dropLast()) }
        let topName: String
        if let first = dirs.first?.first, dirs.allSatisfy({ $0.first == first }) {
            topName = first
            dirs = dirs.map { Array($0.dropFirst()) }
        } else {
            topName = url.deletingPathExtension().lastPathComponent
        }
        // 已經有同名資料夾（例如同一個 zip 匯入第二次）：新資料夾加上 (2)、(3)…，一眼看得出是哪一次匯入的
        let siblings = Set(folders(in: folder).map(\.name))
        var name = topName, n = 2
        while siblings.contains(name) {
            name = "\(topName) (\(n))"
            n += 1
        }
        let top = createFolder(name: name, parent: folder)
        result.folderName = top.name
        var folderIDs: [String: UUID] = ["": top.id]
        func folderID(_ comps: [String]) -> UUID {
            let key = comps.joined(separator: "/")
            if let id = folderIDs[key] { return id }
            let f = createFolder(name: comps[comps.count - 1], parent: folderID(Array(comps.dropLast())))
            folderIDs[key] = f.id
            return f.id
        }

        let tmp = fm.temporaryDirectory.appendingPathComponent("zip-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        for (entry, comps) in zip(pdfs, dirs) {
            // 解到暫存資料夾、保留原本的檔名（筆記本名稱用檔名）
            let dir = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent(entry.name)
                try archive.extract(entry, to: file)
                result.notebooks.append(try importPDF(from: file, folder: folderID(comps)))
            } catch {
                result.failed.append((entry.name, error.localizedDescription))
            }
            try? fm.removeItem(at: dir)
        }
        return result
    }

    /// 加入／移出我的最愛文件（不算修改筆記本，修改日期不變）
    func setStarred(_ id: UUID, _ on: Bool) {
        updateMeta(id) { $0.starred = on }
    }

    func renameNotebook(_ id: UUID, to title: String) {
        guard !title.isEmpty else { return }
        updateMeta(id) { $0.title = title }
    }

    /// 移到 folder；裡面已經有同名的筆記本就加上 (1)
    func moveNotebook(_ id: UUID, to folder: UUID?) {
        guard let nb = notebook(id), nb.folderId != folder else { return }
        let title = availableName(nb.title, forFolder: false, in: folder, except: id)
        updateMeta(id) {
            $0.folderId = folder
            $0.title = title
        }
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
        for nb in visibleNotebooks.sorted(by: { $0.modified > $1.modified }) {
            for fav in nb.favorites.sorted(by: { $0.pageNumber < $1.pageNumber }) {
                result.append((notebook: nb, favorite: fav))
            }
        }
        return result
    }
}
