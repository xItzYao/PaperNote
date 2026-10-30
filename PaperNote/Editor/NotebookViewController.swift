import UIKit
import PencilKit
import PDFKit
import SwiftUI

enum EditorTool: Equatable {
    case pen, highlighter, eraser, lasso, capture, select, image, textSelect, pageResize, tableDraw, circuit

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

enum DragKind {
    case move, resize, colLine(Int), rowLine(Int), cells
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
        get { bool("paletteOnDoubleTap", true) }
        set { d.set(newValue, forKey: "paletteOnDoubleTap") }
    }
    /// 手掌防誤觸："right"（右手寫字）、"left"（左手寫字）、"off"
    var palmRejection: String {
        get { d.string(forKey: "palmRejection") ?? "right" }
        set { d.set(newValue, forKey: "palmRejection") }
    }
    /// 常用筆刷列靠右（左撇子／右撇子）
    var presetsOnRight: Bool {
        get { bool("presetsOnRight", false) }
        set { d.set(newValue, forKey: "presetsOnRight") }
    }
    var captureFreeform: Bool {
        get { bool("captureFreeform", false) }
        set { d.set(newValue, forKey: "captureFreeform") }
    }
    /// 實驗：「筆」改用自製筆刷（照原始取樣點畫，不圓滑；見 InkEngine.swift）
    var customInk: Bool {
        get { bool("customInk", false) }
        set { d.set(newValue, forKey: "customInk") }
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
    let overlay = OverlayView()
    let pinOverlay = PinOverlayView()
    let topBar = UIView()
    let subBar = UIView()
    let subBarStack = UIStackView()
    let pageLabel = UILabel()
    /// 點頁碼後出現的輸入框（輸入要跳到的頁碼）
    var pageJumpField: UITextField?
    var toolButtons: [EditorTool: UIButton] = [:]
    var presetButtons: [UUID: UIButton] = [:]
    /// 筆工具列的「細、中、粗」三個粗細按鈕與虛線開關
    var penWidthButtons: [UIButton] = []
    weak var penDashButton: UIButton?
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
    var saveWorkItem: DispatchWorkItem?
    var keyboardInset: CGFloat = 0

    var tool: EditorTool = .pen
    /// 切到橡皮擦之前的工具（Pencil 點兩下、擦完自動切回時用）
    var toolBeforeEraser: EditorTool = .pen
    /// 自動切到選 PDF 文字之前的工具（選字不在工具列上，用完切回去）
    var toolBeforeTemporary: EditorTool?

    // 手勢
    var toolPan: UIPanGestureRecognizer!
    var tapGesture: UITapGestureRecognizer!
    var doubleTapGesture: UITapGestureRecognizer!
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
    /// 電路元件庫（浮在頁面左邊，見 CircuitLibrary.swift）
    let circuitLibrary = CircuitLibraryView()
    /// 插入圖片工具：下方一排最近的照片
    let photoStrip = PhotoStripView()
    /// 拉過最後一頁底部時出現的＋
    let addPagePull = AddPagePullView()
    /// UI 測試讀得到的除錯資訊（手指按下時卡住的手勢、畫布捲到哪裡）
    var uiTestDump: UILabel?
    var uiTestOffset: UILabel?
    /// PencilKit 開始書寫的時間（收尾後清掉）；下筆時還沒清掉就代表上一筆卡住了
    var pkUsingSince: CFTimeInterval?
    /// 筆身點兩下切到接線前的模式（再點兩下切回來）
    var circuitModeBeforeWire: CircuitMode = .select
    /// 每種元件上次的方向與翻轉，連續擺放時沿用
    var circuitPartStyle: [CircuitPart: (rotation: Int, flipH: Bool, flipV: Bool)] = [:]

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
    var lassoMoveStart: CGPoint?
    var lassoMoveOriginal: PKDrawing?
    var lassoMoveStrokes: [PKStroke] = []
    var lassoMoveElementFrames: [ElementRef: CGRect] = [:]
    var lassoClipboard: LassoClipboard?
    var paletteOverlay: PaletteOverlay?
    var subBarLeftLayout: [NSLayoutConstraint] = []
    var subBarRightLayout: [NSLayoutConstraint] = []

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

    // 橡皮擦擦螢光標示
    var eraserTracker: TouchTracker!
    /// 套索改顏色時的自訂顏色選擇器
    var lassoColorPicker: ColorPickerRelay?
    /// 表格工具列顏色框框打開的顏色選擇器
    var colorPickerRelay: ColorPickerRelay?
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

        if ProcessInfo.processInfo.arguments.contains("-uiTestNotebook") {
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
        }
        DebugLog.watchMainThread()

        computeLayout()
        isApplyingDrawing = true
        canvas.drawing = assembleDrawing()
        isApplyingDrawing = false
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
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.overrideUserInterfaceStyle = .light
        canvas.bouncesZoom = true
        view.addSubview(canvas)
        canvas.layer.addSublayer(holdToShape.previewLayer)

        pagesContainer.backgroundColor = .clear
        overlay.frame = .zero
        pagesContainer.addSubview(overlay)
        canvas.insertSubview(pagesContainer, at: 0)

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
            configurePencilKitGestures()
            pinOverlay.reload()
            if let pid = initialPageID, let i = pageIndex(of: pid) {
                scrollToPage(i, animated: false)
            }
            updateVisiblePages()
            updatePageIndicator()
        } else if abs(w - lastLayoutWidth) > 1 {
            let relative = canvas.zoomScale / fitZoom
            let anchor = currentPageIndex
            lastLayoutWidth = w
            updateZoomLimits(resetZoom: false)
            canvas.zoomScale = min(max(fitZoom * relative, canvas.minimumZoomScale), canvas.maximumZoomScale)
            updateZoomLayout()
            scrollToPage(anchor, animated: false)
            pinOverlay.clampAll()
        }
    }

    @objc private func appWillResignActive() {
        endTextEditing()
        saveNow()
    }

    @objc func titleLongPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let alert = UIAlertController(title: "筆記本名稱", message: nil, preferredStyle: .alert)
        alert.addTextField { [weak self] tf in
            tf.text = self?.session.title
            tf.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "儲存", style: .default) { [weak self, weak alert] _ in
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

    func visibleDocRect() -> CGRect { canvas.convert(canvas.bounds, to: pagesContainer) }

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

    func updateZoomLayout() {
        let z = canvas.zoomScale
        pagesContainer.transform = .identity
        pagesContainer.bounds = CGRect(origin: .zero, size: docSize)
        pagesContainer.transform = CGAffineTransform(scaleX: z, y: z)
        pagesContainer.center = CGPoint(x: docSize.width * z / 2, y: docSize.height * z / 2)
        overlay.frame = CGRect(origin: .zero, size: docSize)
        overlay.lineScale = 1 / z
        let size = CGSize(width: docSize.width * z, height: docSize.height * z)
        if canvas.contentSize != size { canvas.contentSize = size }
        let side = max(0, (canvas.bounds.width - size.width) / 2)
        if canvas.contentInset.left != side || canvas.contentInset.right != side || canvas.contentInset.bottom != bottomInset {
            canvas.contentInset = UIEdgeInsets(top: 0, left: side, bottom: bottomInset, right: side)
        }
        updateSelectionChrome()
        updatePageResizeChrome()
        updateVisiblePages()
    }

    /// 畫布底下的留白：鍵盤擋住的高度；擴展頁面時再多留半個畫面，才拉得到最後一頁下緣的控制點
    var bottomInset: CGFloat {
        keyboardInset + (tool == .pageResize ? max(200, canvas.bounds.height * 0.5) : 0)
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

    func updateVisiblePages() {
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
                let v = PageContainerView(pageID: page.id)
                v.frame = pageFrames[i]
                v.configure(page: page, session: session, contentScale: elementContentScale)
                pagesContainer.insertSubview(v, belowSubview: overlay)
                pageViews[page.id] = v
            }
            i += 1
        }
        for (id, v) in pageViews where !keep.contains(id) {
            v.removeFromSuperview()
            pageViews[id] = nil
        }
    }

    func refreshPage(_ i: Int) {
        guard let page = pages[safe: i], let v = pageViews[page.id] else { return }
        v.frame = pageFrames[i]
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
        updateVisiblePages()
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
        updateZoomLayout()
        let s = elementContentScale
        for v in pageViews.values { v.inkView.setRenderScale(s) }
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        DebugLog.add("zoom begin")
        endTextEditing()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        DebugLog.add("zoom end x\(String(format: "%.2f", scale / max(fitZoom, 0.01)))")
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

    func splitDrawing(_ drawing: PKDrawing) -> [UUID: PKDrawing] {
        var buckets: [Int: [PKStroke]] = [:]
        for s in drawing.strokes {
            let i = nearestPageIndex(to: s.renderBounds.center)
            buckets[i, default: []].append(s)
        }
        var result: [UUID: PKDrawing] = [:]
        for (i, strokes) in buckets where pages.indices.contains(i) {
            let o = contentOrigin(i)
            result[pages[i].id] = PKDrawing(strokes: strokes).transformed(using: CGAffineTransform(translationX: -o.x, y: -o.y))
        }
        return result
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

    func setDrawing(_ d: PKDrawing) {
        isApplyingDrawing = true
        canvas.drawing = d
        isApplyingDrawing = false
        scheduleSave()
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
        isApplyingDrawing = true
        canvas.drawing = assembleDrawing()
        isApplyingDrawing = false
        history.removeAll()
        for v in pageViews.values { v.removeFromSuperview() }
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

    func commitDrawing() {
        session.drawings = splitDrawing(canvas.drawing)
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

    /// 記下一步：筆跡回到 drawing（nil＝沒動到筆跡）、這些頁面回到現在的樣子。在改動之前呼叫
    func recordEdit(drawing: PKDrawing?, pageIDs: [UUID]) {
        var snaps: [UUID: PageContentSnapshot] = [:]
        for id in pageIDs {
            if let i = pageIndex(of: id) { snaps[id] = PageContentSnapshot(pages[i]) }
        }
        history.record(.init(drawing: drawing, pages: snaps))
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

    @objc func undoTapped() {
        endTextEditing()
        if holdToShape.undo() { return }
        // 手繪新表格還沒完成：上一步＝收回最後畫的那條線
        if tool == .tableDraw, tableDrawTarget == nil, tableDraft != nil {
            undoTableDivider()
            return
        }
        _ = history.undo(capture: currentEditState, apply: restoreEditState)
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
        guard !isApplyingDrawing else { return }
        recordStrokeGesture(strokeGesture)
        holdToShape.drawingChanged()
        scheduleSave()
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        pkUsingSince = CACurrentMediaTime()
        holdToShape.pencilKitBegan()
        strokeGesture = StrokeGesture(before: canvas.drawing, mark: history.recordCount)
        // 下筆就關掉工具列的小視窗（粗細、虛線、筆刷設定）
        dismissToolPopover()
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
        if tool == .eraser && settings.eraserAutoReturn {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.tool == .eraser else { return }
                self.setTool(self.toolBeforeEraser)
            }
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
            showMessage("至少要保留一頁")
            return
        }
        // 移到「最近刪除的頁面」，30 天內可以還原
        performLayoutChange {
            session.trashPage(at: index)
        }
        showToast("第 \(index + 1) 頁已移到「頁面 → 最近刪除的頁面」，30 天內可以還原")
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

    /// 匯出：畫面中間跳出小視窗選格式
    func presentExportChoice(from source: UIView) {
        let alert = UIAlertController(title: "匯出「\(session.title)」", message: "要匯出成哪一種格式？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "PDF（給別人看、列印）", style: .default) { [weak self] _ in
            self?.export(paperNote: false, from: source)
        })
        alert.addAction(UIAlertAction(title: "PaperNote（可以繼續編輯筆跡）", style: .default) { [weak self] _ in
            self?.export(paperNote: true, from: source)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    func export(paperNote: Bool, from source: UIView) {
        endTextEditing()
        saveNow()
        do {
            let url = paperNote ? try NotebookExporter.exportPaperNote(session: session) : try NotebookExporter.exportPDF(session: session)
            let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            vc.popoverPresentationController?.sourceView = source
            vc.popoverPresentationController?.sourceRect = source.bounds
            present(vc, animated: true)
        } catch {
            showMessage("匯出失敗", error.localizedDescription)
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
                .navigationTitle("最近刪除的頁面")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成", action: onDone) }
                }
        }
    }
}
