import UIKit

/// 自己加的大綱：一個名字指到一頁（頁面移動、前面加頁都跟著那一頁）
struct OutlineBookmark: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var pageID: UUID
}

extension NotebookViewController {
    /// 自己加的大綱，照頁面順序排；那一頁不在了（刪掉、在最近刪除裡）就不列出來
    var outlineBookmarks: [(bookmark: OutlineBookmark, pageIndex: Int)] {
        (session.document.outline ?? [])
            .compactMap { b in pageIndex(of: b.pageID).map { (bookmark: b, pageIndex: $0) } }
            .sorted { $0.pageIndex < $1.pageIndex }
    }

    /// 第 i 頁加入大綱；名字留空就叫「第 n 頁」
    @discardableResult
    func addOutlineBookmark(pageIndex i: Int, title: String) -> OutlineBookmark? {
        guard let page = pages[safe: i] else { return nil }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = OutlineBookmark(title: name.isEmpty ? L("第 \(i + 1) 頁") : name, pageID: page.id)
        session.document.outline = (session.document.outline ?? []) + [b]
        saveNow()
        return b
    }

    func renameOutlineBookmark(_ id: UUID, to title: String) {
        guard let k = session.document.outline?.firstIndex(where: { $0.id == id }) else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        session.document.outline?[k].title = name
        saveNow()
    }

    func removeOutlineBookmark(_ id: UUID) {
        session.document.outline?.removeAll { $0.id == id }
        saveNow()
    }

    /// 「將該頁加入大綱」：跳出視窗為大綱命名（presenter：從哪個畫面跳出來，預設是編輯器）
    func promptAddToOutline(_ i: Int, from presenter: UIViewController? = nil, then: (() -> Void)? = nil) {
        guard pages.indices.contains(i) else { return }
        let a = UIAlertController(title: L("將該頁加入大綱"), message: L("第 \(i + 1) 頁：幫這個大綱取個名字"), preferredStyle: .alert)
        a.addTextField { tf in
            tf.placeholder = L("例如：第三章 電路分析")
            tf.clearButtonMode = .whileEditing
        }
        a.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        a.addAction(UIAlertAction(title: L("加入"), style: .default) { [weak self, weak a] _ in
            guard let self else { return }
            self.addOutlineBookmark(pageIndex: i, title: a?.textFields?.first?.text ?? "")
            self.showToast(L("已加入大綱"))
            then?()
        })
        (presenter ?? self).present(a, animated: true)
    }

    func promptRenameOutlineBookmark(_ b: OutlineBookmark, from presenter: UIViewController, then: @escaping () -> Void) {
        let a = UIAlertController(title: L("重新命名"), message: nil, preferredStyle: .alert)
        a.addTextField { tf in
            tf.text = b.title
            tf.clearButtonMode = .whileEditing
        }
        a.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        a.addAction(UIAlertAction(title: L("完成"), style: .default) { [weak self, weak a] _ in
            self?.renameOutlineBookmark(b.id, to: a?.textFields?.first?.text ?? "")
            then()
        })
        presenter.present(a, animated: true)
    }
}
