import Foundation

/// 每個工具怎麼處理觸控，全部定義在這裡。
///
/// | 工具 | 誰處理拖曳 | Pencil | 手指（沒開「用手指書寫」） |
/// |---|---|---|---|
/// | 筆、螢光筆、橡皮擦 | PencilKit | 書寫／擦除 | 捲動頁面 |
/// | 套索、截圖、PDF 文字、手繪表格、電路 | App 的 toolPan | 圈選／框選／畫線 | 捲動頁面 |
/// | 選取、擴展頁面 | App 的 toolPan | 拖曳物件／控制點 | 拖曳物件／控制點，空白處捲動 |
///
/// 手掌（面積很大，或寫字時壓在螢幕上的觸碰）一律不觸發任何手勢，見 `isPalmTouch`。
extension EditorTool {
    /// 拖曳由 App 自己的 toolPan 處理（筆、螢光筆、橡皮擦交給 PencilKit）
    var usesToolPan: Bool { !isDrawing }

    /// 拖曳是用來畫東西的：沒開「用手指書寫」時只接受 Pencil，手指只捲動頁面
    var drawsWithPan: Bool {
        switch self {
        case .capture, .textSelect, .tableDraw, .lasso, .circuit: return true
        default: return false
        }
    }

    /// 拖曳要先讓頁面捲動判斷，沒捲動才算工具的拖曳（拖到物件、控制點時才會由工具接手）
    var panYieldsToScroll: Bool {
        switch self {
        case .select, .image, .pageResize, .lasso, .circuit: return true
        default: return false
        }
    }
}
