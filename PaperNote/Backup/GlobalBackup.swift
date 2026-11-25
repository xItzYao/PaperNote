import Foundation
import CryptoKit

/// 不屬於任何筆記本、存在這台 iPad 上的東西：貼紙、貼圖（釘在畫面上的截圖）、元件庫的自訂電路與分類、
/// 筆刷預設、喜歡的顏色、各筆型的粗細。備份成 PaperNoteBackup/global.zip。
/// 還原是合併：貼紙、貼圖、自訂電路照 ID 補上這台沒有的；筆刷、顏色、粗細只有這台沒設定過才用雲端的
struct GlobalBackup {
    static let fileName = "global.zip"
    private static let folders = ["Stickers", "Pins"]
    private static let defaultsFolder = "Defaults"
    private static let circuitsKey = "customCircuits"
    private static let circuitCategoriesKey = "customCircuitCategories"

    /// Application Support（裡面有 Stickers/、Pins/）
    let support: URL
    let defaults: UserDefaults
    /// 合併之後讓 App 裡的資料重新讀
    var afterMerge: (() -> Void)?

    static let device = GlobalBackup(
        support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        defaults: .standard,
        afterMerge: {
            StickerStore.shared.reload()
            PinStore.shared.reload()
            CustomCircuitStore.shared.reload()
            BrushStore.shared.reload()
        })

    /// 這台沒設定過才用雲端的
    private static func isPreference(_ key: String) -> Bool {
        key == "brushPresets.v1" || key == "favoriteColors" || key.hasPrefix("brushPresets.current.") || key.hasPrefix("styleWidths.")
    }

    private static func isBackedUp(_ key: String) -> Bool {
        key == circuitsKey || key == circuitCategoriesKey || isPreference(key)
    }

    // MARK: 備份

    /// 要打包的檔案（路徑排好）和指紋；什麼都沒有回傳 nil。偏好設定先寫成檔案放在 work
    func contents(work: URL) throws -> (files: [(url: URL, path: String)], fingerprint: String)? {
        let fm = FileManager.default
        var files: [(url: URL, path: String)] = []
        var lines: [String] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        for folder in Self.folders {
            let dir = support.appendingPathComponent(folder, isDirectory: true)
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in en {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == false,
                      let r = url.path.range(of: "/\(folder)/") else { continue }
                let path = folder + "/" + url.path[r.upperBound...]
                files.append((url, path))
                lines.append("\(path)\t\(values.fileSize ?? 0)\t\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
        }
        let prefs = work.appendingPathComponent(Self.defaultsFolder, isDirectory: true)
        try fm.createDirectory(at: prefs, withIntermediateDirectories: true)
        for key in defaults.dictionaryRepresentation().keys.filter(Self.isBackedUp).sorted() {
            guard let value = defaults.object(forKey: key) else { continue }
            let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            let url = prefs.appendingPathComponent(key + ".plist")
            try data.write(to: url)
            let path = Self.defaultsFolder + "/" + key + ".plist"
            files.append((url, path))
            lines.append("\(path)\t" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        guard !files.isEmpty else { return nil }
        files.sort { $0.path < $1.path }
        let fingerprint = SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        return (files, fingerprint)
    }

    // MARK: 還原

    /// dir：解開的 global.zip
    func merge(from dir: URL) throws {
        try mergeStickers(from: dir.appendingPathComponent("Stickers", isDirectory: true))
        try mergePins(from: dir.appendingPathComponent("Pins", isDirectory: true))
        mergeDefaults(from: dir.appendingPathComponent(Self.defaultsFolder, isDirectory: true))
        afterMerge?()
    }

    /// 檔案只在這台沒有時才搬過來
    private func copyIfMissing(_ name: String, from src: URL, to dst: URL) throws -> Bool {
        let fm = FileManager.default
        let from = src.appendingPathComponent(name), to = dst.appendingPathComponent(name)
        if fm.fileExists(atPath: to.path) { return true }
        guard fm.fileExists(atPath: from.path) else { return false }
        try fm.copyItem(at: from, to: to)
        return true
    }

    private func mergeStickers(from src: URL) throws {
        guard let data = try? Data(contentsOf: src.appendingPathComponent("categories.json")),
              let cloud = try? JSONDecoder().decode(StickerIndex.self, from: data) else { return }
        let dst = support.appendingPathComponent("Stickers", isDirectory: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        let indexURL = dst.appendingPathComponent("categories.json")
        var index = (try? JSONDecoder().decode(StickerIndex.self, from: Data(contentsOf: indexURL))) ?? StickerIndex(categories: [], selected: nil)
        var have = Set(index.categories.flatMap { $0.stickers.map(\.id) })
        for category in cloud.categories {
            var added: [StickerRecord] = []
            for s in category.stickers where !have.contains(s.id) {
                guard try copyIfMissing(s.file, from: src, to: dst) else { continue }
                if let v = s.vector { _ = try copyIfMissing(v, from: src, to: dst) }
                added.append(s)
                have.insert(s.id)
            }
            if let i = index.categories.firstIndex(where: { $0.id == category.id }) {
                index.categories[i].stickers += added
            } else {
                var c = category
                c.stickers = added
                index.categories.append(c)
            }
        }
        if index.selected == nil { index.selected = cloud.selected }
        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
    }

    private func mergePins(from src: URL) throws {
        guard let data = try? Data(contentsOf: src.appendingPathComponent("pins.json")),
              let cloud = try? JSONDecoder().decode([PinRecord].self, from: data) else { return }
        let dst = support.appendingPathComponent("Pins", isDirectory: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        let indexURL = dst.appendingPathComponent("pins.json")
        var pins = (try? JSONDecoder().decode([PinRecord].self, from: Data(contentsOf: indexURL))) ?? []
        for pin in cloud where !pins.contains(where: { $0.id == pin.id }) {
            if try copyIfMissing(pin.file, from: src, to: dst) { pins.append(pin) }
        }
        try JSONEncoder().encode(pins).write(to: indexURL, options: .atomic)
    }

    private func mergeDefaults(from src: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: src.path) else { return }
        for name in names where name.hasSuffix(".plist") {
            let key = String(name.dropLast(".plist".count))
            guard Self.isBackedUp(key), let data = try? Data(contentsOf: src.appendingPathComponent(name)),
                  let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { continue }
            switch key {
            case Self.circuitsKey:
                merge([CustomCircuit].self, value, key: key, id: \.id)
            case Self.circuitCategoriesKey:
                merge([CustomCircuitCategory].self, value, key: key, id: \.key)
            default:
                if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
            }
        }
    }

    /// 存成 JSON 的清單：照 ID 補上這台沒有的，順序是這台的在前
    private func merge<T: Codable, ID: Hashable>(_ type: [T].Type, _ value: Any, key: String, id: KeyPath<T, ID>) {
        guard let data = value as? Data, let cloud = try? JSONDecoder().decode(type, from: data) else { return }
        var local = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) } ?? []
        let have = Set(local.map { $0[keyPath: id] })
        local += cloud.filter { !have.contains($0[keyPath: id]) }
        if let encoded = try? JSONEncoder().encode(local) { defaults.set(encoded, forKey: key) }
    }
}
