import XCTest
import UIKit
import CryptoKit
@testable import PaperNote

/// 假的 Google Drive。行為照 drive.file：App 只看得到自己建立的檔案；
/// 資料夾移到垃圾桶會連裡面看不到的檔案一起移（和真的 Drive 一樣）。
/// 動到 App 不該動的東西就記在 violations。
/// 在主執行緒上跑：還原會同時下載好幾本，資料不會互相踩到
@MainActor
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
    /// 下載過的檔案名稱
    var downloads: [String] = []
    /// 同時在下載的最多幾個
    private(set) var maxConcurrentDownloads = 0
    private var activeDownloads = 0
    /// 同時在上傳的最多幾個
    private(set) var maxConcurrentUploads = 0
    private var activeUploads = 0
    /// 列過內容的資料夾名稱
    var listings: [String] = []
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
        listings.append(items[folder]?.name ?? folder)
        return visible(in: folder).map(driveFile)
    }

    func upload(_ fileURL: URL, name: String, parent: String, existingID: String?) async throws -> String {
        let data = try Data(contentsOf: fileURL)
        uploads.append(name)
        // 上傳要花一點時間：讓同時進行的其他上傳有機會開始
        activeUploads += 1
        maxConcurrentUploads = max(maxConcurrentUploads, activeUploads)
        for _ in 0..<5 { await Task.yield() }
        activeUploads -= 1
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
        downloads.append(item.name)
        // 下載要花一點時間：讓同時進行的其他下載有機會開始
        activeDownloads += 1
        maxConcurrentDownloads = max(maxConcurrentDownloads, activeDownloads)
        for _ in 0..<5 { await Task.yield() }
        activeDownloads -= 1
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

    /// 更新前的格式：Notebooks/<id>/ 資料夾
    func notebookFolder(_ id: UUID) -> Item? {
        folder(path: [BackupManager.rootFolderName, "Notebooks", id.uuidString])
    }

    /// Notebooks/<id>.papernote
    func papernote(_ id: UUID) -> Item? {
        guard let notebooks = folder(path: [BackupManager.rootFolderName, "Notebooks"]) else { return nil }
        return items.values.first { $0.parent == notebooks.id && $0.name == "\(id.uuidString).papernote" }
    }
}

/// 一台 iPad：自己的資料庫和備份紀錄
@MainActor
private final class Device {
    let dir: URL
    let store: LibraryStore
    /// 這台的貼紙、元件庫、筆刷設定（不碰測試機真的資料）
    let global: GlobalBackup
    private let suite: String
    let backup: BackupManager

    init(drive: DriveAPI) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupTests-\(UUID().uuidString)", isDirectory: true)
        let docs = dir.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        store = LibraryStore(documentsURL: docs)
        suite = "BackupTests-\(UUID().uuidString)"
        global = GlobalBackup(support: dir.appendingPathComponent("Support", isDirectory: true), defaults: UserDefaults(suiteName: suite)!)
        backup = BackupManager(drive: drive, library: store, global: global, stateURL: dir.appendingPathComponent("state.json"))
    }

    var defaults: UserDefaults { global.defaults }
    var stickersURL: URL { global.support.appendingPathComponent("Stickers", isDirectory: true) }
    var pinsURL: URL { global.support.appendingPathComponent("Pins", isDirectory: true) }

    func cleanUp() {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults().removePersistentDomain(forName: suite)
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

    /// 雲端這本筆記本的 .papernote 檔
    private func papernoteArchive(_ id: UUID) throws -> ZipArchive {
        let item = try XCTUnwrap(drive.papernote(id))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("entries-\(UUID().uuidString).papernote")
        try item.data.write(to: url)
        // ZipArchive 讀的是記憶體對應，檔案留在暫存區（測試結束系統會清）
        return try ZipArchive(url: url)
    }

    /// 雲端這本筆記本的 .papernote 裡有哪些檔案
    private func zipEntries(_ id: UUID) throws -> [String] {
        try papernoteArchive(id).entries.filter { !$0.isDirectory }.map(\.path)
    }

    /// 把雲端的一本筆記本改成更新前的格式。
    /// loose：再前一版，全部是一個一個的檔案；不然是 notebook.zip，PDF 和圖片在旁邊的 files/
    private func makeOldFormat(_ id: UUID, loose: Bool = true) async throws {
        let archive = try papernoteArchive(id)
        let notebooks = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName, "Notebooks"]))
        let folder = try await drive.createFolder(named: id.uuidString, in: notebooks.id)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("old-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var packed = ZipWriter()
        var hasPacked = false
        for (i, e) in archive.entries.enumerated() where !e.isDirectory && e.path.hasPrefix("notebook/") {
            let rel = String(e.path.dropFirst("notebook/".count))
            let data = try archive.contents(of: e)
            if !loose && !rel.hasPrefix("files/") {
                try packed.add(rel, data, compress: false)
                hasPacked = true
                continue
            }
            var parent = folder
            for name in rel.split(separator: "/").dropLast().map(String.init) {
                if let existing = try await drive.findFolder(named: name, in: parent) {
                    parent = existing
                } else {
                    parent = try await drive.createFolder(named: name, in: parent)
                }
            }
            let file = tmp.appendingPathComponent("\(i)")
            try data.write(to: file)
            _ = try await drive.upload(file, name: (rel as NSString).lastPathComponent, parent: parent, existingID: nil)
        }
        if hasPacked {
            let file = tmp.appendingPathComponent("notebook.zip")
            try packed.finish().write(to: file)
            _ = try await drive.upload(file, name: "notebook.zip", parent: folder, existingID: nil)
        }
        let newFormat = try XCTUnwrap(drive.papernote(id))
        drive.items[newFormat.id] = nil
    }

    /// 這個筆記本資料夾裡全部的檔案和內容
    private func contents(of dir: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        let base = dir.resolvingSymlinksInPath().path + "/"
        let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = en?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            out[String(url.resolvingSymlinksInPath().path.dropFirst(base.count))] = try? Data(contentsOf: url)
        }
        return out
    }

    // MARK: 回報的問題：貼紙、元件庫不在備份裡

    /// a 的貼紙、貼圖、自訂電路、筆刷設定放進雲端
    private func makeGlobalData(on a: Device) throws {
        let stickers = StickerStore(directory: a.stickersURL)
        let category = stickers.addCategory(named: "電路符號")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        XCTAssertNotNil(stickers.add(image, to: category.id))
        try FileManager.default.createDirectory(at: a.pinsURL, withIntermediateDirectories: true)
        try Data("截圖".utf8).write(to: a.pinsURL.appendingPathComponent("pin-a.png"))
        try JSONEncoder().encode([PinRecord(file: "pin-a.png", center: .zero, width: 100)])
            .write(to: a.pinsURL.appendingPathComponent("pins.json"))
        a.defaults.set(try JSONEncoder().encode([CustomCircuit(name: "OTA", data: CircuitData())]), forKey: "customCircuits")
        a.defaults.set(try JSONEncoder().encode([CustomCircuitCategory(key: "user.a", name: "類比")]), forKey: "customCircuitCategories")
        a.defaults.set(["#123456FF"], forKey: "favoriteColors")
        a.defaults.set([1.0, 2.0, 3.0], forKey: "styleWidths.monoline")
        a.defaults.set(true, forKey: "不相關的設定")
    }

    private func circuits(_ d: Device) throws -> [CustomCircuit] {
        try JSONDecoder().decode([CustomCircuit].self, from: XCTUnwrap(d.defaults.data(forKey: "customCircuits")))
    }

    /// 換一台 iPad：貼紙、貼圖、自訂電路回來；這台已經有的不被蓋掉，筆刷設定這台沒設過才用雲端的
    func testStickersAndComponentsComeBackOnAnotherIPad() async throws {
        let a = try device()
        try makeGlobalData(on: a)
        _ = notebook("筆記", on: a)
        _ = try await a.backup.syncWithRetry()
        let root = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName]))
        XCTAssertEqual(drive.count(named: "global.zip", in: root.id), 1)

        let b = try device()
        let mine = StickerStore(directory: b.stickersURL)
        _ = mine.addCategory(named: "b 的分類")
        b.defaults.set(try JSONEncoder().encode([CustomCircuit(name: "b 的電路", data: CircuitData())]), forKey: "customCircuits")
        b.defaults.set(["#ABCDEFFF"], forKey: "favoriteColors")
        for _ in 0..<2 { _ = try await b.backup.restore() }

        let stickers = StickerStore(directory: b.stickersURL)
        XCTAssertEqual(stickers.categories.map(\.name), ["b 的分類", "電路符號"], "還原兩次也不會重複")
        let sticker = try XCTUnwrap(stickers.categories.last?.stickers.first)
        XCTAssertNotNil(stickers.image(for: sticker))
        let pins = try JSONDecoder().decode([PinRecord].self, from: Data(contentsOf: b.pinsURL.appendingPathComponent("pins.json")))
        XCTAssertEqual(pins.map(\.file), ["pin-a.png"])
        XCTAssertEqual(try Data(contentsOf: b.pinsURL.appendingPathComponent("pin-a.png")), Data("截圖".utf8))
        XCTAssertEqual(try circuits(b).map(\.name), ["b 的電路", "OTA"])
        let categories = try JSONDecoder().decode([CustomCircuitCategory].self, from: XCTUnwrap(b.defaults.data(forKey: "customCircuitCategories")))
        XCTAssertEqual(categories.map(\.name), ["類比"])
        XCTAssertEqual(b.defaults.stringArray(forKey: "favoriteColors"), ["#ABCDEFFF"], "這台設定過的不蓋掉")
        XCTAssertEqual(b.defaults.array(forKey: "styleWidths.monoline") as? [Double], [1, 2, 3], "這台沒設定過就用雲端的")
        XCTAssertNil(b.defaults.object(forKey: "不相關的設定"))
        XCTAssertEqual(drive.violations, [])
    }

    /// 沒變就不重傳；改了一個顏色就只傳 global.zip
    func testGlobalDataIsUploadedOnlyWhenItChanges() async throws {
        let a = try device()
        try makeGlobalData(on: a)
        _ = try await a.backup.syncWithRetry()
        resetCounters()

        _ = try await relaunched(a).syncWithRetry()
        XCTAssertEqual(drive.uploads, [])
        XCTAssertFalse(drive.lookups.contains("global.zip"))

        a.defaults.set(["#123456FF", "#654321FF"], forKey: "favoriteColors")
        _ = try await relaunched(a).syncWithRetry()
        XCTAssertEqual(drive.uploads, ["global.zip"])

        // 紀錄不見（中斷連結再連結）：內容一樣就不重傳
        resetCounters()
        a.backup.resetRemoteState()
        _ = try await relaunched(a).syncWithRetry()
        XCTAssertFalse(drive.uploads.contains("global.zip"))
    }

    /// 沒有貼紙也沒有設定：不用傳 global.zip
    func testNothingGlobalUploadsNothing() async throws {
        let a = try device()
        _ = notebook("只有筆記", on: a)
        _ = try await a.backup.syncWithRetry()
        let root = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName]))
        XCTAssertEqual(drive.count(named: "global.zip", in: root.id), 0)
    }

    // MARK: 回報的問題：還原要下載幾千個小檔案，很慢

    /// 回報的問題：還原要 20 分鐘。同時下載幾本，但不超過上限；全部都要回來
    func testRestoreDownloadsSeveralNotebooksAtOnce() async throws {
        let a = try device()
        let ids = (1...7).map { notebook("第 \($0) 本", on: a).id }
        _ = try await a.backup.syncWithRetry()

        let b = try device()
        let result = try await b.backup.restore()

        XCTAssertEqual(result.notebooks, 7)
        XCTAssertEqual(Set(ids.compactMap { b.store.notebook($0)?.title }).count, 7)
        XCTAssertGreaterThan(drive.maxConcurrentDownloads, 1)
        XCTAssertLessThanOrEqual(drive.maxConcurrentDownloads, BackupManager.parallelTransfers)
    }

    /// 備份也同時傳好幾本，但不超過上限
    func testBackupUploadsSeveralNotebooksAtOnce() async throws {
        let a = try device()
        let ids = (1...7).map { notebook("第 \($0) 本", on: a).id }
        _ = try await a.backup.syncWithRetry()

        XCTAssertEqual(Set(drive.uploads.filter { $0.hasSuffix(".papernote") }), Set(ids.map { "\($0.uuidString).papernote" }))
        XCTAssertGreaterThan(drive.maxConcurrentUploads, 1)
        XCTAssertLessThanOrEqual(drive.maxConcurrentUploads, BackupManager.parallelTransfers)
    }

    /// 真的下載成檔案（不整個放進記憶體），內容一樣
    func testClientDownloadsToAFile() async throws {
        URLProtocol.registerClass(RecordingProtocol.self)
        defer {
            URLProtocol.unregisterClass(RecordingProtocol.self)
            RecordingProtocol.reset()
        }
        RecordingProtocol.statusCode = 200
        RecordingProtocol.body = Data("講義內容".utf8)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)/a.pdf")
        defer { try? FileManager.default.removeItem(at: dest.deletingLastPathComponent()) }

        try await DriveClient(accessToken: { "token" }).download("abc", to: dest)

        XCTAssertEqual(try Data(contentsOf: dest), Data("講義內容".utf8))
        XCTAssertEqual(RecordingProtocol.requests.first?.url?.absoluteString, "https://www.googleapis.com/drive/v3/files/abc?alt=media")

        RecordingProtocol.reset()
        RecordingProtocol.statusCode = 404
        do {
            try await DriveClient(accessToken: { "token" }).download("gone", to: dest)
            XCTFail("找不到要回報")
        } catch BackupError.http(404, _) {}
    }

    /// 需求：一本筆記本在雲端就是一個 .papernote（PDF、圖片、筆跡、縮圖都在裡面），還原只下載這個檔案；
    /// 下載下來可以直接用「匯入」打開
    func testNotebookIsOnePaperNoteFile() async throws {
        let a = try device()
        let nb = notebook("打包", on: a)
        let dir = a.store.notebookURL(nb.id)
        let fm = FileManager.default
        for sub in ["drawings", "thumbs", "files"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        for i in 1...3 { try Data("筆跡 \(i)".utf8).write(to: dir.appendingPathComponent("drawings/p\(i).drawing")) }
        try Data("縮圖".utf8).write(to: dir.appendingPathComponent("thumbs/cover.jpg"))
        try Data("講義".utf8).write(to: dir.appendingPathComponent("files/handout.pdf"))
        try Data("照片".utf8).write(to: dir.appendingPathComponent("files/img-1.jpg"))
        _ = try await a.backup.syncWithRetry()

        let notebooks = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName, "Notebooks"]))
        let inFolder = try await drive.children(of: notebooks.id).map(\.name)
        XCTAssertEqual(inFolder, ["\(nb.id.uuidString).papernote"], "一本一個檔案，沒有資料夾")
        XCTAssertEqual(Set(try zipEntries(nb.id)),
                       ["papernote.json", "notebook/document.json", "notebook/drawings/p1.drawing", "notebook/drawings/p2.drawing",
                        "notebook/drawings/p3.drawing", "notebook/thumbs/cover.jpg", "notebook/files/handout.pdf",
                        "notebook/files/img-1.jpg"])

        let b = try device()
        drive.downloads = []
        _ = try await b.backup.restore()

        XCTAssertEqual(drive.downloads.filter { $0 != BackupManifest.fileName }, ["\(nb.id.uuidString).papernote"])
        XCTAssertEqual(contents(of: b.store.notebookURL(nb.id)), contents(of: dir))
        XCTAssertEqual(b.store.notebook(nb.id)?.title, "打包")
        XCTAssertEqual(drive.violations, [])

        // 從 Google Drive 下載下來，直接匯入
        let downloaded = fm.temporaryDirectory.appendingPathComponent("打包-\(UUID().uuidString).papernote")
        defer { try? fm.removeItem(at: downloaded) }
        try XCTUnwrap(drive.papernote(nb.id)).data.write(to: downloaded)
        let imported = try b.store.importPaperNote(from: downloaded, folder: nil)
        XCTAssertEqual(imported.title, "打包 (1)")
        XCTAssertEqual(contents(of: b.store.notebookURL(imported.id)), contents(of: dir))
    }

    /// 文字和筆跡壓縮；PDF、圖片本來就壓縮過，原樣放
    func testTextIsCompressedAndPicturesAreNot() async throws {
        let a = try device()
        let nb = notebook("壓縮", on: a)
        let dir = a.store.notebookURL(nb.id)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("files"), withIntermediateDirectories: true)
        let ink = Data(String(repeating: "一筆一筆的筆跡 ", count: 5_000).utf8)
        try ink.write(to: dir.appendingPathComponent("page.drawing"))
        let pdf = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 7919) })
        try pdf.write(to: dir.appendingPathComponent("files/handout.pdf"))
        _ = try await a.backup.syncWithRetry()

        let archive = try papernoteArchive(nb.id)
        let drawing = try XCTUnwrap(archive.entries.first { $0.path == "notebook/page.drawing" })
        XCTAssertEqual(drawing.method, 8)
        XCTAssertLessThan(drawing.compressedSize * 10, drawing.uncompressedSize)
        XCTAssertEqual(try archive.contents(of: drawing), ink)
        let handout = try XCTUnwrap(archive.entries.first { $0.path == "notebook/files/handout.pdf" })
        XCTAssertEqual(handout.method, 0)
        XCTAssertEqual(try archive.contents(of: handout), pdf)
    }

    /// 改名：雲端檔案裡的名稱也要更新（下載下來匯入才對）
    func testRenameUpdatesTheNameInside() async throws {
        let a = try device()
        let nb = notebook("舊名", on: a)
        _ = try await a.backup.syncWithRetry()
        resetCounters()

        a.store.renameNotebook(nb.id, to: "新名")
        _ = try await a.backup.syncWithRetry()

        XCTAssertEqual(drive.uploads.filter { $0 != BackupManifest.fileName }, ["\(nb.id.uuidString).papernote"])
        let archive = try papernoteArchive(nb.id)
        XCTAssertEqual(PaperNoteFile.manifest(in: archive)?.title, "新名")
    }

    /// 更新前的資料夾還在旁邊：有 .papernote 就照它還原，舊資料夾不下載
    func testPaperNoteFileWinsOverAnOldFolder() async throws {
        let a = try device()
        let nb = notebook("新格式", on: a)
        _ = try await a.backup.syncWithRetry()
        let notebooks = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName, "Notebooks"]))
        let folder = try await drive.createFolder(named: nb.id.uuidString, in: notebooks.id)
        let page = { Page(background: .paper(width: 100, height: 100, style: .blank)) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try NotebookSession.writeDocument(NotebookDocument(pages: [page(), page(), page()]), to: tmp)
        _ = try await drive.upload(NotebookSession.documentURL(in: tmp), name: "document.json", parent: folder, existingID: nil)

        let b = try device()
        drive.downloads = []
        _ = try await b.backup.restore()

        XCTAssertFalse(drive.downloads.contains("document.json"))
        let restored = try Data(contentsOf: NotebookSession.documentURL(in: b.store.notebookURL(nb.id)))
        XCTAssertEqual(try JSONDecoder.app.decode(NotebookDocument.self, from: restored).pages.count, 1)
    }

    /// 再前一版的備份（全部是散檔）還是還原得回來
    func testRestoreFromLooseFilesOfAnOldVersion() async throws {
        let a = try device()
        let nb = notebook("上一版備份的", on: a)
        let dir = a.store.notebookURL(nb.id)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("drawings"), withIntermediateDirectories: true)
        try Data("筆跡".utf8).write(to: dir.appendingPathComponent("drawings/p.drawing"))
        _ = try await a.backup.syncWithRetry()
        try await makeOldFormat(nb.id)

        let b = try device()
        let result = try await b.backup.restore()

        XCTAssertEqual(result.notebooks, 1)
        XCTAssertEqual(b.store.notebook(nb.id)?.title, "上一版備份的")
        XCTAssertEqual(try Data(contentsOf: b.store.notebookURL(nb.id).appendingPathComponent("drawings/p.drawing")), Data("筆跡".utf8))
    }

    /// 上一版的備份（notebook.zip＋files/）還原得回來
    func testRestoreFromTheNotebookZipVersion() async throws {
        let a = try device()
        let nb = notebook("notebook.zip 版", on: a)
        let dir = a.store.notebookURL(nb.id)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("files"), withIntermediateDirectories: true)
        try Data("筆跡".utf8).write(to: dir.appendingPathComponent("page.drawing"))
        try Data("講義".utf8).write(to: dir.appendingPathComponent("files/handout.pdf"))
        _ = try await a.backup.syncWithRetry()
        try await makeOldFormat(nb.id, loose: false)

        let b = try device()
        drive.downloads = []
        let result = try await b.backup.restore()

        XCTAssertEqual(result.notebooks, 1)
        XCTAssertEqual(Set(drive.downloads.filter { $0 != BackupManifest.fileName }), ["notebook.zip", "handout.pdf"])
        XCTAssertEqual(contents(of: b.store.notebookURL(nb.id)), contents(of: dir))
    }

    /// 從上一版更新：第一次備份把每本換成 .papernote，傳好後舊資料夾移到 Drive 垃圾桶（內容還救得回來）；
    /// 之後就不用再傳
    func testUpdatingFromTheNotebookZipVersion() async throws {
        let a = try device()
        let nb = notebook("要換格式", on: a)
        let dir = a.store.notebookURL(nb.id)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("files"), withIntermediateDirectories: true)
        try Data("講義".utf8).write(to: dir.appendingPathComponent("files/handout.pdf"))
        _ = try await a.backup.syncWithRetry()
        try await makeOldFormat(nb.id, loose: false)
        let old = try XCTUnwrap(drive.notebookFolder(nb.id))
        // 上一版留下的備份紀錄
        let stateURL = a.dir.appendingPathComponent("state.json")
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        state["archives"] = [nb.id.uuidString: ["id": "舊的", "fingerprint": "舊的", "md5": "舊的"]]
        state["files"] = ["library.json": ["id": "舊的", "size": 1, "mtime": 1],
                          "Notebooks/\(nb.id.uuidString)/files/handout.pdf": ["id": "舊的", "size": 1, "mtime": 1]]
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
        resetCounters()

        _ = try await relaunched(a).syncWithRetry()

        XCTAssertEqual(drive.uploads.filter { $0 != BackupManifest.fileName }, ["\(nb.id.uuidString).papernote"])
        XCTAssertNotNil(drive.papernote(nb.id))
        XCTAssertNil(drive.notebookFolder(nb.id), "舊資料夾移到 Drive 垃圾桶")
        XCTAssertNotNil(drive.trash[old.id])
        XCTAssertTrue(drive.trash.values.contains { $0.name == "handout.pdf" })
        XCTAssertEqual(drive.violations, [])

        resetCounters()
        _ = try await relaunched(a).syncWithRetry()
        XCTAssertEqual(drive.uploads, [])
    }

    /// 雲端只有舊格式、這台沒有的筆記本（還沒還原）：舊資料夾不能動
    func testOldFolderOfANotebookNotOnThisIPadStays() async throws {
        let a = try device()
        let nb = notebook("別台的", on: a)
        _ = try await a.backup.syncWithRetry()
        try await makeOldFormat(nb.id, loose: false)

        let b = try device()
        _ = notebook("這台的", on: b)
        _ = try await b.backup.syncWithRetry()

        XCTAssertNotNil(drive.notebookFolder(nb.id))
        XCTAssertTrue(drive.trashed.isEmpty)
    }

    // MARK: 回報的問題：永久刪除後雲端還留著

    /// 只丟進垃圾桶：雲端檔案不能動，清單記成在垃圾桶
    func testTrashKeepsTheCloudFiles() async throws {
        let d = try device()
        let nb = notebook("丟垃圾桶", on: d)
        _ = try await d.backup.syncWithRetry()
        XCTAssertEqual(try status(nb.id), .active)
        let before = try XCTUnwrap(drive.papernote(nb.id)).data

        d.store.trashNotebook(nb.id)
        _ = try await d.backup.syncWithRetry()

        XCTAssertEqual(try status(nb.id), .trashed)
        XCTAssertEqual(drive.papernote(nb.id)?.data, before)
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

        XCTAssertNil(drive.papernote(nb.id))
        XCTAssertTrue(drive.trash.values.contains { $0.name == "\(nb.id.uuidString).papernote" }, "內容還在 Drive 垃圾桶")
        XCTAssertNotNil(drive.papernote(keep.id), "別本不受影響")
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
        let flaky = BackupManager(drive: failing, library: d.store, global: d.global, stateURL: d.dir.appendingPathComponent("state.json"))

        d.store.deleteNotebook(nb.id)
        do {
            _ = try await flaky.syncWithRetry()
            XCTFail("刪除失敗要回報")
        } catch {}
        XCTAssertEqual(d.store.index.purgedNotebooks.map(\.id), [nb.id], "沒刪成要繼續記著")
        XCTAssertEqual(try status(nb.id), .deleted, "清單先傳，這時還原也不會帶回來")

        let retry = BackupManager(drive: drive, library: d.store, global: d.global, stateURL: d.dir.appendingPathComponent("state.json"))
        _ = try await retry.syncWithRetry()
        XCTAssertNil(drive.papernote(nb.id))
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

    /// 只有標記永久刪除的才清：別台 iPad 上還在用的筆記本，舊資料夾空了也不能刪
    func testEmptyFolderOfALiveNotebookStays() async throws {
        let a = try device()
        let nb = notebook("另一台的", on: a)
        _ = try await a.backup.syncWithRetry()
        let notebooks = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName, "Notebooks"]))
        _ = try await drive.createFolder(named: nb.id.uuidString, in: notebooks.id)

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

    /// 頁面永久刪除後留下的檔案：筆跡和附件跟著離開 .papernote，雲端不會多出別的檔案
    func testFilesOfDeletedPagesAreRemoved() async throws {
        let d = try device()
        let nb = notebook("有頁面", on: d)
        let dir = d.store.notebookURL(nb.id)
        for sub in ["drawings", "files"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let ink = dir.appendingPathComponent("drawings/page.drawing")
        let attachment = dir.appendingPathComponent("files/old.pdf")
        try Data("筆跡".utf8).write(to: ink)
        try Data("附件".utf8).write(to: attachment)
        _ = try await d.backup.syncWithRetry()
        XCTAssertTrue(try zipEntries(nb.id).contains("notebook/drawings/page.drawing"))
        XCTAssertTrue(try zipEntries(nb.id).contains("notebook/files/old.pdf"))

        try FileManager.default.removeItem(at: ink)
        try FileManager.default.removeItem(at: attachment)
        _ = try await d.backup.syncWithRetry()

        XCTAssertFalse(try zipEntries(nb.id).contains("notebook/drawings/page.drawing"))
        XCTAssertFalse(try zipEntries(nb.id).contains("notebook/files/old.pdf"))
        let notebooks = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName, "Notebooks"]))
        XCTAssertEqual(drive.count(named: "\(nb.id.uuidString).papernote", in: notebooks.id), 1)
        XCTAssertEqual(drive.violations, [])
    }

    /// 本機檔案不見（例如在「檔案」App 把整本刪了）不是永久刪除：雲端是唯一的備份，不能跟著刪
    func testLosingLocalFilesNeverDeletesTheBackup() async throws {
        let d = try device()
        let nb = notebook("還要救回來", on: d)
        _ = try await d.backup.syncWithRetry()
        let before = try XCTUnwrap(drive.papernote(nb.id)).data

        try FileManager.default.removeItem(at: d.store.notebookURL(nb.id))
        _ = try await d.backup.syncWithRetry()

        XCTAssertEqual(drive.papernote(nb.id)?.data, before)
        XCTAssertTrue(drive.trashed.isEmpty)
    }

    // MARK: 不能動到其他資料

    func testNeverTouchesTheUsersOtherFiles() async throws {
        let d = try device()
        let nb = notebook("要刪的", on: d)
        _ = try await d.backup.syncWithRetry()

        // 使用者自己的東西，名字故意和 App 的一樣。PaperNoteBackup 同層、上層的都不能動
        let root = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName]))
        let notebooks = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName, "Notebooks"]))
        let users = [
            drive.addUserFile(name: "畢業論文.pdf", parent: "root"),
            drive.addUserFile(name: BackupManifest.fileName, parent: "root"),
            drive.addUserFile(name: "document.json", parent: "root"),
            drive.addUserFile(name: "\(nb.id.uuidString).papernote", parent: "root"),
            drive.addUserFile(name: "我放進來的.pdf", parent: root.id),
            drive.addUserFile(name: "我放進來的.pdf", parent: notebooks.id),
        ]
        let lookalike = drive.addUserFile(name: "Notebooks", parent: "root", isFolder: true)
        let lookalikeNotebook = drive.addUserFile(name: nb.id.uuidString, parent: lookalike, isFolder: true)
        let lookalikeFile = drive.addUserFile(name: "document.json", parent: lookalikeNotebook)

        d.store.deleteNotebook(nb.id)
        _ = try await d.backup.syncWithRetry()

        XCTAssertNil(drive.papernote(nb.id))
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

    /// 回報的問題：還原到一半斷線（螢幕暗掉、切出 App），下載好的筆記本在重開 App 後
    /// 變成最外層的「復原的筆記本」；再還原一次只補回空的資料夾
    func testInterruptedRestoreKeepsNamesAndFolders() async throws {
        let a = try device()
        let folder = a.store.createFolder(name: "課程", parent: nil)
        let first = notebook("第一本", on: a, folder: folder.id)
        let second = notebook("第二本", on: a, folder: folder.id)
        _ = try await a.backup.syncWithRetry()
        let titles = [first.id: "第一本", second.id: "第二本"]

        // 第一本下載好之後斷線
        let notebooks = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName, "Notebooks"]))
        let order = try await drive.children(of: notebooks.id)
        XCTAssertEqual(order.count, 2)
        let done = try XCTUnwrap(UUID(uuidString: String(order[0].name.dropLast(".papernote".count))))
        let b = try Device(drive: FailingDeleteDrive(drive, failingID: order[1].id))
        devices.append(b)
        do {
            _ = try await b.backup.restore()
            XCTFail("第二本應該斷線")
        } catch {}

        let nb = try XCTUnwrap(b.store.notebook(done), "下載好的筆記本要馬上記進資料庫")
        XCTAssertEqual(nb.title, titles[done])
        XCTAssertEqual(nb.folderId, folder.id)
        XCTAssertNotNil(b.store.folder(folder.id))

        // 重開 App 不能多出「復原的筆記本」
        let relaunched = LibraryStore(documentsURL: b.store.documentsURL)
        XCTAssertEqual(relaunched.index.notebooks.map(\.title), [titles[done]])

        // 網路恢復後再還原：剩下的回到原本的資料夾
        let again = BackupManager(drive: drive, library: b.store, global: b.global, stateURL: b.dir.appendingPathComponent("state-again.json"))
        let result = try await again.restore()
        XCTAssertEqual(result, RestoreResult(notebooks: 1, trashed: 0))
        XCTAssertEqual(Set(b.store.notebooks(in: folder.id).map(\.title)), ["第一本", "第二本"])
        XCTAssertTrue(b.store.notebooks(in: nil).isEmpty)
    }

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
        let flaky = BackupManager(drive: FailingDeleteDrive(drive), library: a.store, global: a.global, stateURL: a.dir.appendingPathComponent("state.json"))
        do { _ = try await flaky.syncWithRetry() } catch {}
        XCTAssertNotNil(drive.papernote(nb.id))

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
        XCTAssertEqual(drive.count(named: "library.json", in: root.id), 0, "清單裡都有，不用另外傳")
        XCTAssertEqual(drive.count(named: BackupManifest.fileName, in: root.id), 1, "不會多一份")

        let result = try await b.backup.restore()
        XCTAssertEqual(result.notebooks, 1)
        XCTAssertEqual(b.store.notebook(nb.id)?.title, "舊 iPad 的")

        // 還原回來的再備份：覆蓋原本的檔案，不會多一份
        _ = try await b.backup.syncWithRetry()
        let notebooks = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName, "Notebooks"]))
        XCTAssertEqual(drive.count(named: "\(nb.id.uuidString).papernote", in: notebooks.id), 1)
    }

    /// 這次更新前的備份（沒有清單）：名稱照 library.json；
    /// 裡面沒列的是以前永久刪除、留在雲端的，放進垃圾桶，不會突然出現
    func testRestoreFromAnOldBackup() async throws {
        let a = try device()
        let listed = notebook("舊版的", on: a)
        let leftover = notebook("以前刪掉的", on: a)
        _ = try await a.backup.syncWithRetry()
        let root = try XCTUnwrap(drive.folder(path: [BackupManager.rootFolderName]))
        // 那時候的備份有 library.json
        var index = a.store.index
        index.notebooks.removeAll { $0.id == leftover.id }
        let lib = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: lib) }
        try JSONEncoder.app.encode(index).write(to: lib)
        _ = try await drive.upload(lib, name: "library.json", parent: root.id, existingID: nil)
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
        try await makeOldFormat(nb.id)
        let folder = try XCTUnwrap(drive.notebookFolder(nb.id))
        let page = { Page(background: .paper(width: 100, height: 100, style: .blank)) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try NotebookSession.writeDocument(NotebookDocument(pages: [page(), page()]), to: tmp)
        _ = try await drive.upload(NotebookSession.documentURL(in: tmp), name: "document.json", parent: folder.id, existingID: nil)
        XCTAssertEqual(drive.count(named: "document.json", in: folder.id), 2)
        XCTAssertNil(drive.papernote(nb.id))

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
        BackupManager(drive: api ?? drive, library: d.store, global: d.global, stateURL: d.dir.appendingPathComponent("state.json"))
    }

    private func resetCounters() {
        drive.uploads = []
        drive.lookups = []
        drive.listings = []
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
        XCTAssertEqual(drive.listings, [], "修改時間存檔後要一模一樣，連雲端都不用問")
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
        XCTAssertEqual(drive.listings, [])

        // 之後時間沒再變：也不用再算一次
        let again = try await relaunched(d).syncWithRetry()
        XCTAssertEqual(again, 0)
    }

    /// 只改一本的一個檔案：只傳那本
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

        XCTAssertEqual(drive.uploads, ["\(nb.id.uuidString).papernote"])
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

        XCTAssertFalse(drive.uploads.contains("\(nb.id.uuidString).papernote"))
    }

    /// 備份到一半被中斷：傳好的要記得，下次只傳沒傳好的
    func testInterruptedBackupKeepsProgress() async throws {
        let d = try device()
        for i in 1...4 { _ = notebook("中斷 \(i)", on: d) }
        // 清單和兩本會成功
        let flaky = relaunched(d, drive: FailingDeleteDrive(drive, uploadsBeforeFailure: 3))
        do {
            _ = try await flaky.syncWithRetry()
            XCTFail("上傳失敗要回報")
        } catch {}
        resetCounters()

        _ = try await relaunched(d).syncWithRetry()

        XCTAssertEqual(drive.uploads.filter { $0.hasSuffix(".papernote") }.count, 2, "共 4 本，傳好的兩本不用再傳")
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
        XCTAssertNotNil(drive.papernote(nb.id))
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

/// 刪除時會失敗的 Drive（例如網路斷了）；也可以在讀某個資料夾或下載某個檔案時斷線
@MainActor
private final class FailingDeleteDrive: DriveAPI {
    private let base: FakeDrive
    private var uploadsLeft: Int
    private let failingID: String?

    init(_ base: FakeDrive, uploadsBeforeFailure: Int = .max, failingID: String? = nil) {
        self.base = base
        uploadsLeft = uploadsBeforeFailure
        self.failingID = failingID
    }

    func findFolder(named name: String, in parent: String) async throws -> String? { try await base.findFolder(named: name, in: parent) }
    func findFile(named name: String, in parent: String) async throws -> DriveFile? { try await base.findFile(named: name, in: parent) }
    func createFolder(named name: String, in parent: String) async throws -> String { try await base.createFolder(named: name, in: parent) }
    func children(of folder: String) async throws -> [DriveFile] {
        if folder == failingID { throw BackupError.http(500, "斷線") }
        return try await base.children(of: folder)
    }
    func upload(_ fileURL: URL, name: String, parent: String, existingID: String?) async throws -> String {
        guard uploadsLeft > 0 else { throw BackupError.http(500, "斷線") }
        uploadsLeft -= 1
        return try await base.upload(fileURL, name: name, parent: parent, existingID: existingID)
    }
    func download(_ fileID: String, to destination: URL) async throws {
        if fileID == failingID { throw BackupError.http(500, "斷線") }
        try await base.download(fileID, to: destination)
    }
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
