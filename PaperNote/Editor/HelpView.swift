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
        Item(symbol: "pencil.tip", title: "筆",
             detail: "第二列左邊是常用筆刷，點一下切換、再點一下調整，長按可移動或刪除；右邊可以把目前這支筆改成細、中、粗或虛線：再點一下已選的粗細可以自訂 pt，長按虛線按鈕可以調線長與間距；虛線在筆離開螢幕後成形。畫線時筆尖停住約 0.5 秒會出現直線（藍色外框），繼續移動可以調整終點，放開後換成直線；畫圓、三角形、四邊形停住會自動修正，筆不放開繼續拖曳可以調整長寬。需要直線可以打開工具列的尺規。"),
        Item(symbol: "highlighter", title: "螢光筆",
             detail: "獨立的螢光筆工具與常用色；畫在 PDF 文字上會自動對齊、放在文字底下。"),
        Item(symbol: "paintpalette", title: "調色盤",
             detail: "Apple Pencil 筆身點兩下會切換橡皮擦，同時在筆尖旁出現調色盤小圖示，點它就打開（Pencil Pro 也可以擠壓直接打開）。筆和螢光筆在左側。按住「筆」或「螢光筆」會往左展開常用顏色，滑到顏色後筆尖離開螢幕就選好；也可以選文字選取。「⋯ → 管理常用筆刷」可以調整顏色數量與順序。"),
        Item(symbol: "eraser", title: "橡皮擦",
             detail: "整筆擦除／局部擦除；也能擦掉 PDF 上的螢光標示。表格、圖片、文字框不會被擦掉。Apple Pencil 筆身點兩下可以切換橡皮擦。"),
        Item(symbol: "lasso", title: "套索",
             detail: "用 Pencil 圈選筆跡、表格、圖片、文字框、螢光標示，拖曳可以一起移動；選單有拷貝、剪下、複製一份、刪除。圈到一部分就會選到。表格（右上角）與圖片（左上角）的鎖頭可以鎖定位置，鎖定後不會被圈到。"),
        Item(symbol: "camera.viewfinder", title: "截圖",
             detail: "用 Pencil 框選範圍（開啟「用手指書寫」時手指也可以），可以釘選在畫面上、拷貝、翻譯圖中文字、存到照片。釘選的圖片換頁、換筆記本都會留著，拖右下角可以調整大小。"),
        Item(symbol: "hand.point.up.left", title: "選取",
             detail: "點一下選取表格、圖片、文字框，再拖曳移動、拉右下角縮放；長按開啟選單，可以固定位置。在筆模式下用手指點物件也會直接選取。"),
        Item(symbol: "character.cursor.ibeam", title: "PDF 文字",
             detail: "在 PDF 上拖曳選取文字、點一下選取單字，可以翻譯、拷貝、查詢、螢光標示。掃描檔會自動用文字辨識。筆模式下用手指長按 PDF 文字也可以。"),
        Item(symbol: "arrow.up.left.and.arrow.down.right", title: "擴展頁面",
             detail: "拖曳頁面四周 8 個控制點，加寬或加高空白畫布，原本內容不動。點其他頁可以切換要擴展的頁面。"),
        Item(symbol: "rectangle.stack", title: "分頁與群組",
             detail: "打開的筆記本會排在最上方。長按分頁或群組會出現選單；長按後把分頁拖到另一個分頁上放開會組成群組，拖到群組上放開會加入群組。點群組可以展開／收合。"),
        Item(symbol: "bolt", title: "電路圖",
             detail: "左邊的元件庫（電阻、電容、電感、電源、接地、NMOS／PMOS、各種邏輯閘）點一下元件就能連續點著放（沿用上次的方向與翻轉），也可以直接拖到頁面上；按「選取」結束。選取的元件旁有旋轉、翻轉小圓鈕；「接線」模式下照著想要的路線畫，會依筆跡排成直角導線，頭尾自動吸附接腳。選取模式下點導線會出現控制點：拖頭尾改接到別的地方、拖轉角或整段調整走線。選取元件可以旋轉、翻轉、刪除，邏輯閘可以調整輸入數量。元件一律對齊頁面格點。三條以上接在一起會畫圓點，只是交叉的線會畫跨線。點兩下電路圖可以回到編輯。"),
        Item(symbol: "plus.circle", title: "插入",
             detail: "表格、手繪新表格、文字框、照片、貼上剪貼簿。"),
    ]

    private let table: [Item] = [
        Item(symbol: "hand.tap", title: "選取儲存格", detail: "點一格選取；在表格裡拖曳可以選取多格。"),
        Item(symbol: "arrow.up.and.down.and.arrow.left.and.right", title: "移動、刪除表格", detail: "拖曳左上角的青綠色按鈕或表格外框移動；上方的紅色 ✕ 刪除整個表格（可以復原）。"),
        Item(symbol: "plus.circle", title: "＋ 插入列／欄", detail: "表格上緣與左緣的 ＋ 會在那個位置插入一欄或一列。"),
        Item(symbol: "circle.fill", title: "調整欄寬／列高", detail: "拖曳下緣、右緣的藍色小圓點，或直接拖格線。"),
        Item(symbol: "rectangle.compress.vertical", title: "合併／分割", detail: "選取多格後按合併；分割可以把一格切成左右或上下兩格。"),
        Item(symbol: "pencil.and.outline", title: "手繪格線", detail: "在表格上畫橫線、直線會切開儲存格，畫斜線會加上斜線。"),
        Item(symbol: "keyboard", title: "輸入文字", detail: "點兩下儲存格，或按鍵盤按鈕。"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("工具") {
                    ForEach(tools) { row($0) }
                }
                Section("表格（選取表格後第二列會出現表格工具）") {
                    ForEach(table) { row($0) }
                }
                Section("其他") {
                    row(Item(symbol: "star", title: "我的最愛", detail: "把目前這頁加入我的最愛並寫備註；資料庫的「我的最愛頁面」可以搜尋所有備註。"))
                    row(Item(symbol: "square.grid.2x2", title: "全部頁面", detail: "用縮圖看整本筆記（也可以點第二列右側的頁碼打開），點一下跳到那頁。長按拖曳可以調整頁面順序；按「選取」可以一次複製或刪除多頁；上方切到「我的最愛」只看收藏的頁面。"))
                    row(Item(symbol: "doc.on.doc", title: "頁面", detail: "跳頁、新增空白頁、刪除頁面；刪除的頁面 30 天內可以在「最近刪除的頁面」還原。"))
                    row(Item(symbol: "hand.raised", title: "手掌防誤觸", detail: "在「⋯」選擇右手或左手寫字。寫字時與剛寫完的一瞬間，手掌壓在筆尖附近（右手：右下方；左手：左下方）不會捲動、縮放或點到東西；放下筆後手指馬上就能正常操作。"))
                    row(Item(symbol: "ellipsis.circle", title: "設定", detail: "調色盤圖示、手掌防誤觸、筆刷列靠右、手指書寫、橡皮擦自動切回筆、停住變直線、螢光筆對齊文字、管理常用筆刷、匯出 PDF。"))
                }
                Section("關於我") {
                    Text("大學生，喜歡或是想支持我可以透過這個連結贊助窮苦大學生 :P")
                        .font(.subheadline)
                    Link(destination: AboutView.supportURL) {
                        Label("請我喝杯咖啡（Buy Me a Coffee）", systemImage: "cup.and.saucer.fill")
                    }
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
