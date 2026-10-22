import UIKit
import PencilKit
import SwiftUI

enum InkStyle: String, Codable, CaseIterable, Identifiable {
    case pen, monoline, fountainPen, pencil, marker, crayon, watercolor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: return "鋼筆"
        case .monoline: return "原子筆"
        case .fountainPen: return "毛筆／沾水筆"
        case .pencil: return "鉛筆"
        case .marker: return "螢光筆"
        case .crayon: return "蠟筆"
        case .watercolor: return "水彩"
        }
    }

    var inkType: PKInk.InkType {
        switch self {
        case .pen: return .pen
        case .monoline: return .monoline
        case .fountainPen: return .fountainPen
        case .pencil: return .pencil
        case .marker: return .monoline   // 螢光筆：固定粗細、整條同一個顏色
        case .crayon: return .crayon
        case .watercolor: return .watercolor
        }
    }

    var widthRange: ClosedRange<CGFloat> {
        switch self {
        case .pen, .monoline: return 0.5...20
        case .fountainPen: return 1...26
        case .pencil: return 1...16
        case .marker: return 4...40
        case .crayon: return 4...40
        case .watercolor: return 6...60
        }
    }
}

struct BrushPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var style: InkStyle
    var colorHex: String
    var width: CGFloat
    /// 螢光筆的不透明度（nil 用預設 35%）
    var opacity: CGFloat? = nil

    static let defaultMarkerOpacity: CGFloat = 0.35

    var color: UIColor { UIColor(hex: colorHex) }
    var effectiveOpacity: CGFloat { style == .marker ? (opacity ?? Self.defaultMarkerOpacity) : 1 }
    var inkColor: UIColor { style == .marker ? color.withAlphaComponent(effectiveOpacity) : color }
    var tool: PKInkingTool { PKInkingTool(style.inkType, color: inkColor, width: width) }
}

enum BrushCategory: String {
    case pen, highlighter
}

extension BrushPreset {
    var category: BrushCategory { style == .marker ? .highlighter : .pen }
}

/// 常用筆刷（收藏），存在 UserDefaults。筆和螢光筆分開，各自記住目前選的那支。
final class BrushStore {
    static let shared = BrushStore()

    private(set) var allPresets: [BrushPreset]
    private var currentIDs: [BrushCategory: UUID] = [:]
    /// 目前工具是筆還是螢光筆（由編輯器設定）
    var activeCategory: BrushCategory = .pen
    private let key = "brushPresets.v1"

    var presets: [BrushPreset] { presets(activeCategory) }
    var currentID: UUID { current.id }
    var current: BrushPreset { current(activeCategory) }

    func presets(_ c: BrushCategory) -> [BrushPreset] { allPresets.filter { $0.category == c } }

    func current(_ c: BrushCategory) -> BrushPreset {
        let list = presets(c)
        return list.first { $0.id == currentIDs[c] } ?? list.first ?? Self.defaults(c)[0]
    }

    private static func defaults(_ c: BrushCategory) -> [BrushPreset] {
        switch c {
        case .pen:
            return [
                BrushPreset(style: .monoline, colorHex: "#1A1A1AFF", width: 2.5),
                BrushPreset(style: .monoline, colorHex: "#1E5BD8FF", width: 2.5),
                BrushPreset(style: .monoline, colorHex: "#D32F2FFF", width: 2.5),
                BrushPreset(style: .pencil, colorHex: "#555555FF", width: 3),
                BrushPreset(style: .fountainPen, colorHex: "#1A1A1AFF", width: 4),
            ]
        case .highlighter:
            return [
                BrushPreset(style: .marker, colorHex: "#FFE14DFF", width: 18),
                BrushPreset(style: .marker, colorHex: "#8BE38BFF", width: 18),
                BrushPreset(style: .marker, colorHex: "#FF9EC4FF", width: 18),
                BrushPreset(style: .marker, colorHex: "#8FD3FFFF", width: 18),
            ]
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([BrushPreset].self, from: data), !saved.isEmpty {
            allPresets = saved
        } else {
            allPresets = Self.defaults(.pen) + Self.defaults(.highlighter)
        }
        // 每一類至少要有一支
        for c in [BrushCategory.pen, .highlighter] where presets(c).isEmpty {
            allPresets.append(contentsOf: Self.defaults(c))
        }
        for c in [BrushCategory.pen, .highlighter] {
            if let s = UserDefaults.standard.string(forKey: "brushPresets.current.\(c.rawValue)"), let id = UUID(uuidString: s) {
                currentIDs[c] = id
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(allPresets) {
            UserDefaults.standard.set(data, forKey: key)
        }
        for (c, id) in currentIDs {
            UserDefaults.standard.set(id.uuidString, forKey: "brushPresets.current.\(c.rawValue)")
        }
    }

    func select(_ id: UUID) {
        guard let p = allPresets.first(where: { $0.id == id }) else { return }
        currentIDs[p.category] = id
        persist()
    }

    func update(_ preset: BrushPreset) {
        guard let i = allPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        allPresets[i] = preset
        persist()
    }

    @discardableResult
    func add(basedOn preset: BrushPreset) -> BrushPreset {
        var p = preset
        p.id = UUID()
        allPresets.append(p)
        currentIDs[p.category] = p.id
        persist()
        return p
    }

    func remove(_ id: UUID) {
        guard let p = allPresets.first(where: { $0.id == id }), presets(p.category).count > 1 else { return }
        allPresets.removeAll { $0.id == id }
        if currentIDs[p.category] == id { currentIDs[p.category] = presets(p.category).first?.id }
        persist()
    }

    /// 重新排列某一類的順序（另一類維持原樣）
    func setOrder(_ c: BrushCategory, ids: [UUID]) {
        let others = allPresets.filter { $0.category != c }
        let mine = ids.compactMap { id in allPresets.first { $0.id == id } }
        let rest = allPresets.filter { $0.category == c && !ids.contains($0.id) }
        allPresets = (c == .pen ? mine + rest + others : others + mine + rest)
        persist()
    }

    /// 和同一類的前一支交換位置
    func moveLeft(_ id: UUID) {
        guard let i = allPresets.firstIndex(where: { $0.id == id }) else { return }
        let c = allPresets[i].category
        guard let j = allPresets[..<i].lastIndex(where: { $0.category == c }) else { return }
        allPresets.swapAt(i, j)
        persist()
    }
}

struct BrushSettingsView: View {
    @State var preset: BrushPreset
    let onChange: (BrushPreset) -> Void

    private let swatches = ["#1A1A1AFF", "#555555FF", "#1E5BD8FF", "#0F8A7EFF", "#2E7D32FF", "#D32F2FFF",
                            "#E65100FF", "#8E24AAFF", "#FFE14DFF", "#8BE38BFF", "#FF9EC4FF", "#8FD3FFFF"]

    var body: some View {
        Form {
            if preset.style != .marker {
                Section("筆型") {
                    Picker("筆型", selection: $preset.style) {
                        ForEach(InkStyle.allCases.filter { $0 != .marker }) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }
            Section("顏色") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 10), count: 6), spacing: 10) {
                    ForEach(swatches, id: \.self) { hex in
                        Circle()
                            .fill(Color(uiColor: UIColor(hex: hex)))
                            .frame(width: 30, height: 30)
                            .overlay(Circle().stroke(Color.primary.opacity(preset.colorHex == hex ? 0.9 : 0.15),
                                                     lineWidth: preset.colorHex == hex ? 3 : 1))
                            .onTapGesture { preset.colorHex = hex }
                    }
                }
                ColorPicker("自訂顏色", selection: Binding(
                    get: { Color(uiColor: preset.color) },
                    set: { preset.colorHex = UIColor($0).hexString }
                ))
            }
            if preset.style == .marker {
                Section("不透明度：\(Int((preset.opacity ?? BrushPreset.defaultMarkerOpacity) * 100))%") {
                    Slider(value: Binding(
                        get: { preset.opacity ?? BrushPreset.defaultMarkerOpacity },
                        set: { preset.opacity = $0 }
                    ), in: 0.1...0.9)
                }
            }
            Section("粗細：\(String(format: "%.1f", preset.width))") {
                Slider(value: $preset.width, in: preset.style.widthRange)
                StrokePreview(preset: preset)
                    .frame(height: 44)
            }
        }
        .onChange(of: preset) { _, newValue in
            var v = newValue
            let range = v.style.widthRange
            v.width = min(max(v.width, range.lowerBound), range.upperBound)
            if v != preset { preset = v }
            onChange(v)
        }
    }
}

private struct StrokePreview: View {
    let preset: BrushPreset
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            path.move(to: CGPoint(x: 12, y: size.height * 0.65))
            path.addCurve(to: CGPoint(x: size.width - 12, y: size.height * 0.35),
                          control1: CGPoint(x: size.width * 0.35, y: 0),
                          control2: CGPoint(x: size.width * 0.65, y: size.height))
            ctx.stroke(path, with: .color(Color(uiColor: preset.color).opacity(Double(preset.effectiveOpacity))),
                       style: StrokeStyle(lineWidth: preset.width, lineCap: .round))
        }
    }
}
