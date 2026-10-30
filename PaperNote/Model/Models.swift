import Foundation
import CoreGraphics

// MARK: - Page content

struct PageInsets: Codable, Equatable {
    var top: CGFloat = 0
    var left: CGFloat = 0
    var bottom: CGFloat = 0
    var right: CGFloat = 0

    var isZero: Bool { top == 0 && left == 0 && bottom == 0 && right == 0 }
}

enum PaperStyle: String, Codable, CaseIterable, Identifiable {
    case blank, ruled, grid, dotted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: return "空白"
        case .ruled: return "橫線"
        case .grid: return "方格"
        case .dotted: return "點格"
        }
    }
}

/// 紙張大小（直式：寬 × 高，單位是點，1 點 = 1/72 英吋）
struct PaperSize: Equatable, Identifiable {
    let title: String
    let size: CGSize
    var id: String { title }

    static let a4 = PaperSize(title: "A4", size: CGSize(width: 595, height: 842))        // 210 × 297 mm
    static let b5 = PaperSize(title: "B5", size: CGSize(width: 516, height: 729))        // 182 × 257 mm
    static let letter = PaperSize(title: "Letter", size: CGSize(width: 612, height: 792)) // 8.5 × 11 in
    static let presets = [a4, b5, letter]

    /// size 的方向改成直式或橫式
    static func oriented(_ size: CGSize, landscape: Bool) -> CGSize {
        let short = min(size.width, size.height), long = max(size.width, size.height)
        return landscape ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
    }
}

enum PageBackground: Codable, Equatable {
    case pdf(file: String, index: Int)
    case paper(width: CGFloat, height: CGFloat, style: PaperStyle)
}

/// PDF 文字螢光標示。rects 使用頁面內容座標（原始頁面左上角為原點）。
struct TextHighlight: Codable, Equatable, Identifiable {
    var id = UUID()
    var rects: [CGRect]
    var colorHex: String
}

struct TextBoxData: Codable, Equatable {
    var text: String
    var fontSize: CGFloat = 18
    var colorHex: String = "#1A1A1AFF"
    var backgroundHex: String? = nil
}

struct ImageData: Codable, Equatable {
    var file: String
}

enum ElementContent: Codable, Equatable {
    case image(ImageData)
    case table(TableData)
    case text(TextBoxData)
    case circuit(CircuitData)
}

/// 頁面上的物件（圖片、表格、文字框）。frame 使用頁面內容座標。
/// 這些物件畫在筆跡底下，所以橡皮擦擦不到。
struct PageElement: Codable, Equatable, Identifiable {
    var id = UUID()
    var frame: CGRect
    var locked = false
    var content: ElementContent

    var isTable: Bool { if case .table = content { return true }; return false }
    var isImage: Bool { if case .image = content { return true }; return false }
    var isCircuit: Bool { if case .circuit = content { return true }; return false }

    /// 電路圖的外框原點對齊頁面格點，不同電路圖的元件才會落在同一組格點上
    mutating func snapCircuitToGrid() {
        guard isCircuit else { return }
        frame.origin = CircuitData.snap(frame.origin)
    }
}

/// 自製筆刷的一個取樣點（頁面內容座標）；w 是這一點的線寬
struct InkPoint: Codable, Equatable {
    var x: Float
    var y: Float
    var w: Float

    init(_ p: CGPoint, width: CGFloat) {
        x = Float(p.x)
        y = Float(p.y)
        w = Float(width)
    }

    var point: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }
    var width: CGFloat { CGFloat(w) }
}

/// 自製筆刷的一筆：照 Pencil 的原始取樣點畫，不做圓滑處理
struct InkStroke: Codable, Equatable, Identifiable {
    var id = UUID()
    var colorHex: String
    var points: [InkPoint]
}

struct Page: Codable, Equatable, Identifiable {
    var id = UUID()
    var background: PageBackground
    var insets = PageInsets()
    var elements: [PageElement] = []
    var highlights: [TextHighlight] = []
    /// 自製筆刷的筆跡（PencilKit 的筆跡另外存在 drawings）
    var ink: [InkStroke] = []
    var favorite = false
    var note = ""

    init(background: PageBackground) {
        self.background = background
    }

    enum CodingKeys: String, CodingKey {
        case id, background, insets, elements, highlights, ink, favorite, note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        background = try c.decode(PageBackground.self, forKey: .background)
        insets = try c.decodeIfPresent(PageInsets.self, forKey: .insets) ?? PageInsets()
        elements = try c.decodeIfPresent([PageElement].self, forKey: .elements) ?? []
        highlights = try c.decodeIfPresent([TextHighlight].self, forKey: .highlights) ?? []
        ink = try c.decodeIfPresent([InkStroke].self, forKey: .ink) ?? []
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

/// 被刪除的頁面（30 天內可以還原）
struct TrashedPage: Codable, Identifiable {
    var page: Page
    var deletedAt: Date
    var originalIndex: Int

    var id: UUID { page.id }
}

struct NotebookDocument: Codable {
    var version = 1
    var pages: [Page]
    /// 最近刪除的頁面（舊版存檔沒有這個欄位）
    var trash: [TrashedPage]? = nil
}

enum Trash {
    static let retentionDays = 30

    static func isExpired(_ date: Date) -> Bool {
        Date().timeIntervalSince(date) > Double(retentionDays) * 86_400
    }

    static func daysLeft(_ date: Date) -> Int {
        max(0, retentionDays - Int(Date().timeIntervalSince(date) / 86_400))
    }
}

// MARK: - Library

struct Folder: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var parentId: UUID?
    var created = Date()
    /// 有值＝在垃圾桶裡
    var deletedAt: Date? = nil
}

struct FavoriteRef: Codable, Equatable, Hashable {
    var pageId: UUID
    var pageNumber: Int
    var note: String
}

struct NotebookMeta: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var folderId: UUID?
    var created = Date()
    var modified = Date()
    var coverHex: String
    var pageCount = 0
    var favorites: [FavoriteRef] = []
    /// 有值＝在垃圾桶裡
    var deletedAt: Date? = nil
    /// 這本筆記本「最近刪除的頁面」數量
    var trashedPageCount = 0
    /// 加到資料庫的「我的最愛文件」
    var starred = false

    init(title: String, folderId: UUID?, coverHex: String) {
        self.title = title
        self.folderId = folderId
        self.coverHex = coverHex
    }

    enum CodingKeys: String, CodingKey {
        case id, title, folderId, created, modified, coverHex, pageCount, favorites, deletedAt, trashedPageCount, starred
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "未命名"
        folderId = try c.decodeIfPresent(UUID.self, forKey: .folderId)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? Date()
        coverHex = try c.decodeIfPresent(String.self, forKey: .coverHex) ?? "#2654A0FF"
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
        favorites = try c.decodeIfPresent([FavoriteRef].self, forKey: .favorites) ?? []
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        trashedPageCount = try c.decodeIfPresent(Int.self, forKey: .trashedPageCount) ?? 0
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
    }
}

struct LibraryIndex: Codable {
    var folders: [Folder] = []
    var notebooks: [NotebookMeta] = []
}

extension JSONEncoder {
    static var app: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var app: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
