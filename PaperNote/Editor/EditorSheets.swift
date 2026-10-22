import SwiftUI
import UIKit

// MARK: - 擴展頁面空白

struct ExpandPageView: View {
    @State var insets: PageInsets
    let baseSize: CGSize
    let pageNumber: Int
    let onApply: (PageInsets, Bool) -> Void
    let onCancel: () -> Void
    @State private var applyToAll = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    preview
                        .frame(height: 220)
                        .frame(maxWidth: .infinity)
                }
                Section {
                    edgeRow("上方", value: $insets.top, half: baseSize.height / 2)
                    edgeRow("下方", value: $insets.bottom, half: baseSize.height / 2)
                    edgeRow("左側", value: $insets.left, half: baseSize.width / 2)
                    edgeRow("右側", value: $insets.right, half: baseSize.width / 2)
                } header: {
                    Text("擴展空白畫布（單位：點）")
                } footer: {
                    Text("原本的頁面內容、筆跡與螢光標示都會留在原位，只是四周多出可以寫字的空白。")
                }
                Section {
                    Toggle("套用到所有頁面", isOn: $applyToAll)
                    Button("全部歸零", role: .destructive) { insets = PageInsets() }
                }
            }
            .navigationTitle("擴展第 \(pageNumber) 頁")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("套用") { onApply(insets, applyToAll) } }
            }
        }
    }

    private func edgeRow(_ title: String, value: Binding<CGFloat>, half: CGFloat) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 40, alignment: .leading)
            Text("\(Int(value.wrappedValue))")
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(.secondary)
            Stepper("", value: value, in: 0...4000, step: 50).labelsHidden()
            Spacer()
            Button("+半頁") { value.wrappedValue = min(4000, value.wrappedValue + half.rounded()) }
                .buttonStyle(.bordered)
            Button("+一頁") { value.wrappedValue = min(4000, value.wrappedValue + (half * 2).rounded()) }
                .buttonStyle(.bordered)
        }
    }

    private var preview: some View {
        GeometryReader { geo in
            let full = CGSize(width: baseSize.width + insets.left + insets.right,
                              height: baseSize.height + insets.top + insets.bottom)
            let s = min(geo.size.width / max(full.width, 1), geo.size.height / max(full.height, 1)) * 0.95
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: full.width * s, height: full.height * s)
                    .overlay(Rectangle().stroke(Color.blue.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                Rectangle()
                    .fill(Color.gray.opacity(0.25))
                    .overlay(Text("原頁面").font(.caption).foregroundStyle(.secondary))
                    .frame(width: baseSize.width * s, height: baseSize.height * s)
                    .offset(x: insets.left * s, y: insets.top * s)
            }
            .frame(width: full.width * s, height: full.height * s)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

// MARK: - 本筆記本的我的最愛

struct FavoritePageItem: Identifiable {
    let id: UUID
    let number: Int
    var note: String
    let thumbnail: UIImage?
}

struct NotebookFavoritesView: View {
    @State var items: [FavoritePageItem]
    let onSelect: (UUID) -> Void
    let onEditNote: (UUID, String) -> Void
    let onRemove: (UUID) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView("還沒有我的最愛頁面", systemImage: "star",
                                           description: Text("按上方的星號，就能把目前這頁加入我的最愛並寫備註。"))
                } else {
                    List {
                        ForEach($items) { $item in
                            HStack(alignment: .top, spacing: 12) {
                                Button { onSelect(item.id) } label: {
                                    thumb(item.thumbnail)
                                }
                                .buttonStyle(.plain)
                                VStack(alignment: .leading, spacing: 6) {
                                    Button { onSelect(item.id) } label: {
                                        Text("第 \(item.number) 頁").font(.headline)
                                    }
                                    .buttonStyle(.plain)
                                    TextField("寫備註…", text: $item.note, axis: .vertical)
                                        .font(.subheadline)
                                        .lineLimit(1...4)
                                        .onSubmit { onEditNote(item.id, item.note) }
                                        .onChange(of: item.note) { _, v in onEditNote(item.id, v) }
                                }
                            }
                            .padding(.vertical, 4)
                            .swipeActions {
                                Button("移除", role: .destructive) {
                                    onRemove(item.id)
                                    items.removeAll { $0.id == item.id }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("我的最愛頁面")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func thumb(_ img: UIImage?) -> some View {
        Group {
            if let img {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .frame(width: 72, height: 96)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
    }
}
