import UIKit
import CryptoKit

/// 還原的結果
struct RestoreResult: Equatable {
    var notebooks = 0
    /// 其中還在垃圾桶裡的
    var trashed = 0
}

/// 備份到 Google Drive 的「PaperNoteBackup」資料夾。
/// 備份的是 App 內的原始檔（library.json、每本筆記本的 document.json、筆跡、PDF、圖片），
/// 還原後筆跡、表格、螢光標示都能繼續編輯。
/// 只上傳內容有變的檔案：大小和修改時間沒變就不看；變了再比 MD5（重畫一樣的縮圖不用重傳）；
/// 本機沒有紀錄時（重新安裝、還原、重新連結）和雲端的 MD5 比，一樣就不傳。
///
/// 雲端的刪除只有兩種來源，都是使用者在 App 裡的動作：永久刪除筆記本、永久刪除頁面留下的舊檔案。
/// 兩種都只移到 Google Drive 的垃圾桶，留一個救回來的機會。
/// PaperNoteBackup 底下由 App 管理；它本身和它外面的東西一律不動。
final class BackupManager: ObservableObject {
    static let shared = BackupManager(drive: DriveClient(), library: .shared)
    static let rootFolderName = "PaperNoteBackup"
    private static let notebooksFolderName = "Notebooks"

    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var lastError: String?
    @Published private(set) var lastBackup: Date?

    var autoBackup: Bool {
        get { UserDefaults.standard.object(forKey: "backup.auto") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "backup.auto") }
    }

    private struct FileRecord: Codable {
        var id: String
        var size: Int
        var mtime: Double
        /// 舊版的紀錄沒有
        var md5: String?
    }

    private struct BackupState: Codable {
        var rootID: String?
        var folders: [String: String] = [:]
        var files: [String: FileRecord] = [:]
    }

    private let drive: DriveAPI
    private let library: LibraryStore
    private var state = BackupState()
    private let stateURL: URL
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var started = false

    init(drive: DriveAPI, library: LibraryStore, stateURL: URL? = nil) {
        self.drive = drive
        self.library = library
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.stateURL = stateURL ?? support.appendingPathComponent("backup-state.json")
        if let data = try? Data(contentsOf: self.stateURL), let s = try? JSONDecoder().decode(BackupState.self, from: data) {
            state = s
        }
        let t = UserDefaults.standard.double(forKey: "backup.last")
        lastBackup = t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private func saveState() {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    /// App 啟動時呼叫：每 10 分鐘備份一次；進入背景時也備份
    func start() {
        guard !started else { return }
        started = true
        let t = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            guard let self, self.autoBackup else { return }
            self.backupNow()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.autoBackup else { return }
            self.backupNow()
        }
    }

    /// 關閉筆記本後備份（稍微延遲，讓存檔先完成）
    func notebookClosed() {
        guard autoBackup else { return }
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.backupNow() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    func resetRemoteState() {
        state = BackupState()
        saveState()
    }

    func backupNow() {
        guard GoogleAuth.shared.isSignedIn, !isRunning else { return }
        isRunning = true
        lastError = nil
        status = L("準備備份…")
        var bgTask = UIBackgroundTaskIdentifier.invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "PaperNoteBackup") {
            UIApplication.shared.endBackgroundTask(bgTask)
        }
        Task {
            var failure: String?
            var count = 0
            do {
                count = try await syncWithRetry()
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run {
                self.isRunning = false
                if let failure {
                    self.lastError = failure
                    self.status = ""
                } else {
                    self.lastBackup = Date()
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "backup.last")
                    self.status = count == 0 ? L("沒有變動") : L("已更新 \(count) 個檔案")
                }
                UIApplication.shared.endBackgroundTask(bgTask)
            }
        }
    }

    private func setStatus(_ s: String) async {
        await MainActor.run { self.status = s }
    }

    func syncWithRetry() async throws -> Int {
        do {
            return try await sync()
        } catch BackupError.http(404, _) {
            // 雲端的資料夾被刪掉了 → 重新建立後全部重傳
            state = BackupState()
            saveState()
            return try await sync()
        }
    }

    private func sync() async throws -> Int {
        // 中途失敗或被系統暫停也要記下傳好的，下次才不用重新比對
        defer { saveState() }
        let root = try await rootFolder()
        let docs = library.documentsURL
        var files: [(url: URL, rel: String)] = []
        let libraryFile = docs.appendingPathComponent("library.json")
        if FileManager.default.fileExists(atPath: libraryFile.path) { files.append((libraryFile, "library.json")) }
        let notebooks = library.notebooksURL
        let keys: [URLResourceKey] = [.isDirectoryKey]
        if let en = FileManager.default.enumerator(at: notebooks, includingPropertiesForKeys: keys) {
            for case let url as URL in en {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false else { continue }
                // 用 /Documents/Notebooks/ 之後的路徑（避免 /private/var 與 /var 的差異）
                guard let r = url.path.range(of: "/Documents/Notebooks/") else { continue }
                files.append((url, "Notebooks/" + url.path[r.upperBound...]))
            }
        }

        let snapshot = await MainActor.run { library.index }
        let purged = Set(snapshot.purgedNotebooks.map(\.id))
        files.removeAll { f in Self.notebookID(of: f.rel).map { purged.contains($0) } == true }

        // 清單最先傳：之後就算中斷，雲端也已經記下誰被刪了，還原不會把它們帶回來。
        // 也要在 library.json 之前：新 iPad 還沒還原就連結時，library.json 會被蓋掉
        let stored = try await storedManifest(in: root)
        let base = try await stored == nil ? legacyManifest(in: root) : stored
        let manifest = BackupManifest.merged(remote: base, index: snapshot)
        let manifestData = try manifest.encoded()
        if try stored?.encoded() != manifestData {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-\(UUID().uuidString).json")
            try manifestData.write(to: tmp, options: .atomic)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let existing = try await drive.findFile(named: BackupManifest.fileName, in: root)
            let id = try await drive.upload(tmp, name: BackupManifest.fileName, parent: root, existingID: existing?.id)
            state.files[BackupManifest.fileName] = FileRecord(id: id, size: manifestData.count, mtime: 0, md5: nil)
            saveState()
        }

        // 先挑出內容真的變了的，進度才會是「要傳幾個」，不是全部幾個
        var changed: [(url: URL, rel: String, size: Int, mtime: Double, md5: String?)] = []
        for f in files {
            let values = try? f.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let rec = state.files[f.rel]
            if let rec, rec.size == size, rec.mtime == mtime { continue }
            let md5 = try? Self.md5(of: f.url)
            if let rec, let md5, rec.md5 == md5 {
                state.files[f.rel] = FileRecord(id: rec.id, size: size, mtime: mtime, md5: md5)
                continue
            }
            changed.append((f.url, f.rel, size, mtime, md5))
        }

        var uploaded = 0
        for (i, f) in changed.enumerated() {
            await setStatus(L("備份中…（\(i + 1)/\(changed.count)）"))
            let parentRel = (f.rel as NSString).deletingLastPathComponent
            let parent = try await folderID(for: parentRel, root: root)
            let name = (f.rel as NSString).lastPathComponent
            // 用名稱找雲端的檔案，不靠紀錄的 ID：重新安裝後不會多一份
            let remote = try await drive.findFile(named: name, in: parent)
            let id: String
            if let remote, let md5 = f.md5, remote.md5Checksum == md5 {
                id = remote.id
            } else {
                id = try await drive.upload(f.url, name: name, parent: parent, existingID: remote?.id)
                uploaded += 1
            }
            state.files[f.rel] = FileRecord(id: id, size: f.size, mtime: f.mtime, md5: f.md5)
            if (i + 1) % 10 == 0 { saveState() }
        }
        saveState()

        let removed = try await removeNotebookFolders(purged: snapshot.purgedNotebooks.map(\.id), manifest: manifest, root: root)
            + removeFilesOfDeletedPages(index: snapshot)
        saveState()
        await MainActor.run {
            library.clearPurged(notebooks: snapshot.purgedNotebooks.map(\.id), folders: snapshot.purgedFolders.map(\.id))
        }
        return uploaded + removed
    }

    /// 和 Google Drive 的 md5Checksum 一樣的格式。分段讀，大 PDF 不會整個載入記憶體
    static func md5(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Notebooks/<id>/… 的 id
    private static func notebookID(of rel: String) -> UUID? {
        let comps = rel.split(separator: "/")
        guard comps.count >= 2, comps[0] == notebooksFolderName else { return nil }
        return UUID(uuidString: String(comps[1]))
    }

    // MARK: - 清單

    private func storedManifest(in root: String) async throws -> BackupManifest? {
        guard let file = try await drive.findFile(named: BackupManifest.fileName, in: root) else { return nil }
        return try await BackupManifest.decode(downloadData(file.id))
    }

    private func legacyManifest(in root: String) async throws -> BackupManifest? {
        guard let file = try await drive.findFile(named: "library.json", in: root) else { return nil }
        // 下載失敗要往外丟：不然會當成沒有舊資料，接著蓋掉雲端的 library.json
        let data = try await downloadData(file.id)
        guard let index = try? JSONDecoder.app.decode(LibraryIndex.self, from: data) else { return nil }
        return BackupManifest(legacy: index)
    }

    private func downloadData(_ id: String) async throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await drive.download(id, to: tmp)
        return try Data(contentsOf: tmp)
    }

    // MARK: - 永久刪除

    /// 把 Notebooks 底下永久刪除的筆記本資料夾移到 Drive 垃圾桶，只會動 Notebooks/<id> 這一層。
    /// 這台 iPad 永久刪除的（purged）整個移。清單記成刪除、但不是這台刪的，只清已經沒有檔案的
    /// （舊版刪除時留下的空資料夾）：只憑清單不動任何檔案
    private func removeNotebookFolders(purged ids: [UUID], manifest: BackupManifest, root: String) async throws -> Int {
        let deleted = Set(manifest.notebooks.filter { $0.status == .deleted }.map(\.id))
        guard !deleted.isEmpty else { return 0 }
        var removed = 0
        if let folder = try await drive.findFolder(named: Self.notebooksFolderName, in: root) {
            for f in try await drive.children(of: folder) where f.isFolder {
                guard let id = UUID(uuidString: f.name), deleted.contains(id) else { continue }
                let hasFiles = try await containsFiles(f.id)
                if ids.contains(id) || !hasFiles {
                    try await drive.trashFolder(f)
                    removed += 1
                }
            }
        }
        for id in ids {
            let prefix = "\(Self.notebooksFolderName)/\(id.uuidString)"
            state.files = state.files.filter { !($0.key == prefix || $0.key.hasPrefix(prefix + "/")) }
            state.folders = state.folders.filter { !($0.key == prefix || $0.key.hasPrefix(prefix + "/")) }
        }
        return removed
    }

    private func containsFiles(_ folder: String) async throws -> Bool {
        for item in try await drive.children(of: folder) {
            if !item.isFolder { return true }
            if try await containsFiles(item.id) { return true }
        }
        return false
    }

    /// 筆記本還在、但裡面的檔案在本機沒了（頁面永久刪除後留下的筆跡、縮圖）→ 雲端移到垃圾桶。
    /// document.json 不在就不判斷：那是筆記本壞了，不是使用者刪的
    private func removeFilesOfDeletedPages(index: LibraryIndex) async throws -> Int {
        let fm = FileManager.default
        let live = Set(index.notebooks.map(\.id))
        var removed = 0
        for rel in state.files.keys.sorted() {
            guard let id = Self.notebookID(of: rel), live.contains(id),
                  !fm.fileExists(atPath: library.documentsURL.appendingPathComponent(rel).path),
                  fm.fileExists(atPath: NotebookSession.documentURL(in: library.notebookURL(id)).path) else { continue }
            if let parent = state.folders[(rel as NSString).deletingLastPathComponent] {
                let name = (rel as NSString).lastPathComponent
                for f in try await drive.children(of: parent) where !f.isFolder && f.name == name {
                    try await drive.trashFile(f)
                    removed += 1
                }
            }
            state.files[rel] = nil
        }
        return removed
    }

    // MARK: - 資料夾

    private func rootFolder() async throws -> String {
        if let id = state.rootID { return id }
        let id: String
        if let existing = try await drive.findFolder(named: Self.rootFolderName, in: "root") {
            id = existing
        } else {
            id = try await drive.createFolder(named: Self.rootFolderName, in: "root")
        }
        state.rootID = id
        saveState()
        return id
    }

    private func folderID(for rel: String, root: String) async throws -> String {
        if rel.isEmpty || rel == "." { return root }
        if let id = state.folders[rel] { return id }
        let parent = try await folderID(for: (rel as NSString).deletingLastPathComponent, root: root)
        let name = (rel as NSString).lastPathComponent
        let id: String
        if let existing = try await drive.findFolder(named: name, in: parent) {
            id = existing
        } else {
            id = try await drive.createFolder(named: name, in: parent)
        }
        state.folders[rel] = id
        return id
    }

    // MARK: - 還原

    /// 照雲端的清單下載本機沒有的筆記本（不會覆蓋本機已有的筆記本）：
    /// 在垃圾桶的還原後還在垃圾桶，永久刪除的不還原。
    /// 清單沒列的（舊版留下、可能是以前刪掉的）放進垃圾桶，不直接丟掉，也不會突然出現在資料庫裡
    func restore() async throws -> RestoreResult {
        await MainActor.run {
            self.isRunning = true
            self.status = L("正在讀取雲端備份…")
        }
        defer { Task { await MainActor.run { self.isRunning = false } } }

        guard let root = try await drive.findFolder(named: Self.rootFolderName, in: "root") else {
            throw BackupError.http(404, L("雲端找不到 \(Self.rootFolderName) 資料夾"))
        }
        let stored = try await storedManifest(in: root)
        let base = try await stored == nil ? legacyManifest(in: root) : stored
        let manifest = base ?? BackupManifest()
        let index = await MainActor.run { library.index }
        let purged = Set(index.purgedNotebooks.map(\.id))
        let purgedFolders = Set(index.purgedFolders.map(\.id))
        var entries: [UUID: BackupManifest.NotebookEntry] = [:]
        for e in manifest.notebooks { entries[e.id] = e }

        let remoteNotebooks: [DriveFile]
        if let folder = try await drive.findFolder(named: Self.notebooksFolderName, in: root) {
            remoteNotebooks = try await drive.children(of: folder).filter(\.isFolder)
        } else {
            remoteNotebooks = []
        }
        let fm = FileManager.default
        var restored: [NotebookMeta] = []
        for (i, f) in remoteNotebooks.enumerated() {
            guard let id = UUID(uuidString: f.name), !purged.contains(id), entries[id]?.status != .deleted else { continue }
            let dest = library.notebookURL(id)
            if fm.fileExists(atPath: dest.path) { continue }
            await setStatus(L("下載筆記本…（\(i + 1)/\(remoteNotebooks.count)）"))
            // 先下載到暫存：中途失敗不會留下半本筆記本
            let tmp = fm.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: tmp) }
            try await downloadTree(f.id, to: tmp)
            guard let data = try? Data(contentsOf: NotebookSession.documentURL(in: tmp)),
                  let doc = try? JSONDecoder.app.decode(NotebookDocument.self, from: data) else { continue }
            try fm.moveItem(at: tmp, to: dest)
            restored.append(Self.restoredMeta(id: id, entry: entries[id], document: doc))
        }
        let folders = manifest.folders.compactMap { $0.status == .deleted || purgedFolders.contains($0.id) ? nil : $0.folder }
        let result = await MainActor.run { () -> RestoreResult in
            self.library.mergeRestored(folders: folders, notebooks: restored)
            let kept = restored.compactMap { self.library.notebook($0.id) }
            let result = RestoreResult(notebooks: kept.count, trashed: kept.filter(self.library.isHidden).count)
            self.status = result.notebooks == 0 ? L("本機已經有全部的筆記本") : L("已還原 \(result.notebooks) 本筆記本")
            return result
        }
        return result
    }

    private static func restoredMeta(id: UUID, entry: BackupManifest.NotebookEntry?, document: NotebookDocument) -> NotebookMeta {
        guard let entry, var meta = entry.meta else {
            var meta = NotebookMeta(title: L("復原的筆記本"), folderId: nil, coverHex: Palette.covers[0])
            meta.id = id
            meta.pageCount = document.pages.count
            meta.trashedPageCount = document.trash?.count ?? 0
            meta.deletedAt = Date()
            return meta
        }
        meta.deletedAt = entry.status == .trashed ? (meta.deletedAt ?? Date()) : nil
        return meta
    }

    /// 同名的檔案（舊版重新安裝後會重複上傳）只拿最新的：children 由新到舊排
    private func downloadTree(_ folderID: String, to dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var seen = Set<String>()
        for item in try await drive.children(of: folderID) where seen.insert(item.name).inserted {
            let target = dir.appendingPathComponent(item.name, isDirectory: item.isFolder)
            if item.isFolder {
                try await downloadTree(item.id, to: target)
            } else {
                try await drive.download(item.id, to: target)
            }
        }
    }
}
