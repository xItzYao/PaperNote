import Foundation

/// 介面語言。在資料庫右上角「…」選單切換，重新開啟 App 後生效。
enum AppLanguage: String, CaseIterable {
    case system
    case chinese = "zh-Hant"
    case english = "en"

    static let defaultsKey = "appLanguage"

    static var current: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system }
        set {
            let d = UserDefaults.standard
            d.set(newValue.rawValue, forKey: defaultsKey)
            // 系統元件（照片挑選、分享、拷貝貼上選單）也跟著換語言
            if newValue == .system { d.removeObject(forKey: "AppleLanguages") } else { d.set([newValue.rawValue], forKey: "AppleLanguages") }
        }
    }

    /// 「跟隨系統」時，系統第一順位語言是中文就用中文，其他語言都用英文。
    func usesEnglish(preferredLanguages: [String] = Locale.preferredLanguages) -> Bool {
        switch self {
        case .chinese: return false
        case .english: return true
        case .system:
            guard let first = preferredLanguages.first else { return false }
            return !first.lowercased().hasPrefix("zh")
        }
    }

    var menuTitle: String {
        switch self {
        case .system: return L("跟隨系統")
        case .chinese: return "繁體中文"
        case .english: return "English"
        }
    }
}

enum Loc {
    /// 啟動時決定一次；切換語言要重開 App，畫面才不會一半中文一半英文。
    static var isEnglish = AppLanguage.current.usesEnglish()

    /// 中文原文 → 英文。插入的值在原文裡寫成 %@，譯文可以用 %1$@、%2$@ 調換順序。
    static let english: [String: String] = {
        guard let url = Bundle.main.url(forResource: "LocalizedEnglish", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return table
    }()

    static func template(for key: String, english: Bool) -> String {
        english ? (Self.english[key] ?? key) : key
    }

    /// 把 %@（依序）和 %n$@（指定第 n 個）換成插入的值，其他的 % 原樣保留。
    static func fill(_ template: String, _ args: [String]) -> String {
        var out = ""
        var next = 0
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            guard c == "%" else { out.append(c); i = template.index(after: i); continue }
            let after = template.index(after: i)
            if after < template.endIndex, template[after] == "@" {
                if next < args.count { out += args[next] }
                next += 1
                i = template.index(after: after)
                continue
            }
            var j = after
            while j < template.endIndex, template[j].isASCII, template[j].isNumber { j = template.index(after: j) }
            if j > after, j < template.endIndex, template[j] == "$",
               let at = template.index(j, offsetBy: 1, limitedBy: template.endIndex), at < template.endIndex, template[at] == "@",
               let n = Int(template[after..<j]), n >= 1 {
                if n <= args.count { out += args[n - 1] }
                i = template.index(after: at)
                continue
            }
            out.append(c)
            i = after
        }
        return out
    }
}

/// 字串常值寫成 L("中文 \(值)")：中文原文就是查表的 key，插入的值在 key 裡記成 %@。
struct LocalizedKey: ExpressibleByStringInterpolation {
    var key: String
    var args: [String] = []

    init(stringLiteral value: String) { key = value }

    init(stringInterpolation: Interpolation) {
        key = stringInterpolation.key
        args = stringInterpolation.args
    }

    struct Interpolation: StringInterpolationProtocol {
        var key = ""
        var args: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity + interpolationCount * 2) }
        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            args.append(String(describing: value))
        }
    }
}

func L(_ k: LocalizedKey) -> String {
    let t = Loc.template(for: k.key, english: Loc.isEnglish)
    return k.args.isEmpty ? t : Loc.fill(t, k.args)
}
