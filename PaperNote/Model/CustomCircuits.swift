import Foundation

/// 使用者存起來的電路（例如畫好的 OTA）：元件庫「自訂電路圖」裡的一格，中心在原點
struct CustomCircuit: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var data: CircuitData
    /// 放在元件庫的哪個分類（CircuitLibraryView.sections 的 key）；nil＝自訂電路圖那一區
    var section: String? = nil

    /// 自己畫的元件（不是存起來的一段電路）
    var symbol: CircuitSymbol? {
        guard data.wires.isEmpty, data.components.count == 1, data.components[0].part == .customSymbol else { return nil }
        return data.components[0].symbol
    }

    static func symbolData(_ symbol: CircuitSymbol) -> CircuitData {
        var c = CircuitComponent(part: .customSymbol, position: .zero)
        c.symbol = symbol
        var d = CircuitData()
        d.components = [c]
        return d
    }
}

/// 使用者自己加的元件分類（key 是 "user." 開頭，和內建分類的 key 分開）
struct CustomCircuitCategory: Codable, Equatable {
    var key: String
    var name: String
}

extension Notification.Name {
    static let customCircuitsChanged = Notification.Name("customCircuitsChanged")
}

/// 自訂電路存在這台裝置（和常用筆刷一樣）
final class CustomCircuitStore {
    static let shared = CustomCircuitStore()
    private let key = "customCircuits"
    private let categoriesKey = "customCircuitCategories"
    private(set) var circuits: [CustomCircuit] = []
    /// 自己加的分類（排在內建分類後面）
    private(set) var categories: [CustomCircuitCategory] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([CustomCircuit].self, from: data) {
            circuits = saved
        }
        if let data = UserDefaults.standard.data(forKey: categoriesKey),
           let saved = try? JSONDecoder().decode([CustomCircuitCategory].self, from: data) {
            categories = saved
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(circuits) {
            UserDefaults.standard.set(data, forKey: key)
        }
        if let data = try? JSONEncoder().encode(categories) {
            UserDefaults.standard.set(data, forKey: categoriesKey)
        }
        NotificationCenter.default.post(name: .customCircuitsChanged, object: nil)
    }

    func circuit(_ id: UUID) -> CustomCircuit? { circuits.first { $0.id == id } }

    @discardableResult
    func add(name: String, data: CircuitData) -> CustomCircuit {
        let c = CustomCircuit(name: name, data: data)
        circuits.append(c)
        persist()
        return c
    }

    func update(_ id: UUID, name: String, data: CircuitData) {
        guard let i = circuits.firstIndex(where: { $0.id == id }) else { return }
        circuits[i].name = name
        circuits[i].data = data
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = circuits.firstIndex(where: { $0.id == id }) else { return }
        circuits[i].name = name
        persist()
    }

    /// 移到元件庫的另一個分類（nil＝自訂電路圖那一區）
    func move(_ id: UUID, toSection key: String?) {
        guard let i = circuits.firstIndex(where: { $0.id == id }) else { return }
        circuits[i].section = key
        persist()
    }

    func remove(_ id: UUID) {
        circuits.removeAll { $0.id == id }
        persist()
    }

    /// 新增分類，回傳它的 key
    @discardableResult
    func addCategory(_ name: String) -> String {
        let c = CustomCircuitCategory(key: "user." + UUID().uuidString, name: name)
        categories.append(c)
        persist()
        return c.key
    }

    /// 刪掉自己加的分類：裡面的自訂元件回到自訂電路圖那一區
    func removeCategory(_ key: String) {
        categories.removeAll { $0.key == key }
        for i in circuits.indices where circuits[i].section == key { circuits[i].section = nil }
        persist()
    }
}
