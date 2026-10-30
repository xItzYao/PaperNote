import SwiftUI

/// 工具列「？」說明
struct HelpView: View {
    private struct Item: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String
    }

    private let tools: [Item] = [
        Item(symbol: "pencil.tip", title: "筆", detail: "第二列切換常用筆刷、粗細、虛線。筆尖停住約 0.5 秒會變直線或修正成圖形。"),
        Item(symbol: "highlighter", title: "螢光筆", detail: "畫在 PDF 文字上會自動對齊文字。"),
        Item(symbol: "eraser", title: "橡皮擦", detail: "Pencil 筆身點兩下切換橡皮擦。表格、圖片不會被擦掉。"),
        Item(symbol: "lasso", title: "套索", detail: "圈起來可以移動、改顏色、拷貝、刪除。表格、電路圖要整個圈到才會選到。"),
        Item(symbol: "camera.viewfinder", title: "截圖", detail: "框選範圍，可以釘在畫面上、拷貝、翻譯、存到照片。"),
        Item(symbol: "hand.point.up.left", title: "選取", detail: "點物件選取，拖曳移動、拉右下角縮放；左上角的鎖頭固定位置。"),
        Item(symbol: "character.cursor.ibeam", title: "PDF 文字", detail: "選取 PDF 的文字來翻譯、拷貝、查詢、螢光標示。"),
    ]

    private let table: [Item] = [
        Item(symbol: "hand.tap", title: "儲存格", detail: "點一下選取、拖曳選多格；點兩下打字；再點一下打開拷貝、剪下、貼上。"),
        Item(symbol: "pencil.and.outline", title: "手繪格線", detail: "選到表格時 Pencil 筆身點兩下進入：畫線切開格子、畫斜線；再點兩下切到擦線，擦掉格線就合併。"),
        Item(symbol: "rectangle.split.3x1", title: "工具列", detail: "合併、分割、平均分配、鎖定、顏色、字級、線寬都在第二列。"),
        Item(symbol: "plus.circle", title: "插入列／欄", detail: "點上方或左邊的標頭選整欄（列），按兩側的 ＋。拖格線或外面的藍點調整寬高。"),
    ]

    private let others: [Item] = [
        Item(symbol: "bolt", title: "電路圖", detail: "從左邊的元件庫點或拖元件；「接線」模式照路線畫就會排成直角導線。點兩下導線可以命名，可以匯出 SVG。"),
        Item(symbol: "star", title: "我的最愛", detail: "筆記本裡的星號收藏頁面；資料庫裡筆記本旁的星星加入「我的最愛文件」。"),
        Item(symbol: "number", title: "跳到頁碼", detail: "點第二列右邊的頁碼，輸入頁數。"),
        Item(symbol: "rectangle.stack", title: "分頁", detail: "打開的筆記本排在最上面；把分頁拖到另一個分頁上可以組成群組。"),
        Item(symbol: "ellipsis.circle", title: "設定", detail: "「⋯」裡有手掌防誤觸、筆刷列靠右、手指書寫等設定。"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("工具") { ForEach(tools) { row($0) } }
                Section("表格") { ForEach(table) { row($0) } }
                Section("其他") { ForEach(others) { row($0) } }
                Section("關於我") {
                    Text(AboutView.blurb).font(.subheadline)
                    Link(destination: AboutView.githubURL) {
                        Label("GitHub 原始碼", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            }
            .navigationTitle("使用說明")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ item: Item) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline)
                Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
