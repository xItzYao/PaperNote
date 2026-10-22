import SwiftUI
import UIKit

/// 管理常用筆刷：筆和螢光筆各自的顏色數量、順序
struct BrushManagerView: View {
    let onDone: () -> Void
    @State private var category: BrushCategory
    @State private var presets: [BrushPreset] = []
    @State private var editing: BrushPreset?
    @Environment(\.editMode) private var editMode

    init(category: BrushCategory, onDone: @escaping () -> Void) {
        self.onDone = onDone
        _category = State(initialValue: category)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("類別", selection: $category) {
                        Text("筆").tag(BrushCategory.pen)
                        Text("螢光筆").tag(BrushCategory.highlighter)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    ForEach(presets) { p in
                        Button { editing = p } label: { row(p) }
                            .buttonStyle(.plain)
                    }
                    .onMove { from, to in
                        presets.move(fromOffsets: from, toOffset: to)
                        BrushStore.shared.setOrder(category, ids: presets.map(\.id))
                    }
                    .onDelete { offsets in
                        for i in offsets where presets.count > 1 { BrushStore.shared.remove(presets[i].id) }
                        reload()
                    }
                    Button {
                        let base = BrushStore.shared.current(category)
                        let p = BrushStore.shared.add(basedOn: base)
                        reload()
                        editing = p
                    } label: {
                        Label("新增顏色", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("按右上角「編輯」可以拖曳排序、刪除；點一下可以改顏色、粗細")
                } footer: {
                    Text("順序會套用到工具列和調色盤。至少要保留一個。")
                }
            }
            .navigationTitle("管理常用筆刷")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { onDone() } }
            }
            .onAppear { reload() }
            .onChange(of: category) { _, _ in reload() }
            .sheet(item: $editing, onDismiss: reload) { p in
                NavigationStack {
                    BrushSettingsView(preset: p) { updated in BrushStore.shared.update(updated) }
                        .navigationTitle(category == .pen ? "筆" : "螢光筆")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("完成") { editing = nil } }
                        }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func reload() {
        presets = BrushStore.shared.presets(category)
    }

    private func row(_ p: BrushPreset) -> some View {
        HStack(spacing: 14) {
            Group {
                if p.style == .marker {
                    RoundedRectangle(cornerRadius: 4).fill(Color(uiColor: p.color).opacity(0.75))
                        .frame(width: 30, height: 16)
                } else {
                    Circle().fill(Color(uiColor: p.color)).frame(width: 26, height: 26)
                }
            }
            .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.style.title)
                Text("粗細 \(String(format: "%.1f", p.width))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if p.id == BrushStore.shared.current(category).id {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }
}
