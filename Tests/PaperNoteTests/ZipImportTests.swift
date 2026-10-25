import XCTest
import PDFKit
@testable import PaperNote

/// zip 批次匯入（從 GoodNotes 搬家）
final class ZipImportTests: XCTestCase {
    private var work: URL!
    private var createdFolders: [UUID] = []
    private let store = LibraryStore.shared

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("zip-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for id in createdFolders { store.deleteFolder(id) }
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    /// pages 頁的 PDF
    private func pdf(pages: Int) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            for i in 0..<pages {
                ctx.beginPage()
                ("第 \(i + 1) 頁" as NSString).draw(at: CGPoint(x: 50, y: 50), withAttributes: nil)
            }
        }
    }

    /// 用系統內建的壓縮（和「檔案」App 壓縮資料夾一樣）把資料夾壓成 zip
    private func systemZip(of dir: URL) throws -> URL {
        let out = work.appendingPathComponent(dir.lastPathComponent + ".zip")
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: .forUploading, error: &coordError) { zipped in
            do { try FileManager.default.copyItem(at: zipped, to: out) } catch { copyError = error }
        }
        if let e = coordError ?? copyError as NSError? { throw e }
        return out
    }

    /// 像 GoodNotes 一次匯出好幾本：中文檔名、子資料夾、混了一個 .goodnotes 檔
    private func goodNotesLikeExport() throws -> URL {
        let dir = work.appendingPathComponent("GoodNotes 匯出", isDirectory: true)
        let sub = dir.appendingPathComponent("電子學", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try pdf(pages: 3).write(to: dir.appendingPathComponent("工程數學.pdf"))
        try pdf(pages: 2).write(to: sub.appendingPathComponent("第一章 二極體.pdf"))
        try Data("not a pdf".utf8).write(to: sub.appendingPathComponent("舊格式.goodnotes"))
        return try systemZip(of: dir)
    }

    func testReadsSystemZipWithChineseNamesAndFolders() throws {
        let archive = try ZipArchive(url: try goodNotesLikeExport())
        let files = archive.entries.filter { !$0.isDirectory }.map(\.path).sorted()
        XCTAssertEqual(files, ["GoodNotes 匯出/工程數學.pdf", "GoodNotes 匯出/電子學/第一章 二極體.pdf", "GoodNotes 匯出/電子學/舊格式.goodnotes"].sorted())
        let entry = try XCTUnwrap(archive.entries.first { $0.name == "工程數學.pdf" })
        XCTAssertEqual(PDFDocument(data: try archive.contents(of: entry))?.pageCount, 3, "解出來要是完整的 PDF")
    }

    func testImportsEveryPDFAsNotebookKeepingFolders() throws {
        let result = try store.importZip(from: try goodNotesLikeExport(), folder: nil)
        let top = try XCTUnwrap(store.folders(in: nil).first { $0.name == "GoodNotes 匯出" })
        createdFolders.append(top.id)
        XCTAssertEqual(result.folderName, "GoodNotes 匯出", "zip 只有一個最上層資料夾：就用它，不要多包一層")
        XCTAssertEqual(result.notebooks.count, 2)
        XCTAssertEqual(store.notebooks(in: top.id).map(\.title), ["工程數學"])
        XCTAssertEqual(store.notebooks(in: top.id).first?.pageCount, 3)
        let sub = try XCTUnwrap(store.folders(in: top.id).first { $0.name == "電子學" })
        XCTAssertEqual(store.notebooks(in: sub.id).map(\.title), ["第一章 二極體"])
        XCTAssertEqual(store.notebooks(in: sub.id).first?.pageCount, 2)
        XCTAssertEqual(result.skipped, ["舊格式.goodnotes"])
        XCTAssertTrue(result.summary.contains("GoodNotes 格式"), "混到 .goodnotes 檔要提醒改用 PDF 匯出")
        XCTAssertTrue(result.failed.isEmpty)
    }

    func testLooseFilesGoIntoAFolderNamedAfterTheZip() throws {
        // 兩個 PDF 直接放在 zip 最上層（不是包在資料夾裡），另外有 macOS 的隱藏檔
        let a = pdf(pages: 1), b = pdf(pages: 4)
        let zipURL = work.appendingPathComponent("期中筆記.zip")
        try TestZip.stored([("a.pdf", a), ("b.pdf", b), ("__MACOSX/._a.pdf", Data([1, 2, 3])), (".DS_Store", Data([0]))]).write(to: zipURL)
        let result = try store.importZip(from: zipURL, folder: nil)
        let top = try XCTUnwrap(store.folders(in: nil).first { $0.name == "期中筆記" })
        createdFolders.append(top.id)
        XCTAssertEqual(Set(store.notebooks(in: top.id).map(\.title)), ["a", "b"])
        XCTAssertTrue(result.skipped.isEmpty, "macOS 的隱藏檔不算")
    }

    /// 同一個 zip 匯入好幾次：新資料夾加上 (2)、(3)，原本的不動
    func testImportingAgainNumbersTheNewFolder() throws {
        let zipURL = try goodNotesLikeExport()
        let names = try (0..<3).map { _ in try XCTUnwrap(store.importZip(from: zipURL, folder: nil).folderName) }
        let tops = store.folders(in: nil).filter { $0.name.hasPrefix("GoodNotes 匯出") }
        createdFolders += tops.map(\.id)
        XCTAssertEqual(names, ["GoodNotes 匯出", "GoodNotes 匯出 (2)", "GoodNotes 匯出 (3)"])
        XCTAssertEqual(Set(tops.map(\.name)), Set(names))
        for top in tops {
            XCTAssertEqual(store.notebooks(in: top.id).map(\.title), ["工程數學"], "每一份都完整")
        }
        // 子資料夾在新資料夾裡面，不用編號
        let second = try XCTUnwrap(tops.first { $0.name == "GoodNotes 匯出 (2)" })
        XCTAssertEqual(store.folders(in: second.id).map(\.name), ["電子學"])
    }

    func testCorruptEntryIsReportedAndOthersStillImport() throws {
        var bytes = TestZip.stored([("好的.pdf", pdf(pages: 1)), ("壞的.pdf", pdf(pages: 1))])
        // 破壞第二個檔案的內容（CRC 對不上）
        let marker = Data("壞的.pdf".utf8)
        let r = try XCTUnwrap(bytes.range(of: marker))
        bytes[r.upperBound + 40] ^= 0xFF
        let zipURL = work.appendingPathComponent("混合.zip")
        try bytes.write(to: zipURL)
        let result = try store.importZip(from: zipURL, folder: nil)
        if let top = store.folders(in: nil).first(where: { $0.name == "混合" }) { createdFolders.append(top.id) }
        XCTAssertEqual(result.notebooks.map(\.title), ["好的"])
        XCTAssertEqual(result.failed.map(\.name), ["壞的.pdf"])
    }

    func testNotAZip() throws {
        let url = work.appendingPathComponent("假的.zip")
        try Data("hello".utf8).write(to: url)
        XCTAssertThrowsError(try ZipArchive(url: url))
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }
}

/// 測試用：產生不壓縮的 zip（標 UTF-8 檔名）
enum TestZip {
    private static func u16(_ v: Int, into d: inout Data) {
        d.append(UInt8(v & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
    }

    private static func u32(_ v: UInt32, into d: inout Data) {
        u16(Int(v & 0xFFFF), into: &d)
        u16(Int(v >> 16), into: &d)
    }

    static func stored(_ files: [(String, Data)]) -> Data {
        var out = Data(), central = Data()
        for (name, data) in files {
            let n = Data(name.utf8), crc = CRC32.checksum(data), size = UInt32(data.count), offset = UInt32(out.count)
            // 檔案標頭：簽名、版本、旗標（UTF-8）、不壓縮、時間、日期、CRC、大小×2、檔名長度、額外欄位長度
            u32(0x0403_4b50, into: &out)
            for v in [20, 0x800, 0, 0, 0] { u16(v, into: &out) }
            for v in [crc, size, size] { u32(v, into: &out) }
            u16(n.count, into: &out)
            u16(0, into: &out)
            out.append(n)
            out.append(data)
            // 目錄：簽名、版本×2、旗標、不壓縮、時間、日期、CRC、大小×2、檔名／額外／註解長度、磁碟、屬性、位置
            u32(0x0201_4b50, into: &central)
            for v in [20, 20, 0x800, 0, 0, 0] { u16(v, into: &central) }
            for v in [crc, size, size] { u32(v, into: &central) }
            for v in [n.count, 0, 0, 0, 0] { u16(v, into: &central) }
            u32(0, into: &central)
            u32(offset, into: &central)
            central.append(n)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        u32(0x0605_4b50, into: &out)
        for v in [0, 0, files.count, files.count] { u16(v, into: &out) }
        u32(UInt32(central.count), into: &out)
        u32(cdOffset, into: &out)
        u16(0, into: &out)
        return out
    }
}
