import UIKit
import PDFKit
import PencilKit

/// 一本打開中的筆記本：頁面資料、每頁筆跡、PDF 與圖片快取。
final class NotebookSession {
    let id: UUID
    let directory: URL
    var document: NotebookDocument
    /// 每頁筆跡，座標為頁面內容座標（原始頁面左上角為原點，擴展區為負值或超出原尺寸）
    var drawings: [UUID: PKDrawing] = [:]

    private var savedDrawingData: [UUID: Data] = [:]
    private var pdfCache: [String: PDFDocument] = [:]
    private let imageCache = NSCache<NSString, UIImage>()
    private let fm = FileManager.default

    var filesURL: URL { directory.appendingPathComponent("files", isDirectory: true) }
    var drawingsURL: URL { directory.appendingPathComponent("drawings", isDirectory: true) }
    var thumbsURL: URL { directory.appendingPathComponent("thumbs", isDirectory: true) }

    static func documentURL(in dir: URL) -> URL { dir.appendingPathComponent("document.json") }

    static func writeDocument(_ doc: NotebookDocument, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder.app.encode(doc)
        try data.write(to: documentURL(in: dir), options: .atomic)
    }

    var title: String { LibraryStore.shared.notebook(id)?.title ?? "筆記本" }
    var pages: [Page] { document.pages }

    init(id: UUID) throws {
        self.id = id
        directory = LibraryStore.shared.notebookURL(id)
        let data = try Data(contentsOf: Self.documentURL(in: directory))
        document = try JSONDecoder.app.decode(NotebookDocument.self, from: data)
        for dir in [filesURL, drawingsURL, thumbsURL] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for page in document.pages {
            let url = drawingURL(page.id)
            if let d = try? Data(contentsOf: url), let drawing = try? PKDrawing(data: d) {
                drawings[page.id] = drawing
                savedDrawingData[page.id] = d
            }
        }
        // 垃圾桶裡頁面的筆跡留在磁碟上；記錄起來，存檔時才不會被當成孤兒刪掉
        for t in document.trash ?? [] {
            if let d = try? Data(contentsOf: drawingURL(t.page.id)) { savedDrawingData[t.page.id] = d }
        }
        purgeExpiredPages()
    }

    // MARK: 最近刪除的頁面

    var trashedPages: [TrashedPage] { document.trash ?? [] }

    /// 頁面移到垃圾桶（筆跡先寫到磁碟保留）
    func trashPage(at index: Int) {
        guard document.pages.indices.contains(index) else { return }
        let page = document.pages.remove(at: index)
        if let d = drawings[page.id], !d.strokes.isEmpty {
            let data = d.dataRepresentation()
            try? data.write(to: drawingURL(page.id), options: .atomic)
            savedDrawingData[page.id] = data
        }
        var trash = document.trash ?? []
        trash.insert(TrashedPage(page: page, deletedAt: Date(), originalIndex: index), at: 0)
        document.trash = trash
    }

    /// 還原頁面，回傳放回的位置
    @discardableResult
    func restoreTrashedPage(_ id: UUID) -> Int? {
        guard var trash = document.trash, let i = trash.firstIndex(where: { $0.page.id == id }) else { return nil }
        let t = trash.remove(at: i)
        document.trash = trash
        let at = min(max(0, t.originalIndex), document.pages.count)
        document.pages.insert(t.page, at: at)
        if let drawing = loadDrawingFromDisk(t.page.id) { drawings[t.page.id] = drawing }
        return at
    }

    func deleteTrashedPage(_ id: UUID) {
        document.trash?.removeAll { $0.page.id == id }
    }

    func emptyPageTrash() {
        document.trash = []
    }

    func purgeExpiredPages() {
        document.trash?.removeAll { Trash.isExpired($0.deletedAt) }
    }

    func loadDrawingFromDisk(_ pageID: UUID) -> PKDrawing? {
        guard let d = try? Data(contentsOf: drawingURL(pageID)) else { return nil }
        return try? PKDrawing(data: d)
    }

    func trashedPageThumbnail(_ id: UUID, width: CGFloat = 160) -> UIImage? {
        guard let t = trashedPages.first(where: { $0.page.id == id }) else { return nil }
        let page = t.page
        let had = drawings[page.id]
        if had == nil, let d = loadDrawingFromDisk(page.id) { drawings[page.id] = d }
        defer { if had == nil { drawings[page.id] = nil } }
        let size = fullSize(of: page)
        guard size.width > 0 else { return nil }
        let scale = width / size.width
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: (size.height * scale).rounded()), format: fmt).image { rc in
            rc.cgContext.scaleBy(x: scale, y: scale)
            PageRenderer.drawFullPage(page, session: self, in: rc.cgContext, inkScale: max(scale * 2, 0.5))
        }
    }

    private func drawingURL(_ pageID: UUID) -> URL {
        drawingsURL.appendingPathComponent("\(pageID.uuidString).drawing")
    }

    // MARK: PDF

    func pdfDocument(_ file: String) -> PDFDocument? {
        if let d = pdfCache[file] { return d }
        let d = PDFDocument(url: filesURL.appendingPathComponent(file))
        pdfCache[file] = d
        return d
    }

    func pdfPage(for page: Page) -> PDFPage? {
        guard case let .pdf(file, index) = page.background else { return nil }
        return pdfDocument(file)?.page(at: index)
    }

    /// 原始頁面尺寸（不含擴展）
    func baseSize(of page: Page) -> CGSize {
        switch page.background {
        case let .paper(w, h, _):
            return CGSize(width: w, height: h)
        case .pdf:
            guard let p = pdfPage(for: page) else { return CGSize(width: 595, height: 842) }
            let box = p.bounds(for: .cropBox)
            let rot = ((p.rotation % 360) + 360) % 360
            return (rot == 90 || rot == 270) ? CGSize(width: box.height, height: box.width) : box.size
        }
    }

    /// 含擴展空白的整頁尺寸
    func fullSize(of page: Page) -> CGSize {
        let b = baseSize(of: page)
        return CGSize(width: b.width + page.insets.left + page.insets.right,
                      height: b.height + page.insets.top + page.insets.bottom)
    }

    /// PDF 頁面座標 → 頁面內容座標（左上原點、y 向下，已處理旋轉）
    static func displayTransform(for p: PDFPage) -> CGAffineTransform {
        let c = p.bounds(for: .cropBox)
        let x0 = c.minX, y0 = c.minY, w = c.width, h = c.height
        switch ((p.rotation % 360) + 360) % 360 {
        case 90: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: -y0, ty: -x0)
        case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: x0 + w, ty: -y0)
        case 270: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: y0 + h, ty: x0 + w)
        default: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -x0, ty: y0 + h)
        }
    }

    func backgroundSnapshot(for page: Page) -> BackgroundSnapshot {
        var paper: PaperStyle?
        var cgPage: CGPDFPage?
        var transform = CGAffineTransform.identity
        switch page.background {
        case let .paper(_, _, style):
            paper = style
        case .pdf:
            if let p = pdfPage(for: page) {
                cgPage = p.pageRef
                transform = Self.displayTransform(for: p)
            }
        }
        return BackgroundSnapshot(fullSize: fullSize(of: page), insets: page.insets, baseSize: baseSize(of: page),
                                  paper: paper, pdfPage: cgPage, pdfTransform: transform, highlights: page.highlights)
    }

    // MARK: Images

    func image(named file: String) -> UIImage? {
        if let img = imageCache.object(forKey: file as NSString) { return img }
        guard let img = UIImage(contentsOfFile: filesURL.appendingPathComponent(file).path) else { return nil }
        imageCache.setObject(img, forKey: file as NSString)
        return img
    }

    /// 存圖片，回傳檔名。截圖用 PNG 保持文字清晰，照片用 JPEG 節省空間。
    func saveImage(_ image: UIImage, jpeg: Bool = false) -> String? {
        let name = "img-\(UUID().uuidString).\(jpeg ? "jpg" : "png")"
        guard let data = jpeg ? image.jpegData(compressionQuality: 0.85) : image.pngData() else { return nil }
        do {
            try data.write(to: filesURL.appendingPathComponent(name), options: .atomic)
            imageCache.setObject(image, forKey: name as NSString)
            return name
        } catch {
            return nil
        }
    }

    // MARK: Save

    func save() {
        do {
            try Self.writeDocument(document, to: directory)
        } catch {
            print("Save document failed: \(error)")
        }
        let ids = Set(document.pages.map(\.id) + trashedPages.map(\.page.id))
        for page in document.pages {
            let d = drawings[page.id] ?? PKDrawing()
            if d.strokes.isEmpty && savedDrawingData[page.id] == nil { continue }
            let data = d.dataRepresentation()
            if data != savedDrawingData[page.id] {
                try? data.write(to: drawingURL(page.id), options: .atomic)
                savedDrawingData[page.id] = data
            }
        }
        for pid in Array(savedDrawingData.keys) where !ids.contains(pid) {
            try? fm.removeItem(at: drawingURL(pid))
            savedDrawingData[pid] = nil
            drawings[pid] = nil
        }
        let trashedCount = trashedPages.count
        let favorites = document.pages.enumerated().compactMap { i, p -> FavoriteRef? in
            p.favorite ? FavoriteRef(pageId: p.id, pageNumber: i + 1, note: p.note) : nil
        }
        let count = document.pages.count
        LibraryStore.shared.updateMeta(id) { meta in
            meta.pageCount = count
            meta.modified = Date()
            meta.favorites = favorites
            meta.trashedPageCount = trashedCount
        }
    }

    // MARK: Thumbnails

    func renderThumbnail(pageIndex: Int, width: CGFloat = 360) -> UIImage? {
        guard let page = document.pages[safe: pageIndex] else { return nil }
        let size = fullSize(of: page)
        guard size.width > 0 else { return nil }
        let scale = width / size.width
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let out = CGSize(width: width, height: (size.height * scale).rounded())
        return UIGraphicsImageRenderer(size: out, format: fmt).image { rc in
            rc.cgContext.scaleBy(x: scale, y: scale)
            PageRenderer.drawFullPage(page, session: self, in: rc.cgContext, inkScale: max(scale * 2, 0.5))
        }
    }

    func writeThumbnail(pageIndex: Int) {
        guard let page = document.pages[safe: pageIndex], let img = renderThumbnail(pageIndex: pageIndex),
              let data = img.jpegData(compressionQuality: 0.75) else { return }
        try? data.write(to: thumbsURL.appendingPathComponent("\(page.id.uuidString).jpg"), options: .atomic)
    }

    /// 封面＋所有我的最愛頁面的縮圖
    func writeLibraryThumbnails() {
        if let img = renderThumbnail(pageIndex: 0, width: 320), let data = img.jpegData(compressionQuality: 0.75) {
            try? data.write(to: thumbsURL.appendingPathComponent("cover.jpg"), options: .atomic)
        }
        for (i, p) in document.pages.enumerated() where p.favorite {
            writeThumbnail(pageIndex: i)
        }
    }
}
