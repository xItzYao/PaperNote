import UIKit
import PDFKit

/// PDF 大綱的一行：標題、層級，和它在這本筆記本裡是第幾頁（nil＝那一頁已經刪掉了）
struct PDFOutlineEntry: Equatable {
    var title: String
    var depth: Int
    var pageIndex: Int?
}

extension Page {
    /// PDF 匯入的頁面
    var isPDFPage: Bool {
        if case .pdf = background { return true }
        return false
    }
}

/// 「全部頁面」的「大綱」：把筆記本裡 PDF 的大綱（書籤）對到筆記本的頁面
enum PDFOutlineList {
    static func entries(pages: [Page], document: (String) -> PDFDocument?) -> [PDFOutlineEntry] {
        // PDF 的第幾頁 → 筆記本的第幾頁（同一頁出現兩次取前面的）
        var where_: [String: [Int: Int]] = [:]
        var files: [String] = []
        for (i, p) in pages.enumerated() {
            guard case let .pdf(file, index) = p.background else { continue }
            if where_[file] == nil {
                where_[file] = [:]
                files.append(file)
            }
            if where_[file]?[index] == nil { where_[file]?[index] = i }
        }
        var out: [PDFOutlineEntry] = []
        for file in files {
            guard let doc = document(file), let root = doc.outlineRoot else { continue }
            func walk(_ item: PDFOutline, depth: Int) {
                for k in 0..<item.numberOfChildren {
                    guard let child = item.child(at: k) else { continue }
                    let dest = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                    let pdfIndex = dest?.page.map { doc.index(for: $0) }
                    let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    out.append(PDFOutlineEntry(title: title.isEmpty ? L("（沒有標題）") : title, depth: depth,
                                               pageIndex: pdfIndex.flatMap { where_[file]?[$0] }))
                    walk(child, depth: depth + 1)
                }
            }
            walk(root, depth: 0)
        }
        return out
    }
}

/// 大綱的一行：依層級縮排，右邊是頁碼
final class PDFOutlineCell: UITableViewCell {
    func show(_ e: PDFOutlineEntry) {
        var c = UIListContentConfiguration.valueCell()
        c.text = e.title
        c.secondaryText = e.pageIndex.map { L("第 \($0 + 1) 頁") } ?? L("頁面已刪除")
        c.textProperties.font = e.depth == 0 ? .systemFont(ofSize: 17, weight: .semibold) : .systemFont(ofSize: 16)
        c.textProperties.numberOfLines = 2
        let enabled = e.pageIndex != nil
        c.textProperties.color = enabled ? .label : .tertiaryLabel
        c.directionalLayoutMargins.leading = 20 + CGFloat(min(e.depth, 6)) * 22
        contentConfiguration = c
        selectionStyle = enabled ? .default : .none
        accessibilityLabel = e.title
    }
}
