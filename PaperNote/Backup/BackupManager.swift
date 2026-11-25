import UIKit
import CryptoKit

/// 還原的結果
struct RestoreResult: Equatable {
    var notebooks = 0
    /// 其中還在垃圾桶裡的
    var trashed = 0
}

//// 備份到 Google Drive 的「PaperNoteBackup」資料夾。
/// 每本筆記本在雲端是一個 Notebooks/<id>.papernote（和 App 匯出的一樣，下載下來可以直接匯入）：
/// 筆跡、PDF、圖片、縮圖都在裡面，文字和筆跡有壓縮。一本只有一個檔案，上傳、還原都只要一次請求；
/// 同時傳好幾本。另外還有 backup-manifest.json（名稱、資料夾、狀態）和 global.zip（貼紙、元件庫、筆刷設定）。
/// 只上傳內容有變的：檔案的大小和修改時間沒變就不看；變了就重新打包、比 MD5（一樣就不傳）；
/// 本機沒有紀錄時（重新安裝、還原、重新連結）和雲端的 MD5 比，一樣就不傳。
/// 更新前的格式（Notebooks/<id>/ 資料夾）還原得回來；這台的那本傳好新格式後，舊資料夾移到 Drive 垃圾桶。
///
/// 雲端的刪除只有兩種來源，都是使用者在 App 裡的動作：永久刪除筆記本、換成新格式後的舊資料夾。
/// 都只移到 Google Drive 的垃圾桶，留一個救回來的機會。
/// PaperNoteBackup 底下由 App 管理；它本身和它外面的東西一律不動。
final class BackupManager: ObservableObject {
    static let shared = BackupManager(drive: DriveClient(), library: .shared, global: .device)
    static let rootFolderName = "PaperNoteBackup"
    static let notebooksFolderName = "Notebooks"
    static let fileExtension = "papernote"
    /// 更新前的格式：Notebooks/<id>/notebook.zip，PDF 和圖片在旁邊的 files/
    static let legacyArchiveName = "notebook.zip"
    private static let legacyAttachmentsFolderName = "files"
    /// global.zip 在備份紀錄裡的 key
    private static let globalKey = "global"
    /// 同時上傳、下載幾個
    static let parallelTransfers = 4

    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var lastError: String?
    @Published private(set) var lastBackup: Date?

    var autoBackup: Bool {
        get { UserDefaults.standard.object(forKey: "backup.auto") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "backup.auto") }
    }

    /// 雲端的清單
    private struct FileRecord: Codable {
        var id: String
        var size: Int
        var mtime: Double
        var md5: String?
    }

    /// 上傳過的一個打包檔（筆記本的 .papernote、global.zip）。
    /// fingerprint：裡面每個檔案的路徑、大小、修改時間，沒變就不用重新打包
    private struct ArchiveRecord: Codable {
        var id: String
        var fingerprint: String
        var md5: String
    }

    private struct BackupState: Codable {
        var rootID: String?
        var folders: [String: String] = [:]
        var files: [String: FileRecord] = [:]
        /// key：筆記本是雲端的路徑（Notebooks/<id>.papernote），貼紙那些是 "global"
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
            let began = Date()
            do {
                count = try await syncWithRetry()
            } catch {
                failure = error.localizedDescription
            }
            let seconds = String(format: "%.1f", Date().timeIntervalSince(began))
            await MainActor.run {
                // 除錯紀錄：備份花多久、傳了幾個
                DebugLog.add("backup \(failure == nil ? "ok" : "failed"): \(count) files, \(seconds)s")
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
        dropLegacyRecords()
        let notebooks = collectNotebooks(snapshot)

        // 清單最先傳：之後就算中斷，雲端也已經記下誰被刪了，還原不會把它們帶回來
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

        // 先挑出內容真的變了的，進度才會是「要傳幾個」，不是全部幾個。打包好的先放在暫存，傳完就刪
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var changed: [Pending] = []
        for a in notebooks {
            let rec = state.archives?[a.key]
            if let rec, rec.fingerprint == a.fingerprint { continue }
            let url = work.appendingPathComponent(a.name)
            try PaperNoteFile.write(a.manifest, files: a.files, to: url)
            let md5 = try Self.md5(of: url)
            if let rec, rec.md5 == md5 {
                setArchive(a.key, ArchiveRecord(id: rec.id, fingerprint: a.fingerprint, md5: md5))
                continue
            }
            changed.append(Pending(url: url, name: a.name, inNotebooks: true, key: a.key, fingerprint: a.fingerprint, md5: md5))
        }
        // 貼紙、元件庫、筆刷設定：PaperNoteBackup/global.zip
        if let g = try global.contents(work: work), state.archives?[Self.globalKey]?.fingerprint != g.fingerprint {
            let url = work.appendingPathComponent(GlobalBackup.fileName)
            try Self.pack(g.files, to: url)
            let md5 = try Self.md5(of: url)
            if let rec = state.archives?[Self.globalKey], rec.md5 == md5 {
                setArchive(Self.globalKey, ArchiveRecord(id: rec.id, fingerprint: g.fingerprint, md5: md5))
            } else {
                changed.append(Pending(url: url, name: GlobalBackup.fileName, inNotebooks: false, key: Self.globalKey,
                                       fingerprint: g.fingerprint, md5: md5))
            }
        }

        var notebooksFolder: String?
        var remoteNotebooks: [DriveFile] = []
        var uploaded = 0
        if !changed.isEmpty {
            // 雲端已經有的：列一次資料夾，不用每個檔案各問一次
            var remote: [String: DriveFile] = [:]
            if changed.contains(where: \.inNotebooks) {
                let folder = try await folderID(for: Self.notebooksFolderName, root: root)
                notebooksFolder = folder
                remoteNotebooks = try await drive.children(of: folder)
                // 同名的（舊版重新安裝會多一份）用最新的：children 由新到舊排
                for f in remoteNotebooks where !f.isFolder && remote[f.name] == nil { remote[f.name] = f }
            }
            if changed.contains(where: { !$0.inNotebooks }),
               let g = try await drive.findFile(named: GlobalBackup.fileName, in: root) {
                remote[GlobalBackup.fileName] = g
            }
            uploaded = try await upload(changed, root: root, notebooks: notebooksFolder, remote: remote)
        }

        let purged = Set(snapshot.purgedNotebooks.map(\.id))
        let deleted = Set(manifest.notebooks.filter { $0.status == .deleted }.map(\.id))
        var removed = 0
        if !changed.isEmpty || !deleted.isEmpty {
            if notebooksFolder == nil, let folder = try await drive.findFolder(named: Self.notebooksFolderName, in: root) {
                notebooksFolder = folder
                remoteNotebooks = try await drive.children(of: folder)
            }
            // 這次傳好的也算雲端有了（列表是傳之前列的）
            var present = Set(remoteNotebooks.filter { !$0.isFolder }.map(\.name))
            for p in changed where p.inNotebooks && state.archives?[p.key]?.md5 == p.md5 { present.insert(p.name) }
            removed = try await cleanUpNotebooks(remoteNotebooks, uploaded: present, deleted: deleted, purged: purged)
        }
        for id in purged { setArchive(Self.notebookKey(id), nil) }
        saveState()
        await MainActor.run {
            library.clearPurged(notebooks: snapshot.purgedNotebooks.map(\.id), folders: snapshot.purgedFolders.map(\.id))
        }
        return uploaded + removed
    }

    /// 同時傳好幾個（一次只傳一個時，等待往返比傳資料還久）。一個失敗不影響其他，傳好的都記下來，最後再回報錯誤
    private func upload(_ changed: [Pending], root: String, notebooks: String?, remote: [String: DriveFile]) async throws -> Int {
        var uploaded = 0, finished = 0, next = 0
        var firstError: Error?
        let drive = self.drive
        let send = { (p: Pending) async -> Result<Sent, Error> in
            let existing = remote[p.name]
            // 雲端已經是一樣的內容（重新安裝、還原後）就不傳
            if let existing, existing.md5Checksum == p.md5 { return .success(Sent(id: existing.id, uploaded: false)) }
            do {
                let parent = p.inNotebooks ? (notebooks ?? root) : root
                let id = try await drive.upload(p.url, name: p.name, parent: parent, existingID: existing?.id)
                return .success(Sent(id: id, uploaded: true))
            } catch {
                return .failure(error)
            }
        }
        await setStatus(L("備份中…（\(0)/\(changed.count)）"))
        await withTaskGroup(of: (Int, Result<Sent, Error>).self) { group in
            while next < min(Self.parallelTransfers, changed.count) {
                let i = next
                next += 1
                group.addTask { (i, await send(changed[i])) }
            }
            while let (i, result) = await group.next() {
                finished += 1
                await setStatus(L("備份中…（\(finished)/\(changed.count)）"))
                switch result {
                case let .success(sent):
                    let p = changed[i]
                    setArchive(p.key, ArchiveRecord(id: sent.id, fingerprint: p.fingerprint, md5: p.md5))
                    if sent.uploaded { uploaded += 1 }
                    saveState()
                case let .failure(error):
                    firstError = firstError ?? error
                }
                if next < changed.count {
                    let j = next
                    next += 1
                    group.addTask { (j, await send(changed[j])) }
                }
            }
        }
        if let firstError { throw firstError }
        return uploaded
    }

    private struct Sent {
        let id: String
        /// false：雲端本來就是一樣的內容
        let uploaded: Bool
    }

    /// 要上傳的一個打包檔
    private struct Pending {
        let url: URL
        /// 雲端的檔名
        let name: String
        /// 放在 Notebooks 裡（不然在 PaperNoteBackup 底下）
        let inNotebooks: Bool
        let key: String
        let fingerprint: String
        let md5: String
    }

    /// 一本筆記本：資料夾裡全部的檔案，照路徑排好（內容一樣，打包出來就一模一樣）
    private struct Archive {
        let id: UUID
        let manifest: PaperNoteManifest
        /// path：筆記本資料夾裡的路徑
        let files: [(url: URL, path: String)]
        let fingerprint: String

        var name: String { BackupManager.fileName(id) }
        var key: String { BackupManager.notebookKey(id) }
    }

    static func fileName(_ id: UUID) -> String { "\(id.uuidString).\(fileExtension)" }
    fileprivate static func notebookKey(_ id: UUID) -> String { "\(notebooksFolderName)/\(fileName(id))" }

    private func setArchive(_ key: String, _ record: ArchiveRecord?) {
        var archives = state.archives ?? [:]
        archives[key] = record
        state.archives = archives
    }

    /// 更新前的紀錄（notebook.zip、一個一個的附件、library.json）用不到了；清單和 global 留著
    private func dropLegacyRecords() {
        state.files = state.files.filter { $0.key == BackupManifest.fileName }
        state.folders = state.folders.filter { $0.key == Self.notebooksFolderName }
        state.archives = state.archives?.filter { UUID(uuidString: $0.key) == nil }
    }

    /// 每本筆記本資料夾裡的全部檔案（永久刪除的不傳）。名稱和封面顏色也寫在 .papernote 裡，改名也算有變
    private func collectNotebooks(_ index: LibraryIndex) -> [Archive] {
        let fm = FileManager.default
        let purged = Set(index.purgedNotebooks.map(\.id))
        var metas: [UUID: NotebookMeta] = [:]
        for m in index.notebooks { metas[m.id] = m }
        var archives: [Archive] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let dirs = (try? fm.contentsOfDirectory(at: library.notebooksURL, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let id = UUID(uuidString: dir.lastPathComponent), !purged.contains(id),
                  let en = fm.enumerator(at: dir, includingPropertiesForKeys: keys) else { continue }
            let prefix = "\(Self.notebooksFolderName)/\(id.uuidString)/"
            var files: [(url: URL, path: String, size: Int, mtime: Double)] = []
            for case let url as URL in en {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == false,
                      // 用 /Documents/Notebooks/ 之後的路徑（避免 /private/var 與 /var 的差異）
                      let r = url.path.range(of: "/Documents/" + prefix) else { continue }
                files.append((url, String(url.path[r.upperBound...]), values.fileSize ?? 0,
                              values.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
            guard !files.isEmpty else { continue }
            files.sort { $0.path < $1.path }
            let manifest = PaperNoteManifest(title: metas[id]?.title ?? L("筆記本"), coverHex: metas[id]?.coverHex ?? Palette.covers[0])
            let lines = [manifest.title, manifest.coverHex] + files.map { "\($0.path)\t\($0.size)\t\($0.mtime)" }
            let fingerprint = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
            archives.append(Archive(id: id, manifest: manifest, files: files.map { ($0.url, $0.path) }, fingerprint: fingerprint))
        }
        return archives
    }

    static func pack(_ files: [(url: URL, path: String)], to url: URL) throws {
        var zip = try ZipWriter(writingTo: url)
        for f in files { try zip.add(f.path, Data(contentsOf: f.url, options: .alwaysMapped)) }
        try zip.close()
    }

    /// 解開 zip（global.zip、舊格式的 notebook.zip）。路徑跑出資料夾的（../、絕對路徑）當成壞掉
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

    /// Notebooks 裡的 <id>.papernote 或舊格式的 <id> 資料夾，是哪一本
    private static func notebookID(of item: DriveFile) -> UUID? {
        if item.isFolder { return UUID(uuidString: item.name) }
        guard item.name.hasSuffix("." + fileExtension) else { return nil }
        return UUID(uuidString: String(item.name.dropLast(fileExtension.count + 1)))
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

    // MARK: - 移到 Drive 垃圾桶

    /// Notebooks 裡要移到 Drive 垃圾桶的（只動 Notebooks/ 底下這一層）：
    /// - 這台永久刪除的筆記本：新格式的檔案、舊格式的資料夾
    /// - 舊格式的資料夾，這台的那本已經傳好新格式（雲端有 <id>.papernote）
    /// - 清單記成刪除、但不是這台刪的：只清已經沒有檔案的舊資料夾（舊版刪除時留下的），只憑清單不動任何內容
    /// items：Notebooks 裡的東西；uploaded：雲端已經有的 .papernote 檔名（包括這次剛傳的）
    private func cleanUpNotebooks(_ items: [DriveFile], uploaded: Set<String>, deleted: Set<UUID>, purged: Set<UUID>) async throws -> Int {
        var removed = 0
        for item in items {
            guard let id = Self.notebookID(of: item) else { continue }
            if item.isFolder {
                let replaced = uploaded.contains(Self.fileName(id)) && state.archives?[Self.notebookKey(id)] != nil
                var trash = purged.contains(id) || replaced
                if !trash, deleted.contains(id) { trash = try await containsFiles(item.id) == false }
                guard trash else { continue }
                try await drive.trashFolder(item)
                removed += 1
            } else if purged.contains(id) {
                try await drive.trashFile(item)
                removed += 1
            }
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

        let remote: [DriveFile]
        if let folder = try await drive.findFolder(named: Self.notebooksFolderName, in: root) {
            remote = try await drive.children(of: folder)
        } else {
            remote = []
        }
        // 每本從哪裡下載：有 <id>.papernote 就用它（同名的用最新的，children 由新到舊排），沒有才用舊格式的資料夾
        var sources: [UUID: String] = [:]
        for f in remote where !f.isFolder {
            if let id = Self.notebookID(of: f), sources[id] == nil { sources[id] = f.id }
        }
        for f in remote where f.isFolder {
            if let id = Self.notebookID(of: f), sources[id] == nil { sources[id] = f.id }
        }
        // 資料夾先建好、每本下載好就記進資料庫：還原隨時可能中斷（螢幕暗掉、切出 App、斷線），
        // 已經放進 Notebooks 的筆記本一定要有名稱和位置，不然重開 App 會被當成遺失的「復原的筆記本」
        let folders = manifest.folders.compactMap { $0.status == .deleted || purgedFolders.contains($0.id) ? nil : $0.folder }
        await MainActor.run { self.library.mergeRestored(folders: folders, notebooks: []) }
        try await restoreGlobal(in: root)
        let fm = FileManager.default
        let todo = remote.compactMap { f -> (id: UUID, item: DriveFile)? in
            guard let id = Self.notebookID(of: f), sources[id] == f.id, !purged.contains(id), entries[id]?.status != .deleted,
                  !fm.fileExists(atPath: library.notebookURL(id).path) else { return nil }
            return (id, f)
        }
        // 同時下載幾本：一次只抓一個檔案時，等待和單一連線的速度才是瓶頸。
        // 一本失敗不影響其他本，全部跑完再回報第一個錯誤（再按一次還原會補下載失敗的）
        var restored: [NotebookMeta] = []
        var firstError: Error?
        var next = 0, finished = 0
        await setStatus(L("下載筆記本…（\(0)/\(todo.count)）"))
        let fetch = { (item: (id: UUID, item: DriveFile)) async -> Result<(UUID, URL), Error> in
            do {
                return .success((item.id, try await self.fetchNotebook(item.item)))
            } catch {
                return .failure(error)
            }
        }
        await withTaskGroup(of: Result<(UUID, URL), Error>.self) { group in
            while next < min(Self.parallelTransfers, todo.count) {
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

    /// 下載一本到暫存資料夾（完整了才搬進 App，中途失敗不會留下半本）；失敗會清掉暫存。
    /// item：<id>.papernote，或舊格式的資料夾
    private func fetchNotebook(_ item: DriveFile) async throws -> URL {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        do {
            if item.isFolder {
                try await downloadNotebook(item.id, to: tmp)
            } else {
                let file = fm.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString).\(Self.fileExtension)")
                defer { try? fm.removeItem(at: file) }
                try await drive.download(item.id, to: file)
                try PaperNoteFile.extract(ZipArchive(url: file), into: tmp)
            }
            return tmp
        } catch {
            try? fm.removeItem(at: tmp)
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

    /// 舊格式的資料夾：notebook.zip 解開、files/ 的附件照檔案下載。有 notebook.zip 時旁邊的散檔是更早留下的，不下載；
    /// 沒有的是更早的備份（全部是散檔），照舊一個一個下載
    private func downloadNotebook(_ folderID: String, to dir: URL) async throws {
        let children = try await drive.children(of: folderID)
        guard let archive = children.first(where: { !$0.isFolder && $0.name == Self.legacyArchiveName }) else {
            return try await downloadTree(folderID, to: dir)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let zipURL = fm.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: zipURL) }
        try await drive.download(archive.id, to: zipURL)
        try Self.unpack(zipURL, into: dir)
        if let files = children.first(where: { $0.isFolder && $0.name == Self.legacyAttachmentsFolderName }) {
            try await downloadTree(files.id, to: dir.appendingPathComponent(Self.legacyAttachmentsFolderName, isDirectory: true))
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
