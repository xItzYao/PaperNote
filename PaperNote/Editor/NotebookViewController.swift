import UIKit
import PencilKit
import PDFKit
import SwiftUI

enum EditorTool: Equatable {
    case pen, highlighter, eraser, lasso, capture, select, image, sticker, textSelect, pageResize, tableDraw, circuit

    /// 筆或螢光筆
    var isInking: Bool { self == .pen || self == .highlighter }
    /// 由 PencilKit 處理的工具（套索是自己寫的，才能圈到表格與螢光標示）
    var isDrawing: Bool { isInking || self == .eraser }
}

struct PageResizeDrag {
    var handle: Int          // 0 左上、1 上、2 右上、3 右、4 右下、5 下、6 左下、7 左
    var start: CGPoint
    var original: PageInsets
    var preview: PageInsets
}

/// 手繪表格：外框＋分隔線（文件座標）
struct TableDraft {
    var pageIndex: Int
    var rect: CGRect
    var xs: [CGFloat] = []
    var ys: [CGFloat] = []
}

struct ElementRef: Hashable {
    var pageID: UUID
    var elementID: UUID
}

/// 選取框四邊中間的把手
enum BoxEdge: CaseIterable {
    case top, bottom, left, right
}

enum DragKind {
    case move, resize, colLine(Int), rowLine(Int), cells
    /// 文字框四邊中間的把手：只拉這一邊
    case edge(BoxEdge)
    /// 拖曳選取範圍右下角的填滿控制點：重複這一組
    case fill
    /// 拖曳表格上方的欄標頭／左邊的列標頭：選好幾欄（列），參數是一開始按的那一欄（列）
    case colHeaders(Int)
    case rowHeaders(Int)
}

struct DragState {
    var ref: ElementRef
    var kind: DragKind
    var start: CGPoint
    var original: PageElement
}

struct TextSelectionState {
    var pageIndex: Int
    var text: String
    var docRects: [CGRect]
    /// PDF 文字層的字元範圍（拖曳兩端的控制點調整範圍用）；文字辨識選到的沒有
    var charRange: NSRange? = nil
}

/// 拖曳文字選取的哪一端
enum TextHandle {
    case start, end
}

final class EditorSettings {
    static let shared = EditorSettings()
    private let d = UserDefaults.standard

    private func bool(_ key: String, _ def: Bool) -> Bool { d.object(forKey: key) as? Bool ?? def }

    var fingerDrawing: Bool {
        get { bool("fingerDrawing", false) }
        set { d.set(newValue, forKey: "fingerDrawing") }
    }
    var smartHighlight: Bool {
        get { bool("smartHighlight", true) }
        set { d.set(newValue, forKey: "smartHighlight") }
    }
    var pixelEraser: Bool {
        get { bool("pixelEraser", false) }
        set { d.set(newValue, forKey: "pixelEraser") }
    }
    /// 局部擦除的三個大小（舊版的大小取最接近的）
    static let eraserSizes: [CGFloat] = [16, 32, 60]
    var eraserWidth: CGFloat {
        get {
            let v = d.object(forKey: "eraserWidth") as? CGFloat ?? 16
            return Self.eraserSizes.min { abs($0 - v) < abs($1 - v) } ?? 16
        }
        set { d.set(newValue, forKey: "eraserWidth") }
    }
    /// 畫線停住變直線／圖形
    var shapeSnap: Bool {
        get { bool("shapeSnap", true) }
        set { d.set(newValue, forKey: "shapeSnap") }
    }
    var eraserAutoReturn: Bool {
        get { bool("eraserAutoReturn", false) }
        set { d.set(newValue, forKey: "eraserAutoReturn") }
    }
    /// Apple Pencil 筆身點兩下時，在筆尖旁顯示調色盤小圖示
    var paletteOnDoubleTap: Bool {
        get { bool("paletteOnDoubleTap", false) }
        set { d.set(newValue, forKey: "paletteOnDoubleTap") }
    }
    /// 手掌防誤觸："right"（右手寫字）、"left"（左手寫字）、"off"
    var palmRejection: String {
        get { d.string(forKey: "palmRejection") ?? "right" }
        set { d.set(newValue, forKey: "palmRejection") }
    }
    var captureFreeform: Bool {
        get { bool("captureFreeform", false) }
        set { d.set(newValue, forKey: "captureFreeform") }
    }
    /// 「筆」用自製筆刷（照原始取樣點畫，不圓滑；見 InkEngine.swift）。預設打開，可以在「⋯」改回 PencilKit
    /// Pencil Pro 按壓："palette"＝叫出調色盤；其他是工具列的工具（squeezeKey）
    var squeezeAction: String {
        get { d.string(forKey: "squeezeAction") ?? "palette" }
        set { d.set(newValue, forKey: "squeezeAction") }
    }
    static func squeezeKey(_ t: EditorTool) -> String { String(describing: t) }
    /// 畫元件的橡皮擦：只擦掉碰到的那一段（關掉＝整條擦掉）
    var symbolPartialErase: Bool {
        get { bool("symbolPartialErase", false) }
        set { d.set(newValue, forKey: "symbolPartialErase") }
    }
    var customInk: Bool {
        get { bool("customInk", true) }
        set { d.set(newValue, forKey: "customInk") }
    }
    /// 電路圖放完元件留在放置模式；關掉的話放好就回到選取
    var circuitContinuousPlace: Bool {
        get { bool("circuitContinuousPlace", true) }
        set { d.set(newValue, forKey: "circuitContinuousPlace") }
    }
    /// 電路圖用 Pencil 圈選的方式：default 順時針窗選、逆時針交集；reversed 反過來；window 只有窗選；crossing 只有交集
    var circuitLassoMode: String {
        get { d.string(forKey: "circuitLassoMode") ?? "default" }
        set { d.set(newValue, forKey: "circuitLassoMode") }
    }
    /// 電路元件自動編號（R1、R2…，每一頁各自從 1 開始）；預設關
    var circuitAutoNumber: Bool {
        get { bool("circuitAutoNumber", false) }
        set { d.set(newValue, forKey: "circuitAutoNumber") }
    }
    /// 電路圖的橡皮擦擦完一筆就切回原本的模式（選取、接線或放置元件）
    var circuitEraserAutoReturn: Bool {
        get { bool("circuitEraserAutoReturn", false) }
        set { d.set(newValue, forKey: "circuitEraserAutoReturn") }
    }
    /// 電路元件庫放左邊；預設放下面
    var circuitLibraryOnLeft: Bool {
        get { bool("circuitLibraryOnLeft", false) }
        set { d.set(newValue, forKey: "circuitLibraryOnLeft") }
    }
}

/// 筆記本編輯畫面。整本筆記本是一張長畫布（一個 PKCanvasView），頁面背景與物件放在筆跡底下。
final class NotebookViewController: UIViewController, PKCanvasViewDelegate {
    let session: NotebookSession
    let initialPageID: UUID?
    let onClose: () -> Void
    let settings = EditorSettings.shared

    let canvas = EditorCanvasView()
    /// 上一步／下一步（自己的堆疊，最多 40 步）
    let history = EditHistory()
    private(set) lazy var editorUndo: EditorUndoManager = {
        let u = EditorUndoManager()
        u.editor = self
        return u
    }()
    /// 系統的上一步手勢也走自己的堆疊
    override var undoManager: UndoManager? { editorUndo }
    /// 這一次用 PencilKit 下筆（寫字、擦除）
    var strokeGesture: StrokeGesture?
    let pagesContainer = UIView()
    /// 自製筆刷的筆跡：放在 PencilKit 筆跡（螢光筆）上面，螢光筆不會蓋住字。和 pagesContainer 一起縮放
    let inkContainer = UIView()
    let overlay = OverlayView()
    let pinOverlay = PinOverlayView()
    let topBar = UIView()
    let subBar = UIView()
    let subBarStack = UIStackView()
    let pageLabel = UILabel()
    /// 除錯紀錄：手指放開後的縮放（回彈）
    lazy var zoomTrace = ZoomTrace(editor: self)
    var zoomTraceAttached = false
    /// 點頁碼後出現的輸入框（輸入要跳到的頁碼）
    var pageJumpField: UITextField?
    var toolButtons: [EditorTool: UIButton] = [:]
    var presetButtons: [UUID: UIButton] = [:]
    weak var presetStrip: UIScrollView?
    /// 筆工具列的「細、中、粗」三個粗細按鈕與虛線開關
    var penWidthButtons: [UIButton] = []
    weak var penDashButton: UIButton?
    /// 工具列的小視窗開著時接下頁面上的觸碰
    let popoverShield = PopoverShieldView()
    var favoriteButton: UIButton!
    var settingsButton: UIButton!

    let pageGap: CGFloat = 28
    let docPadding: CGFloat = 28
    var pageFrames: [CGRect] = []
    var docSize: CGSize = .zero
    var pageViews: [UUID: PageContainerView] = [:]
    var fitZoom: CGFloat = 1
    var didInitialLayout = false
    var lastLayoutWidth: CGFloat = 0
    var isApplyingDrawing = false
    /// 畫布上次從各頁組起來、或拆回各頁時，每頁（畫布座標）的筆跡指紋。沒變的頁不重拆：
    /// 拆的時候座標要減回去，小數可能差一點點，存檔就會以為每一頁都改過
    var committedInk: [UUID: Data] = [:]
    var saveWorkItem: DispatchWorkItem?
    var keyboardInset: CGFloat = 0

    var tool: EditorTool = .pen
    /// 切到橡皮擦之前的工具（Pencil 點兩下、擦完自動切回時用）
    var toolBeforeEraser: EditorTool = .pen
    /// Pencil Pro 按壓切到某個工具之前的工具（再按一次切回來）
    var toolBeforeSqueeze: EditorTool = .pen
    /// 自動切到選 PDF 文字之前的工具（選字不在工具列上，用完切回去）
    var toolBeforeTemporary: EditorTool?

    // 手勢
    var toolPan: UIPanGestureRecognizer!
    var tapGesture: UITapGestureRecognizer!
    var doubleTapGesture: EditDoubleTapRecognizer!
    /// 手指點兩下的第一下按下之前，最上面那一步的編號（0＝還沒有任何一步）。
    /// 開了「用手指書寫」時這兩下也會寫出墨點、放下元件：進入編輯時回到這一步
    var stepBeforeEditTap: Int?
    /// 這一下是手指點空白處：只取消選取，不選、不放、不貼別的東西（收到觸碰時決定）
    var tapOnlyClears = false
    var longPressGesture: UILongPressGestureRecognizer!
    var textLongPress: UILongPressGestureRecognizer!
    /// 拖曳文字選取兩端的控制點（手指或 Pencil）
    var textHandlePan: UIPanGestureRecognizer!
    var pencilPointTracker: TouchTracker!
    var holdRecognizer: PencilHoldRecognizer!
    var lastPencilPoint: CGPoint?
    var pencilDown = false
    var lastPencilTime: CFTimeInterval = 0
    var palmBlocker: PalmBlocker!
    // 電路圖
    var circuitMode: CircuitMode = .select
    var circuitTarget: ElementRef?
    var circuitSel: CircuitSelection?
    var circuitDrag: CircuitDrag?
    var wireDraft: WireDraft?
    var circuitGateInputs: [CircuitPart: Int] = [:]
    /// 電路元件庫（浮在頁面下面或左邊，見 CircuitLibrary.swift）
    let circuitLibrary = CircuitLibraryView()
    /// 插入圖片工具：下方一排最近的照片
    let photoStrip = PhotoStripView()
    /// 貼紙工具：畫面下面一排目前分類的貼紙
    let stickerStrip = StickerStripView()
    /// 拉過最後一頁底部時出現的＋
    let addPagePull = AddPagePullView()
    /// UI 測試讀得到的除錯資訊（手指按下時卡住的手勢、畫布捲到哪裡）
    var uiTestDump: UILabel?
    var uiTestOffset: UILabel?
    /// UI 測試：PencilKit 筆跡的數量、最近的除錯紀錄、最後一筆 PencilKit 筆跡的墨水
    var uiTestStrokes: UILabel?
    var uiTestLog: UILabel?
    var uiTestInk: UILabel?
    /// UI 測試：第一頁表格在視窗裡的位置
    var uiTestTablePoint: UILabel?
    /// PencilKit 開始書寫的時間（收尾後清掉）；下筆時還沒清掉就代表上一筆卡住了
    var pkUsingSince: CFTimeInterval?
    /// 切到橡皮擦前的模式（筆身再點兩下、或擦完自動切回時回到這裡）
    var circuitModeBeforeErase: CircuitMode = .select
    /// 橡皮擦這一筆擦到的元件和導線：筆尖離開才刪
    var circuitErasing: [ElementRef: Set<UUID>] = [:]
    /// 橡皮擦這一筆上一次的位置；nil＝沒有在擦
    var circuitEraseLast: CGPoint?
    /// 每種元件上次的方向與翻轉，連續擺放時沿用
    var circuitPartStyle: [CircuitPart: (rotation: Int, flipH: Bool, flipV: Bool)] = [:]
    /// 選取模式下 Pencil 從空白處畫的框選；nil＝沒有在框選
    var circuitMarquee: [CGPoint]?
    /// toolPan 這次的觸碰是用來畫的（Pencil，或開了「用手指書寫」的手指）
    var toolPanByDrawingTouch = false

    // 預覽模式：工具列收起來，只能看
    var previewMode = false
    var toolBeforePreview: EditorTool = .pen
    /// 預覽時藏起來的工具列
    var barChrome: [UIView] = []
    var canvasBelowBars: NSLayoutConstraint!
    var canvasFullHeight: NSLayoutConstraint!
    /// 預覽模式下長按頁面：問要不要回到筆記模式（不放「結束預覽」按鈕，畫面乾淨）
    let previewLongPress = UILongPressGestureRecognizer()

    // 自製筆刷（見 InkEngine.swift）
    let inkRecognizer = InkCaptureRecognizer(target: nil, action: nil)
    let liveInkView = LiveInkView()
    var inkDraft: InkDraft?
    /// 自製筆刷停住變圖形：筆尖停住多久沒動
    var inkHoldTimer: Timer?
    /// 上次重新計時的位置（螢幕座標）
    var inkHoldAnchor: CGPoint = .zero
    /// 這次擦除已經登記過上一步的頁面（下筆時清空）
    var inkEraseUndoRegistered: Set<UUID> = []

    // 自訂套索
    var lassoPoints: [CGPoint] = []
    var lassoSel: LassoSelection?
    /// 貼紙的相簿選擇器（選擇器只弱參照 delegate）
    var stickerPicker: StickerPhotoPicker?
    var lassoMoveStart: CGPoint?
    /// 拖的是右下角的縮放把手（不是移動）
    var lassoScaling = false
    /// 拖曳中預覽的自製筆刷筆跡（文件座標）、預覽圖是照多大的倍數畫的
    var lassoMoveInk: [InkStroke] = []
    var lassoPreviewScale: CGFloat = 1
    var lassoMoveOriginal: PKDrawing?
    var lassoMoveStrokes: [PKStroke] = []
    var lassoMoveElementFrames: [ElementRef: CGRect] = [:]
    var lassoClipboard: LassoClipboard?
    var paletteOverlay: PaletteOverlay?

    // 掃描檔文字辨識快取
    var pageHasTextCache: [UUID: Bool] = [:]
    var ocrCache: [UUID: [OCRLine]] = [:]
    var ocrInFlight: Set<UUID> = []
    var charRectCache: [UUID: [CGRect]] = [:]

    // 表格編輯
    var tableCellSel: CellRange?
    var tableDrawTarget: ElementRef?
    /// 在已有的表格上手繪格線：這一筆的所有點（劃掉格線要看整條路徑）
    var tableDrawPoints: [CGPoint] = []
    /// 手繪格線模式切到「擦線」：沿著格線擦＝合併兩邊的格子
    var tableEraseLines = false
    /// 擦線中、放開就會擦掉的那幾段線（半透明顯示）
    var tableErasePreview: [ErasedLine] = []
    /// 拖曳移動表格（電路圖）時，一起帶走的手寫字
    var inkCarry: InkCarry?
    /// 表格工具列目前的分頁：0 列與欄、1 儲存格、2 樣式
    /// 工具列的＋（插入表格的小視窗指著它）
    weak var insertButton: UIButton?
    weak var tableCellLabel: UILabel?
    /// 表格工具列的顏色框：照現在選到的格子更新
    var tableColorBoxes: [() -> Void] = []

    // 橡皮擦擦螢光標示
    /// 橡皮擦：App 自己擦（見 Eraser.swift），PencilKit 的橡皮擦不用
    let eraserCapture = InkCaptureRecognizer(target: nil, action: nil)
    /// 橡皮擦上一個位置（文件座標）：和下一個點連起來，中間經過的都擦
    var lastEraserPoint: CGPoint?
    /// 這次擦除（筆碰到螢幕到離開）擦完的筆跡：下一下直接用，不從 PencilKit 讀回來（讀回來的遮罩是新的一份，對不上記著哪些點擦掉了）
    var eraseWorking: [PKStroke]?
    /// 橡皮擦走過、還沒擦的點（見 eraseEvery）
    var eraserPending: [CGPoint] = []
    var eraserErasedAt: CFTimeInterval = 0
    /// 上一次擦花了多久（見 eraserMoved）
    var eraserFlushCost: CFTimeInterval = 0
    /// 這一次擦除的上一步（第一次擦到東西時登記，之後併進去）
    var eraseStep: Int?
    /// 套索改顏色時的自訂顏色選擇器
    var lassoColorPicker: ColorPickerRelay?
    /// 表格格子的拷貝（照相對位置）；剪貼簿換過內容就不算
    var tableCellClipboard: (cells: [[String]], changeCount: Int)?
    /// 停住變直線／圖形（見 HoldToShape.swift）
    lazy var holdToShape = HoldToShapeController(editor: self)
    var editMenu: UIEditMenuInteraction!
    /// 工具列左邊的筆記本名稱
    weak var notebookTitleLabel: UILabel?
    var pendingMenu: UIMenu?
    /// 選單要避開的範圍（畫布座標）：選單放在它的上面或下面，不蓋住選到的東西
    var pendingMenuAvoid: CGRect?

    // 選取物件
    var selected: ElementRef?
    var dragState: DragState?
    var clipboardElement: (element: PageElement, changeCount: Int)?
    var editingTextView: UITextView?
    var editingTarget: (ref: ElementRef, cell: (row: Int, col: Int)?)?

    // PDF 文字選取
    var textSelection: TextSelectionState?
    var textPanStart: CGPoint?
    /// 正在拖的控制點：另一端固定的位置（字和字之間的縫，0 是第一個字前面）
    var textHandleFixed: Int?
    /// 按下的位置到控制點直線中間的距離（手指按在圓點上，拖的是直線那一點）
    var textHandleGrab: CGPoint = .zero

    // 截圖
    var capturePoints: [CGPoint] = []
    /// 截好的範圍（文件座標）：拉錨點調整大小、拖曳框內移動，放開再跳出選單
    var captureRegion: UIBezierPath?
    /// 正在拉的錨點（0…7，-1＝移動整個範圍）、開始的位置和範圍
    var captureDrag: (handle: Int, start: CGPoint, path: UIBezierPath)?

    // 擴展頁面
    var resizePageIndex: Int?
    var resizeDrag: PageResizeDrag?

    // 手繪表格
    var tableDraft: TableDraft?
    var tableDraftStart: CGPoint?

    // 筆畫後處理（形狀修正、螢光筆對齊）
    var toolBeganAt: CFTimeInterval = 0
    var strokeCountAtBegin = 0

    var pages: [Page] { session.document.pages }

    init(session: NotebookSession, initialPageID: UUID?, onClose: @escaping () -> Void) {
        self.session = session
        self.initialPageID = initialPageID
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.92, alpha: 1)
        overrideUserInterfaceStyle = .light

        setupCanvas()
        setupBars()
        setupGestures()
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)

        pinOverlay.frame = view.bounds
        pinOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pinOverlay.onInsertIntoPage = { [weak self] img in self?.insertImage(img, jpeg: false, at: nil) }
        pinOverlay.notebookID = session.id
        view.addSubview(pinOverlay)
        #if DEBUG
        if ScreenshotDemo.isOn { scheduleScreenshotScene() }
        #endif

        if ProcessInfo.processInfo.arguments.contains("-uiTestNotebook") {
            // UI 測試讀的除錯紀錄定時更新（不是每個地方記完都會更新，例如手勢沒有走完）
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] t in
                guard let self else { return t.invalidate() }
                self.updateUITestDump()
            }
            let l = UILabel(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
            l.accessibilityIdentifier = "gestureDump"
            l.accessibilityLabel = "-"
            l.isAccessibilityElement = true
            view.addSubview(l)
            uiTestDump = l
            let o = UILabel(frame: CGRect(x: 0, y: 2, width: 2, height: 2))
            o.accessibilityIdentifier = "scrollOffset"
            o.accessibilityLabel = "0"
            o.isAccessibilityElement = true
            view.addSubview(o)
            uiTestOffset = o
            for (i, id) in ["pkStrokes", "debugTail", "pkInk", "tablePoint"].enumerated() {
                let l = UILabel(frame: CGRect(x: 0, y: 4 + 2 * CGFloat(i), width: 2, height: 2))
                l.accessibilityIdentifier = id
                l.accessibilityLabel = id == "pkStrokes" ? "0" : "-"
                l.isAccessibilityElement = true
                view.addSubview(l)
                switch i {
                case 0: uiTestStrokes = l
                case 1: uiTestLog = l
                case 2: uiTestInk = l
                default: uiTestTablePoint = l
                }
            }
        }
        DebugLog.watchMainThread()

        computeLayout()
        loadCanvasFromPages()
        applyTool()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    private func setupCanvas() {
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.delegate = self
        canvas.editorUndoManager = editorUndo
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.alwaysBounceVertical = true
        // 點到最上面的狀態列不要跳回第一頁（很容易誤觸）
        canvas.scrollsToTop = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.overrideUserInterfaceStyle = .light
        canvas.bouncesZoom = true
        view.addSubview(canvas)
        canvas.layer.addSublayer(holdToShape.previewLayer)
        // 小視窗開著時碰到頁面：當作點旁邊，系統的關閉動畫，這一下不寫字
        popoverShield.translatesAutoresizingMaskIntoConstraints = false
        popoverShield.backgroundColor = .clear
        popoverShield.isActive = { [weak self] in self?.toolPopoverShown ?? false }
        popoverShield.onTouch = { [weak self] in self?.dismissToolPopover(animated: true) }
        view.insertSubview(popoverShield, aboveSubview: canvas)
        NSLayoutConstraint.activate([
            popoverShield.topAnchor.constraint(equalTo: canvas.topAnchor),
            popoverShield.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            popoverShield.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            popoverShield.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
        ])

        pagesContainer.backgroundColor = .clear
        canvas.insertSubview(pagesContainer, at: 0)
        inkContainer.backgroundColor = .clear
        inkContainer.isUserInteractionEnabled = false
        canvas.addSubview(inkContainer)
        // 套索、選取框、橡皮擦的圓圈：放在自製筆刷的字上面（inkContainer 又在 PencilKit 的筆跡上面），不會被筆跡蓋住
        overlay.frame = .zero
        inkContainer.addSubview(overlay)

        editMenu = UIEditMenuInteraction(delegate: self)
        canvas.addInteraction(editMenu)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if canvas.subviews.first !== pagesContainer {
            canvas.sendSubviewToBack(pagesContainer)
        }
        let w = canvas.bounds.width
        guard w > 0 else { return }
        if !didInitialLayout {
            didInitialLayout = true
            lastLayoutWidth = w
            updateZoomLimits(resetZoom: true)
            // 設定縮放時系統保持的是畫面中心（這時還沒有在看哪裡）：一開始看的地方要自己指定，從最上面開始
            setVisibleDocOrigin(.zero)
            configurePencilKitGestures()
            pinOverlay.reload()
            if let pid = initialPageID, let i = pageIndex(of: pid) {
                scrollToPage(i, animated: false)
            }
            updateVisiblePages()
            updatePageIndicator()
        } else if abs(w - lastLayoutWidth) > 1 {
            let relative = canvas.zoomScale / fitZoom
            // 畫面左上角對到的文件位置不變：App 切到背景時系統會用另一個方向排版截圖，
            // 切回來要回到原本看的地方，不是那一頁的最上面
            let anchor = visibleDocRect().origin
            lastLayoutWidth = w
            updateZoomLimits(resetZoom: false)
            canvas.zoomScale = min(max(fitZoom * relative, canvas.minimumZoomScale), canvas.maximumZoomScale)
            updateZoomLayout()
            setVisibleDocOrigin(anchor)
            pinOverlay.clampAll()
        }
    }

    @objc private func appWillResignActive() {
        endTextEditing()
        saveNow()
    }

    @objc func titleLongPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let alert = UIAlertController(title: L("筆記本名稱"), message: nil, preferredStyle: .alert)
        alert.addTextField { [weak self] tf in
            tf.text = self?.session.title
            tf.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("儲存"), style: .default) { [weak self, weak alert] _ in
            self?.renameNotebook(to: alert?.textFields?.first?.text ?? "")
        })
        present(alert, animated: true)
    }

    /// 改筆記本名稱（空白的名稱不改）
    func renameNotebook(to name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != session.title else { return }
        LibraryStore.shared.renameNotebook(session.id, to: title)
        notebookTitleLabel?.text = title
        NotificationCenter.default.post(name: .notebookRenamed, object: session.id)
    }

    @objc func closeTapped() {
        // 存檔由分頁容器統一處理（prepareForClose）
        onClose()
    }

    /// 切到別的分頁時：存檔並記住看到第幾頁
    func saveAndRememberPage() {
        guard isViewLoaded else { return }
        endTextEditing()
        saveNow()
        if pages.indices.contains(currentPageIndex) {
            TabStore.setLastPage(pages[currentPageIndex].id, for: session.id)
        }
    }

    /// 關閉分頁或回到資料庫：存檔、更新縮圖、觸發雲端備份
    func prepareForClose() {
        guard isViewLoaded else { return }
        saveAndRememberPage()
        session.writeLibraryThumbnails()
        BackupManager.shared.notebookClosed()
    }

    /// 切回這個分頁時：重新載入貼圖（可能在其他分頁新增過）
    func didBecomeActiveTab() {
        guard isViewLoaded else { return }
        pinOverlay.reload()
        applyTool()
    }

    func jump(toPageID id: UUID) {
        guard isViewLoaded, didInitialLayout, let i = pageIndex(of: id) else { return }
        scrollToPage(i, animated: false)
    }

    // MARK: - Layout

    func computeLayout() {
        let sizes = pages.map { session.fullSize(of: $0) }
        let maxW = sizes.map(\.width).max() ?? 595
        let docW = maxW + docPadding * 2
        var frames: [CGRect] = []
        var y = docPadding
        for s in sizes {
            frames.append(CGRect(x: ((docW - s.width) / 2).rounded(), y: y, width: s.width, height: s.height))
            y += s.height + pageGap
        }
        pageFrames = frames
        // 最後一頁底下就是結尾：再往上拉會出現＋新增頁面（見 Editor+AddPage）
        docSize = CGSize(width: docW, height: y - pageGap + docPadding)
    }

    func contentOrigin(_ i: Int) -> CGPoint {
        let f = pageFrames[i]
        let ins = pages[i].insets
        return CGPoint(x: f.minX + ins.left, y: f.minY + ins.top)
    }

    func nearestPageIndex(to p: CGPoint) -> Int {
        guard !pageFrames.isEmpty else { return 0 }
        var lo = 0, hi = pageFrames.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if pageFrames[mid].maxY + pageGap / 2 < p.y { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func pageIndex(containing p: CGPoint) -> Int? {
        guard !pageFrames.isEmpty else { return nil }
        let i = nearestPageIndex(to: p)
        return pageFrames[i].contains(p) ? i : nil
    }

    func pageIndex(of id: UUID) -> Int? { pages.firstIndex { $0.id == id } }

    /// 畫面看得到的範圍（文件座標）。用捲動視圖自己的縮放算，不是用頁面容器：
    /// 縮放時系統先改好縮放和捲動位置、通知捲動，之後才通知縮放（容器在那裡才跟上）。
    /// 捲動通知裡容器還是舊的縮放，拿它算會偏好幾頁：正在看的頁面被拿掉重建（一瞬間全白）、頁碼亂跳
    func visibleDocRect() -> CGRect {
        let z = max(canvas.zoomScale, 0.001), b = canvas.bounds
        return CGRect(x: b.minX / z, y: b.minY / z, width: b.width / z, height: b.height / z)
    }

    var currentPageIndex: Int {
        let r = visibleDocRect()
        return nearestPageIndex(to: CGPoint(x: r.midX, y: r.minY + r.height * 0.4))
    }

    func scrollToPage(_ i: Int, animated: Bool) {
        guard pageFrames.indices.contains(i) else { return }
        let z = canvas.zoomScale
        let maxY = max(0, canvas.contentSize.height - canvas.bounds.height + canvas.contentInset.bottom)
        let y = min(max(0, (pageFrames[i].minY - 12) * z), maxY)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: y), animated: animated)
        updateVisiblePages()
        updatePageIndicator()
    }

    func updateZoomLimits(resetZoom: Bool) {
        fitZoom = canvas.bounds.width / max(docSize.width, 1)
        canvas.minimumZoomScale = fitZoom * 0.3
        canvas.maximumZoomScale = fitZoom * 6
        if resetZoom { canvas.zoomScale = fitZoom }
        updateZoomLayout()
    }

    /// followZoomAnimation：縮放本身在動畫裡（放到最大再拉、放開後回彈；程式的動畫縮放）。
    /// 系統用同一個動畫一起改縮放和捲動位置，頁面也要跟著這個動畫縮放、移動；
    /// 不跟的話頁面一下就變成最後的大小，捲動位置卻還在動畫裡，畫面會先偏到角落再跳回來。
    /// 只有兩個容器的縮放跟著動畫：同一輪裡新加進來的頁面、選取框等等直接放到位置，
    /// 不然新的頁面會從左上角 (0,0) 一路動畫飛到自己的位置
    func updateZoomLayout(followZoomAnimation: Bool = false) {
        let z = canvas.zoomScale
        if followZoomAnimation, pagesContainer.bounds.size == docSize {
            let t = CGAffineTransform(scaleX: z, y: z)
            let c = CGPoint(x: docSize.width * z / 2, y: docSize.height * z / 2)
            pagesContainer.transform = t
            pagesContainer.center = c
            inkContainer.transform = t
            inkContainer.center = c
            UIView.performWithoutAnimation { finishZoomLayout(z, removeHidden: false) }
            return
        }
        // 頁面的位置、縮放不做動畫：鍵盤跳出來時系統在鍵盤的動畫裡通知，
        // 這裡先把縮放歸零再設回去，跟著動畫的話頁面會縮小再放大（閃一下）
        UIView.performWithoutAnimation {
            pagesContainer.transform = .identity
            pagesContainer.bounds = CGRect(origin: .zero, size: docSize)
            pagesContainer.transform = CGAffineTransform(scaleX: z, y: z)
            pagesContainer.center = CGPoint(x: docSize.width * z / 2, y: docSize.height * z / 2)
            inkContainer.transform = .identity
            inkContainer.bounds = pagesContainer.bounds
            inkContainer.transform = pagesContainer.transform
            inkContainer.center = pagesContainer.center
            overlay.frame = CGRect(origin: .zero, size: docSize)
        }
        finishZoomLayout(z)
    }

    private func finishZoomLayout(_ z: CGFloat, removeHidden: Bool = true) {
        // PencilKit 之後才加的 view 也要在筆跡底下
        if canvas.subviews.last !== inkContainer { canvas.bringSubviewToFront(inkContainer) }
        overlay.lineScale = 1 / z
        let size = CGSize(width: docSize.width * z, height: docSize.height * z)
        if canvas.contentSize != size { canvas.contentSize = size }
        applyCanvasInsets()
        updateSelectionChrome()
        updatePageResizeChrome()
        updateVisiblePages(removeHidden: removeHidden)
    }

    /// 畫布底下的留白：鍵盤擋住的高度；擴展頁面時再多留一個畫面，才拉得到最後一頁下緣的控制點
    var bottomInset: CGFloat {
        keyboardInset + resizeRoom.height + (tool == .circuit ? circuitLibrary.bottomOverlap : 0)
    }

    /// 擴展頁面時四周多留的空間（各一個畫面）：頁面變大後留白也跟著往外，可以一直往任何方向捲、一直擴展
    var resizeRoom: CGSize {
        guard tool == .pageResize else { return .zero }
        return CGSize(width: max(200, canvas.bounds.width * 0.9), height: max(200, canvas.bounds.height * 0.9))
    }

    /// 畫布的留白：頁面比畫面窄時左右置中；擴展頁面時四周各留一個畫面
    var canvasInsets: UIEdgeInsets {
        let side = max(0, (canvas.bounds.width - canvas.contentSize.width) / 2)
        let room = resizeRoom
        return UIEdgeInsets(top: room.height, left: max(side, room.width), bottom: bottomInset, right: max(side, room.width))
    }

    func applyCanvasInsets() {
        let new = canvasInsets
        let old = canvas.contentInset
        guard new != old else { return }
        canvas.contentInset = new
        // 離開擴展頁面：四周的留白收回去，畫面不能停在留白裡
        if old.top > new.top || old.left > new.left {
            let minX = -new.left, minY = -new.top
            let maxX = max(minX, canvas.contentSize.width - canvas.bounds.width + new.right)
            let maxY = max(minY, canvas.contentSize.height - canvas.bounds.height + new.bottom)
            let o = canvas.contentOffset
            let c = CGPoint(x: min(max(o.x, minX), maxX), y: min(max(o.y, minY), maxY))
            if c != o { canvas.contentOffset = c }
        }
    }

    /// 讓文件座標 p 出現在畫面左上角
    func setVisibleDocOrigin(_ p: CGPoint) {
        let z = canvas.zoomScale
        let inset = canvas.contentInset
        let maxX = max(-inset.left, canvas.contentSize.width - canvas.bounds.width + inset.right)
        let maxY = max(-inset.top, canvas.contentSize.height - canvas.bounds.height + inset.bottom)
        let off = CGPoint(x: min(max(p.x * z, -inset.left), maxX), y: min(max(p.y * z, -inset.top), maxY))
        canvas.setContentOffset(off, animated: false)
        updateVisiblePages()
        updatePageIndicator()
    }

    var elementContentScale: CGFloat {
        min(traitCollection.displayScale * canvas.zoomScale, 8)
    }

    /// removeHidden：拿掉看不到的頁面。系統的動畫縮放（放開後回彈）是在動畫裡一項一項改的：先改縮放、通知捲動，
    /// 再改捲動位置、再通知一次。中間那次的縮放和捲動位置配不起來，算出來的範圍差好幾頁（越後面的頁差越多），
    /// 照它拿掉頁面，正在看的頁面就被拿掉又重建，背景重畫（PDF 比較慢）時一瞬間全白。
    /// 動畫裡只加不拿；動畫裡的值都改好後（縮放結束、下一次一般的捲動）再拿掉
    func updateVisiblePages(removeHidden: Bool = true) {
        guard !pageFrames.isEmpty else { return }
        let visible = visibleDocRect()
        let margin = visible.height * 0.75
        let range = visible.insetBy(dx: -visible.width, dy: -margin)
        var keep = Set<UUID>()
        var i = nearestPageIndex(to: CGPoint(x: range.midX, y: range.minY))
        while i < pageFrames.count, pageFrames[i].minY <= range.maxY {
            let page = pages[i]
            keep.insert(page.id)
            if pageViews[page.id] == nil {
                // 新的頁面直接放在自己的位置：在系統的動畫縮放裡（回彈）加進來也不從 (0,0) 飛過去
                UIView.performWithoutAnimation {
                    let v = PageContainerView(pageID: page.id)
                    v.frame = pageFrames[i]
                    // 筆跡先放好、有大小，configure 才會在背景準備筆跡
                    inkContainer.insertSubview(v.inkView, belowSubview: overlay)
                    v.inkView.frame = v.frame
                    v.configure(page: page, session: session, contentScale: elementContentScale)
                    pagesContainer.addSubview(v)
                    pageViews[page.id] = v
                }
                zoomTrace.note("page+ \(i + 1)")
            }
            i += 1
        }
        // 放很大時筆跡只把看得到的地方畫清楚（見 PageInkView）
        for v in pageViews.values {
            let f = v.inkView.frame
            let r = visible.intersection(f)
            v.inkView.setVisibleRect(r.isNull || r.isEmpty ? nil : r.offsetBy(dx: -f.minX, dy: -f.minY))
        }
        guard removeHidden else { return }
        for (id, v) in pageViews where !keep.contains(id) {
            zoomTrace.note("page- \(pageIndex(of: id).map { $0 + 1 } ?? 0)")
            v.removeFromSuperview()
            v.inkView.removeFromSuperview()
            pageViews[id] = nil
        }
    }

    func refreshPage(_ i: Int) {
        guard let page = pages[safe: i], let v = pageViews[page.id] else { return }
        v.frame = pageFrames[i]
        v.inkView.frame = v.frame
        v.configure(page: page, session: session, contentScale: elementContentScale)
        updateSelectionChrome()
    }

    func updatePageIndicator() {
        guard !pages.isEmpty else { return }
        let i = currentPageIndex
        pageLabel.text = "\(i + 1) / \(pages.count)"
        refreshFavoriteButton()
    }

    // MARK: - Scroll / zoom

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        uiTestOffset?.accessibilityLabel = "\(Int(scrollView.contentOffset.y))"
        zoomTrace.note("didScroll")
        updateVisiblePages(removeHidden: UIView.inheritedAnimationDuration == 0)
        updatePageIndicator()
        updateAddPagePull()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        addPagePullEnded()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        DebugLog.add("scroll begin")
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        zoomTrace.note("didZoom")
        // 在動畫裡（回彈、動畫縮放）：頁面跟著同一個動畫
        updateZoomLayout(followZoomAnimation: UIView.inheritedAnimationDuration > 0)
        let s = elementContentScale
        UIView.performWithoutAnimation {
            for v in pageViews.values { v.inkView.setRenderScale(s) }
        }
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        DebugLog.add("zoom begin")
        if !zoomTraceAttached, let pinch = canvas.pinchGestureRecognizer {
            pinch.addTarget(zoomTrace, action: #selector(ZoomTrace.pinchChanged(_:)))
            zoomTraceAttached = true
        }
        endTextEditing()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        DebugLog.add("zoom end x\(String(format: "%.2f", scale / max(fitZoom, 0.01)))")
        zoomTrace.note("didEndZooming")
        // 回彈的動畫裡只加不拿：值都定了，把看不到的頁面拿掉
        updateVisiblePages()
        let s = elementContentScale
        for v in pageViews.values { v.updateContentScale(s) }
    }

    // MARK: - Drawing ↔ pages

    func assembleDrawing() -> PKDrawing {
        var strokes: [PKStroke] = []
        for (i, page) in pages.enumerated() {
            guard let d = session.drawings[page.id], !d.strokes.isEmpty else { continue }
            let o = contentOrigin(i)
            strokes.append(contentsOf: d.transformed(using: CGAffineTransform(translationX: o.x, y: o.y)).strokes)
        }
        return PKDrawing(strokes: strokes)
    }

    /// 用程式加進去的新筆跡 PencilKit 不一定會重畫：先放不含最後 n 筆的版本，下一刻再補上
    func setDrawingAddingStrokes(_ d: PKDrawing, added n: Int, then done: (() -> Void)? = nil) {
        var without = d
        without.strokes.removeLast(min(n, without.strokes.count))
        setDrawing(without)
        let count = without.strokes.count
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let current = self.canvas.drawing.strokes.count
            if current == count { self.setDrawing(d) }
            DebugLog.add("add strokes step 2: \(current == count ? "added \(n)" : "skipped, strokes=\(current) expected=\(count)") now=\(self.canvas.drawing.strokes.count)")
            done?()
        }
    }

    /// 畫布換成 d 的筆跡。一律從畫布現在的筆跡改過去，不直接換上 d 這一份：
    /// PencilKit 留著它自己最後寫進去的那一版，下一筆收尾時和畫布的筆跡合併；
    /// 換上的是比較舊的一版（上一步、下一步記下的），合併就會把之後才拿掉的筆跡帶回來
    func setDrawing(_ d: PKDrawing, file: StaticString = #fileID, line: UInt = #line) {
        setStrokes(d.strokes, file: file, line: line)
    }

    /// 畫布換成這些筆跡。整本的 PencilKit 筆跡都在同一張畫布上，組一份 PKDrawing 要時間（2500 筆約 10ms）：
    /// 手上已經是筆跡的話直接給這裡，不要先組一份 PKDrawing 再交給 setDrawing（會組兩次）
    func setStrokes(_ strokes: [PKStroke], file: StaticString = #fileID, line: UInt = #line) {
        uiTestTrace("set \(file):\(line)", strokes)
        var next = canvas.drawing
        next.strokes = strokes
        isApplyingDrawing = true
        canvas.drawing = next
        isApplyingDrawing = false
        scheduleSave()
        updateUITestDump()
    }

    /// UI 測試：記下筆跡的變化（每一筆用建立時間的尾數當代號）
    func uiTestTrace(_ what: String, _ strokes: @autoclosure () -> [PKStroke]) {
        guard uiTestStrokes != nil else { return }
        let all = strokes()
        let ids = all.map { String(format: "%.2f", $0.path.creationDate.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100)) }
        DebugLog.add("\(what) n=\(all.count) [\(ids.joined(separator: ","))]")
    }

    func updateUITestDump() {
        guard let l = uiTestStrokes else { return }
        l.accessibilityLabel = "\(canvas.drawing.strokes.count)"
        uiTestInk?.accessibilityLabel = canvas.drawing.strokes.last?.ink.inkType.rawValue ?? "-"
        uiTestLog?.accessibilityLabel = DebugLog.text.split(separator: "\n").suffix(25).joined(separator: " / ")
        uiTestTablePoint?.accessibilityLabel = uiTestTableSpot()
    }

    /// UI 測試要點表格：第一頁的表格現在看得到的那一塊的中心（視窗座標）。打開時頁面不一定捲在最上面
    private func uiTestTableSpot() -> String {
        guard didInitialLayout, let e = pages.first?.elements.first(where: \.isTable) else { return "-" }
        let r = pagesContainer.convert(docFrame(of: e, pageIndex: 0), to: nil).intersection(view.convert(canvas.frame, to: nil))
        return r.isEmpty ? "-" : "\(Int(r.midX)),\(Int(r.midY))"
    }

    /// 改變頁面尺寸、增刪頁面時：先依舊版面拆分筆跡，再依新版面組回去
    func performLayoutChange(_ change: () -> Void) {
        endTextEditing()
        select(nil)
        let anchorIndex = currentPageIndex
        let anchorID = pages[anchorIndex].id
        // 記住畫面相對於該頁內容的位置，擴展後內容不會在畫面上跳動
        let visible = visibleDocRect()
        let oldOrigin = contentOrigin(anchorIndex)
        let anchorOffset = CGPoint(x: visible.minX - oldOrigin.x, y: visible.minY - oldOrigin.y)
        commitDrawing()
        change()
        computeLayout()
        loadCanvasFromPages()
        history.removeAll()
        for v in pageViews.values {
            v.removeFromSuperview()
            v.inkView.removeFromSuperview()
        }
        pageViews = [:]
        updateZoomLimits(resetZoom: false)
        canvas.zoomScale = min(max(canvas.zoomScale, canvas.minimumZoomScale), canvas.maximumZoomScale)
        updateZoomLayout()
        if let i = pageIndex(of: anchorID) {
            setVisibleDocOrigin(contentOrigin(i) + anchorOffset)
        } else {
            scrollToPage(min(anchorIndex, pages.count - 1), animated: false)
        }
        if let r = resizePageIndex, !pages.indices.contains(r) { resizePageIndex = currentPageIndex }
        updatePageResizeChrome()
        scheduleSave()
    }

    // MARK: - Save

    func scheduleSave() {
        saveWorkItem?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    /// 各頁的筆跡組到畫布上
    func loadCanvasFromPages() {
        isApplyingDrawing = true
        canvas.drawing = assembleDrawing()
        isApplyingDrawing = false
        committedInk = pageBuckets(canvas.drawing).mapValues { PKDrawing(strokes: $0).contentSignature }
    }

    /// 畫布的筆跡拆回各頁。筆跡沒變的頁維持原本的資料，不重算座標
    func commitDrawing() {
        var next: [UUID: PKDrawing] = [:]
        var ink: [UUID: Data] = [:]
        var indices: [UUID: Int] = [:]
        for (i, p) in pages.enumerated() { indices[p.id] = i }
        for (id, strokes) in pageBuckets(canvas.drawing) {
            guard let i = indices[id] else { continue }
            let onCanvas = PKDrawing(strokes: strokes)
            let signature = onCanvas.contentSignature
            ink[id] = signature
            if signature == committedInk[id], let kept = session.drawings[id] {
                next[id] = kept
                continue
            }
            let o = contentOrigin(i)
            next[id] = onCanvas.transformed(using: CGAffineTransform(translationX: -o.x, y: -o.y))
        }
        session.drawings = next
        committedInk = ink
    }

    /// 畫布上的筆跡依所在的頁分開（還是畫布座標）
    func pageBuckets(_ drawing: PKDrawing) -> [UUID: [PKStroke]] {
        var buckets: [UUID: [PKStroke]] = [:]
        for s in drawing.strokes {
            let i = nearestPageIndex(to: s.renderBounds.center)
            guard pages.indices.contains(i) else { continue }
            buckets[pages[i].id, default: []].append(s)
        }
        return buckets
    }

    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        commitDrawing()
        session.save()
    }

    // MARK: - Model edits with undo

    struct PageContentSnapshot {
        var elements: [PageElement]
        var highlights: [TextHighlight]
        var ink: [InkStroke]

        init(_ page: Page) {
            elements = page.elements
            highlights = page.highlights
            ink = page.ink
        }
    }

    func updatePage(_ i: Int, undoable: Bool = true, _ change: (inout Page) -> Void) {
        guard pages.indices.contains(i) else { return }
        let old = pages[i]
        change(&session.document.pages[i])
        let new = pages[i]
        guard old != new else { return }
        if undoable {
            history.record(.init(drawing: nil, pages: [old.id: PageContentSnapshot(old)]))
        }
        refreshPage(i)
        scheduleSave()
    }

    /// 記下一步：筆跡回到 drawing（nil＝沒動到筆跡）、這些頁面回到現在的樣子。在改動之前呼叫。
    /// newStep：一定自成一步（使用者明確下的指令，例如清除整頁），不併進同一輪剛記的動作
    func recordEdit(drawing: PKDrawing?, pageIDs: [UUID], newStep: Bool = false) {
        var snaps: [UUID: PageContentSnapshot] = [:]
        for id in pageIDs {
            if let i = pageIndex(of: id) { snaps[id] = PageContentSnapshot(pages[i]) }
        }
        history.record(.init(drawing: drawing, pages: snaps), newStep: newStep)
    }

    /// 同一步範圍內的目前狀態（按上一步時記下來，給下一步用）
    private func currentEditState(like s: EditHistory.State) -> EditHistory.State {
        var snaps: [UUID: PageContentSnapshot] = [:]
        for id in s.pages.keys {
            if let i = pageIndex(of: id) { snaps[id] = PageContentSnapshot(pages[i]) }
        }
        return .init(drawing: s.drawing == nil ? nil : canvas.drawing, pages: snaps)
    }

    /// 回到記下的狀態
    private func restoreEditState(_ s: EditHistory.State) {
        if let d = s.drawing {
            setDrawing(d)
            clearLassoSelection()
        }
        for (id, snap) in s.pages {
            guard let i = pageIndex(of: id) else { continue }
            session.document.pages[i].elements = snap.elements
            session.document.pages[i].highlights = snap.highlights
            session.document.pages[i].ink = snap.ink
            refreshPage(i)
        }
        if let sel = selected, locate(sel) == nil { select(nil) }
        scheduleSave()
    }

    /// 收回 id 這一步之後做的
    func discardEdits(after id: Int) {
        history.discard(after: id, apply: restoreEditState)
    }

    @objc func undoTapped() {
        endTextEditing()
        if holdToShape.undo() { return }
        // 手繪新表格還沒完成：上一步＝收回最後畫的那條線
        if tool == .tableDraw, tableDrawTarget == nil, tableDraft != nil {
            undoTableDivider()
            return
        }
        let done = history.undo(capture: currentEditState, apply: restoreEditState)
        uiTestTrace("undo done=\(done)", canvas.drawing.strokes)
    }

    @objc func redoTapped() {
        endTextEditing()
        holdToShape.redo()
        _ = history.redo(capture: currentEditState, apply: restoreEditState)
    }

    /// PencilKit 改了筆跡（寫了一筆、擦掉幾筆）：這次下筆第一次改到時登記一步，回到下筆之前
    @discardableResult
    func recordStrokeGesture(_ g: StrokeGesture?) -> Int? {
        guard let g else { return nil }
        if g.step == nil, history.recordCount == g.mark {
            g.step = history.record(.init(drawing: g.before, pages: [:]), newStep: true)
        }
        return g.step
    }

    // MARK: - PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        uiTestTrace("pk changed applying=\(isApplyingDrawing)", canvas.drawing.strokes)
        updateUITestDump()
        guard !isApplyingDrawing else { return }
        recordStrokeGesture(strokeGesture)
        holdToShape.drawingChanged()
        scheduleSave()
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        pkUsingSince = CACurrentMediaTime()
        holdToShape.pencilKitBegan()
        strokeGesture = StrokeGesture(before: canvas.drawing, mark: history.recordCount)
        // 開始寫字 → 收起還沒點的調色盤小圖示
        if let p = paletteOverlay, p.mode == .launcher { dismissPalette() }
        toolBeganAt = CACurrentMediaTime()
        strokeCountAtBegin = canvas.drawing.strokes.count
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        pkUsingSince = nil
        // 停住變直線的那一筆：交給 holdToShape 換成直線，不當成新筆跡處理
        if holdToShape.pencilKitEnded() { return }
        let gesture = strokeGesture
        if !tool.isDrawing {
            let before = strokeCountAtBegin
            DispatchQueue.main.async { [weak self] in self?.absorbStrayStroke(countBefore: before, gesture: gesture) }
            return
        }
        guard tool.isInking else { return }
        let duration = CACurrentMediaTime() - toolBeganAt
        let before = strokeCountAtBegin
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            // 畫完之後的整理（拉直、遮掉頁面外、對齊 PDF 文字）和寫這一筆算同一步
            self?.history.merging(into: gesture?.step) {
                self?.processNewStroke(duration: duration, countBefore: before)
            }
        }
    }

    private func processNewStroke(duration: TimeInterval, countBefore: Int) {
        var drawing = canvas.drawing
        guard drawing.strokes.count == countBefore + 1, var stroke = drawing.strokes.last else { return }
        // 不畫到頁面外：超出這一筆所在那一頁的部分遮掉
        if let masked = maskedToPage(stroke) {
            stroke = masked
            drawing.strokes[drawing.strokes.count - 1] = masked
            setDrawing(drawing)
        }
        holdToShape.recordSample(of: stroke, presetID: BrushStore.shared.current.id)
        if tool == .pen { DebugLog.add(Self.pencilKitStrokeSummary(stroke)) }
        // 虛線：筆放開後把這一筆切成一段一段
        let preset = BrushStore.shared.current
        if tool == .pen, preset.isDashed {
            let width = ShapeRecognizer.samplePoint(of: stroke)?.size.width ?? preset.tool.width
            let pieces = DashedStroke.apply(stroke, dashed: true, lineWidth: width, preset: preset)
            drawing.strokes.removeLast()
            drawing.strokes += pieces
            setDrawingAddingStrokes(drawing, added: pieces.count)
            return
        }
        // 對齊 PDF 文字：筆跡拿掉、改成螢光標示
        if BrushStore.shared.current.style == .marker && settings.smartHighlight && snapHighlightToText(stroke) {
            drawing.strokes.removeLast()
            setDrawing(drawing)
            return
        }
        // 螢光筆畫得接近直線 → 自動拉直；比較歪就保持原樣
        if tool == .highlighter,
           let straight = ShapeRecognizer.straightenIfNearlyStraight(stroke, preset: BrushStore.shared.current) {
            drawing.strokes[drawing.strokes.count - 1] = straight
            setDrawing(drawing)
        }
        if tool == .highlighter { keepHighlightsBelowInk() }
    }

    /// 螢光筆的筆跡排在其他 PencilKit 筆跡前面（畫在底下），字才不會被螢光筆蓋住
    func keepHighlightsBelowInk() {
        guard let sorted = Self.highlightsBelowInk(canvas.drawing.strokes) else { return }
        var d = canvas.drawing
        d.strokes = sorted
        setDrawing(d)
    }

    /// 螢光筆排到最前面、其他順序不變；本來就排好了回傳 nil
    static func highlightsBelowInk(_ strokes: [PKStroke]) -> [PKStroke]? {
        let isHighlight = isHighlighterStroke
        guard let firstInk = strokes.firstIndex(where: { !isHighlight($0) }),
              strokes[firstInk...].contains(where: isHighlight) else { return nil }
        return strokes.filter(isHighlight) + strokes.filter { !isHighlight($0) }
    }

    /// 螢光筆畫的：螢光筆是半透明的 monoline 墨水（見 InkStyle.inkType），舊的筆記可能有 PencilKit 的 marker。
    /// 存檔再讀回來，monoline 會變成 pen（顏色的透明度還在）：半透明的 pen 也是
    static func isHighlighterStroke(_ s: PKStroke) -> Bool {
        s.ink.inkType == .marker || ([.monoline, .pen].contains(s.ink.inkType) && s.ink.color.cgColor.alpha < 1)
    }

    /// 除錯紀錄：PencilKit 這一筆的取樣（墨水、點數、平均間隔，和平均挑的 8 個點的粗細、筆壓、傾斜、方位、透明度）。
    /// 自製引擎照著 PencilKit 調的時候用：Pencil 的筆壓、傾斜怎麼變成粗細，只有真的用 Pencil 寫才知道
    static func pencilKitStrokeSummary(_ s: PKStroke) -> String {
        let pts = Array(s.path)
        guard let last = pts.last else { return "pk stroke empty" }
        let dt = pts.count > 1 ? last.timeOffset / Double(pts.count - 1) * 1000 : 0
        let picks = (0..<8).map { pts[min(pts.count - 1, $0 * pts.count / 8)] } + [last]
        let detail = picks.map {
            String(format: "%.2f/%.2f/%.2f/%.2f/%.2f/%.2f", $0.size.width, $0.size.height, $0.force, $0.altitude, $0.azimuth, $0.opacity)
        }.joined(separator: " ")
        return "pk stroke ink=\(s.ink.inkType.rawValue) n=\(pts.count) dt=\(String(format: "%.1f", dt))ms w/h/force/alt/az/op: \(detail)"
    }

    /// 筆跡超出它所在的那一頁（存檔時歸到的頁）時，加上遮罩只顯示頁面裡的部分；沒超出回傳 nil
    func maskedToPage(_ s: PKStroke) -> PKStroke? {
        guard !pageFrames.isEmpty else { return nil }
        let f = pageFrames[nearestPageIndex(to: s.renderBounds.center)]
        guard !f.contains(s.renderBounds) else { return nil }
        var m = s
        m.mask = UIBezierPath(rect: f.applying(s.transform.inverted()))
        return m
    }

    /// 不該畫出筆跡的工具卻被 PencilKit 畫了一筆 → 刪掉；手繪格線模式下改當成格線
    private func absorbStrayStroke(countBefore: Int, gesture: StrokeGesture?) {
        var d = canvas.drawing
        guard d.strokes.count > countBefore, let stroke = d.strokes.last else { return }
        d.strokes.removeSubrange(countBefore...)
        setDrawing(d)
        // 這一筆不算：拿掉它登記的那一步，不留下按了沒反應的上一步
        if let id = gesture?.step { history.remove(id) }
        guard tool == .tableDraw, let target = tableDrawTarget else { return }
        let pts = stroke.path.map { $0.location.applying(stroke.transform) }
        applyTableStroke(target, points: pts)
    }

    // MARK: - Pages

    func deletePage(_ index: Int) {
        guard pages.count > 1 else {
            showMessage(L("至少要保留一頁"))
            return
        }
        // 移到「最近刪除的頁面」，30 天內可以還原
        performLayoutChange {
            session.trashPage(at: index)
        }
        showToast(L("第 \(index + 1) 頁已移到「頁面 → 最近刪除的頁面」，30 天內可以還原"))
    }

    /// 「⋯ → 清除該頁面所有物件」：先問一次
    func confirmClearPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        let a = UIAlertController(title: L("清除第 \(index + 1) 頁所有物件？"),
                                  message: L("筆跡、螢光筆、文字框、圖片、表格、電路圖都會清掉，頁面和背景留著。可以按「上一步」復原。"),
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        a.addAction(UIAlertAction(title: L("清除"), style: .destructive) { [weak self] _ in self?.clearPage(index) })
        present(a, animated: true)
    }

    /// 清掉一頁上的所有東西（筆跡、螢光標示、自製筆刷筆跡、文字框、圖片、表格、電路圖），一步就能復原。
    /// 頁面本身、背景（PDF、格線）、擴展的大小都不動
    func clearPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        endTextEditing()
        select(nil)
        clearLassoSelection()
        let id = pages[index].id
        DebugLog.add("clear page \(index + 1)")
        recordEdit(drawing: canvas.drawing, pageIDs: [id], newStep: true)
        // PencilKit 的筆跡：和存檔時一樣，看每一筆最靠近哪一頁
        var drawing = canvas.drawing
        drawing.strokes.removeAll { nearestPageIndex(to: $0.renderBounds.center) == index }
        if drawing.strokes.count != canvas.drawing.strokes.count { setDrawing(drawing) }
        updatePage(index, undoable: false) { page in
            page.elements = []
            page.highlights = []
            page.ink = []
        }
        showToast(L("已清除第 \(index + 1) 頁，按「上一步」可以復原"))
    }

    func presentTrashedPages(from source: UIView?) {
        saveNow()
        var host: UIHostingController<TrashedPagesHost>?
        let view = TrashedPagesHost(
            items: TrashedPageItem.make(from: session),
            onRestore: { [weak self] id in
                guard let self else { return }
                var restored: Int?
                self.performLayoutChange { restored = self.session.restoreTrashedPage(id) }
                if let i = restored { self.scrollToPage(i, animated: true) }
                host?.rootView.items = TrashedPageItem.make(from: self.session)
            },
            onDelete: { [weak self] id in
                guard let self else { return }
                self.session.deleteTrashedPage(id)
                self.saveNow()
                host?.rootView.items = TrashedPageItem.make(from: self.session)
            },
            onDone: { host?.dismiss(animated: true) }
        )
        let h = UIHostingController(rootView: view)
        h.modalPresentationStyle = .formSheet
        host = h
        present(h, animated: true)
    }

    func presentExpandSheet(pageIndex: Int? = nil) {
        let i = pageIndex ?? currentPageIndex
        guard pages.indices.contains(i) else { return }
        let page = pages[i]
        let sheet = ExpandPageView(
            insets: page.insets,
            baseSize: session.baseSize(of: page),
            pageNumber: i + 1,
            onApply: { [weak self] insets, all in
                self?.dismiss(animated: true)
                self?.applyInsets(insets, pageIndex: i, toAll: all)
            },
            onCancel: { [weak self] in self?.dismiss(animated: true) }
        )
        let host = UIHostingController(rootView: sheet)
        host.modalPresentationStyle = .formSheet
        present(host, animated: true)
    }

    func applyInsets(_ insets: PageInsets, pageIndex: Int, toAll: Bool) {
        performLayoutChange {
            if toAll {
                for k in session.document.pages.indices { session.document.pages[k].insets = insets }
            } else if session.document.pages.indices.contains(pageIndex) {
                session.document.pages[pageIndex].insets = insets
            }
        }
    }

    /// 匯出：上面打頁碼、下面勾縮圖（兩邊同步），再選格式
    func presentExportChoice(from source: UIView) {
        endTextEditing()
        saveNow()
        let vc = ExportPagesViewController(session: session)
        vc.onExport = { [weak self, weak vc] paperNote, pages in
            vc?.dismiss(animated: true) {
                self?.export(paperNote: paperNote, pages: pages, from: source)
            }
        }
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        nav.preferredContentSize = CGSize(width: 720, height: 820)
        present(nav, animated: true)
    }

    /// pages：要匯出的頁面索引（0 起算，排好）
    func export(paperNote: Bool, pages: [Int], from source: UIView) {
        endTextEditing()
        saveNow()
        do {
            let url = paperNote ? try NotebookExporter.exportPaperNote(session: session, pages: pages)
                                : try NotebookExporter.exportPDF(session: session, pages: pages)
            let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            vc.popoverPresentationController?.sourceView = source
            vc.popoverPresentationController?.sourceRect = source.bounds
            present(vc, animated: true)
        } catch {
            showMessage(L("匯出失敗"), error.localizedDescription)
        }
    }

    // MARK: - Keyboard

    @objc private func keyboardWillChange(_ n: Notification) {
        guard let end = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let local = view.convert(end, from: nil)
        keyboardInset = max(0, canvas.frame.maxY - local.minY)
        updateZoomLayout()
        if let tv = editingTextView {
            canvas.scrollRectToVisible(tv.frame.insetBy(dx: 0, dy: -20), animated: true)
        }
    }

    @objc private func keyboardWillHide(_ n: Notification) {
        keyboardInset = 0
        updateZoomLayout()
    }
}

/// 編輯畫面裡的「最近刪除的頁面」
struct TrashedPagesHost: View {
    var items: [TrashedPageItem]
    let onRestore: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            TrashedPagesList(items: items, onRestore: onRestore, onDelete: onDelete)
                .navigationTitle(L("最近刪除的頁面"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button(L("完成"), action: onDone) }
                }
        }
    }
}
