import XCTest
import CryptoKit
@testable import PaperNote

/// 假的 Google Drive。行為照 drive.file：App 只看得到自己建立的檔案；
/// 資料夾移到垃圾桶會連裡面看不到的檔案一起移（和真的 Drive 一樣）。
/// 動到 App 不該動的東西就記在 violations
private final class FakeDrive: DriveAPI {
    final class Item {
        let id: String
        var name: String
        let parent: String
        let isFolder: Bool
        /// App 建立的；不是的話 App 看不到
        let appCreated: Bool
        var data: Data
        var modified: Int

        init(id: String, name: String, parent: String, isFolder: Bool, appCreated: Bool, data: Data, modified: Int) {
            self.id = id
            self.name = name
            self.parent = parent
            self.isFolder = isFolder
            self.appCreated = appCreated
            self.data = data
            self.modified = modified
        }
    }

    var items: [String: Item] = [:]
    private(set) var trashed: [String] = []
    /// 移到 Drive 垃圾桶的項目：App 看不到了，但內容還在
    private(set) var trash: [String: Item] = [:]
    private(set) var violations: [String] = []
    /// 真的傳上來的檔案名稱
    var uploads: [String] = []
    /// 用名稱找過的檔案
    var lookups: [String] = []
    private var next = 0

    private func newID() -> String {
        next += 1
        return "id\(next)"
    }

    @discardableResult
    func addUserFile(name: String, parent: String, isFolder: Bool = false) -> String {
        let id = newID()
        next += 1
        items[id] = Item(id: id, name: name, parent: parent, isFolder: isFolder, appCreated: false, data: Data("使用者的".utf8), modified: next)
        return id
    }

    /// 這個項目在 PaperNoteBackup 底下嗎
    private func isInsideBackup(_ id: String) -> Bool {
        var cur = items[id]
        while let c = cur {
            if c.name == BackupManager.rootFolderName, c.parent == "root" { return true }
            cur = items[c.parent]
        }
        return false
    }

    private func visible(in parent: String) -> [Item] {
        items.values.filter { $0.parent == parent && $0.appCreated }.sorted { $0.modified > $1.modified }
    }

    func findFolder(named name: String, in parent: String) async throws -> String? {
        visible(in: parent).first { $0.isFolder && $0.name == name }?.id
    }

    func findFile(named name: String, in parent: String) async throws -> DriveFile? {
        lookups.append(name)
        return visible(in: parent).first { !$0.isFolder && $0.name == name }.map(driveFile)
    }

    private func driveFile(_ item: Item) -> DriveFile {
        DriveFile(id: item.id, name: item.name, mimeType: item.isFolder ? DriveClient.folderMime : "application/octet-stream",
                  md5Checksum: item.isFolder ? nil : Insecure.MD5.hash(data: item.data).map { String(format: "%02x", $0) }.joined())
    }

    func createFolder(named name: String, in parent: String) async throws -> String {
        let id = newID()
        next += 1
        items[id] = Item(id: id, name: name, parent: parent, isFolder: true, appCreated: true, data: Data(), modified: next)
        return id
    }

    func children(of folder: String) async throws -> [DriveFile] {
        visible(in: folder).map(driveFile)
    }

    func upload(_ fileURL: URL, name: String, parent: String, existingID: String?) async throws -> String {
        let data = try Data(contentsOf: fileURL)
        uploads.append(name)
        next += 1
        if let existingID {
            guard let item = items[existingID] else { throw BackupError.http(404, "") }
            if !item.appCreated { violations.append("覆蓋了使用者的 \(item.name)") }
            item.data = data
            item.modified = next
            return existingID
        }
        let id = newID()
        items[id] = Item(id: id, name: name, parent: parent, isFolder: false, appCreated: true, data: data, modified: next)
        return id
    }

    func download(_ fileID: String, to destination: URL) async throws {
        guard let item = items[fileID] else { throw BackupError.http(404, "") }
        if !item.appCreated { violations.append("讀了使用者的 \(item.name)") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try item.data.write(to: destination)
    }

    func trashFile(_ file: DriveFile) async throws {
        guard let item = items[file.id] else { return }
        if item.isFolder { violations.append("刪了資料夾 \(item.name)") }
        if !item.appCreated { violations.append("刪了使用者的 \(item.name)") }
        if !isInsideBackup(file.id) { violations.append("刪了 PaperNoteBackup 外面的 \(item.name)") }
        moveToTrash(file.id)
    }

    /// 只有 PaperNoteBackup/Notebooks/<筆記本> 這一層可以整個移
    func trashFolder(_ folder: DriveFile) async throws {
        guard let item = items[folder.id] else { return }
        let notebooks = self.folder(path: [BackupManager.rootFolderName, "Notebooks"])
        if !item.isFolder || !item.appCreated || item.parent != notebooks?.id {
            violations.append("刪了不該刪的 \(item.name)")
        }
        moveToTrash(folder.id)
    }

    private func moveToTrash(_ id: String) {
        for child in items.values where child.parent == id {
            moveToTrash(child.id)
        }
        trash[id] = items[id]
        items[id] = nil
        trashed.append(id)
    }

    // MARK: 查內容

    func folder(path: [String]) -> Item? {
        var parent = "root"
        var cur: Item?
        for name in path {
            cur = items.values.first { $0.parent == parent && $0.name == name }
            guard let c = cur else { return nil }
            parent = c.id
        }
        return cur
    }

    func filesAnywhere(under id: String) -> [Item] {
        items.values.filter { $0.parent == id }.flatMap { $0.isFolder ? filesAnywhere(under: $0.id) : [$0] }
    }

    func count(named name: String, in parent: String) -> Int {
        items.values.filter { $0.parent == parent && $0.name == name }.count
    }

    func manifest() throws -> BackupManifest {
        let root = try XCTUnwrap(folder(path: [BackupManager.rootFolderName]))
        let file = try XCTUnwrap(items.values.first { $0.parent == root.id && $0.name == BackupManifest.fileName })
        return try BackupManifest.decode(file.data)
    }

    func notebookFolder(_ id: UUID) -> Item? {
        folder(path: [BackupManager.rootFolderName, "Notebooks", id.uuidString])
    }
}

/// 一台 iPad：自己的資料庫和備份紀錄
@MainActor
private final class Device {
    let dir: URL
    let store: LibraryStore
    let backup: BackupManager

    init(drive: FakeDrive) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupTests-\(UUID().uuidString)", isDirectory: true)
        let docs = dir.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        store = LibraryStore(documentsURL: docs)
        backup = BackupManager(drive: drive, library: store, stateURL: dir.appendingPathComponent("state.json"))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: dir)
    }
}

@MainActor
final class BackupTests: XCTestCase {
    private var drive: FakeDrive!
    private var devices: [Device] = []

    override func setUp() async throws {
        drive = FakeDrive()
    }

    override func tearDown() async throws {
        for d in devices { d.cleanUp() }
        devices = []
    }

    private func device() throws -> Device {
        let d = try Device(drive: drive)
        devices.append(d)
        return d
    }

    private func notebook(_ title: String, on d: Device, folder: UUID? = nil) -> NotebookMeta {
        d.store.createNotebook(title: title, folder: folder, paper: .blank, landscape: false)
    }

    private func fileID(_ name: String, in folder: String) async throws -> String {
        let file = try await drive.findFile(named: name, in: folder)
        return try XCTUnwrap(file).id
    }

    private func status(_ id: UUID) throws -> BackupManifest.Status? {
        try drive.manifest().notebooks.first { $0.id == id }?.status
    }

    // MARK: 回報的問題：永久刪除後雲端還留著

    /// 只丟進垃圾桶：雲端檔案不能動，清單記成在垃圾桶
    func testTrashKeepsTheCloudFiles() async throws {
        let d = try device()
        let nb = notebook("丟垃圾桶", on: d)
        _ = try await d.backup.syncWithRetry()
        XCTAssertEqual(try status(nb.id), .active)
        let before = drive.filesAnywhere(under: try XCTUnwrap(drive.notebookFolder(nb.id)).id).count
        XCTAssertGreaterThan(before, 0)

        d.store.trashNotebook(nb.id)
        _ = try await d.backup.syncWithRetry()

        XCTAssertEqual(try status(nb.id), .trashed)
        XCTAssertEqual(drive.filesAnywhere(under: try XCTUnwrap(drive.notebookFolder(nb.id)).id).count, before)
        XCTAssertEqual(drive.violations, [])
    }

    /// 回報的問題：清空垃圾桶後，雲端的檔案要移到 Drive 垃圾桶（還救得回來），名稱不能留在清單裡
    func testPermanentDeleteRemovesTheCloudFiles() async throws {
        let d = try device()
        let nb = notebook("機密筆記", on: d)
        let keep = notebook("留著", on: d)
        _ = try await d.backup.syncWithRetry()

        d.store.trashNotebook(nb.id)
        d.store.emptyTrash()
        XCTAssertEqual(d.store.index.purgedNotebooks.map(\.id), [nb.id], "等雲端刪掉之前要記著")
        _ = try await d.backup.syncWithRetry()

        XCTAssertNil(drive.notebookFolder(nb.id), "資料夾也要移走，不留空的")
        XCTAssertTrue(drive.trash.values.contains { $0.name == "document.json" }, "內容還在 Drive 垃圾桶")
        XCTAssertGreaterThan(drive.filesAnywhere(under: try XCTUnwrap(drive.notebookFolder(keep.id)).id).count, 0, "別本不受影響")
        XCTAssertEqual(try status(nb.id), .deleted)
        XCTAssertEqual(try status(keep.id), .active)
        let entry = try XCTUnwrap(drive.manifest().notebooks.first { $0.id == nb.id })
        XCTAssertNil(entry.meta, "永久刪除的不留名稱")
        XCTAssertNotNil(entry.purgedAt)
        XCTAssertTrue(d.store.index.purgedNotebooks.isEmpty, "刪好了就不用再記")
        XCTAssertEqual(drive.violations, [])
    }

    /// 網路斷掉時永久刪除：下次備份要補刪；中途失敗也要能再試一次
    func testPurgeRetriesAfterAFailedSync() async throws {
        let d = try device()
        let nb = notebook("等等刪", on: d)
        _ = try await d.backup.syncWithRetry()
        let failing = FailingDeleteDrive(drive)
        let flaky = BackupManager(drive: failing, library: d.store, stateURL: d.dir.appendingPathComponent("state.json"))

        d.store.deleteNotebook(nb.id)
        do {
            _ = try await flaky.syncWithRetry()
            XCTFail("刪除失敗要回報")
        } catch {}
        XCTAssertEqual(d.store.index.purgedNotebooks.map(\.id), [nb.id], "沒刪成要繼續記著")
        XCTAssertEqual(try status(nb.id), .deleted, "清單先傳，這時還原也不會帶回來")

        let retry = BackupManager(drive: drive, library: d.store, stateURL: d.dir.appendingPathComponent("state.json"))
        _ = try await retry.syncWithRetry()
        XCTAssertNil(drive.notebookFolder(nb.id))
        XCTAssertTrue(d.store.index.purgedNotebooks.isEmpty)
    }

    /// 回報的問題：上一版永久刪除後留下的空資料夾（含空的子資料夾），下次備份要清掉
    func testEmptyFoldersLeftByTheLastVersionAreRemoved() async throws {
        let d = try device()
        let nb = notebook("上一版刪的", on: d)
        _ = try await d.backup.syncWithRetry()
        let notebooks = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName, "Notebooks"]))
        d.store.deleteNotebook(nb.id)
        _ = try await d.backup.syncWithRetry()
        let left = try await drive.createFolder(named: nb.id.uuidString, in: notebooks.id)
        _ = try await drive.createFolder(named: "assets", in: left)

        _ = try await relaunched(d).syncWithRetry()

        XCTAssertNil(drive.notebookFolder(nb.id))
        XCTAssertEqual(drive.violations, [])
    }

    /// 只有標記永久刪除的才清：別台 iPad 上還在用的筆記本，資料夾空了也不能刪
    func testEmptyFolderOfALiveNotebookStays() async throws {
        let a = try device()
        let nb = notebook("另一台的", on: a)
        _ = try await a.backup.syncWithRetry()
        let folder = try XCTUnwrap(drive.notebookFolder(nb.id))
        for f in try await drive.children(of: folder.id) { try await drive.trashFile(f) }

        let b = try device()
        _ = try await b.backup.syncWithRetry()

        XCTAssertNotNil(drive.notebookFolder(nb.id))
    }

    /// 永久刪除只影響自己的資料夾：Notebooks 和 PaperNoteBackup 本身要留著
    func testPermanentDeleteKeepsTheBackupFolders() async throws {
        let d = try device()
        let nb = notebook("唯一的一本", on: d)
        _ = try await d.backup.syncWithRetry()

        d.store.deleteNotebook(nb.id)
        _ = try await d.backup.syncWithRetry()

        XCTAssertNotNil(drive.folder(path: [BackupManager.rootFolderName, "Notebooks"]))
        XCTAssertEqual(try status(nb.id), .deleted)
        XCTAssertEqual(drive.violations, [])

        let fresh = try device()
        let result = try await fresh.backup.restore()
        XCTAssertEqual(result.notebooks, 0, "在 Drive 垃圾桶的不會被還原")
    }

    /// 頁面永久刪除後留下的檔案：雲端跟著刪，筆記本其他檔案不動
    func testFilesOfDeletedPagesAreRemoved() async throws {
        let d = try device()
        let nb = notebook("有頁面", on: d)
        let ink = d.store.notebookURL(nb.id).appendingPathComponent("page.drawing")
        try Data("筆跡".utf8).write(to: ink)
        _ = try await d.backup.syncWithRetry()
        let folder = try XCTUnwrap(drive.notebookFolder(nb.id))
        XCTAssertEqual(drive.count(named: "page.drawing", in: folder.id), 1)

        try FileManager.default.removeItem(at: ink)
        _ = try await d.backup.syncWithRetry()

        XCTAssertEqual(drive.count(named: "page.drawing", in: folder.id), 0)
        XCTAssertEqual(drive.count(named: "document.json", in: folder.id), 1)
        XCTAssertEqual(drive.violations, [])
    }

    /// 本機檔案不見（例如在「檔案」App 把整本刪了）不是永久刪除：雲端是唯一的備份，不能跟著刪
    func testLosingLocalFilesNeverDeletesTheBackup() async throws {
        let d = try device()
        let nb = notebook("還要救回來", on: d)
        _ = try await d.backup.syncWithRetry()
        let folder = try XCTUnwrap(drive.notebookFolder(nb.id))
        let before = drive.filesAnywhere(under: folder.id).count

        try FileManager.default.removeItem(at: d.store.notebookURL(nb.id))
        _ = try await d.backup.syncWithRetry()

        XCTAssertEqual(drive.filesAnywhere(under: folder.id).count, before)
        XCTAssertTrue(drive.trashed.isEmpty)
    }

    // MARK: 不能動到其他資料

    func testNeverTouchesTheUsersOtherFiles() async throws {
        let d = try device()
        let nb = notebook("要刪的", on: d)
        _ = try await d.backup.syncWithRetry()

        // 使用者自己的東西，名字故意和 App 的一樣。PaperNoteBackup 同層、上層的都不能動；
        // 放進筆記本資料夾的，隨著筆記本一起刪（那層是 App 管理的）
        let root = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName]))
        let notebookFolder = try XCTUnwrap(drive.notebookFolder(nb.id))
        let users = [
            drive.addUserFile(name: "畢業論文.pdf", parent: "root"),
            drive.addUserFile(name: BackupManifest.fileName, parent: "root"),
            drive.addUserFile(name: "document.json", parent: "root"),
            drive.addUserFile(name: "我放進來的.pdf", parent: root.id),
        ]
        let insideNotebook = drive.addUserFile(name: "我放進筆記本資料夾的.pdf", parent: notebookFolder.id)
        let lookalike = drive.addUserFile(name: "Notebooks", parent: "root", isFolder: true)
        let lookalikeNotebook = drive.addUserFile(name: nb.id.uuidString, parent: lookalike, isFolder: true)
        let lookalikeFile = drive.addUserFile(name: "document.json", parent: lookalikeNotebook)

        d.store.deleteNotebook(nb.id)
        _ = try await d.backup.syncWithRetry()

        XCTAssertNil(drive.notebookFolder(nb.id))
        XCTAssertNil(drive.items[insideNotebook])
        for id in users + [lookalike, lookalikeNotebook, lookalikeFile] {
            XCTAssertNotNil(drive.items[id], "使用者的檔案不能不見")
        }
        XCTAssertEqual(drive.violations, [])

        // 還原也一樣
        let fresh = try device()
        _ = try await fresh.backup.restore()
        XCTAssertEqual(drive.violations, [])
    }

    /// 雲端清單被改成全部已刪除，也不會讓 App 刪掉檔案：只有這台 iPad 上的永久刪除才會刪有內容的資料夾
    func testManifestAloneNeverTriggersADelete() async throws {
        let a = try device()
        let nb = notebook("別台刪的", on: a)
        _ = try await a.backup.syncWithRetry()
        a.store.deleteNotebook(nb.id)
        let keep = notebook("留著", on: a)
        _ = keep
        // 另一台 iPad 還沒還原就連結，雲端清單已經有刪除紀錄
        let tombstone = BackupManifest.merged(remote: nil, index: a.store.index)
        let root = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName]))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString).json")
        try tombstone.encoded().write(to: tmp)
        let existing = try await drive.findFile(named: BackupManifest.fileName, in: root.id)
        _ = try await drive.upload(tmp, name: BackupManifest.fileName, parent: root.id, existingID: existing?.id)

        let other = try device()
        _ = try await other.backup.syncWithRetry()

        XCTAssertTrue(drive.trashed.isEmpty, "別台的紀錄不會讓這台動檔案")
        XCTAssertEqual(try status(nb.id), .deleted, "也不會把刪除紀錄蓋掉")
    }

    func testOnlyAsksForTheAppsOwnFiles() {
        XCTAssertEqual(GoogleAuth.scope, "https://www.googleapis.com/auth/drive.file")
    }

    // MARK: 真正送出去的請求

    func testDeleteMovesToTheDriveTrash() async throws {
        URLProtocol.registerClass(RecordingProtocol.self)
        defer {
            URLProtocol.unregisterClass(RecordingProtocol.self)
            RecordingProtocol.reset()
        }
        let client = DriveClient(accessToken: { "token" })

        try await client.trashFile(DriveFile(id: "abc", name: "a.json", mimeType: "application/json"))
        XCTAssertEqual(RecordingProtocol.requests.map(\.httpMethod), ["PATCH"], "移到垃圾桶，不是真的刪除（DELETE）")
        XCTAssertEqual(RecordingProtocol.bodies.map { String(decoding: $0, as: UTF8.self) }, [#"{"trashed":true}"#])
        XCTAssertEqual(RecordingProtocol.requests.first?.url?.absoluteString, "https://www.googleapis.com/drive/v3/files/abc")

        RecordingProtocol.reset()
        RecordingProtocol.statusCode = 404
        try await client.trashFile(DriveFile(id: "gone", name: "a.json", mimeType: "application/json"))

        RecordingProtocol.reset()
        for mime in [DriveClient.folderMime, nil] {
            do {
                try await client.trashFile(DriveFile(id: "folder", name: "Notebooks", mimeType: mime))
                XCTFail("資料夾或不確定種類的不能當檔案丟")
            } catch {}
        }
        for mime in ["application/json", nil] {
            do {
                try await client.trashFolder(DriveFile(id: "file", name: "a.json", mimeType: mime))
                XCTFail("檔案或不確定種類的不能當資料夾丟")
            } catch {}
        }
        XCTAssertTrue(RecordingProtocol.requests.isEmpty, "連請求都不會送出去")

        try await client.trashFolder(DriveFile(id: "nb", name: "notebook", mimeType: DriveClient.folderMime))
        XCTAssertEqual(RecordingProtocol.requests.map(\.httpMethod), ["PATCH"], "移到垃圾桶，不是真的刪除（DELETE）")
        XCTAssertEqual(RecordingProtocol.bodies.map { String(decoding: $0, as: UTF8.self) }, [#"{"trashed":true}"#])
        XCTAssertEqual(RecordingProtocol.requests.first?.url?.absoluteString, "https://www.googleapis.com/drive/v3/files/nb")
    }

    // MARK: 還原照清單

    /// 需求：在垃圾桶的還原後還在垃圾桶（刪除時間也一樣），永久刪除的不還原，一般的正常回來
    func testRestoreFollowsTheManifest() async throws {
        let a = try device()
        let live = notebook("平常的", on: a)
        let trashed = notebook("垃圾桶的", on: a)
        let gone = notebook("永久刪除的", on: a)
        let folder = a.store.createFolder(name: "在垃圾桶的資料夾", parent: nil)
        let inFolder = notebook("資料夾裡的", on: a, folder: folder.id)
        a.store.trashNotebook(trashed.id)
        a.store.trashFolder(folder.id)
        a.store.deleteNotebook(gone.id)
        _ = try await a.backup.syncWithRetry()
        let deletedAt = try XCTUnwrap(a.store.notebook(trashed.id)?.deletedAt)

        let b = try device()
        let result = try await b.backup.restore()

        XCTAssertEqual(result, RestoreResult(notebooks: 3, trashed: 2))
        let store = b.store
        XCTAssertEqual(store.notebook(live.id)?.title, "平常的")
        XCTAssertNil(store.notebook(live.id)?.deletedAt)
        XCTAssertEqual(store.visibleNotebooks.map(\.id), [live.id])
        let t = try XCTUnwrap(store.notebook(trashed.id))
        XCTAssertEqual(t.title, "垃圾桶的")
        XCTAssertEqual(try XCTUnwrap(t.deletedAt).timeIntervalSince1970, deletedAt.timeIntervalSince1970, accuracy: 1, "30 天不會重算")
        XCTAssertTrue(store.trashedNotebooks.map(\.id).contains(trashed.id))
        XCTAssertTrue(store.trashedFolders.map(\.id).contains(folder.id), "資料夾也在垃圾桶")
        XCTAssertNotNil(store.notebook(inFolder.id))
        XCTAssertNil(store.notebook(gone.id), "永久刪除的不還原")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.notebookURL(gone.id).path))
    }

    /// 雲端檔案還沒刪完（中途斷線）時還原：清單說刪了就不還原
    func testRestoreSkipsDeletedEvenIfFilesRemain() async throws {
        let a = try device()
        let nb = notebook("刪到一半", on: a)
        _ = try await a.backup.syncWithRetry()
        a.store.deleteNotebook(nb.id)
        let flaky = BackupManager(drive: FailingDeleteDrive(drive), library: a.store, stateURL: a.dir.appendingPathComponent("state.json"))
        do { _ = try await flaky.syncWithRetry() } catch {}
        XCTAssertGreaterThan(drive.filesAnywhere(under: try XCTUnwrap(drive.notebookFolder(nb.id)).id).count, 0)

        let b = try device()
        let result = try await b.backup.restore()

        XCTAssertEqual(result.notebooks, 0)
        XCTAssertNil(b.store.notebook(nb.id))
    }

    /// 本機已有的筆記本不會被還原蓋掉；垃圾桶放超過 30 天的，還原後照規定刪除
    func testRestoreKeepsLocalAndHonorsExpiry() async throws {
        let a = try device()
        let nb = notebook("本機較新", on: a)
        let expired = notebook("過期的", on: a)
        a.store.updateMeta(expired.id) { $0.deletedAt = Date().addingTimeInterval(-31 * 86_400) }
        _ = try await a.backup.syncWithRetry()
        a.store.renameNotebook(nb.id, to: "改過名")

        let result = try await a.backup.restore()
        XCTAssertEqual(result.notebooks, 0)
        XCTAssertEqual(a.store.notebook(nb.id)?.title, "改過名")

        let b = try device()
        let restored = try await b.backup.restore()
        XCTAssertEqual(restored.notebooks, 1)
        XCTAssertNil(b.store.notebook(expired.id))
        XCTAssertEqual(b.store.index.purgedNotebooks.map(\.id), [expired.id], "下次備份雲端也會刪")
    }

    // MARK: 換 iPad、舊版備份

    /// 新 iPad 還沒還原就連結：不能把雲端的清單和檔案蓋掉，也不能多一份
    func testConnectingAFreshDeviceKeepsTheBackup() async throws {
        let a = try device()
        let nb = notebook("舊 iPad 的", on: a)
        _ = try await a.backup.syncWithRetry()
        let root = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName]))

        let b = try device()
        let mine = notebook("新 iPad 的", on: b)
        _ = try await b.backup.syncWithRetry()

        XCTAssertEqual(try status(nb.id), .active, "還沒還原的還在清單裡")
        XCTAssertEqual(try status(mine.id), .active)
        XCTAssertEqual(drive.count(named: "library.json", in: root.id), 1, "不會多一份")
        XCTAssertEqual(drive.count(named: BackupManifest.fileName, in: root.id), 1)

        let result = try await b.backup.restore()
        XCTAssertEqual(result.notebooks, 1)
        XCTAssertEqual(b.store.notebook(nb.id)?.title, "舊 iPad 的")

        // 還原回來的再備份：覆蓋原本的檔案，不會多一份
        _ = try await b.backup.syncWithRetry()
        let folder = try XCTUnwrap(drive.notebookFolder(nb.id))
        XCTAssertEqual(drive.count(named: "document.json", in: folder.id), 1)
    }

    /// 這次更新前的備份（沒有清單）：名稱照 library.json；
    /// 裡面沒列的是以前永久刪除、留在雲端的，放進垃圾桶，不會突然出現
    func testRestoreFromAnOldBackup() async throws {
        let a = try device()
        let listed = notebook("舊版的", on: a)
        let leftover = notebook("以前刪掉的", on: a)
        _ = try await a.backup.syncWithRetry()
        let root = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName]))
        var index = a.store.index
        index.notebooks.removeAll { $0.id == leftover.id }
        let lib = try await fileID("library.json", in: root.id)
        drive.items[lib]?.data = try JSONEncoder.app.encode(index)
        let manifest = try await fileID(BackupManifest.fileName, in: root.id)
        try await drive.trashFile(DriveFile(id: manifest, name: BackupManifest.fileName, mimeType: "application/json"))

        let b = try device()
        let result = try await b.backup.restore()

        XCTAssertEqual(result, RestoreResult(notebooks: 2, trashed: 1))
        XCTAssertEqual(b.store.notebook(listed.id)?.title, "舊版的")
        XCTAssertNil(b.store.notebook(listed.id)?.deletedAt)
        XCTAssertNotNil(b.store.notebook(leftover.id)?.deletedAt, "放進垃圾桶")
        XCTAssertEqual(b.store.visibleNotebooks.map(\.id), [listed.id])
    }

    /// 同名的舊檔案（舊版重新安裝會多傳一份）：還原拿最新的，永久刪除全部刪掉
    func testDuplicatesFromOldVersions() async throws {
        let a = try device()
        let nb = notebook("重複", on: a)
        _ = try await a.backup.syncWithRetry()
        let folder = try XCTUnwrap(drive.notebookFolder(nb.id))
        let page = { Page(background: .paper(width: 100, height: 100, style: .blank)) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try NotebookSession.writeDocument(NotebookDocument(pages: [page(), page()]), to: tmp)
        _ = try await drive.upload(NotebookSession.documentURL(in: tmp), name: "document.json", parent: folder.id, existingID: nil)
        XCTAssertEqual(drive.count(named: "document.json", in: folder.id), 2)

        let b = try device()
        _ = try await b.backup.restore()
        let restored = try Data(contentsOf: NotebookSession.documentURL(in: b.store.notebookURL(nb.id)))
        XCTAssertEqual(try JSONDecoder.app.decode(NotebookDocument.self, from: restored).pages.count, 2, "拿最新的")

        a.store.deleteNotebook(nb.id)
        _ = try await a.backup.syncWithRetry()

        XCTAssertEqual(drive.count(named: "document.json", in: folder.id), 0)
    }

    // MARK: 回報的問題：看起來每次都全部重傳

    private func relaunched(_ d: Device, drive api: DriveAPI? = nil) -> BackupManager {
        BackupManager(drive: api ?? drive, library: d.store, stateURL: d.dir.appendingPathComponent("state.json"))
    }

    private func resetCounters() {
        drive.uploads = []
        drive.lookups = []
    }

    /// 關掉 App 再打開：紀錄要讀得回來、修改時間要對得上，連比對都不用
    func testRelaunchDoesNotCheckOrUploadAgain() async throws {
        let d = try device()
        let nb = notebook("不變", on: d)
        try Data("筆跡".utf8).write(to: d.store.notebookURL(nb.id).appendingPathComponent("page.drawing"))
        _ = try await d.backup.syncWithRetry()
        resetCounters()

        let count = try await relaunched(d).syncWithRetry()

        XCTAssertEqual(count, 0)
        XCTAssertEqual(drive.uploads, [])
        XCTAssertFalse(drive.lookups.contains("document.json"), "修改時間存檔後要一模一樣")
        XCTAssertFalse(drive.lookups.contains("page.drawing"))
    }

    /// 更新 App 前留下的紀錄沒有 MD5：不能因此全部重傳
    func testOldStateFileDoesNotReupload() async throws {
        let d = try device()
        let nb = notebook("舊紀錄", on: d)
        _ = try await d.backup.syncWithRetry()
        let url = d.dir.appendingPathComponent("state.json")
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var files = try XCTUnwrap(state["files"] as? [String: [String: Any]])
        for key in files.keys { files[key]?["md5"] = nil }
        state["files"] = files
        try JSONSerialization.data(withJSONObject: state).write(to: url)
        resetCounters()

        // 內容沒變、時間也沒變
        _ = try await relaunched(d).syncWithRetry()
        XCTAssertEqual(drive.uploads, [])

        // 時間變了、紀錄沒有 MD5：和雲端比，一樣就不傳
        let doc = NotebookSession.documentURL(in: d.store.notebookURL(nb.id))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-500)], ofItemAtPath: doc.path)
        _ = try await relaunched(d).syncWithRetry()
        XCTAssertEqual(drive.uploads, [])
    }

    /// 內容一樣、只是重新存過（例如打開筆記本重畫縮圖）：不傳，也不用問雲端
    func testSameContentWithNewDateIsNotUploaded() async throws {
        let d = try device()
        let nb = notebook("重存", on: d)
        let thumb = d.store.notebookURL(nb.id).appendingPathComponent("cover.jpg")
        try Data("縮圖".utf8).write(to: thumb)
        _ = try await d.backup.syncWithRetry()
        resetCounters()

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-500)], ofItemAtPath: thumb.path)
        let count = try await d.backup.syncWithRetry()

        XCTAssertEqual(count, 0)
        XCTAssertEqual(drive.uploads, [])
        XCTAssertFalse(drive.lookups.contains("cover.jpg"))

        // 之後時間沒再變：也不用再算一次
        let again = try await relaunched(d).syncWithRetry()
        XCTAssertEqual(again, 0)
    }

    /// 只改一個檔案：只傳那一個
    func testOnlyTheChangedFileIsUploaded() async throws {
        let d = try device()
        let nb = notebook("改這本", on: d)
        _ = notebook("不動這本", on: d)
        let ink = d.store.notebookURL(nb.id).appendingPathComponent("page.drawing")
        try Data("舊筆跡".utf8).write(to: ink)
        _ = try await d.backup.syncWithRetry()
        resetCounters()

        try Data("新的筆跡內容".utf8).write(to: ink)
        let count = try await d.backup.syncWithRetry()

        XCTAssertEqual(drive.uploads, ["page.drawing"])
        XCTAssertEqual(count, 1)
    }

    /// 中斷連結再連結、或雲端資料夾 404 造成紀錄清空：內容沒變就不重傳
    func testLosingTheRecordsDoesNotReupload() async throws {
        let d = try device()
        _ = notebook("紀錄不見", on: d)
        _ = try await d.backup.syncWithRetry()
        resetCounters()

        d.backup.resetRemoteState()
        let count = try await d.backup.syncWithRetry()

        XCTAssertEqual(drive.uploads, [])
        XCTAssertEqual(count, 0)
    }

    /// 還原後的第一次備份：筆記本都是剛從雲端下載的，不用傳回去
    func testBackupAfterRestoreDoesNotReuploadNotebooks() async throws {
        let a = try device()
        let nb = notebook("換 iPad", on: a)
        try Data("筆跡".utf8).write(to: a.store.notebookURL(nb.id).appendingPathComponent("page.drawing"))
        _ = try await a.backup.syncWithRetry()

        let b = try device()
        _ = try await b.backup.restore()
        resetCounters()
        _ = try await b.backup.syncWithRetry()

        XCTAssertFalse(drive.uploads.contains("document.json"))
        XCTAssertFalse(drive.uploads.contains("page.drawing"))
    }

    /// 備份到一半被中斷：傳好的要記得，不足 10 個也一樣
    func testInterruptedBackupKeepsProgress() async throws {
        let d = try device()
        let nb = notebook("中斷", on: d)
        let dir = d.store.notebookURL(nb.id)
        for i in 1...4 { try Data("頁 \(i)".utf8).write(to: dir.appendingPathComponent("p\(i).drawing")) }
        // 清單、library.json、第一個檔案會成功
        let flaky = relaunched(d, drive: FailingDeleteDrive(drive, uploadsBeforeFailure: 3))
        do {
            _ = try await flaky.syncWithRetry()
            XCTFail("上傳失敗要回報")
        } catch {}
        resetCounters()

        _ = try await relaunched(d).syncWithRetry()

        let names = drive.lookups.filter { $0 != BackupManifest.fileName && $0 != "library.json" }
        XCTAssertEqual(names.count, 4, "共 5 個檔案，傳好的那個不用再比對")
    }

    func testMD5MatchesTheFormatDriveUses() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("md5-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try BackupManager.md5(of: url), "900150983cd24fb0d6963f7d28e17f72")
    }

    /// 真的向 Drive 要 MD5，沒要的話永遠比對不到
    func testClientAsksDriveForTheChecksum() async throws {
        URLProtocol.registerClass(RecordingProtocol.self)
        defer {
            URLProtocol.unregisterClass(RecordingProtocol.self)
            RecordingProtocol.reset()
        }
        RecordingProtocol.statusCode = 200
        RecordingProtocol.body = Data(#"{"files":[{"id":"x","name":"a","mimeType":"text/plain","md5Checksum":"abc"}]}"#.utf8)

        let file = try await DriveClient(accessToken: { "token" }).findFile(named: "a", in: "root")

        XCTAssertEqual(file?.md5Checksum, "abc")
        let query = try XCTUnwrap(RecordingProtocol.requests.first?.url?.query)
        XCTAssertTrue(query.contains("md5Checksum"))
    }

    // MARK: 永久刪除的確認

    func testPermanentDeleteConfirmationText() {
        XCTAssertEqual(PermanentDeleteText.title("期中筆記"), "確認刪除期中筆記?")
        XCTAssertEqual(PermanentDeleteText.message, "此操作將會把本機檔案永久刪除，且無法復原；雲端檔案會移到 Google Drive 的垃圾桶")
    }

    // MARK: 格式

    /// 更新前的 library.json 沒有 purged：一定要讀得出來，不然整個資料庫會不見
    func testOldLibraryFileStillDecodes() throws {
        let id = UUID()
        let json = #"{"folders":[],"notebooks":[{"id":"\#(id.uuidString)","title":"舊的"}]}"#
        let index = try JSONDecoder.app.decode(LibraryIndex.self, from: Data(json.utf8))
        XCTAssertEqual(index.notebooks.first?.title, "舊的")
        XCTAssertTrue(index.purgedNotebooks.isEmpty)
    }

    /// 清單讀不懂就停手，不能拿空的蓋掉雲端
    func testUnreadableManifestStopsTheBackup() async throws {
        let a = try device()
        let nb = notebook("不能被蓋掉", on: a)
        _ = try await a.backup.syncWithRetry()
        let root = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName]))
        let id = try await fileID(BackupManifest.fileName, in: root.id)

        for (bad, expected) in [("不是 JSON", "bad"), (#"{"format":99,"folders":[],"notebooks":[]}"#, "newer"), (#"{"format":1}"#, "bad")] {
            drive.items[id]?.data = Data(bad.utf8)
            do {
                _ = try await a.backup.syncWithRetry()
                XCTFail("要停手：\(bad)")
            } catch BackupError.newerManifest {
                XCTAssertEqual(expected, "newer", bad)
            } catch BackupError.badManifest {
                XCTAssertEqual(expected, "bad", bad)
            }
            XCTAssertEqual(drive.items[id]?.data, Data(bad.utf8), "雲端不變")
        }
        XCTAssertNotNil(drive.notebookFolder(nb.id))
    }

    /// 一樣的內容不重傳清單
    func testUnchangedManifestIsNotUploadedAgain() async throws {
        let a = try device()
        _ = notebook("不變", on: a)
        _ = try await a.backup.syncWithRetry()
        let root = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName]))
        let file = try await fileID(BackupManifest.fileName, in: root.id)
        let modified = drive.items[file]?.modified

        let count = try await a.backup.syncWithRetry()

        XCTAssertEqual(count, 0)
        XCTAssertEqual(drive.items[file]?.modified, modified)
    }
}

/// 刪除時會失敗的 Drive（例如網路斷了）
private final class FailingDeleteDrive: DriveAPI {
    private let base: FakeDrive
    private var uploadsLeft: Int

    init(_ base: FakeDrive, uploadsBeforeFailure: Int = .max) {
        self.base = base
        uploadsLeft = uploadsBeforeFailure
    }

    func findFolder(named name: String, in parent: String) async throws -> String? { try await base.findFolder(named: name, in: parent) }
    func findFile(named name: String, in parent: String) async throws -> DriveFile? { try await base.findFile(named: name, in: parent) }
    func createFolder(named name: String, in parent: String) async throws -> String { try await base.createFolder(named: name, in: parent) }
    func children(of folder: String) async throws -> [DriveFile] { try await base.children(of: folder) }
    func upload(_ fileURL: URL, name: String, parent: String, existingID: String?) async throws -> String {
        guard uploadsLeft > 0 else { throw BackupError.http(500, "斷線") }
        uploadsLeft -= 1
        return try await base.upload(fileURL, name: name, parent: parent, existingID: existingID)
    }
    func download(_ fileID: String, to destination: URL) async throws { try await base.download(fileID, to: destination) }
    func trashFile(_ file: DriveFile) async throws { throw BackupError.http(500, "斷線") }
    func trashFolder(_ folder: DriveFile) async throws { throw BackupError.http(500, "斷線") }
}

/// 記下 DriveClient 真正送出去的請求
private final class RecordingProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var statusCode = 204
    nonisolated(unsafe) static var body = Data()

    static func reset() {
        requests = []
        bodies = []
        statusCode = 204
        body = Data()
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "www.googleapis.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        Self.bodies.append(Self.body(of: request))
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession 交過來的請求，內容通常放在 stream 裡
    private static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            out.append(buffer, count: n)
        }
        return out
    }
}
