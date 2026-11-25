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
/// 每本筆記本在雲端是 Notebooks/<id>/notebook.zip（document.json、筆跡、縮圖這些常改的小檔案），
/// PDF 和圖片（files/）又大又幾乎不變，各自一個檔案：還原只要下載幾個檔案，改一筆也不用重傳 PDF。
/// 只上傳內容有變的：大小和修改時間沒變就不看；變了再比 MD5（重畫一樣的縮圖不用重傳）；
/// 本機沒有紀錄時（重新安裝、還原、重新連結）和雲端的 MD5 比，一樣就不傳。
///
/// 雲端的刪除只有兩種來源，都是使用者在 App 裡的動作：永久刪除筆記本、永久刪除頁面留下的舊檔案。
/// 兩種都只移到 Google Drive 的垃圾桶，留一個救回來的機會。
/// PaperNoteBackup 底下由 App 管理；它本身和它外面的東西一律不動。
final class BackupManager: ObservableObject {
    static let shared = BackupManager(drive: DriveClient(), library: .shared, global: .device)
    static let rootFolderName = "PaperNoteBackup"
    private static let notebooksFolderName = "Notebooks"
    static let archiveName = "notebook.zip"
    /// 筆記本裡不打包、各自上傳的資料夾（PDF、圖片）
    private static let attachmentsFolderName = "files"
    /// global.zip 在備份紀錄裡的 key（筆記本用 UUID，不會撞到）
    private static let globalKey = "global"
    /// 還原時同時下載幾本
    static let parallelDownloads = 4

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

    /// 一本筆記本的 notebook.zip。fingerprint：裡面每個檔案的路徑、大小、修改時間，沒變就不用重新打包
    private struct ArchiveRecord: Codable {
        var id: String
        var fingerprint: String
        var md5: String
    }

    private struct BackupState: Codable {
        var rootID: String?
        var folders: [String: String] = [:]
        var files: [String: FileRecord] = [:]
        /// key：筆記本 ID。舊版的紀錄沒有
        var archives: [String: ArchiveRecord]?
    }

    private let drive: DriveAPI
    private let library: LibraryStore
    private let global: GlobalBackup
    private var state = BackupState()
    private let stateURL: URL
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var started = false

    init(drive: DriveAPI, library: LibraryStore, global: GlobalBackup, stateURL: URL? = nil) {
        self.drive = drive
        self.library = library
        self.global = global
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
        let snapshot = await MainActor.run { library.index }
        let (files, archives) = collectFiles(skipping: Set(snapshot.purgedNotebooks.map(\.id)))

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
        var changed: [Pending] = []
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
            changed.append(Pending(url: f.url, rel: f.rel, md5: md5, kind: .file(size: size, mtime: mtime)))
        }
        // 打包好的 zip 先放在暫存，傳完就刪
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for a in archives {
            let key = a.id.uuidString
            let rec = state.archives?[key]
            if let rec, rec.fingerprint == a.fingerprint { continue }
            let url = work.appendingPathComponent("\(key).zip")
            try Self.pack(a.files).write(to: url)
            let md5 = try Self.md5(of: url)
            if let rec, rec.md5 == md5 {
                setArchive(key, ArchiveRecord(id: rec.id, fingerprint: a.fingerprint, md5: md5))
                continue
            }
            let rel = "\(Self.notebooksFolderName)/\(key)/\(Self.archiveName)"
            changed.append(Pending(url: url, rel: rel, md5: md5, kind: .archive(key: key, fingerprint: a.fingerprint)))
        }
        // 貼紙、元件庫、筆刷設定：PaperNoteBackup/global.zip
        if let g = try global.contents(work: work), state.archives?[Self.globalKey]?.fingerprint != g.fingerprint {
            let url = work.appendingPathComponent(GlobalBackup.fileName)
            try Self.pack(g.files).write(to: url)
            let md5 = try Self.md5(of: url)
            if let rec = state.archives?[Self.globalKey], rec.md5 == md5 {
                setArchive(Self.globalKey, ArchiveRecord(id: rec.id, fingerprint: g.fingerprint, md5: md5))
            } else {
                changed.append(Pending(url: url, rel: GlobalBackup.fileName, md5: md5, kind: .archive(key: Self.globalKey, fingerprint: g.fingerprint)))
            }
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
            switch f.kind {
            case let .file(size, mtime):
                state.files[f.rel] = FileRecord(id: id, size: size, mtime: mtime, md5: f.md5)
            case let .archive(key, fingerprint):
                setArchive(key, ArchiveRecord(id: id, fingerprint: fingerprint, md5: f.md5 ?? ""))
            }
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

    /// 要上傳的一個檔案：一般檔案，或一本筆記本打包好的 notebook.zip
    private struct Pending {
        enum Kind {
            case file(size: Int, mtime: Double)
            case archive(key: String, fingerprint: String)
        }
        let url: URL
        let rel: String
        let md5: String?
        let kind: Kind
    }

    /// 一本筆記本要打包的檔案（files/ 以外的全部），照路徑排好：內容一樣，zip 就一模一樣
    private struct Archive {
        let id: UUID
        /// path：筆記本資料夾裡的路徑
        let files: [(url: URL, path: String)]
        let fingerprint: String
    }

    private func setArchive(_ notebook: String, _ record: ArchiveRecord?) {
        var archives = state.archives ?? [:]
        archives[notebook] = record
        state.archives = archives
    }

    /// library.json 和每本筆記本 files/ 裡的附件各自上傳；筆記本其他的檔案打包成 notebook.zip。
    /// 永久刪除的筆記本不傳
    private func collectFiles(skipping purged: Set<UUID>) -> (files: [(url: URL, rel: String)], archives: [Archive]) {
        let fm = FileManager.default
        var files: [(url: URL, rel: String)] = []
        let libraryFile = library.documentsURL.appendingPathComponent("library.json")
        if fm.fileExists(atPath: libraryFile.path) { files.append((libraryFile, "library.json")) }
        var archives: [Archive] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let dirs = (try? fm.contentsOfDirectory(at: library.notebooksURL, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let id = UUID(uuidString: dir.lastPathComponent), !purged.contains(id),
                  let en = fm.enumerator(at: dir, includingPropertiesForKeys: keys) else { continue }
            let prefix = "\(Self.notebooksFolderName)/\(id.uuidString)/"
            var packed: [(url: URL, path: String, size: Int, mtime: Double)] = []
            for case let url as URL in en {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == false,
                      // 用 /Documents/Notebooks/ 之後的路徑（避免 /private/var 與 /var 的差異）
                      let r = url.path.range(of: "/Documents/" + prefix) else { continue }
                let path = String(url.path[r.upperBound...])
                if path.hasPrefix(Self.attachmentsFolderName + "/") {
                    files.append((url, prefix + path))
                } else {
                    packed.append((url, path, values.fileSize ?? 0, values.contentModificationDate?.timeIntervalSince1970 ?? 0))
                }
            }
            guard !packed.isEmpty else { continue }
            packed.sort { $0.path < $1.path }
            let lines = packed.map { "\($0.path)\t\($0.size)\t\($0.mtime)" }.joined(separator: "\n")
            let fingerprint = SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
            archives.append(Archive(id: id, files: packed.map { ($0.url, $0.path) }, fingerprint: fingerprint))
        }
        return (files, archives)
    }

    static func pack(_ files: [(url: URL, path: String)]) throws -> Data {
        var zip = ZipWriter()
        for f in files { try zip.add(f.path, Data(contentsOf: f.url)) }
        return try zip.finish()
    }

    /// 解開 notebook.zip。路徑跑出筆記本資料夾的（../、絕對路徑）當成壞掉
    static func unpack(_ zipURL: URL, into dir: URL) throws {
        let zip = try ZipArchive(url: zipURL)
        for e in zip.entries where !e.isDirectory {
            let parts = e.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw ZipError.corrupt(e.path) }
            let target = dir.appendingPathComponent(e.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try zip.extract(e, to: target)
        }
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
            setArchive(id.uuidString, nil)
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
        // 資料夾先建好、每本下載好就記進資料庫：還原隨時可能中斷（螢幕暗掉、切出 App、斷線），
        // 已經放進 Notebooks 的筆記本一定要有名稱和位置，不然重開 App 會被當成遺失的「復原的筆記本」
        let folders = manifest.folders.compactMap { $0.status == .deleted || purgedFolders.contains($0.id) ? nil : $0.folder }
        await MainActor.run { self.library.mergeRestored(folders: folders, notebooks: []) }
        try await restoreGlobal(in: root)
        let fm = FileManager.default
        let todo = remoteNotebooks.compactMap { f -> (id: UUID, folder: String)? in
            guard let id = UUID(uuidString: f.name), !purged.contains(id), entries[id]?.status != .deleted,
                  !fm.fileExists(atPath: library.notebookURL(id).path) else { return nil }
            return (id, f.id)
        }
        // 同時下載幾本：一次只抓一個檔案時，等待和單一連線的速度才是瓶頸。
        // 一本失敗不影響其他本，全部跑完再回報第一個錯誤（再按一次還原會補下載失敗的）
        var restored: [NotebookMeta] = []
        var firstError: Error?
        var next = 0, finished = 0
        await setStatus(L("下載筆記本…（\(0)/\(todo.count)）"))
        let fetch = { (item: (id: UUID, folder: String)) async -> Result<(UUID, URL), Error> in
            do {
                return .success((item.id, try await self.fetchNotebook(item.folder)))
            } catch {
                return .failure(error)
            }
        }
        await withTaskGroup(of: Result<(UUID, URL), Error>.self) { group in
            while next < min(Self.parallelDownloads, todo.count) {
                let item = todo[next]
                next += 1
                group.addTask { await fetch(item) }
            }
            while let result = await group.next() {
                finished += 1
                await setStatus(L("下載筆記本…（\(finished)/\(todo.count)）"))
                switch result {
                case let .success((id, tmp)):
                    defer { try? fm.removeItem(at: tmp) }
                    // 讀不出來的（不是筆記本）跳過，不算錯誤
                    guard let data = try? Data(contentsOf: NotebookSession.documentURL(in: tmp)),
                          let doc = try? JSONDecoder.app.decode(NotebookDocument.self, from: data) else { break }
                    let meta = Self.restoredMeta(id: id, entry: entries[id], document: doc)
                    do {
                        try await MainActor.run {
                            try FileManager.default.moveItem(at: tmp, to: self.library.notebookURL(id))
                            self.library.mergeRestored(folders: [], notebooks: [meta])
                        }
                        restored.append(meta)
                    } catch {
                        firstError = firstError ?? error
                    }
                case let .failure(error):
                    firstError = firstError ?? error
                }
                if next < todo.count {
                    let item = todo[next]
                    next += 1
                    group.addTask { await fetch(item) }
                }
            }
        }
        if let firstError { throw firstError }
        let result = await MainActor.run { () -> RestoreResult in
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

    /// 下載一本到暫存資料夾（完整了才搬進 App，中途失敗不會留下半本）；失敗會清掉暫存
    private func fetchNotebook(_ folderID: String) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        do {
            try await downloadNotebook(folderID, to: tmp)
            return tmp
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// 貼紙、元件庫、筆刷設定：合併進這台，不蓋掉已經有的。舊版的備份沒有 global.zip
    private func restoreGlobal(in root: String) async throws {
        guard let file = try await drive.findFile(named: GlobalBackup.fileName, in: root) else { return }
        await setStatus(L("下載貼紙與元件庫…"))
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("global-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let zipURL = tmp.appendingPathComponent(GlobalBackup.fileName)
        try await drive.download(file.id, to: zipURL)
        let dir = tmp.appendingPathComponent("contents", isDirectory: true)
        try Self.unpack(zipURL, into: dir)
        let global = self.global
        try await MainActor.run { try global.merge(from: dir) }
    }

    /// notebook.zip 解開、files/ 的附件照檔案下載。有 notebook.zip 時旁邊的散檔是更新前留下的，不下載；
    /// 沒有的是更新前的備份（全部是散檔），照舊一個一個下載
    private func downloadNotebook(_ folderID: String, to dir: URL) async throws {
        let children = try await drive.children(of: folderID)
        guard let archive = children.first(where: { !$0.isFolder && $0.name == Self.archiveName }) else {
            return try await downloadTree(folderID, to: dir)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let zipURL = fm.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: zipURL) }
        try await drive.download(archive.id, to: zipURL)
        try Self.unpack(zipURL, into: dir)
        if let files = children.first(where: { $0.isFolder && $0.name == Self.attachmentsFolderName }) {
            try await downloadTree(files.id, to: dir.appendingPathComponent(Self.attachmentsFolderName, isDirectory: true))
        }
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
