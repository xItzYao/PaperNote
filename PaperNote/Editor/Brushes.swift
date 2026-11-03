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

    /// 筆工具列的「細、中、粗」（PencilKit 畫的筆不會比它畫得出來的最細值更細，見 pencilKitWidthRange）
    var styleWidths: [CGFloat] {
        switch self {
        case .monoline: return [0.8, 2, 4]
        case .pen: return [1, 2.5, 5]
        case .fountainPen: return [1.5, 4, 8]
        case .pencil: return [2.4, 4, 8]
        case .marker: return [10, 18, 30]
        case .crayon: return [6, 12, 24]
        case .watercolor: return [6, 16, 30]
        }
    }

    /// 自製筆刷只畫原子筆。其他筆要和 PencilKit 一模一樣（寫的時候、放開後都是），交給 PencilKit 畫
    var usesCustomInk: Bool { self == .monoline }

    /// 這種筆實際可以調的粗細（自製筆刷可以更細）
    var usableWidthRange: ClosedRange<CGFloat> {
        usesCustomInk && EditorSettings.shared.customInk ? widthRange : pencilKitWidthRange
    }

    /// 自製筆刷最細可以到多細
    static let finestWidth: CGFloat = 0.3

    /// 自製筆刷可以調的粗細（上限不照 PencilKit 宣稱的範圍：螢光筆 18pt 用的就是宣稱上限 4pt 的墨水，照樣畫得出來）
    var widthRange: ClosedRange<CGFloat> {
        switch self {
        case .pen, .monoline: return Self.finestWidth...20
        case .fountainPen: return Self.finestWidth...26
        case .pencil: return Self.finestWidth...16
        case .marker: return 4...40
        case .crayon: return Self.finestWidth...40
        case .watercolor: return Self.finestWidth...60
        }
    }

    /// PencilKit 的筆可以調的粗細：下限是這種筆真正畫得出來的最細值（再細會完全畫不出來）
    var pencilKitWidthRange: ClosedRange<CGFloat> {
        let lower = max(0.1, (inkType.validWidthRange.lowerBound * 10 - 0.01).rounded(.up) / 10)
        return max(lower, widthRange.lowerBound)...widthRange.upperBound
    }

    /// 之前自製筆刷畫的鉛筆、蠟筆、水彩的質感。現在這些筆交給 PencilKit 畫，已經存下來的筆跡照這個畫
    var look: InkLook? {
        switch self {
        case .pencil: return InkLook(alpha: 0.55, grain: 0.55, gapRatio: 0.7)
        case .crayon: return InkLook(alpha: 0.7, grain: 0.4, gapRatio: 1.4)
        case .watercolor: return InkLook(alpha: 0.32, halo: 0.16)
        default: return nil
        }
    }

    /// 預覽用的一筆的形狀
    static func samplePath(in size: CGSize) -> [CGPoint] {
        (0...60).map { i in
            let t = CGFloat(i) / 60
            return CGPoint(x: 12 + (size.width - 24) * t, y: size.height / 2 - sin(t * .pi * 2) * size.height * 0.28)
        }
    }
}

/// 自製筆刷的質感：底色的透明度＋顆粒（一樣的顏色，斷斷續續疊上去）＋水彩的外暈
struct InkLook: Equatable {
    var alpha: CGFloat
    /// 顆粒的透明度；0＝沒有顆粒
    var grain: CGFloat = 0
    /// 顆粒的間隔（線寬的幾倍）
    var gapRatio: CGFloat = 1
    /// 外暈的透明度；0＝沒有
    var halo: CGFloat = 0

    /// 外暈比線寬寬多少
    static let haloSpread: CGFloat = 1.35
    var spread: CGFloat { halo > 0 ? Self.haloSpread : 1 }
    /// 放大很多時改用向量，只有一個透明度
    var flatOpacity: CGFloat { min(1, alpha + grain * 0.4 + halo * 0.5) }
}

/// 可以加進調色盤的喜歡的顏色（接在固定的 12 色後面），存在這台裝置
enum FavoriteColors {
    private static let key = "favoriteColors"
    static let limit = 36

    static var all: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    /// 已經有了（或滿了）回傳 false
    @discardableResult
    static func add(_ hex: String, besides fixed: [String] = BrushSettingsView.swatches) -> Bool {
        var list = all
        guard !list.contains(hex), !fixed.contains(hex), list.count < limit else { return false }
        list.append(hex)
        UserDefaults.standard.set(list, forKey: key)
        return true
    }

    static func remove(_ hex: String) {
        UserDefaults.standard.set(all.filter { $0 != hex }, forKey: key)
    }
}

struct BrushPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var style: InkStyle
    var colorHex: String
    var width: CGFloat
    /// 螢光筆的不透明度（nil 用預設 35%）
    var opacity: CGFloat? = nil
    /// 虛線（螢光筆不支援；舊存檔沒有這個欄位＝實線）
    var dashed: Bool? = nil
    /// 虛線每段長度、間距（pt；nil 依粗細自動決定）
    var dashLength: CGFloat? = nil
    var gapLength: CGFloat? = nil

    static let defaultMarkerOpacity: CGFloat = 0.35

    var color: UIColor { UIColor(hex: colorHex) }
    var effectiveOpacity: CGFloat { style == .marker ? (opacity ?? Self.defaultMarkerOpacity) : 1 }
    var inkColor: UIColor { style == .marker ? color.withAlphaComponent(effectiveOpacity) : color }
    /// 交給 PencilKit 的筆。粗細不低於這種筆畫得出來的最細值（舊設定可能更細）；上限不限制
    var tool: PKInkingTool { PKInkingTool(style.inkType, color: inkColor, width: max(width, style.pencilKitWidthRange.lowerBound)) }
    var isDashed: Bool { dashed == true && style != .marker }

    /// 預設的虛線每一段長度與間隔，依粗細決定
    static func defaultDashPattern(lineWidth w: CGFloat) -> (dash: CGFloat, gap: CGFloat) {
        (max(1, w * 3.5), max(1, w * 2.5))
    }

    /// 這支筆的虛線長度與間隔（有自訂就用自訂的 pt）
    func dashPattern(lineWidth w: CGFloat) -> (dash: CGFloat, gap: CGFloat) {
        let d = Self.defaultDashPattern(lineWidth: w)
        return (max(0.1, dashLength ?? d.dash), max(0.1, gapLength ?? d.gap))
    }
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

    // MARK: 細、中、粗（每種筆型各自記住，可以自訂 pt）

    func styleWidths(_ style: InkStyle) -> [CGFloat] {
        let saved = (UserDefaults.standard.array(forKey: "styleWidths.\(style.rawValue)") as? [Double])?.map { CGFloat($0) }
        guard let saved, saved.count == 3 else { return style.styleWidths }
        return saved
    }

    func setStyleWidth(_ width: CGFloat, slot: Int, style: InkStyle) {
        var widths = styleWidths(style)
        guard widths.indices.contains(slot) else { return }
        widths[slot] = min(max(width, style.widthRange.lowerBound), style.widthRange.upperBound)
        UserDefaults.standard.set(widths.map { Double($0) }, forKey: "styleWidths.\(style.rawValue)")
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

    static let swatches = ["#1A1A1AFF", "#555555FF", "#1E5BD8FF", "#0F8A7EFF", "#2E7D32FF", "#D32F2FFF",
                           "#E65100FF", "#8E24AAFF", "#FFE14DFF", "#8BE38BFF", "#FF9EC4FF", "#8FD3FFFF"]
    @State private var favorites = FavoriteColors.all

    private func swatch(_ hex: String) -> some View {
        Circle()
            .fill(Color(uiColor: UIColor(hex: hex)))
            .frame(width: 30, height: 30)
            .overlay(Circle().stroke(Color.primary.opacity(preset.colorHex == hex ? 0.9 : 0.15),
                                     lineWidth: preset.colorHex == hex ? 3 : 1))
            .onTapGesture { preset.colorHex = hex }
    }

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
                    ForEach(Self.swatches, id: \.self) { swatch($0) }
                    // 喜歡的顏色：長按可以拿掉
                    ForEach(favorites, id: \.self) { hex in
                        swatch(hex).contextMenu {
                            Button("從色票移除", systemImage: "trash", role: .destructive) {
                                FavoriteColors.remove(hex)
                                favorites = FavoriteColors.all
                            }
                        }
                    }
                }
                ColorPicker("自訂顏色", selection: Binding(
                    get: { Color(uiColor: preset.color) },
                    set: { preset.colorHex = UIColor($0).hexString }
                ))
                Button("把這個顏色加進色票", systemImage: "plus.circle") {
                    FavoriteColors.add(preset.colorHex)
                    favorites = FavoriteColors.all
                }
                .disabled(favorites.contains(preset.colorHex) || Self.swatches.contains(preset.colorHex) || favorites.count >= FavoriteColors.limit)
            }
            if preset.style == .marker {
                Section("不透明度：\(Int((preset.opacity ?? BrushPreset.defaultMarkerOpacity) * 100))%") {
                    Slider(value: Binding(
                        get: { preset.opacity ?? BrushPreset.defaultMarkerOpacity },
                        set: { preset.opacity = $0 }
                    ), in: 0.1...0.9)
                }
            }
            if preset.style == .marker {
                Section("粗細：\(String(format: "%.1f", preset.width))") {
                    Slider(value: $preset.width, in: preset.style.widthRange)
                    StrokePreview(preset: preset)
                        .frame(height: 44)
                }
            } else {
                // 筆的粗細在工具列的細、中、粗調整，這裡只留預覽
                Section("預覽") {
                    StrokePreview(preset: preset)
                        .frame(height: 44)
                }
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
            // 筆：和真正寫出來的一樣（原子筆用自製筆刷畫，其他筆是 PencilKit 畫）
            if preset.style != .marker {
                let path = InkStyle.samplePath(in: size)
                if preset.style.usesCustomInk && EditorSettings.shared.customInk {
                    let stroke = InkStroke(colorHex: preset.colorHex, points: path.map { InkPoint($0, width: preset.width) })
                    ctx.withCGContext { InkRenderer.draw([stroke], in: $0) }
                } else {
                    let tool = preset.tool
                    let stroke = ShapeRecognizer.makeStroke(points: path, ink: tool.ink, width: tool.width, sample: nil)
                    let rect = CGRect(origin: .zero, size: size)
                    ctx.draw(Image(uiImage: PKDrawing(strokes: [stroke]).image(from: rect, scale: ctx.environment.displayScale)), in: rect)
                }
                return
            }
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
