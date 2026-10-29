import UIKit
import PencilKit

/// 上一步／下一步：編輯器自己管理的堆疊，最多 40 步。
/// 每一步記的是「回到哪裡」：整張畫布的筆跡（有動到才記）和動到的頁面內容；
/// 下一步要用的狀態在按上一步的那一刻才記下來。
/// 同一個事件（同一輪 run loop）裡記的併成一步，和系統的 UndoManager 一樣。
/// PencilKit 自己登記的上一步不用：畫完的筆跡常被換掉（拉直、遮掉頁面外），那些紀錄會失效
final class EditHistory {
    struct State {
        /// 整張畫布的筆跡；nil＝這一步沒動到筆跡
        var drawing: PKDrawing?
        /// 頁面 id → 那一頁的物件、螢光標示、自製筆刷筆跡
        var pages: [UUID: NotebookViewController.PageContentSnapshot]

        /// 併進同一步：保留最早記下的
        mutating func merge(_ other: State) {
            if drawing == nil { drawing = other.drawing }
            for (id, s) in other.pages where pages[id] == nil { pages[id] = s }
        }
    }

    private struct Step {
        var id: Int
        var restore: State
    }

    static let limit = 40

    private var undoSteps: [Step] = []
    private var redoSteps: [Step] = []
    private var nextID = 0
    /// 這一輪 run loop 已經有一步：接著記的併進去
    private var groupOpen = false
    /// 不管是不是同一輪，都併進這一步（例：畫完一筆之後的整理、對齊 PDF 文字）
    private var mergeTarget: Int?

    /// 記過幾次（含併進前一步的）：用來看某個時間點之後有沒有別的動作
    private(set) var recordCount = 0

    var canUndo: Bool { !undoSteps.isEmpty }
    var canRedo: Bool { !redoSteps.isEmpty }
    var undoCount: Int { undoSteps.count }

    /// 記下動作之前的狀態，回傳這一步的編號。newStep：不併進同一輪的前一步（之後可能要整步拿掉）
    @discardableResult
    func record(_ s: State, newStep: Bool = false) -> Int {
        recordCount += 1
        redoSteps.removeAll()
        if let top = undoSteps.last, top.id == mergeTarget || (groupOpen && !newStep) {
            undoSteps[undoSteps.count - 1].restore.merge(s)
            return top.id
        }
        nextID += 1
        undoSteps.append(Step(id: nextID, restore: s))
        if undoSteps.count > Self.limit { undoSteps.removeFirst(undoSteps.count - Self.limit) }
        groupOpen = true
        DispatchQueue.main.async { [weak self] in self?.endGroup() }
        return nextID
    }

    /// 這一輪結束：之後記的是新的一步
    func endGroup() { groupOpen = false }

    /// body 裡記的都併進 id 那一步（它還在最上面的話）
    func merging(into id: Int?, _ body: () -> Void) {
        let old = mergeTarget
        mergeTarget = id
        body()
        mergeTarget = old
    }

    /// 拿掉一步（那個動作後來被整個取消了）
    func remove(_ id: Int) {
        undoSteps.removeAll { $0.id == id }
    }

    func removeAll() {
        undoSteps.removeAll()
        redoSteps.removeAll()
        groupOpen = false
    }

    /// capture：同樣範圍的目前狀態（給反方向用）；apply：回到那個狀態
    func undo(capture: (State) -> State, apply: (State) -> Void) -> Bool {
        guard let s = undoSteps.popLast() else { return false }
        groupOpen = false
        let now = capture(s.restore)
        apply(s.restore)
        nextID += 1
        redoSteps.append(Step(id: nextID, restore: now))
        return true
    }

    func redo(capture: (State) -> State, apply: (State) -> Void) -> Bool {
        guard let s = redoSteps.popLast() else { return false }
        groupOpen = false
        let now = capture(s.restore)
        apply(s.restore)
        nextID += 1
        undoSteps.append(Step(id: nextID, restore: now))
        return true
    }
}

/// 一次用 PencilKit 下筆（從筆碰到畫布到下一次碰到）：第一次改到筆跡時登記一步，回到下筆之前
final class StrokeGesture {
    let before: PKDrawing
    /// 下筆時 history.recordCount：之後有別的動作，before 就過時了，不能再拿來登記
    let mark: Int
    var step: Int?

    init(before: PKDrawing, mark: Int) {
        self.before = before
        self.mark = mark
    }
}

/// 畫布和編輯畫面的 UndoManager：系統的上一步（三指滑動、鍵盤 ⌘Z）轉到編輯器自己的堆疊。
/// PencilKit 還是會往這裡登記它自己的上一步，但不會被執行
final class EditorUndoManager: UndoManager {
    weak var editor: NotebookViewController?

    override init() {
        super.init()
        // PencilKit 的紀錄留在這裡也不會用到，不用存很多
        levelsOfUndo = 1
    }

    override var canUndo: Bool { editor?.history.canUndo ?? false }
    override var canRedo: Bool { editor?.history.canRedo ?? false }
    override func undo() { editor?.undoTapped() }
    override func redo() { editor?.redoTapped() }
}

/// 畫布：上一步用編輯器的 EditorUndoManager
final class EditorCanvasView: PKCanvasView {
    weak var editorUndoManager: UndoManager?
    override var undoManager: UndoManager? { editorUndoManager ?? super.undoManager }
}

/// 文字框：打字的上一步留在文字框自己裡面，不和頁面的上一步混在一起
final class EditorTextView: UITextView {
    private let typingUndo = UndoManager()
    override var undoManager: UndoManager? { typingUndo }
}
