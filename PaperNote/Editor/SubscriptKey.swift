import UIKit

/// 電路名稱的「下標」鍵：英文鍵盤要切到符號頁才打得出 _，鍵盤上面另外放一個按鍵。
/// 沒選字：插入 _（接著打的英數字就是下標）；有選字：選到的字變成下標（_{選到的字}）
enum SubscriptKey {
    static let accessibilityID = "subscriptKey"

    /// 在 selection 的位置按下標鍵後的字與游標（NSRange 以 UTF-16 計）
    static func apply(to text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = text as NSString
        let r = NSRange(location: min(max(selection.location, 0), ns.length),
                        length: max(0, min(selection.length, ns.length - min(max(selection.location, 0), ns.length))))
        let picked = ns.substring(with: r)
        let insert: String
        let cursor: Int
        if picked.isEmpty {
            insert = "_"
            cursor = r.location + 1
        } else {
            // 一個英數字不用大括號（R_1）；其他的包起來，整段都是下標
            let single = picked.count == 1 && picked.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
            insert = single ? "_" + picked : "_{" + picked + "}"
            cursor = r.location + (insert as NSString).length
        }
        return (ns.replacingCharacters(in: r, with: insert), NSRange(location: cursor, length: 0))
    }

    /// 在這個輸入框的鍵盤上方加上下標鍵
    static func install(on field: UITextField) {
        let bar = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.backgroundColor = .secondarySystemBackground
        var c = UIButton.Configuration.gray()
        c.title = L("下標")
        c.image = UIImage(systemName: "textformat.subscript")
        c.imagePadding = 6
        c.cornerStyle = .medium
        let b = UIButton(configuration: c)
        b.accessibilityIdentifier = accessibilityID
        b.accessibilityLabel = L("下標")
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addAction(UIAction { [weak field] _ in
            guard let field else { return }
            press(on: field)
        }, for: .touchUpInside)
        bar.addSubview(b)
        NSLayoutConstraint.activate([
            b.leadingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            b.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            b.heightAnchor.constraint(equalToConstant: 34),
        ])
        field.inputAccessoryView = bar
    }

    /// 按下標鍵：改輸入框的字，游標放在下標後面
    static func press(on field: UITextField) {
        let text = field.text ?? ""
        var sel = NSRange(location: (text as NSString).length, length: 0)
        if let r = field.selectedTextRange {
            let start = field.offset(from: field.beginningOfDocument, to: r.start)
            sel = NSRange(location: start, length: field.offset(from: r.start, to: r.end))
        }
        let out = apply(to: text, selection: sel)
        field.text = out.text
        if let p = field.position(from: field.beginningOfDocument, offset: out.selection.location) {
            field.selectedTextRange = field.textRange(from: p, to: p)
        }
        field.sendActions(for: .editingChanged)
    }
}
