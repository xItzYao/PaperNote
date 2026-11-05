import UIKit
import PencilKit
import SwiftUI
import PhotosUI

extension NotebookViewController {
    // MARK: - Bars

    func setupBars() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.backgroundColor = UIColor(white: 0.985, alpha: 1)
        subBar.translatesAutoresizingMaskIntoConstraints = false
        subBar.backgroundColor = UIColor(white: 0.96, alpha: 1)
        view.addSubview(topBar)
        view.addSubview(subBar)

        let sep = UIView()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.backgroundColor = UIColor(white: 0.82, alpha: 1)
        view.addSubview(sep)

        canvasBelowBars = canvas.topAnchor.constraint(equalTo: sep.bottomAnchor)
        canvasFullHeight = canvas.topAnchor.constraint(equalTo: view.topAnchor)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 50),
            subBar.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            subBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            subBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            subBar.heightAnchor.constraint(equalToConstant: 44),
            sep.topAnchor.constraint(equalTo: subBar.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 0.5),
            canvasBelowBars,
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // 電路元件庫：浮在畫布下面（「⋯」可以改放左邊），只在電路工具顯示
        circuitLibrary.install(in: view, top: canvas.topAnchor, onLeft: settings.circuitLibraryOnLeft)
        circuitLibrary.isHidden = true
        circuitLibrary.onLayoutChange = { [weak self] in
            guard let self else { return }
            self.canvas.contentInset.bottom = self.bottomInset
        }
        circuitLibrary.onSelectMode = { [weak self] mode in self?.selectCircuitMode(mode) }
        circuitLibrary.onDropCustom = { [weak self] id, p in self?.dropCustomCircuit(id, at: p) }
        circuitLibrary.onAddCustom = { [weak self] in self?.addSelectionToCustomCircuits() }
        circuitLibrary.onDrawSymbol = { [weak self] id in self?.presentSymbolEditor(editing: id) }
        circuitLibrary.onRenameCustom = { [weak self] id in self?.promptRenameCustomCircuit(id) }
        circuitLibrary.onDeleteCustom = { [weak self] id in self?.deleteCustomCircuit(id) }

        // 插入圖片：一排照片浮在畫布下方，只在圖片工具顯示
        photoStrip.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(photoStrip)
        photoStrip.isHidden = true
        NSLayoutConstraint.activate([
            photoStrip.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            photoStrip.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            photoStrip.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            photoStrip.heightAnchor.constraint(equalToConstant: PhotoStripView.height),
        ])
        photoStrip.presenter = self
        photoStrip.onPick = { [weak self] img in self?.insertPhotoFromStrip(img) }
        photoStrip.onBrowse = { [weak self] in self?.presentPhotoPicker() }
        circuitLibrary.onDrop = { [weak self] part, p in self?.dropCircuitPart(part, at: p) }

        // 安全區頂端也塗上底色
        let topFill = UIView()
        topFill.translatesAutoresizingMaskIntoConstraints = false
        topFill.backgroundColor = topBar.backgroundColor
        view.insertSubview(topFill, belowSubview: topBar)
        NSLayoutConstraint.activate([
            topFill.topAnchor.constraint(equalTo: view.topAnchor),
            topFill.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topFill.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topFill.bottomAnchor.constraint(equalTo: topBar.topAnchor),
        ])
        barChrome = [topFill, topBar, subBar, sep]
        setupPreviewExitButton()

        // 左：標題（回資料庫用分頁列最左邊的「<」）；長按看完整名稱、改名
        let titleLabel = UILabel()
        titleLabel.text = session.title
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.isUserInteractionEnabled = true
        titleLabel.accessibilityHint = L("長按可以看完整名稱、改名")
        titleLabel.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(titleLongPressed(_:))))
        notebookTitleLabel = titleLabel
        let left = UIStackView(arrangedSubviews: [titleLabel])
        left.spacing = 6
        left.alignment = .center

        // 中：工具
        let center = UIStackView()
        center.spacing = 4
        for (t, symbol, label) in Self.toolbarTools {
            let b = makeButton(symbol: symbol, title: nil, action: nil)
            b.accessibilityLabel = label
            b.addAction(UIAction { [weak self] _ in self?.setTool(t) }, for: .touchUpInside)
            toolButtons[t] = b
            center.addArrangedSubview(b)
        }
        let insert = makeButton(symbol: "plus.circle", title: nil, action: nil)
        insertButton = insert
        insert.accessibilityLabel = L("插入")
        insert.menu = makeInsertMenu()
        insert.showsMenuAsPrimaryAction = true
        center.addArrangedSubview(insert)

        // 右：復原、最愛、頁面、設定
        let undo = makeButton(symbol: "arrow.uturn.backward", title: nil, action: #selector(undoTapped))
        let redo = makeButton(symbol: "arrow.uturn.forward", title: nil, action: #selector(redoTapped))
        undo.accessibilityLabel = L("上一步")
        redo.accessibilityLabel = L("下一步")
        favoriteButton = makeButton(symbol: "star", title: nil, action: #selector(favoriteTapped))
        let favList = makeButton(symbol: "list.star", title: nil, action: nil)
        favList.addAction(UIAction { [weak self, weak favList] _ in
            guard let self, let favList else { return }
            self.presentFavoritesList(from: favList)
        }, for: .touchUpInside)
        let overview = makeButton(symbol: "square.grid.2x2", title: nil, action: nil)
        overview.accessibilityLabel = L("全部頁面")
        overview.addAction(UIAction { [weak self] _ in self?.presentPageOverview() }, for: .touchUpInside)
        let pageMenu = makeButton(symbol: "doc.on.doc", title: nil, action: nil)
        pageMenu.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.makePageMenuItems() ?? [])
        }])
        pageMenu.showsMenuAsPrimaryAction = true
        settingsButton = makeButton(symbol: "ellipsis.circle", title: nil, action: nil)
        settingsButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.makeSettingsMenuItems() ?? [])
        }])
        settingsButton.showsMenuAsPrimaryAction = true
        let export = makeButton(symbol: "square.and.arrow.up", title: nil, action: nil)
        export.accessibilityLabel = L("匯出")
        export.addAction(UIAction { [weak self, weak export] _ in
            guard let self, let export else { return }
            self.presentExportChoice(from: export)
        }, for: .touchUpInside)
        let right = UIStackView(arrangedSubviews: [undo, redo, favoriteButton, favList, overview, pageMenu, export, settingsButton])
        right.spacing = 2

        for s in [left, center, right] {
            s.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(s)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 8),
            left.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: center.leadingAnchor, constant: -8),
            center.centerXAnchor.constraint(equalTo: topBar.centerXAnchor).withPriority(.defaultHigh),
            center.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: center.trailingAnchor, constant: 8),
            right.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -8),
            right.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
        ])

        // 第二列：依工具變化
        subBarStack.axis = .horizontal
        subBarStack.spacing = 8
        subBarStack.alignment = .center
        subBarStack.translatesAutoresizingMaskIntoConstraints = false
        subBar.addSubview(subBarStack)
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        pageLabel.textColor = .secondaryLabel
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        // 點頁碼：直接輸入要跳到的頁碼
        pageLabel.isUserInteractionEnabled = true
        pageLabel.accessibilityIdentifier = "pageIndicator"
        pageLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(pageLabelTapped)))
        subBar.addSubview(pageLabel)
        pageLabel.textAlignment = .right
        // 第二列置中（在最左邊很難按）；放不下時往左延伸，不蓋到右邊的頁碼
        let centered = subBarStack.centerXAnchor.constraint(equalTo: subBar.centerXAnchor)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            subBarStack.centerYAnchor.constraint(equalTo: subBar.centerYAnchor),
            pageLabel.centerYAnchor.constraint(equalTo: subBar.centerYAnchor),
            // 頁碼固定留到 5 位數（99999 / 99999）的寬度：工具列可以一直延伸到這裡，頁數變多也不會跳動
            pageLabel.widthAnchor.constraint(equalToConstant: Self.pageLabelWidth),
            pageLabel.trailingAnchor.constraint(equalTo: subBar.trailingAnchor, constant: -16),
            centered,
            subBarStack.leadingAnchor.constraint(greaterThanOrEqualTo: subBar.leadingAnchor, constant: 12),
            subBarStack.trailingAnchor.constraint(lessThanOrEqualTo: pageLabel.leadingAnchor, constant: -12),
        ])
    }

    /// 工具列中間的工具（Pencil Pro 按壓也從這裡選）
    static let toolbarTools: [(EditorTool, String, String)] = [
        (.pen, "pencil.tip", L("筆")),
        (.highlighter, "highlighter", L("螢光筆")),
        (.eraser, "eraser", L("橡皮擦")),
        (.lasso, "lasso", L("套索")),
        (.capture, "camera.viewfinder", L("截圖")),
        (.select, "hand.point.up.left", L("選取")),
        (.image, "photo", L("圖片")),
        (.pageResize, "arrow.up.left.and.arrow.down.right", L("擴展")),
        (.circuit, "bolt", L("電路")),
    ]

    static var pageLabelWidth: CGFloat {
        let font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        return ceil(("99999 / 99999" as NSString).size(withAttributes: [.font: font]).width)
    }

    func makeButton(symbol: String, title: String?, action: Selector?) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        config.title = title
        config.imagePadding = 4
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        config.baseForegroundColor = .label
        // 文字固定單行，不被擠成直排
        config.titleLineBreakMode = .byClipping
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 15, weight: .regular)
            return a
        }
        let b = UIButton(configuration: config)
        if let action { b.addTarget(self, action: action, for: .touchUpInside) }
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        b.titleLabel?.numberOfLines = 1
        return b
    }

    // MARK: - Tools

    func setTool(_ t: EditorTool) {
        DebugLog.add("tool \(tool) -> \(t)")
        endTextEditing()
        dismissToolPopover()
        if t != tool {
            clearTextSelection()
            clearCapture()
            if t != .select { select(nil) }
            tableDraft = nil
            tableDraftStart = nil
            tableDrawTarget = nil
            tableEraseLines = false
            resizeDrag = nil
            clearLassoSelection()
            circuitSel = nil
            circuitMode = .select
            wireDraft = nil
            overlay.showCircuitDraft(nil, ink: nil)
            clearCircuitErasing()
            if circuitMarquee != nil {
                circuitMarquee = nil
                overlay.showLassoPath(nil)
            }
        }
        if t == .pageResize, resizePageIndex == nil || t != tool { resizePageIndex = currentPageIndex }
        if t == .eraser, tool.isInking || tool == .lasso { toolBeforeEraser = tool }
        // 選 PDF 文字不在工具列上：記住從哪個工具切過來，用完切回去
        if t != .textSelect {
            toolBeforeTemporary = nil
        } else if tool != .textSelect {
            toolBeforeTemporary = tool
        }
        tool = t
        applyTool()
        updateSelectionChrome()
        updatePageResizeChrome()
        updateTableDraftChrome()
        updateCircuitChrome()
    }

    // MARK: - 預覽模式

    private func setupPreviewExitButton() {
        var c = UIButton.Configuration.filled()
        c.image = UIImage(systemName: "eye.slash")
        c.title = L("結束預覽")
        c.imagePadding = 4
        c.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        c.baseForegroundColor = .white
        c.cornerStyle = .capsule
        previewExitButton.configuration = c
        previewExitButton.translatesAutoresizingMaskIntoConstraints = false
        previewExitButton.isHidden = true
        previewExitButton.addAction(UIAction { [weak self] _ in self?.setPreviewMode(false) }, for: .touchUpInside)
        view.addSubview(previewExitButton)
        NSLayoutConstraint.activate([
            previewExitButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            previewExitButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
    }

    /// 預覽模式：工具列、貼圖收起來，頁面佔滿畫面，只能捲動、縮放（筆跡還是看得到）
    func setPreviewMode(_ on: Bool) {
        guard on != previewMode else { return }
        let oldTop = canvas.frame.minY
        if on {
            toolBeforePreview = tool
            setTool(.select)
        }
        previewMode = on
        barChrome.forEach { $0.isHidden = on }
        pinOverlay.isHidden = on
        previewExitButton.isHidden = !on
        canvasBelowBars.isActive = false
        canvasFullHeight.isActive = false
        (on ? canvasFullHeight : canvasBelowBars)?.isActive = true
        if on { applyTool() } else { setTool(toolBeforePreview) }
        view.layoutIfNeeded()
        // 畫布變高或變矮：頁面留在畫面上原本的位置
        let maxY = max(0, canvas.contentSize.height + canvas.contentInset.bottom - canvas.bounds.height)
        canvas.contentOffset.y = min(max(0, canvas.contentOffset.y + oldTop - canvas.frame.minY), maxY)
    }

    func applyTool() {
        canvas.drawingGestureRecognizer.isEnabled = tool.isDrawing && !previewMode
        circuitLibrary.isHidden = tool != .circuit
        photoStrip.isHidden = tool != .image
        if tool == .image { photoStrip.reload() }
        if tool.isInking { BrushStore.shared.activeCategory = tool == .highlighter ? .highlighter : .pen }
        switch tool {
        case .pen, .highlighter:
            setCanvasTool(BrushStore.shared.current.tool)
        case .eraser:
            canvas.tool = settings.pixelEraser ? PKEraserTool(.bitmap, width: settings.eraserWidth) : PKEraserTool(.vector)
        case .lasso:
            canvas.tool = PKLassoTool()
        default:
            break
        }
        canvas.drawingPolicy = settings.fingerDrawing ? .anyInput : .pencilOnly
        canvas.contentInset.bottom = bottomInset
        applyInkEngine()

        for (t, b) in toolButtons {
            var c = b.configuration ?? .plain()
            c.background.backgroundColor = t == tool ? UIColor.systemBlue.withAlphaComponent(0.15) : .clear
            c.baseForegroundColor = t == tool ? .systemBlue : .label
            c.background.cornerRadius = 8
            // UIButton 換 configuration 時預設會淡入淡出：工具切換要馬上變色
            UIView.performWithoutAnimation {
                b.configuration = c
                b.layoutIfNeeded()
            }
        }
        rebuildSubBar()
        scrollCurrentPresetIntoView()
    }

    /// 筆用自製筆刷還是 PencilKit 畫（看工具和目前的筆型）：換筆、改筆型後也要重新設定
    func applyInkEngine() {
        // 只有開啟「用手指書寫」時，手指才用來截圖、選字、畫表格線、圈選；否則單指捲動
        let fingerUsedByTool = settings.fingerDrawing && (tool.drawsWithPan || customInkActive)
        canvas.panGestureRecognizer.minimumNumberOfTouches = fingerUsedByTool ? 2 : 1
        updateGestureAvailability()
        configurePencilKitGestures()
    }

    func rebuildSubBar() {
        // 小視窗依附的按鈕要被拿掉了，先關掉
        dismissToolPopover()
        subBarStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        presetButtons = [:]
        penWidthButtons = []
        switch tool {
        case .pen, .highlighter:
            subBarStack.addArrangedSubview(makePresetStrip())
            // 新增緊接在常用筆刷的右邊
            let add = makeButton(symbol: "plus", title: nil, action: nil)
            add.accessibilityLabel = L("新增常用筆刷")
            add.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                let p = BrushStore.shared.add(basedOn: BrushStore.shared.current)
                self.applyTool()
                if let b = self.presetButtons[p.id] { self.presentBrushSettings(p, from: b) }
            }, for: .touchUpInside)
            subBarStack.addArrangedSubview(add)
            if tool == .pen {
                subBarStack.addArrangedSubview(toolbarSeparator())
                for v in penStyleControls() { subBarStack.addArrangedSubview(v) }
                subBarStack.addArrangedSubview(toolbarSeparator())
                let ruler = makeButton(symbol: "ruler", title: nil, action: nil)
                ruler.accessibilityLabel = L("尺規")
                ruler.addAction(UIAction { [weak self] _ in self?.canvas.isRulerActive.toggle() }, for: .touchUpInside)
                subBarStack.addArrangedSubview(ruler)
                return
            }
            if tool == .highlighter {
                // 螢光筆也可以像筆一樣選細、中、粗（再點一次或長按調整 pt）
                subBarStack.addArrangedSubview(toolbarSeparator())
                for v in penStyleControls(dash: false) { subBarStack.addArrangedSubview(v) }
            }
            let edit = makeButton(symbol: "slider.horizontal.3", title: nil, action: nil)
            edit.accessibilityLabel = L("調整筆刷")
            edit.addAction(UIAction { [weak self, weak edit] _ in
                guard let self, let edit else { return }
                self.presentBrushSettings(BrushStore.shared.current, from: edit)
            }, for: .touchUpInside)
            let ruler = makeButton(symbol: "ruler", title: nil, action: nil)
            ruler.accessibilityLabel = L("尺規")
            ruler.addAction(UIAction { [weak self] _ in self?.canvas.isRulerActive.toggle() }, for: .touchUpInside)
            subBarStack.addArrangedSubview(edit)
            subBarStack.addArrangedSubview(ruler)

        case .eraser:
            let kind = UISegmentedControl(items: [L("整筆擦除"), L("局部擦除")])
            kind.selectedSegmentIndex = settings.pixelEraser ? 1 : 0
            kind.addAction(UIAction { [weak self, weak kind] _ in
                self?.settings.pixelEraser = kind?.selectedSegmentIndex == 1
                self?.applyTool()
            }, for: .valueChanged)
            subBarStack.addArrangedSubview(kind)
            if settings.pixelEraser {
                // 三個大小：小圓、中圓、大圓（中間透明、灰色外框）
                let sizes = EditorSettings.eraserSizes
                let icons = [9, 14, 20].map { d -> UIImage in
                    let size = CGSize(width: 22, height: 22)
                    return UIGraphicsImageRenderer(size: size).image { _ in
                        let r = CGFloat(d)
                        let ring = UIBezierPath(ovalIn: CGRect(x: (size.width - r) / 2, y: (size.height - r) / 2, width: r, height: r))
                        ring.lineWidth = 1.5
                        UIColor.systemGray.setStroke()
                        ring.stroke()
                    }.withRenderingMode(.alwaysOriginal)
                }
                let size = UISegmentedControl(items: icons)
                for (i, name) in [L("小"), L("中"), L("大")].enumerated() { icons[i].accessibilityLabel = L("橡皮擦\(name)") }
                size.selectedSegmentIndex = sizes.firstIndex(of: settings.eraserWidth) ?? 1
                size.addAction(UIAction { [weak self, weak size] _ in
                    guard let i = size?.selectedSegmentIndex, sizes.indices.contains(i) else { return }
                    self?.settings.eraserWidth = sizes[i]
                    self?.applyTool()
                }, for: .valueChanged)
                subBarStack.addArrangedSubview(size)
            }
            let autoLabel = hintLabel(L("自動切回筆"))
            autoLabel.textColor = .label
            let autoSwitch = UISwitch()
            autoSwitch.isOn = settings.eraserAutoReturn
            autoSwitch.addAction(UIAction { [weak self, weak autoSwitch] _ in
                self?.settings.eraserAutoReturn = autoSwitch?.isOn ?? false
            }, for: .valueChanged)
            subBarStack.addArrangedSubview(autoLabel)
            subBarStack.addArrangedSubview(autoSwitch)

        case .lasso:
            break

        case .capture:
            let shape = UISegmentedControl(items: [L("矩形"), L("自由形狀")])
            shape.selectedSegmentIndex = settings.captureFreeform ? 1 : 0
            shape.addAction(UIAction { [weak self, weak shape] _ in
                self?.settings.captureFreeform = shape?.selectedSegmentIndex == 1
            }, for: .valueChanged)
            subBarStack.addArrangedSubview(shape)

        case .select:
            // 選到表格時顯示表格工具列
            for v in buildTableRibbon() { subBarStack.addArrangedSubview(v) }

        case .circuit:
            for v in buildCircuitRibbon() { subBarStack.addArrangedSubview(v) }

        case .textSelect:
            break

        case .image:
            let hint = UILabel()
            hint.text = L("點下面的照片，放到目前這一頁；捲到別頁可以接著加")
            hint.font = .systemFont(ofSize: 13)
            hint.textColor = .secondaryLabel
            subBarStack.addArrangedSubview(hint)

        case .pageResize:
            let reset = makeButton(symbol: "arrow.counterclockwise", title: L("重設"), action: nil)
            reset.addAction(UIAction { [weak self] _ in
                guard let self, let i = self.resizePageIndex else { return }
                self.applyInsets(PageInsets(), pageIndex: i, toAll: false)
            }, for: .touchUpInside)
            let all = makeButton(symbol: "doc.on.doc", title: L("套用全部"), action: nil)
            all.addAction(UIAction { [weak self] _ in
                guard let self, let i = self.resizePageIndex, self.pages.indices.contains(i) else { return }
                self.applyInsets(self.pages[i].insets, pageIndex: i, toAll: true)
            }, for: .touchUpInside)
            let numbers = makeButton(symbol: "number", title: L("數值"), action: nil)
            numbers.addAction(UIAction { [weak self] _ in
                self?.presentExpandSheet(pageIndex: self?.resizePageIndex)
            }, for: .touchUpInside)
            subBarStack.addArrangedSubview(reset)
            subBarStack.addArrangedSubview(all)
            subBarStack.addArrangedSubview(numbers)

        case .tableDraw:
            if tableDrawTarget != nil {
                // 在既有表格上畫線：畫線（切開、斜線、加列欄）或擦線（合併）
                let mode = UISegmentedControl(items: [UIImage(systemName: "pencil")!, UIImage(systemName: "eraser")!])
                mode.setTitle(nil, forSegmentAt: 0)
                mode.selectedSegmentIndex = tableEraseLines ? 1 : 0
                mode.accessibilityLabel = L("畫線或擦線")
                mode.addAction(UIAction { [weak self, weak mode] _ in
                    guard let self, let mode, (mode.selectedSegmentIndex == 1) != self.tableEraseLines else { return }
                    self.toggleTableEraseLines()
                }, for: .valueChanged)
                subBarStack.addArrangedSubview(mode)
                let done = makeButton(symbol: "checkmark.circle.fill", title: L("完成"), action: nil)
                done.configuration?.baseForegroundColor = .systemBlue
                done.addAction(UIAction { [weak self] _ in self?.finishTableEditDraw() }, for: .touchUpInside)
                subBarStack.addArrangedSubview(done)
                return
            }
            let done = makeButton(symbol: "checkmark.circle.fill", title: L("完成"), action: nil)
            done.configuration?.baseForegroundColor = .systemBlue
            done.addAction(UIAction { [weak self] _ in self?.finishTableDraft() }, for: .touchUpInside)
            // 收回一條線：用右上角的「上一步」
            let cancel = makeButton(symbol: "xmark", title: L("取消"), action: nil)
            cancel.addAction(UIAction { [weak self] _ in self?.setTool(.pen) }, for: .touchUpInside)
            subBarStack.addArrangedSubview(done)
            subBarStack.addArrangedSubview(cancel)
        }
    }

    func hintLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabel
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    func presetImage(_ p: BrushPreset, selected: Bool) -> UIImage {
        let size = CGSize(width: 32, height: 32)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            if selected {
                UIColor.systemBlue.setStroke()
                let ring = UIBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
                ring.lineWidth = 2.5
                ring.stroke()
            }
            let inner = rect.insetBy(dx: 6, dy: 6)
            let color = p.style == .marker ? p.color.withAlphaComponent(0.7) : p.color
            color.setFill()
            if p.style == .marker {
                UIBezierPath(roundedRect: inner.insetBy(dx: 0, dy: 4), cornerRadius: 3).fill()
            } else {
                UIBezierPath(ovalIn: inner).fill()
            }
            // 粗細示意
            let dot = min(inner.width - 6, max(2, p.width * 0.9))
            UIColor.white.withAlphaComponent(0.85).setFill()
            if p.style != .marker {
                UIBezierPath(ovalIn: CGRect(x: rect.midX - dot / 4, y: rect.midY - dot / 4, width: dot / 2, height: dot / 2)).fill()
            }
            if p.isDashed {
                let dash = UIBezierPath()
                dash.move(to: CGPoint(x: inner.minX + 3, y: rect.midY))
                dash.addLine(to: CGPoint(x: inner.maxX - 3, y: rect.midY))
                dash.lineWidth = 2
                dash.setLineDash([3, 2.5], count: 2, phase: 0)
                UIColor.white.setStroke()
                dash.stroke()
            }
            // 筆型字樣
            let mark: String
            switch p.style {
            case .pencil: mark = L("鉛")
            case .fountainPen: mark = L("毛")
            case .crayon: mark = L("蠟")
            case .watercolor: mark = L("水")
            default: mark = ""
            }
            if !mark.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 9), .foregroundColor: UIColor.white]
                let s = NSAttributedString(string: mark, attributes: attrs)
                let sz = s.size()
                s.draw(at: CGPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
            }
        }
    }

    func selectPreset(_ id: UUID) {
        if id == BrushStore.shared.currentID, let b = presetButtons[id] {
            presentBrushSettings(BrushStore.shared.current, from: b)
            return
        }
        BrushStore.shared.select(id)
        setCanvasTool(BrushStore.shared.current.tool)
        applyInkEngine()
        refreshPresetButtons()
    }

    /// 常用筆刷（沒有數量上限）：放不下的時候左右捲動，不會把第二列撐出畫面
    func makePresetStrip() -> UIScrollView {
        let stack = UIStackView()
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        for p in BrushStore.shared.presets {
            let b = UIButton(type: .custom)
            b.setImage(presetImage(p, selected: p.id == BrushStore.shared.currentID), for: .normal)
            b.widthAnchor.constraint(equalToConstant: 36).isActive = true
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
            b.accessibilityLabel = p.style.title
            b.addAction(UIAction { [weak self] _ in self?.selectPreset(p.id) }, for: .touchUpInside)
            b.menu = presetMenu(p.id, source: b)
            presetButtons[p.id] = b
            stack.addArrangedSubview(b)
        }
        let strip = UIScrollView()
        strip.showsHorizontalScrollIndicator = false
        strip.addSubview(stack)
        // 放得下就和筆刷一樣寬；比置中還優先（放不下時第二列先往旁邊移，再不夠才捲動）
        let fit = strip.widthAnchor.constraint(equalTo: stack.widthAnchor)
        fit.priority = UILayoutPriority(UILayoutPriority.defaultHigh.rawValue + 1)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: strip.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: strip.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: strip.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: strip.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: strip.frameLayoutGuide.heightAnchor),
            strip.heightAnchor.constraint(equalToConstant: 36),
            fit,
        ])
        presetStrip = strip
        return strip
    }

    /// 目前的筆刷捲到看得到的地方（剛新增的在最後面）
    func scrollCurrentPresetIntoView() {
        guard let strip = presetStrip, let b = presetButtons[BrushStore.shared.currentID] else { return }
        subBar.layoutIfNeeded()
        strip.scrollRectToVisible(b.convert(b.bounds, to: strip).insetBy(dx: -8, dy: 0), animated: false)
    }

    func refreshPresetButtons() {
        for p in BrushStore.shared.presets {
            presetButtons[p.id]?.setImage(presetImage(p, selected: p.id == BrushStore.shared.currentID), for: .normal)
            // 換了筆型，名稱也跟著換
            presetButtons[p.id]?.accessibilityLabel = p.style.title
        }
        refreshPenStyleControls()
    }

    // MARK: 筆的線條樣式

    /// 細、中、粗（不同粗細的橫線圖示）＋虛線：改的是目前選的這支筆。長按粗細圖示可以自訂 pt
    /// 細、中、粗（筆和螢光筆都有）；dash：筆才有虛線
    func penStyleControls(dash withDash: Bool = true) -> [UIView] {
        let names = [L("細"), L("中"), L("粗")]
        penWidthButtons = (0..<3).map { slot in
            let b = UIButton(configuration: .plain())
            b.accessibilityLabel = names[slot]
            b.addAction(UIAction { [weak self, weak b] _ in
                guard let self, let b else { return }
                var p = BrushStore.shared.current
                let w = BrushStore.shared.styleWidths(p.style)[slot]
                // 已經是這個粗細：再點一次打開 pt 調整（和筆刷「再點一下調整」一樣）
                if abs(p.width - w) < 0.01 {
                    self.presentWidthEditor(slot: slot, from: b)
                    return
                }
                p.width = w
                self.updateCurrentPreset(p)
            }, for: .touchUpInside)
            b.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(penWidthLongPressed(_:))))
            b.tag = slot
            return b
        }

        guard withDash else {
            penDashButton = nil
            refreshPenStyleControls()
            return penWidthButtons
        }
        let dash = UIButton(configuration: .plain())
        dash.accessibilityLabel = L("虛線")
        dash.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            var p = BrushStore.shared.current
            p.dashed = !p.isDashed
            self.updateCurrentPreset(p)
        }, for: .touchUpInside)
        dash.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(penDashLongPressed(_:))))
        penDashButton = dash
        refreshPenStyleControls()
        return penWidthButtons + [dash]
    }

    /// 長按粗細圖示：用滑桿自訂這一格的 pt（目前的筆用的是這一格就一起改）
    @objc func penWidthLongPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let button = g.view as? UIButton else { return }
        presentWidthEditor(slot: button.tag, from: button)
    }

    /// 自訂某一格（細／中／粗）的 pt；目前的筆用的是這一格就一起改
    func presentWidthEditor(slot: Int, from button: UIView) {
        let style = BrushStore.shared.current.style
        let wasUsing = currentWidthSlot() == slot
        let editor = WidthSlotEditor(title: [L("細"), L("中"), L("粗")][slot], range: style.usableWidthRange,
                                     width: BrushStore.shared.styleWidths(style)[slot]) { [weak self] w in
            guard let self else { return }
            BrushStore.shared.setStyleWidth(w, slot: slot, style: style)
            if wasUsing, BrushStore.shared.current.style == style {
                var p = BrushStore.shared.current
                p.width = BrushStore.shared.styleWidths(style)[slot]
                self.updateCurrentPreset(p)
            } else {
                self.refreshPenStyleControls()
            }
        }
        presentToolPopover(UIHostingController(rootView: editor), from: button, size: CGSize(width: 300, height: 150))
    }

    /// 長按虛線按鈕：調整這支筆的虛線長度與間距（打開就順便切成虛線）
    @objc func penDashLongPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let button = g.view else { return }
        var p = BrushStore.shared.current
        if !p.isDashed {
            p.dashed = true
            updateCurrentPreset(p)
        }
        let view = DashSettingsView(preset: p) { [weak self] changed in
            // 只改虛線設定，其他欄位以最新的為準
            var cur = BrushStore.shared.current
            guard cur.id == changed.id else { return }
            cur.dashLength = changed.dashLength
            cur.gapLength = changed.gapLength
            self?.updateCurrentPreset(cur)
        }
        presentToolPopover(UIHostingController(rootView: view), from: button, size: CGSize(width: 320, height: 340))
    }

    /// 目前的筆最接近哪一格粗細
    private func currentWidthSlot() -> Int {
        let p = BrushStore.shared.current
        let widths = BrushStore.shared.styleWidths(p.style)
        return widths.indices.min { abs(widths[$0] - p.width) < abs(widths[$1] - p.width) } ?? 1
    }

    private func updateCurrentPreset(_ p: BrushPreset) {
        BrushStore.shared.update(p)
        setCanvasTool(p.tool)
        refreshPresetButtons()
    }

    /// 把筆交給 PencilKit。一樣的筆不重設：每次換筆 PencilKit 都要重新準備，太頻繁會暫時不理會書寫
    func setCanvasTool(_ t: PKInkingTool) {
        if let old = canvas.tool as? PKInkingTool,
           old.inkType == t.inkType, old.width == t.width, old.color == t.color { return }
        canvas.tool = t
    }

    // MARK: 工具列的小視窗

    /// 粗細、虛線、筆刷設定的小視窗。開著時碰到頁面（筆或手指，點或畫）都當作點旁邊：
    /// 關掉它、這一下不寫字也不捲動，關好了才照常寫。換工具也會關掉
    /// rect：指著 source 裡的這一塊（沒給就是整個 source）
    func presentToolPopover(_ vc: UIViewController, from source: UIView, rect: CGRect? = nil, size: CGSize) {
        dismissToolPopover()
        vc.modalPresentationStyle = .popover
        vc.preferredContentSize = size
        if let pop = vc.popoverPresentationController {
            pop.sourceView = source
            pop.sourceRect = rect ?? source.bounds
            // 頁面上的觸碰交給 popoverShield（不讓系統的透明底接走：點旁邊關掉後頁面的手勢會卡住）
            pop.passthroughViews = [popoverShield]
        }
        present(vc, animated: true)
    }

    /// 關掉小視窗。工具列重建時它依附的按鈕會被拿掉，不關的話可能卡在看不到的地方擋住所有觸控（這時不要動畫）。
    /// animated：點旁邊關掉時縮回去
    func dismissToolPopover(animated: Bool = false) {
        guard let p = presentedViewController, p.modalPresentationStyle == .popover, !p.isBeingDismissed else { return }
        p.dismiss(animated: animated)
    }

    /// 工具列的小視窗開著（包含正在關的時候）
    var toolPopoverShown: Bool { presentedViewController?.modalPresentationStyle == .popover }

    /// 依目前的筆更新「細、中、粗」與虛線按鈕
    func refreshPenStyleControls() {
        let p = BrushStore.shared.current
        if !penWidthButtons.isEmpty {
            let widths = BrushStore.shared.styleWidths(p.style)
            let selected = currentWidthSlot()
            for (slot, b) in penWidthButtons.enumerated() where widths.indices.contains(slot) {
                var c = b.configuration ?? .plain()
                c.image = Self.widthIcons[slot]
                c.baseForegroundColor = slot == selected ? .systemBlue : .label
                c.background.backgroundColor = slot == selected ? UIColor.systemBlue.withAlphaComponent(0.15) : .clear
                c.background.cornerRadius = 8
                c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
                b.configuration = c
                b.accessibilityValue = String(format: "%.1f pt", Double(widths[slot]))
            }
        }
        if let dash = penDashButton {
            var c = dash.configuration ?? .plain()
            c.image = Self.dashedLineIcon
            c.baseForegroundColor = p.isDashed ? .systemBlue : .label
            c.background.backgroundColor = p.isDashed ? UIColor.systemBlue.withAlphaComponent(0.15) : .clear
            c.background.cornerRadius = 8
            c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
            dash.configuration = c
        }
    }

    /// 細、中、粗圖示：固定粗細的橫線（實際 pt 再小也看得出差別）
    static let widthIcons: [UIImage] = ([1.5, 4, 8] as [CGFloat]).map { widthIcon($0) }

    private static func widthIcon(_ t: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 28, height: 18)).image { _ in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 3 + t / 2, y: 9))
            path.addLine(to: CGPoint(x: 25 - t / 2, y: 9))
            path.lineWidth = t
            path.lineCapStyle = .round
            UIColor.black.setStroke()
            path.stroke()
        }.withRenderingMode(.alwaysTemplate)
    }

    static let dashedLineIcon: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 26, height: 18)).image { _ in
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 3, y: 9))
        path.addLine(to: CGPoint(x: 23, y: 9))
        path.lineWidth = 2.5
        path.lineCapStyle = .round
        path.setLineDash([4, 5], count: 2, phase: 0)
        UIColor.black.setStroke()
        path.stroke()
    }.withRenderingMode(.alwaysTemplate)

    func toolbarSeparator() -> UIView {
        let v = UIView()
        v.backgroundColor = .separator
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return v
    }

    func presetMenu(_ id: UUID, source: UIButton) -> UIMenu {
        UIMenu(children: [
            UIAction(title: L("調整"), image: UIImage(systemName: "slider.horizontal.3")) { [weak self, weak source] _ in
                guard let self, let source, let p = BrushStore.shared.presets.first(where: { $0.id == id }) else { return }
                BrushStore.shared.select(id)
                self.setCanvasTool(p.tool)
                self.applyInkEngine()
                self.refreshPresetButtons()
                self.presentBrushSettings(p, from: source)
            },
            UIAction(title: L("往左移"), image: UIImage(systemName: "arrow.left")) { [weak self] _ in
                BrushStore.shared.moveLeft(id)
                self?.rebuildSubBar()
            },
            UIAction(title: L("刪除"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                BrushStore.shared.remove(id)
                self?.applyTool()
            },
        ])
    }

    func presentBrushSettings(_ preset: BrushPreset, from source: UIView) {
        var view = BrushSettingsView(preset: preset) { [weak self] p in
            BrushStore.shared.update(p)
            if BrushStore.shared.currentID == p.id {
                self?.setCanvasTool(BrushStore.shared.current.tool)
                // 改了筆型：可能從自製筆刷換成 PencilKit（或相反）
                self?.applyInkEngine()
            }
            self?.refreshPresetButtons()
        }
        // 每一類至少留一支
        if BrushStore.shared.presets(preset.category).count > 1 {
            view.onDelete = { [weak self] in
                self?.dismissToolPopover()
                BrushStore.shared.remove(preset.id)
                self?.applyTool()
            }
        }
        // 筆多了最上面的筆型
        presentToolPopover(UIHostingController(rootView: view), from: source, size: CGSize(width: 340, height: preset.style == .marker ? 460 : 600))
    }

    // MARK: - Menus

    func makeInsertMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: L("表格…"), image: UIImage(systemName: "tablecells")) { [weak self] _ in
                guard let self else { return }
                let r = self.visibleDocRect()
                self.presentInsertTablePanel(anchor: self.insertButton.map { .view($0) } ?? .doc(CGRect(x: r.midX, y: r.midY, width: 1, height: 1)))
            },
            UIAction(title: L("手繪新表格"), image: UIImage(systemName: "pencil.and.outline")) { [weak self] _ in self?.setTool(.tableDraw) },
            UIAction(title: L("文字框"), image: UIImage(systemName: "character.textbox")) { [weak self] _ in self?.insertTextBox(at: nil) },
        ])
    }

    @objc func pageLabelTapped() { beginPageJump() }

    /// 頁碼變成輸入框，選好目前的頁碼，直接打數字；Enter 或點旁邊就跳過去
    func beginPageJump() {
        guard !pages.isEmpty else { return }
        let f = pageJumpField ?? makePageJumpField()
        f.text = "\(currentPageIndex + 1)"
        f.placeholder = "1–\(pages.count)"
        f.isHidden = false
        pageLabel.alpha = 0
        f.becomeFirstResponder()
        f.selectAll(nil)
    }

    private func makePageJumpField() -> UITextField {
        let f = UITextField()
        f.keyboardType = .numberPad
        f.returnKeyType = .go
        f.textAlignment = .center
        f.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        f.borderStyle = .roundedRect
        f.accessibilityIdentifier = "pageJumpField"
        f.translatesAutoresizingMaskIntoConstraints = false
        f.isHidden = true
        subBar.addSubview(f)
        NSLayoutConstraint.activate([
            f.centerYAnchor.constraint(equalTo: pageLabel.centerYAnchor),
            f.centerXAnchor.constraint(equalTo: pageLabel.centerXAnchor),
            f.widthAnchor.constraint(equalToConstant: 76),
        ])
        // 按 Enter 收起鍵盤，收起時（含點旁邊）跳過去
        f.addAction(UIAction { _ in }, for: .editingDidEndOnExit)
        f.addAction(UIAction { [weak self] _ in self?.finishPageJump() }, for: .editingDidEnd)
        pageJumpField = f
        return f
    }

    /// 輸入框收起：是有效的頁碼就跳過去（超過範圍就到第一頁／最後一頁）
    func finishPageJump() {
        guard let f = pageJumpField, !f.isHidden else { return }
        f.isHidden = true
        pageLabel.alpha = 1
        if f.isFirstResponder { f.resignFirstResponder() }
        guard let n = Int(f.text ?? ""), !pages.isEmpty else { return }
        let i = min(max(n, 1), pages.count) - 1
        if i != currentPageIndex { scrollToPage(i, animated: true) }
    }

    func makePageMenuItems() -> [UIMenuElement] {
        guard !pages.isEmpty else { return [] }
        let i = currentPageIndex
        // 全部頁面、跳到頁碼、擴展頁面在工具列上都有，這裡不重複
        var items: [UIMenuElement] = [
            UIAction(title: L("在此頁後新增頁面…"), image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in
                self?.presentPaperPicker(title: L("在第 \(i + 1) 頁後新增頁面"), insertAt: i + 1)
            },
            UIAction(title: L("在此頁前新增頁面…"), image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in
                self?.presentPaperPicker(title: L("在第 \(i + 1) 頁前新增頁面"), insertAt: i)
            },
        ]
        if !pages[i].insets.isZero {
            items.append(UIAction(title: L("移除此頁擴展"), image: UIImage(systemName: "arrow.down.right.and.arrow.up.left")) { [weak self] _ in
                self?.applyInsets(PageInsets(), pageIndex: i, toAll: false)
            })
        }
        let trashed = session.trashedPages.count
        items.append(UIAction(title: trashed > 0 ? L("最近刪除的頁面（\(trashed)）…") : L("最近刪除的頁面…"),
                              image: UIImage(systemName: "trash.slash")) { [weak self] _ in
            self?.presentTrashedPages(from: nil)
        })
        items.append(UIAction(title: L("刪除此頁"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.deletePage(i)
        })
        return items
    }

    /// Pencil Pro 按壓：調色盤，或工具列的某個工具
    func squeezeMenuItems() -> [UIMenuElement] {
        let s = settings
        let palette = UIAction(title: L("調色盤"), image: UIImage(systemName: "paintpalette"),
                               state: s.squeezeAction == "palette" ? .on : .off) { _ in s.squeezeAction = "palette" }
        let tools: [UIMenuElement] = Self.toolbarTools.map { item in
            let key = EditorSettings.squeezeKey(item.0)
            return UIAction(title: item.2, image: UIImage(systemName: item.1),
                            state: s.squeezeAction == key ? .on : .off) { _ in s.squeezeAction = key }
        }
        return [palette] + tools
    }

    /// 常用筆刷列靠左或靠右
    func makeSettingsMenuItems() -> [UIMenuElement] {
        let s = settings
        let toggles = UIMenu(options: .displayInline, children: [
            UIAction(title: L("Pencil 點兩下時顯示調色盤圖示"), image: UIImage(systemName: "paintpalette"), state: s.paletteOnDoubleTap ? .on : .off) { _ in
                s.paletteOnDoubleTap.toggle()
            },
            UIMenu(title: L("Pencil Pro 按壓"), image: UIImage(systemName: "hand.pinch"), children: squeezeMenuItems()),
            UIMenu(title: L("手掌防誤觸"), image: UIImage(systemName: "hand.raised"), children: [
                UIAction(title: L("右手寫字"), state: s.palmRejection == "right" ? .on : .off) { _ in s.palmRejection = "right" },
                UIAction(title: L("左手寫字"), state: s.palmRejection == "left" ? .on : .off) { _ in s.palmRejection = "left" },
                UIAction(title: L("關閉"), state: s.palmRejection == "off" ? .on : .off) { _ in s.palmRejection = "off" },
            ]),
            UIAction(title: L("用手指書寫"), image: UIImage(systemName: "hand.draw"), state: s.fingerDrawing ? .on : .off) { [weak self] _ in
                s.fingerDrawing.toggle()
                self?.applyTool()
            },
            UIAction(title: L("橡皮擦擦完自動切回筆"), image: UIImage(systemName: "eraser"), state: s.eraserAutoReturn ? .on : .off) { [weak self] _ in
                s.eraserAutoReturn.toggle()
                if self?.tool == .eraser { self?.rebuildSubBar() }
            },
            UIAction(title: L("畫線停住變直線／圖形"), image: UIImage(systemName: "line.diagonal"), state: s.shapeSnap ? .on : .off) { [weak self] _ in
                s.shapeSnap.toggle()
                self?.updateGestureAvailability()
            },
            UIAction(title: L("原子筆用自製筆刷（不圓滑）"), image: UIImage(systemName: "scribble"), state: s.customInk ? .on : .off) { [weak self] _ in
                s.customInk.toggle()
                self?.applyTool()
                self?.showToast(s.customInk ? L("原子筆改用自製筆刷：照筆尖原始軌跡畫，不做圓滑（其他筆照樣是 PencilKit）") : L("原子筆改回 PencilKit"))
            },
            UIAction(title: L("連續放置元件"), image: UIImage(systemName: "square.on.square"), state: s.circuitContinuousPlace ? .on : .off) { _ in
                s.circuitContinuousPlace.toggle()
            },
            UIAction(title: L("電路元件庫放左邊"), image: UIImage(systemName: "sidebar.left"), state: s.circuitLibraryOnLeft ? .on : .off) { [weak self] _ in
                self?.setCircuitLibraryOnLeft(!s.circuitLibraryOnLeft)
            },
            UIAction(title: L("拷貝除錯紀錄"), image: UIImage(systemName: "ladybug")) { [weak self] _ in
                UIPasteboard.general.string = DebugLog.text
                self?.showToast(L("已拷貝除錯紀錄，可以貼給開發者"))
            },
            UIAction(title: L("螢光筆自動對齊 PDF 文字"), image: UIImage(systemName: "highlighter"), state: s.smartHighlight ? .on : .off) { _ in
                s.smartHighlight.toggle()
            },
        ])
        // 最下面：使用說明、關於我
        let help = UIMenu(options: .displayInline, children: [
            UIAction(title: L("使用說明…"), image: UIImage(systemName: "questionmark.circle")) { [weak self] _ in
                guard let self else { return }
                self.presentHelp(from: self.settingsButton)
            },
            UIAction(title: L("關於我…"), image: UIImage(systemName: "person.crop.circle")) { [weak self] _ in
                let about = UIHostingController(rootView: AboutView())
                about.modalPresentationStyle = .formSheet
                self?.present(about, animated: true)
            },
        ])
        let actions = UIMenu(options: .displayInline, children: [
            UIAction(title: L("預覽模式（收合工具列）"), image: UIImage(systemName: "eye")) { [weak self] _ in
                self?.setPreviewMode(true)
            },
            UIAction(title: L("管理常用筆刷…"), image: UIImage(systemName: "swatchpalette")) { [weak self] _ in
                self?.presentBrushManager()
            },
            UIAction(title: L("清除畫面上所有貼圖"), image: UIImage(systemName: "pin.slash"), attributes: .destructive) { [weak self] _ in
                PinStore.shared.removeAll()
                self?.pinOverlay.reload()
            },
        ])
        return [toggles, actions, help]
    }

    // MARK: - Favorites

    func refreshFavoriteButton() {
        guard let b = favoriteButton, !pages.isEmpty else { return }
        let fav = pages[currentPageIndex].favorite
        var c = b.configuration ?? .plain()
        c.image = UIImage(systemName: fav ? "star.fill" : "star", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17))
        c.baseForegroundColor = fav ? .systemYellow : .label
        b.configuration = c
    }

    @objc func favoriteTapped() {
        let i = currentPageIndex
        if pages[i].favorite {
            let a = UIAlertController(title: L("第 \(i + 1) 頁"), message: pages[i].note.isEmpty ? nil : pages[i].note, preferredStyle: .actionSheet)
            a.addAction(UIAlertAction(title: L("編輯備註"), style: .default) { [weak self] _ in self?.promptFavoriteNote(i, isNew: false) })
            a.addAction(UIAlertAction(title: L("從我的最愛移除"), style: .destructive) { [weak self] _ in
                guard let self else { return }
                self.session.document.pages[i].favorite = false
                self.afterFavoriteChange(i)
            })
            a.addAction(UIAlertAction(title: L("取消"), style: .cancel))
            a.popoverPresentationController?.sourceView = favoriteButton
            a.popoverPresentationController?.sourceRect = favoriteButton.bounds
            present(a, animated: true)
        } else {
            promptFavoriteNote(i, isNew: true)
        }
    }

    func promptFavoriteNote(_ i: Int, isNew: Bool) {
        let a = UIAlertController(title: isNew ? L("加入我的最愛") : L("編輯備註"),
                                  message: L("第 \(i + 1) 頁：寫下這頁有什麼資料，之後比較好找（可留空）"),
                                  preferredStyle: .alert)
        a.addTextField { [weak self] tf in
            tf.text = self?.pages[i].note
            tf.placeholder = L("例如：第三章公式整理")
            tf.clearButtonMode = .whileEditing
        }
        a.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        a.addAction(UIAlertAction(title: isNew ? L("加入") : L("儲存"), style: .default) { [weak self, weak a] _ in
            guard let self, self.pages.indices.contains(i) else { return }
            self.session.document.pages[i].favorite = true
            self.session.document.pages[i].note = a?.textFields?.first?.text ?? ""
            self.afterFavoriteChange(i)
        })
        present(a, animated: true)
    }

    func afterFavoriteChange(_ i: Int) {
        refreshFavoriteButton()
        saveNow()
        if pages[safe: i]?.favorite == true { session.writeThumbnail(pageIndex: i) }
    }

    func presentFavoritesList(from source: UIView) {
        commitDrawing()
        let items: [FavoritePageItem] = pages.enumerated().compactMap { i, p in
            guard p.favorite else { return nil }
            return FavoritePageItem(id: p.id, number: i + 1, note: p.note, thumbnail: session.renderThumbnail(pageIndex: i, width: 180))
        }
        let list = NotebookFavoritesView(
            items: items,
            onSelect: { [weak self] id in
                self?.dismiss(animated: true)
                if let i = self?.pageIndex(of: id) { self?.scrollToPage(i, animated: true) }
            },
            onEditNote: { [weak self] id, note in
                guard let self, let i = self.pageIndex(of: id) else { return }
                self.session.document.pages[i].note = note
                self.scheduleSave()
            },
            onRemove: { [weak self] id in
                guard let self, let i = self.pageIndex(of: id) else { return }
                self.session.document.pages[i].favorite = false
                self.afterFavoriteChange(i)
            }
        )
        let host = UIHostingController(rootView: list)
        host.modalPresentationStyle = .popover
        host.preferredContentSize = CGSize(width: 420, height: 560)
        host.popoverPresentationController?.sourceView = source
        host.popoverPresentationController?.sourceRect = source.bounds
        present(host, animated: true)
    }
}

extension NSLayoutConstraint {
    func withPriority(_ p: UILayoutPriority) -> NSLayoutConstraint {
        priority = p
        return self
    }
}

extension NotebookViewController {
    func presentHelp(from source: UIView) {
        let host = UIHostingController(rootView: HelpView())
        host.modalPresentationStyle = .popover
        host.preferredContentSize = CGSize(width: 460, height: 640)
        host.popoverPresentationController?.sourceView = source
        host.popoverPresentationController?.sourceRect = source.bounds
        present(host, animated: true)
    }
}

extension NotebookViewController {
    func presentBrushManager() {
        let category: BrushCategory = tool == .highlighter ? .highlighter : .pen
        var host: UIHostingController<BrushManagerView>?
        let view = BrushManagerView(category: category) { [weak self] in
            host?.dismiss(animated: true)
            self?.applyTool()
        }
        let h = UIHostingController(rootView: view)
        h.modalPresentationStyle = .formSheet
        h.presentationController?.delegate = nil
        host = h
        present(h, animated: true)
    }
}

/// 長按「細／中／粗」時的 pt 調整
struct WidthSlotEditor: View {
    let title: String
    let range: ClosedRange<CGFloat>
    @State var width: CGFloat
    let onChange: (CGFloat) -> Void

    init(title: String, range: ClosedRange<CGFloat>, width: CGFloat, onChange: @escaping (CGFloat) -> Void) {
        self.title = title
        self.range = range
        _width = State(initialValue: width)
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(String(format: "%.1f pt", Double(width))).monospacedDigit().foregroundStyle(.secondary)
            }
            Capsule().frame(width: 160, height: min(max(width, 1), 30)).frame(maxWidth: .infinity)
            Slider(value: $width, in: range, step: 0.1)
                .onChange(of: width) { _, w in onChange(w) }
        }
        .padding()
    }
}

/// 長按虛線按鈕時的設定：線段長度、間距，預覽照這支筆的顏色與粗細
struct DashSettingsView: View {
    @State var preset: BrushPreset
    let onChange: (BrushPreset) -> Void

    private var pattern: (dash: CGFloat, gap: CGFloat) { preset.dashPattern(lineWidth: preset.tool.width) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("虛線樣式")).font(.headline)
            DashPreview(preset: preset).frame(height: 80)
            HStack {
                Text(L("線段長度"))
                Spacer()
                Text(String(format: "%.1f pt", Double(pattern.dash))).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { pattern.dash }, set: { preset.dashLength = ($0 * 10).rounded() / 10 }),
                   in: 0.3...30, step: 0.1)
            HStack {
                Text(L("間距"))
                Spacer()
                Text(String(format: "%.1f pt", Double(pattern.gap))).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { pattern.gap }, set: { preset.gapLength = ($0 * 10).rounded() / 10 }),
                   in: 0.3...30, step: 0.1)
            Button(L("恢復預設")) {
                preset.dashLength = nil
                preset.gapLength = nil
            }
            .font(.subheadline)
        }
        .padding()
        .onChange(of: preset) { _, p in onChange(p) }
    }
}

/// 用 PencilKit 實際畫一條虛線，和寫出來的一樣
private struct DashPreview: View {
    let preset: BrushPreset

    var body: some View {
        let w = preset.tool.width
        let pattern = preset.dashPattern(lineWidth: w)
        // 和寫出來的一樣：每段 dash 長、空 gap，圓頭
        let style = StrokeStyle(lineWidth: w, lineCap: .round, dash: [pattern.dash, pattern.gap])
        Canvas { ctx, size in
            var straight = Path()
            straight.move(to: CGPoint(x: 14, y: size.height * 0.3))
            straight.addLine(to: CGPoint(x: size.width - 14, y: size.height * 0.3))
            var wave = Path()
            wave.move(to: CGPoint(x: 14, y: size.height * 0.72))
            wave.addCurve(to: CGPoint(x: size.width - 14, y: size.height * 0.72),
                          control1: CGPoint(x: size.width * 0.35, y: size.height * 0.45),
                          control2: CGPoint(x: size.width * 0.65, y: size.height * 1.0))
            let color = Color(uiColor: preset.color)
            ctx.stroke(straight, with: .color(color), style: style)
            ctx.stroke(wave, with: .color(color), style: style)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3)))
        .environment(\.colorScheme, .light)
    }
}

/// 蓋在頁面上：工具列的小視窗開著時接下頁面上的觸碰（一碰到就通知），這整個觸碰都不會到頁面；
/// 小視窗關好了就讓觸碰穿過去
final class PopoverShieldView: UIView {
    var isActive: () -> Bool = { false }
    var onTouch: () -> Void = {}

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        isActive() && super.point(inside: point, with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouch()
    }
}
