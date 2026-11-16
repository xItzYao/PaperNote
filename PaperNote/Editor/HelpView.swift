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
        Item(symbol: "eraser", title: L("橡皮擦"), detail: L("Pencil 筆身點兩下切換橡皮擦。擦的時候碰到的筆跡馬上不見；碰到螢光筆畫出來的範圍就擦得掉，不用擦到正中間。表格、圖片不會被擦掉。")),
        Item(symbol: "lasso", title: L("套索"), detail: L("圈起來可以移動、改顏色、拷貝、刪除；只圈到筆跡時拉右下角可以等比例縮放。選取框照你圈的形狀。點一下物件或筆跡就能直接選起來，再點一下打開選單；表格點兩下打字。表格、圖片、電路圖圈到一部分就算，不想被圈到就點鎖頭鎖起來；只圈到一個物件時，選單的「編輯」可以編輯它。")),
        Item(symbol: "camera.viewfinder", title: L("截圖"), detail: L("框選範圍，可以分享、釘在畫面上、拷貝、翻譯、存到照片；拉範圍四周的錨點可以調整大小、拖曳框裡可以移動。")),
        Item(symbol: "seal", title: L("貼紙"), detail: L("工具列的「貼紙」：上面一排是分類，下面一排是這個分類的貼紙，點一下選起來，再用 Pencil 點頁面就貼在那裡（可以接著點、接著貼；手指照樣捲動、縮放頁面，開了「用手指書寫」手指才會貼上）。只圈到筆跡的貼紙會存成向量的筆跡，貼上的是真的筆跡。從相簿加入時可以選裁切範圍、要不要去背：藍色虛線裡的會留下來，用 Pencil 像套索一樣圈「保留」、塗「去掉」修改；用套索圈起來選「添加至貼紙」、或點頁面上的圖片選「變成貼紙」也可以，會跳出分類的大圖讓你選。選著的貼紙再點一下（或長按任何一張）可以刪除或設為分類封面，長按分類可以重新命名、刪除。所有筆記本共用。")),
        Item(symbol: "character.cursor.ibeam", title: L("PDF 文字"), detail: L("選取 PDF 的文字來翻譯、拷貝、查詢、螢光標示。")),
    ]

    private let table: [Item] = [
        Item(symbol: "hand.tap", title: L("儲存格"), detail: L("點一下選取、拖曳選多格；點兩下打字；再點一下打開拷貝、剪下、貼上。")),
        Item(symbol: "pencil.and.outline", title: L("手繪格線"), detail: L("選到表格時 Pencil 筆身點兩下進入：畫線切開格子、畫斜線；再點兩下切到擦線，擦掉格線就合併。")),
        Item(symbol: "rectangle.split.3x1", title: L("工具列"), detail: L("合併、分割、平均分配、鎖定、顏色、字級、線寬都在第二列。")),
        Item(symbol: "plus.circle", title: L("插入列／欄"), detail: L("點上方或左邊的標頭選整欄（列），按兩側的 ＋。拖格線或外面的藍點調整寬高。")),
    ]

    private let others: [Item] = [
        Item(symbol: "bolt", title: L("電路圖"), detail: L("從下面的元件庫點或拖元件（「⋯」可以改放左邊）；「接線」模式照路線畫就會排成直角導線；元件的接腳放在導線上就直接接上（共點）。手指負責捲動、縮放頁面，開了「用手指書寫」手指才能放、選元件。選取元件後旁邊有旋轉、翻轉、複製、刪除，再點一下元件可以命名、填數值（後面的選單選 p、n、µ、m、K、M、G 這些單位前綴）；命名時打 _（或按「下標」）就直接在右下的框裡打下標、打 ^ 是上標，空白回到一般的字；勾「純文字」可以改打 R_1、x^2。點一下導線選取，再點一下可以命名或刪除；名稱可以拖動、拉大。Pencil 從空白處圈起來可以選好幾個：順時針圈要整個圈到才選，逆時針圈碰到就選（線變綠色），再按「群組」；選好後按「自訂電路」存進元件庫，之後拉出來就是一個群組；長按自訂的元件選「移到分類」可以放進任何一個元件分類；「畫元件」可以用線條（兩端吸到格點）、筆刷（停住變直線或圖形）自己畫符號，再標出接腳；也可以按「JSON」→「拷貝給 AI 的說明」，連同手繪的照片給 AI，再把 AI 回覆的 JSON 貼上。「⋯」的「連續放置元件」關掉後，放好一個就回到選取。也可以用「橡皮擦」（Pencil 筆身點兩下切換）劃過去，筆尖離開後才刪；橡皮擦旁邊打開「擦完切回」，擦完一筆就回到原本的模式。工具列的「自動編號」打開後，放上去的元件自動取名 R1、R2…，每一頁各自從 1 開始；自己畫的元件可以在名稱旁邊設定用什麼開頭編號（空白是 U）。「匯出」可以存成 SVG，或匯出、拷貝網表（netlist：每個元件接到哪些節點），貼給 AI 最清楚。")),
        Item(symbol: "eye", title: L("預覽模式"), detail: L("「⋯」裡的「預覽模式」把工具列收起來，只能捲動、縮放；按右上角「結束預覽」回來。")),
        Item(symbol: "star", title: L("我的最愛"), detail: L("筆記本裡的星號收藏頁面；資料庫裡筆記本旁的星星加入「我的最愛文件」，按左上角的星星打開。")),
        Item(symbol: "number", title: L("跳到頁碼"), detail: L("點第二列右邊的頁碼，輸入頁數。")),
        Item(symbol: "list.bullet.indent", title: L("大綱"), detail: L("「全部頁面」上方切到「大綱」：列出自己加的大綱和 PDF 的大綱（書籤），點一下跳到那一頁。在「全部頁面」長按頁面（不拖曳）、或在頁碼的選單選「將該頁加入大綱」，取個名字就加進去；往左滑可以重新命名、刪除。縮圖右上角的星號可以寫備註、加入我的最愛。")),
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
