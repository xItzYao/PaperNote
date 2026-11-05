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
        Item(symbol: "pencil.tip", title: L("筆"), detail: L("第二列切換常用筆刷、粗細、虛線；原子筆用自製筆刷（照筆尖原始軌跡、不做圓滑），鋼筆、毛筆、鉛筆、蠟筆、水彩和 PencilKit 一樣。管理常用筆刷裡可以把喜歡的顏色加進色票。筆尖停住約 0.5 秒會變直線或修正成圖形。")),
        Item(symbol: "highlighter", title: L("螢光筆"), detail: L("畫在 PDF 文字上會自動對齊文字。")),
        Item(symbol: "eraser", title: L("橡皮擦"), detail: L("Pencil 筆身點兩下切換橡皮擦。表格、圖片不會被擦掉。")),
        Item(symbol: "lasso", title: L("套索"), detail: L("圈起來可以移動、改顏色、拷貝、刪除；只圈到筆跡時拉右下角可以等比例縮放。表格、圖片、電路圖圈到一部分就算，不想被圈到就點鎖頭鎖起來；只圈到一個物件時，選單的「編輯」會換到選取工具編輯它。")),
        Item(symbol: "camera.viewfinder", title: L("截圖"), detail: L("框選範圍，可以釘在畫面上、拷貝、翻譯、存到照片。")),
        Item(symbol: "hand.point.up.left", title: L("選取"), detail: L("點物件或筆跡選取，拖曳移動、拉右下角縮放（筆跡是等比例）；再點一下打開選單。左上角的鎖頭固定物件的位置。")),
        Item(symbol: "character.cursor.ibeam", title: L("PDF 文字"), detail: L("選取 PDF 的文字來翻譯、拷貝、查詢、螢光標示。")),
    ]

    private let table: [Item] = [
        Item(symbol: "hand.tap", title: L("儲存格"), detail: L("點一下選取、拖曳選多格；點兩下打字；再點一下打開拷貝、剪下、貼上。")),
        Item(symbol: "pencil.and.outline", title: L("手繪格線"), detail: L("選到表格時 Pencil 筆身點兩下進入：畫線切開格子、畫斜線；再點兩下切到擦線，擦掉格線就合併。")),
        Item(symbol: "rectangle.split.3x1", title: L("工具列"), detail: L("合併、分割、平均分配、鎖定、顏色、字級、線寬都在第二列。")),
        Item(symbol: "plus.circle", title: L("插入列／欄"), detail: L("點上方或左邊的標頭選整欄（列），按兩側的 ＋。拖格線或外面的藍點調整寬高。")),
    ]

    private let others: [Item] = [
        Item(symbol: "bolt", title: L("電路圖"), detail: L("從下面的元件庫點或拖元件（「⋯」可以改放左邊）；「接線」模式照路線畫就會排成直角導線。手指可以直接拖元件。選取元件後旁邊有旋轉、翻轉、複製、刪除，再點一下元件可以命名；名稱打 R_1、x^2 會變成上下標。點一下導線選取，再點一下可以命名或刪除；名稱可以拖動、拉大。Pencil 從空白處圈起來可以選好幾個，再按「群組」；選好後按「自訂電路」存進元件庫，之後拉出來就是一個群組；「畫元件」可以用線條（兩端吸到格點）、筆刷（停住變直線或圖形）自己畫符號，再標出接腳；也可以按「JSON」→「拷貝給 AI 的說明」，連同手繪的照片給 AI，再把 AI 回覆的 JSON 貼上。「⋯」的「連續放置元件」關掉後，放好一個就回到選取。也可以用「橡皮擦」（Pencil 筆身點兩下切換）劃過去，筆尖離開後才刪；可以匯出 SVG。")),
        Item(symbol: "eye", title: L("預覽模式"), detail: L("「⋯」裡的「預覽模式」把工具列收起來，只能捲動、縮放；按右上角「結束預覽」回來。")),
        Item(symbol: "star", title: L("我的最愛"), detail: L("筆記本裡的星號收藏頁面；資料庫裡筆記本旁的星星加入「我的最愛文件」，按左上角的星星打開。")),
        Item(symbol: "number", title: L("跳到頁碼"), detail: L("點第二列右邊的頁碼，輸入頁數。")),
        Item(symbol: "rectangle.stack", title: L("分頁"), detail: L("打開的筆記本排在最上面；把分頁拖到另一個分頁上可以組成群組。")),
        Item(symbol: "ellipsis.circle", title: L("設定"), detail: L("「⋯」裡有手掌防誤觸、手指書寫等設定。")),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section(L("工具")) { ForEach(tools) { row($0) } }
                Section(L("表格")) { ForEach(table) { row($0) } }
                Section(L("其他")) { ForEach(others) { row($0) } }
                Section(L("關於我")) {
                    Text(AboutView.blurb).font(.subheadline)
                }
            }
            .navigationTitle(L("使用說明"))
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
