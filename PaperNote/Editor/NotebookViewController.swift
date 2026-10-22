import UIKit
import PencilKit
import PDFKit
import SwiftUI

enum EditorTool: Equatable {
    case pen, highlighter, eraser, lasso, capture, select, textSelect, pageResize, tableDraw

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
}

struct DragState {
    var ref: ElementRef
    var kind: DragKind
    var start: CGPoint
    var original: PageElement
}

/// 停住約 0.5 秒後的即時直線／圖形
struct LiveShape {
    var start: CGPoint
    var end: CGPoint
    var shapePoints: [CGPoint]?   // 有值＝封閉圖形；nil＝直線
    var preset: BrushPreset
    var countBefore: Int

    var points: [CGPoint] { shapePoints ?? ShapeRecognizer.segment(start, end) }
}

struct TextSelectionState {
    var pageIndex: Int
    var text: String
    var docRects: [CGRect]
}

final class EditorSettings {
    static let shared = EditorSettings()
    private let d = UserDefaults.standard

    private func bool(_ key: String, _ def: Bool) -> Bool { d.object(forKey: key) as? Bool ?? def }

    var fingerDrawing: Bool {
        get { bool("fingerDrawing", false) }
        set { d.set(newValue, forKey: "fingerDrawing") }
    }
    var shapeSnap: Bool {
        get { bool("shapeSnap", true) }
        set { d.set(newValue, forKey: "shapeSnap") }
    }
    var smartHighlight: Bool {
        get { bool("smartHighlight", true) }
        set { d.set(newValue, forKey: "smartHighlight") }
    }
    var pixelEraser: Bool {
        get { bool("pixelEraser", false) }
        set { d.set(newValue, forKey: "pixelEraser") }
    }
    var eraserWidth: CGFloat {
        get { d.object(forKey: "eraserWidth") as? CGFloat ?? 16 }
        set { d.set(newValue, forKey: "eraserWidth") }
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
    /// 常用筆刷列靠右（左撇子／右撇子）
    var presetsOnRight: Bool {
        get { bool("presetsOnRight", false) }
        set { d.set(newValue, forKey: "presetsOnRight") }
    }
    var captureFreeform: Bool {
        get { bool("captureFreeform", false) }
        set { d.set(newValue, forKey: "captureFreeform") }
    }
}

/// 筆記本編輯畫面。整本筆記本是一張長畫布（一個 PKCanvasView），頁面背景與物件放在筆跡底下。
final class NotebookViewController: UIViewController, PKCanvasViewDelegate {
    let session: NotebookSession
    let initialPageID: UUID?
    let onClose: () -> Void
    let settings = EditorSettings.shared

    let canvas = PKCanvasView()
    let pagesContainer = UIView()
    let overlay = OverlayView()
    let pinOverlay = PinOverlayView()
    let topBar = UIView()
    let subBar = UIView()
    let subBarStack = UIStackView()
    let pageLabel = UILabel()
    var toolButtons: [EditorTool: UIButton] = [:]
    var presetButtons: [UUID: UIButton] = [:]
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

    // 手勢
    var toolPan: UIPanGestureRecognizer!
    var tapGesture: UITapGestureRecognizer!
    var doubleTapGesture: UITapGestureRecognizer!
    var longPressGesture: UILongPressGestureRecognizer!
    var holdRecognizer: PencilHoldRecognizer!
    var textLongPress: UILongPressGestureRecognizer!
    var pencilPointTracker: TouchTracker!
    var lastPencilPoint: CGPoint?
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
    weak var tableCellLabel: UILabel?

    // 橡皮擦擦螢光標示
    var eraserTracker: TouchTracker!
    var liveShape: LiveShape?
    var editMenu: UIEditMenuInteraction!
    var pendingMenu: UIMenu?

    // 選取物件
    var selected: ElementRef?
    var dragState: DragState?
    var clipboardElement: (element: PageElement, changeCount: Int)?
    var editingTextView: UITextView?
    var editingTarget: (ref: ElementRef, cell: (row: Int, col: Int)?)?

    // PDF 文字選取
    var textSelection: TextSelectionState?
    var textPanStart: CGPoint?

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
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.alwaysBounceVertical = true
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.overrideUserInterfaceStyle = .light
        canvas.bouncesZoom = true
        view.addSubview(canvas)

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
        docSize = CGSize(width: docW, height: y - pageGap + docPadding + 200)
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
        if canvas.contentInset.left != side || canvas.contentInset.right != side || canvas.contentInset.bottom != keyboardInset {
            canvas.contentInset = UIEdgeInsets(top: 0, left: side, bottom: keyboardInset, right: side)
        }
        updateSelectionChrome()
        updatePageResizeChrome()
        updateVisiblePages()
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
        updateVisiblePages()
        updatePageIndicator()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateZoomLayout()
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        endTextEditing()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
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
        canvas.undoManager?.removeAllActions()
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
    }

    func updatePage(_ i: Int, undoable: Bool = true, _ change: (inout Page) -> Void) {
        guard pages.indices.contains(i) else { return }
        let old = pages[i]
        change(&session.document.pages[i])
        let new = pages[i]
        guard old != new else { return }
        if undoable {
            registerUndo(pageID: old.id, restore: PageContentSnapshot(elements: old.elements, highlights: old.highlights))
        }
        refreshPage(i)
        scheduleSave()
    }

    private func registerUndo(pageID: UUID, restore: PageContentSnapshot) {
        canvas.undoManager?.registerUndo(withTarget: self) { vc in
            guard let i = vc.pageIndex(of: pageID) else { return }
            let current = vc.pages[i]
            vc.registerUndo(pageID: pageID, restore: PageContentSnapshot(elements: current.elements, highlights: current.highlights))
            vc.session.document.pages[i].elements = restore.elements
            vc.session.document.pages[i].highlights = restore.highlights
            if let sel = vc.selected, vc.locate(sel) == nil { vc.select(nil) }
            vc.refreshPage(i)
            vc.scheduleSave()
        }
    }

    @objc func undoTapped() {
        endTextEditing()
        canvas.undoManager?.undo()
    }

    @objc func redoTapped() {
        endTextEditing()
        canvas.undoManager?.redo()
    }

    // MARK: - PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isApplyingDrawing else { return }
        scheduleSave()
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        // 開始寫字 → 收起還沒點的調色盤小圖示
        if let p = paletteOverlay, p.mode == .launcher { dismissPalette() }
        toolBeganAt = CACurrentMediaTime()
        strokeCountAtBegin = canvas.drawing.strokes.count
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        if liveShape != nil { return }
        if !tool.isDrawing {
            let before = strokeCountAtBegin
            DispatchQueue.main.async { [weak self] in self?.absorbStrayStroke(countBefore: before) }
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
            self?.processNewStroke(duration: duration, countBefore: before)
        }
    }

    private func processNewStroke(duration: TimeInterval, countBefore: Int) {
        var drawing = canvas.drawing
        guard drawing.strokes.count == countBefore + 1, let stroke = drawing.strokes.last else { return }
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

    /// 不該畫出筆跡的工具卻被 PencilKit 畫了一筆 → 刪掉；手繪格線模式下改當成格線
    private func absorbStrayStroke(countBefore: Int) {
        var d = canvas.drawing
        guard d.strokes.count > countBefore, let stroke = d.strokes.last else { return }
        d.strokes.removeSubrange(countBefore...)
        setDrawing(d)
        guard tool == .tableDraw, let target = tableDrawTarget else { return }
        let pts = stroke.path.map { $0.location.applying(stroke.transform) }
        if let a = pts.first, let b = pts.last { applyTableStroke(target, from: a, to: b) }
    }

    // MARK: - 停住變直線

    func beginLiveShape(_ pts: [CGPoint]) {
        guard tool.isInking, let start = pts.first, let last = pts.last else { return }
        let preset = BrushStore.shared.current
        let shape = ShapeRecognizer.closedShapePoints(pts)
        liveShape = LiveShape(start: start, end: ShapeRecognizer.snappedLineEnd(from: start, to: last),
                              shapePoints: shape, preset: preset, countBefore: strokeCountAtBegin)
        // 中斷 PencilKit 正在畫的那一筆，改由預覽線接手
        canvas.drawingGestureRecognizer.isEnabled = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showLiveShapePreview()
    }

    func updateLiveShape(_ p: CGPoint) {
        guard var ls = liveShape, ls.shapePoints == nil else { return }
        ls.end = ShapeRecognizer.snappedLineEnd(from: ls.start, to: p)
        liveShape = ls
        showLiveShapePreview()
    }

    func endLiveShape(_ p: CGPoint, cancelled: Bool) {
        guard var ls = liveShape else { return }
        liveShape = nil
        canvas.drawingGestureRecognizer.isEnabled = tool.isDrawing
        if ls.shapePoints == nil { ls.end = ShapeRecognizer.snappedLineEnd(from: ls.start, to: p) }
        guard !cancelled || ls.shapePoints != nil || ls.start.distance(to: ls.end) > 4 else {
            overlay.showLiveShape(nil, color: .clear, width: 0)
            return
        }
        // 等 PencilKit 處理完被中斷的那一筆再放上去，否則會被它蓋掉；預覽線留到放上去為止
        commitLiveStroke(ShapeRecognizer.makeStroke(points: ls.points, preset: ls.preset), countBefore: ls.countBefore, attempt: 0)
    }

    /// 把直線／圖形放進筆跡；之後再確認一次，被 PencilKit 蓋掉就補回去
    private func commitLiveStroke(_ stroke: PKStroke, countBefore: Int, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.08 : 0.3)) { [weak self] in
            guard let self else { return }
            let date = stroke.path.creationDate
            var d = self.canvas.drawing
            if !d.strokes.contains(where: { $0.path.creationDate == date }) {
                // 移除被中斷的那一筆手繪線（比直線早建立的），之後才畫的新筆跡保留
                var kept = Array(d.strokes.prefix(countBefore))
                kept += d.strokes.dropFirst(countBefore).filter { $0.path.creationDate > date }
                kept.append(stroke)
                d.strokes = kept
                self.setDrawing(d)
            }
            self.overlay.showLiveShape(nil, color: .clear, width: 0)
            if attempt < 2 { self.commitLiveStroke(stroke, countBefore: countBefore, attempt: attempt + 1) }
        }
    }

    private func showLiveShapePreview() {
        guard let ls = liveShape else { return }
        let color = ls.preset.inkColor
        overlay.showLiveShape(ls.points, color: color, width: ls.preset.width)
    }

    // MARK: - Pages

    func addBlankPage(at index: Int) {
        let refIndex = min(max(0, index - 1), pages.count - 1)
        let ref = pages[refIndex]
        let size = session.baseSize(of: ref)
        var style: PaperStyle = .blank
        if case let .paper(_, _, s) = ref.background { style = s }
        let newPage = Page(background: .paper(width: size.width, height: size.height, style: style))
        performLayoutChange {
            session.document.pages.insert(newPage, at: index)
        }
        scrollToPage(index, animated: true)
    }

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

    func presentJumpToPage() {
        let a = UIAlertController(title: "跳到頁碼", message: "共 \(pages.count) 頁", preferredStyle: .alert)
        a.addTextField { tf in
            tf.keyboardType = .numberPad
            tf.placeholder = "頁碼"
        }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "前往", style: .default) { [weak self, weak a] _ in
            guard let self, let n = Int(a?.textFields?.first?.text ?? "") else { return }
            self.scrollToPage(min(max(n, 1), self.pages.count) - 1, animated: true)
        })
        present(a, animated: true)
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

    func exportPDF(from source: UIView) {
        endTextEditing()
        saveNow()
        do {
            let url = try NotebookExporter.exportPDF(session: session)
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
