import UIKit

/// 備份到 Google Drive 的「PaperNoteBackup」資料夾。
/// 備份的是 App 內的原始檔（library.json、每本筆記本的 document.json、筆跡、PDF、圖片），
/// 還原後筆跡、表格、螢光標示都能繼續編輯。只上傳有變動的檔案。
final class BackupManager: ObservableObject {
    static let shared = BackupManager()
    static let rootFolderName = "PaperNoteBackup"

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
    }

    private struct BackupState: Codable {
        var rootID: String?
        var folders: [String: String] = [:]
        var files: [String: FileRecord] = [:]
    }

    private let drive = DriveClient()
    private var state = BackupState()
    private let stateURL: URL
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var started = false

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        stateURL = support.appendingPathComponent("backup-state.json")
        if let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(BackupState.self, from: data) {
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
        status = "準備備份…"
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
                    self.status = count == 0 ? "沒有變動" : "已上傳 \(count) 個檔案"
                }
                UIApplication.shared.endBackgroundTask(bgTask)
            }
        }
    }

    private func setStatus(_ s: String) async {
        await MainActor.run { self.status = s }
    }

    private func syncWithRetry() async throws -> Int {
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
        let root = try await rootFolder()
        let docs = LibraryStore.shared.documentsURL
        var files: [(url: URL, rel: String)] = []
        let library = docs.appendingPathComponent("library.json")
        if FileManager.default.fileExists(atPath: library.path) { files.append((library, "library.json")) }
        let notebooks = LibraryStore.shared.notebooksURL
        let keys: [URLResourceKey] = [.isDirectoryKey]
        if let en = FileManager.default.enumerator(at: notebooks, includingPropertiesForKeys: keys) {
            for case let url as URL in en {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false else { continue }
                // 用 /Documents/Notebooks/ 之後的路徑（避免 /private/var 與 /var 的差異）
                guard let r = url.path.range(of: "/Documents/Notebooks/") else { continue }
                files.append((url, "Notebooks/" + url.path[r.upperBound...]))
            }
        }

        var uploaded = 0
        for (index, f) in files.enumerated() {
            let values = try? f.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            if let rec = state.files[f.rel], rec.size == size, rec.mtime == mtime { continue }
            await setStatus("上傳中…（\(index + 1)/\(files.count)）")
            let parentRel = (f.rel as NSString).deletingLastPathComponent
            let parent = try await folderID(for: parentRel, root: root)
            let name = (f.rel as NSString).lastPathComponent
            let id: String
            do {
                id = try await drive.upload(f.url, name: name, parent: parent, existingID: state.files[f.rel]?.id)
            } catch BackupError.http(404, _) where state.files[f.rel] != nil {
                id = try await drive.upload(f.url, name: name, parent: parent, existingID: nil)
            }
            state.files[f.rel] = FileRecord(id: id, size: size, mtime: mtime)
            uploaded += 1
            if uploaded % 10 == 0 { saveState() }
        }
        saveState()
        return uploaded
    }

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

    /// 從雲端下載本機沒有的筆記本（不會覆蓋本機已有的筆記本），回傳還原了幾本
    func restore() async throws -> Int {
        await MainActor.run {
            self.isRunning = true
            self.status = "正在讀取雲端備份…"
        }
        defer { Task { await MainActor.run { self.isRunning = false } } }

        guard let root = try await drive.findFolder(named: Self.rootFolderName, in: "root") else {
            throw BackupError.http(404, "雲端找不到 \(Self.rootFolderName) 資料夾")
        }
        let top = try await drive.children(of: root)
        var remoteIndex: LibraryIndex?
        if let lib = top.first(where: { $0.name == "library.json" && !$0.isFolder }) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("restore-library.json")
            try await drive.download(lib.id, to: tmp)
            remoteIndex = try? JSONDecoder.app.decode(LibraryIndex.self, from: Data(contentsOf: tmp))
        }
        guard let nbFolder = top.first(where: { $0.name == "Notebooks" && $0.isFolder }) else { return 0 }
        let remoteNotebooks = try await drive.children(of: nbFolder.id).filter(\.isFolder)
        let local = LibraryStore.shared.notebooksURL
        var restored = 0
        for (i, f) in remoteNotebooks.enumerated() {
            guard let id = UUID(uuidString: f.name) else { continue }
            let dest = local.appendingPathComponent(f.name, isDirectory: true)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            await setStatus("下載筆記本…（\(i + 1)/\(remoteNotebooks.count)）")
            try await downloadTree(f.id, to: dest)
            _ = id
            restored += 1
        }
        await MainActor.run {
            LibraryStore.shared.mergeRestored(remoteIndex)
            self.status = restored == 0 ? "本機已經有全部的筆記本" : "已還原 \(restored) 本筆記本"
        }
        return restored
    }

    private func downloadTree(_ folderID: String, to dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for item in try await drive.children(of: folderID) {
            let target = dir.appendingPathComponent(item.name, isDirectory: item.isFolder)
            if item.isFolder {
                try await downloadTree(item.id, to: target)
            } else {
                try await drive.download(item.id, to: target)
            }
        }
    }
}
