import Foundation

/// 使用者存起來的電路（例如畫好的 OTA）：元件庫「自訂電路圖」裡的一格，中心在原點
struct CustomCircuit: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var data: CircuitData

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

extension Notification.Name {
    static let customCircuitsChanged = Notification.Name("customCircuitsChanged")
}

/// 自訂電路存在這台裝置（和常用筆刷一樣）
final class CustomCircuitStore {
    static let shared = CustomCircuitStore()
    private let key = "customCircuits"
    private(set) var circuits: [CustomCircuit] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([CustomCircuit].self, from: data) {
            circuits = saved
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(circuits) {
            UserDefaults.standard.set(data, forKey: key)
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

    func remove(_ id: UUID) {
        circuits.removeAll { $0.id == id }
        persist()
    }
}
