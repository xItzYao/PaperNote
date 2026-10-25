import SwiftUI

/// 「從 GoodNotes 搬家」說明：怎麼從 GoodNotes 匯出、怎麼匯入 PaperNote
struct GoodNotesMigrationView: View {
    /// 按「選擇檔案匯入」
    let onImport: () -> Void
    @Environment(\.dismiss) private var dismiss

    private struct Step: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String
    }

    private let steps: [Step] = [
        Step(symbol: "checkmark.circle", title: "在 GoodNotes 選取要搬的筆記本",
             detail: "可以一次選好幾本，或選整個資料夾。"),
        Step(symbol: "square.and.arrow.up", title: "分享／匯出，格式選「PDF」",
             detail: "不要選 GoodNotes 格式（.goodnotes），PaperNote 讀不了。一次匯出好幾本時如果變成一個 zip，PaperNote 也可以直接匯入。"),
        Step(symbol: "folder", title: "儲存到「檔案」",
             detail: "存在 iPad 或 iCloud 雲碟都可以。只有一本時，也可以在分享選單直接選 PaperNote 打開。"),
        Step(symbol: "plus", title: "回到 PaperNote 匯入",
             detail: "資料庫右上角「＋」→「匯入 PDF 或 zip」，選剛剛存的 PDF 或 zip（可以多選）。"),
        Step(symbol: "books.vertical", title: "完成",
             detail: "每個 PDF 會變成一本筆記本；zip 會放進一個新資料夾，裡面的資料夾照原樣建立。"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(i + 1)")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color.accentColor))
                            VStack(alignment: .leading, spacing: 4) {
                                Label(step.title, systemImage: step.symbol).font(.headline)
                                Text(step.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section("要注意") {
                    Label("GoodNotes 裡的筆跡會變成頁面的一部分：看得到、可以在上面繼續寫，但不能擦掉或移動原本的筆跡。",
                          systemImage: "info.circle")
                        .font(.subheadline)
                }
                Section {
                    Button {
                        onImport()
                    } label: {
                        Label("選擇檔案匯入", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("從 GoodNotes 搬家")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
            }
        }
    }
}
