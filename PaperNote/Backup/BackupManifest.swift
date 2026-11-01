import Foundation

/// 雲端的狀態清單（PaperNoteBackup/backup-manifest.json）：記每本筆記本、每個資料夾現在的狀態。
/// 還原時照這份清單決定：在垃圾桶的還原後還在垃圾桶，永久刪除的不會還原。
/// 永久刪除的項目只留 ID 和時間，不留名稱。
struct BackupManifest: Codable, Equatable {
    static let fileName = "backup-manifest.json"
    static let currentFormat = 1

    enum Status: String, Codable {
        case active, trashed, deleted
    }

    struct NotebookEntry: Codable, Equatable {
        var id: UUID
        var status: Status
        var meta: NotebookMeta?
        var purgedAt: Date?
    }

    struct FolderEntry: Codable, Equatable {
        var id: UUID
        var status: Status
        var folder: Folder?
        var purgedAt: Date?
    }

    var format = BackupManifest.currentFormat
    var folders: [FolderEntry] = []
    var notebooks: [NotebookEntry] = []

    init() {}

    /// 舊版備份只有 library.json：用它當第一份清單
    init(legacy index: LibraryIndex) {
        folders = index.folders.map(Self.entry)
        notebooks = index.notebooks.map(Self.entry)
    }

    /// 雲端清單加上本機的現況。本機知道的以本機為準；本機沒有的（例如新 iPad 還沒還原）保留雲端的紀錄
    static func merged(remote: BackupManifest?, index: LibraryIndex) -> BackupManifest {
        var folders: [UUID: FolderEntry] = [:]
        var notebooks: [UUID: NotebookEntry] = [:]
        for e in remote?.folders ?? [] { folders[e.id] = e }
        for e in remote?.notebooks ?? [] { notebooks[e.id] = e }
        for f in index.folders { folders[f.id] = entry(f) }
        for nb in index.notebooks { notebooks[nb.id] = entry(nb) }
        for p in index.purgedFolders { folders[p.id] = FolderEntry(id: p.id, status: .deleted, folder: nil, purgedAt: p.purgedAt) }
        for p in index.purgedNotebooks { notebooks[p.id] = NotebookEntry(id: p.id, status: .deleted, meta: nil, purgedAt: p.purgedAt) }
        var out = BackupManifest()
        out.folders = folders.values.sorted { $0.id.uuidString < $1.id.uuidString }
        out.notebooks = notebooks.values.sorted { $0.id.uuidString < $1.id.uuidString }
        return out
    }

    private static func entry(_ f: Folder) -> FolderEntry {
        FolderEntry(id: f.id, status: f.deletedAt == nil ? .active : .trashed, folder: f, purgedAt: nil)
    }

    private static func entry(_ nb: NotebookMeta) -> NotebookEntry {
        NotebookEntry(id: nb.id, status: nb.deletedAt == nil ? .active : .trashed, meta: nb, purgedAt: nil)
    }

    /// 讀不懂的清單不能拿來覆蓋雲端：直接丟錯，這次不備份
    static func decode(_ data: Data) throws -> BackupManifest {
        struct Header: Decodable { let format: Int }
        guard let header = try? JSONDecoder.app.decode(Header.self, from: data) else { throw BackupError.badManifest }
        guard header.format <= currentFormat else { throw BackupError.newerManifest }
        guard let manifest = try? JSONDecoder.app.decode(BackupManifest.self, from: data) else { throw BackupError.badManifest }
        return manifest
    }

    /// 內容一樣就會是一樣的資料，用來判斷要不要重傳
    func encoded() throws -> Data {
        let e = JSONEncoder.app
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }
}
