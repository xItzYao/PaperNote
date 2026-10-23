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
            canvas.topAnchor.constraint(equalTo: sep.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

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

        // 左：返回＋標題
        let back = makeButton(symbol: "chevron.left", title: "資料庫", action: #selector(closeTapped))
        let titleLabel = UILabel()
        titleLabel.text = session.title
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let left = UIStackView(arrangedSubviews: [back, titleLabel])
        left.spacing = 6
        left.alignment = .center

        // 中：工具
        let tools: [(EditorTool, String, String)] = [
            (.pen, "pencil.tip", "筆"),
            (.highlighter, "highlighter", "螢光筆"),
            (.eraser, "eraser", "橡皮擦"),
            (.lasso, "lasso", "套索"),
            (.capture, "camera.viewfinder", "截圖"),
            (.select, "hand.point.up.left", "選取"),
            (.textSelect, "character.cursor.ibeam", "PDF文字"),
            (.pageResize, "arrow.up.left.and.arrow.down.right", "擴展"),
            (.circuit, "bolt", "電路"),
        ]
        let center = UIStackView()
        center.spacing = 4
        for (t, symbol, label) in tools {
            let b = makeButton(symbol: symbol, title: nil, action: nil)
            b.accessibilityLabel = label
            b.addAction(UIAction { [weak self] _ in self?.setTool(t) }, for: .touchUpInside)
            toolButtons[t] = b
            center.addArrangedSubview(b)
        }
        let insert = makeButton(symbol: "plus.circle", title: nil, action: nil)
        insert.accessibilityLabel = "插入"
        insert.menu = makeInsertMenu()
        insert.showsMenuAsPrimaryAction = true
        center.addArrangedSubview(insert)

        // 右：復原、最愛、頁面、設定
        let undo = makeButton(symbol: "arrow.uturn.backward", title: nil, action: #selector(undoTapped))
        let redo = makeButton(symbol: "arrow.uturn.forward", title: nil, action: #selector(redoTapped))
        favoriteButton = makeButton(symbol: "star", title: nil, action: #selector(favoriteTapped))
        let favList = makeButton(symbol: "list.star", title: nil, action: nil)
        favList.addAction(UIAction { [weak self, weak favList] _ in
            guard let self, let favList else { return }
            self.presentFavoritesList(from: favList)
        }, for: .touchUpInside)
        let overview = makeButton(symbol: "square.grid.2x2", title: nil, action: nil)
        overview.accessibilityLabel = "全部頁面"
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
        let help = makeButton(symbol: "questionmark.circle", title: nil, action: nil)
        help.accessibilityLabel = "說明"
        help.addAction(UIAction { [weak self, weak help] _ in
            guard let self, let help else { return }
            self.presentHelp(from: help)
        }, for: .touchUpInside)
        let right = UIStackView(arrangedSubviews: [undo, redo, favoriteButton, favList, overview, pageMenu, help, settingsButton])
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
        // 點頁碼打開全部頁面
        pageLabel.isUserInteractionEnabled = true
        pageLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(pageLabelTapped)))
        subBar.addSubview(pageLabel)
        NSLayoutConstraint.activate([
            subBarStack.centerYAnchor.constraint(equalTo: subBar.centerYAnchor),
            pageLabel.centerYAnchor.constraint(equalTo: subBar.centerYAnchor),
        ])
        subBarLeftLayout = [
            subBarStack.leadingAnchor.constraint(equalTo: subBar.leadingAnchor, constant: 12),
            subBarStack.trailingAnchor.constraint(lessThanOrEqualTo: pageLabel.leadingAnchor, constant: -12),
            pageLabel.trailingAnchor.constraint(equalTo: subBar.trailingAnchor, constant: -16),
        ]
        subBarRightLayout = [
            subBarStack.trailingAnchor.constraint(equalTo: subBar.trailingAnchor, constant: -12),
            subBarStack.leadingAnchor.constraint(greaterThanOrEqualTo: pageLabel.trailingAnchor, constant: 12),
            pageLabel.leadingAnchor.constraint(equalTo: subBar.leadingAnchor, constant: 16),
        ]
        applyPresetAlignment()
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
        endTextEditing()
        dismissToolPopover()
        if t != tool {
            clearTextSelection()
            clearCapture()
            if t != .select { select(nil) }
            tableDraft = nil
            tableDraftStart = nil
            tableDrawTarget = nil
            resizeDrag = nil
            clearLassoSelection()
            circuitSel = nil
            circuitMode = .select
            wireDraft = nil
            overlay.showCircuitDraft(nil, ink: nil)
        }
        if t == .pageResize, resizePageIndex == nil || t != tool { resizePageIndex = currentPageIndex }
        if t == .eraser, tool.isInking || tool == .lasso { toolBeforeEraser = tool }
        tool = t
        applyTool()
        updateSelectionChrome()
        updatePageResizeChrome()
        updateTableDraftChrome()
        updateCircuitChrome()
    }

    /// 筆是虛線時由 DashedPen 接手，PencilKit 不書寫
    var dashedPenActive: Bool { tool == .pen && BrushStore.shared.current.isDashed }
    var pencilKitDraws: Bool { tool.isDrawing && !dashedPenActive }

    /// 換筆後決定由 PencilKit 還是虛線筆書寫（只在換筆、換工具時呼叫，不會在下筆中途切換）
    func updateDrawingRouting() {
        let pk = pencilKitDraws
        if canvas.drawingGestureRecognizer.isEnabled != pk { canvas.drawingGestureRecognizer.isEnabled = pk }
        dashedPen.tracker.isEnabled = dashedPenActive
    }

    func applyTool() {
        canvas.drawingGestureRecognizer.isEnabled = pencilKitDraws
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
        // 只有開啟「用手指書寫」時，手指才用來截圖、選字、畫表格線、圈選；否則單指捲動
        let fingerUsedByTool = settings.fingerDrawing && tool.drawsWithPan
        canvas.panGestureRecognizer.minimumNumberOfTouches = fingerUsedByTool ? 2 : 1
        updateGestureAvailability()
        configurePencilKitGestures()

        for (t, b) in toolButtons {
            var c = b.configuration ?? .plain()
            c.background.backgroundColor = t == tool ? UIColor.systemBlue.withAlphaComponent(0.15) : .clear
            c.baseForegroundColor = t == tool ? .systemBlue : .label
            c.background.cornerRadius = 8
            b.configuration = c
        }
        rebuildSubBar()
    }

    func rebuildSubBar() {
        // 小視窗依附的按鈕要被拿掉了，先關掉
        dismissToolPopover()
        subBarStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        presetButtons = [:]
        penWidthButtons = []
        switch tool {
        case .pen, .highlighter:
            for p in BrushStore.shared.presets {
                let b = UIButton(type: .custom)
                b.setImage(presetImage(p, selected: p.id == BrushStore.shared.currentID), for: .normal)
                b.widthAnchor.constraint(equalToConstant: 36).isActive = true
                b.heightAnchor.constraint(equalToConstant: 36).isActive = true
                b.accessibilityLabel = p.style.title
                b.addAction(UIAction { [weak self] _ in self?.selectPreset(p.id) }, for: .touchUpInside)
                b.menu = presetMenu(p.id, source: b)
                presetButtons[p.id] = b
                subBarStack.addArrangedSubview(b)
            }
            if tool == .pen {
                subBarStack.addArrangedSubview(toolbarSeparator())
                for v in penStyleControls() { subBarStack.addArrangedSubview(v) }
                subBarStack.addArrangedSubview(toolbarSeparator())
                let ruler = makeButton(symbol: "ruler", title: nil, action: nil)
                ruler.accessibilityLabel = "尺規"
                ruler.addAction(UIAction { [weak self] _ in self?.canvas.isRulerActive.toggle() }, for: .touchUpInside)
                subBarStack.addArrangedSubview(ruler)
                return
            }
            let add = makeButton(symbol: "plus", title: nil, action: nil)
            add.accessibilityLabel = "新增常用筆刷"
            add.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                let p = BrushStore.shared.add(basedOn: BrushStore.shared.current)
                self.applyTool()
                if let b = self.presetButtons[p.id] { self.presentBrushSettings(p, from: b) }
            }, for: .touchUpInside)
            let edit = makeButton(symbol: "slider.horizontal.3", title: nil, action: nil)
            edit.accessibilityLabel = "調整筆刷"
            edit.addAction(UIAction { [weak self, weak edit] _ in
                guard let self, let edit else { return }
                self.presentBrushSettings(BrushStore.shared.current, from: edit)
            }, for: .touchUpInside)
            let ruler = makeButton(symbol: "ruler", title: nil, action: nil)
            ruler.accessibilityLabel = "尺規"
            ruler.addAction(UIAction { [weak self] _ in self?.canvas.isRulerActive.toggle() }, for: .touchUpInside)
            subBarStack.addArrangedSubview(add)
            subBarStack.addArrangedSubview(edit)
            subBarStack.addArrangedSubview(ruler)

        case .eraser:
            let kind = UISegmentedControl(items: ["整筆擦除", "局部擦除"])
            kind.selectedSegmentIndex = settings.pixelEraser ? 1 : 0
            kind.addAction(UIAction { [weak self, weak kind] _ in
                self?.settings.pixelEraser = kind?.selectedSegmentIndex == 1
                self?.applyTool()
            }, for: .valueChanged)
            subBarStack.addArrangedSubview(kind)
            if settings.pixelEraser {
                let sizes: [CGFloat] = [8, 16, 32, 60]
                let size = UISegmentedControl(items: ["細", "中", "粗", "特粗"])
                size.selectedSegmentIndex = sizes.firstIndex(of: settings.eraserWidth) ?? 1
                size.addAction(UIAction { [weak self, weak size] _ in
                    guard let i = size?.selectedSegmentIndex, sizes.indices.contains(i) else { return }
                    self?.settings.eraserWidth = sizes[i]
                    self?.applyTool()
                }, for: .valueChanged)
                subBarStack.addArrangedSubview(size)
            }
            let autoLabel = hintLabel("自動切回筆")
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
            let shape = UISegmentedControl(items: ["矩形", "自由形狀"])
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

        case .pageResize:
            let reset = makeButton(symbol: "arrow.counterclockwise", title: "重設", action: nil)
            reset.addAction(UIAction { [weak self] _ in
                guard let self, let i = self.resizePageIndex else { return }
                self.applyInsets(PageInsets(), pageIndex: i, toAll: false)
            }, for: .touchUpInside)
            let all = makeButton(symbol: "doc.on.doc", title: "套用全部", action: nil)
            all.addAction(UIAction { [weak self] _ in
                guard let self, let i = self.resizePageIndex, self.pages.indices.contains(i) else { return }
                self.applyInsets(self.pages[i].insets, pageIndex: i, toAll: true)
            }, for: .touchUpInside)
            let numbers = makeButton(symbol: "number", title: "數值", action: nil)
            numbers.addAction(UIAction { [weak self] _ in
                self?.presentExpandSheet(pageIndex: self?.resizePageIndex)
            }, for: .touchUpInside)
            subBarStack.addArrangedSubview(reset)
            subBarStack.addArrangedSubview(all)
            subBarStack.addArrangedSubview(numbers)

        case .tableDraw:
            if tableDrawTarget != nil {
                // 在既有表格上畫線
                let done = makeButton(symbol: "checkmark.circle.fill", title: "完成", action: nil)
                done.configuration?.baseForegroundColor = .systemBlue
                done.addAction(UIAction { [weak self] _ in self?.finishTableEditDraw() }, for: .touchUpInside)
                let undo = makeButton(symbol: "arrow.uturn.backward", title: nil, action: #selector(undoTapped))
                subBarStack.addArrangedSubview(done)
                subBarStack.addArrangedSubview(undo)
                return
            }
            let done = makeButton(symbol: "checkmark.circle.fill", title: "完成", action: nil)
            done.configuration?.baseForegroundColor = .systemBlue
            done.addAction(UIAction { [weak self] _ in self?.finishTableDraft() }, for: .touchUpInside)
            let undo = makeButton(symbol: "arrow.uturn.backward", title: "收回一條", action: nil)
            undo.addAction(UIAction { [weak self] _ in self?.undoTableDivider() }, for: .touchUpInside)
            let cancel = makeButton(symbol: "xmark", title: "取消", action: nil)
            cancel.addAction(UIAction { [weak self] _ in self?.setTool(.pen) }, for: .touchUpInside)
            subBarStack.addArrangedSubview(done)
            subBarStack.addArrangedSubview(undo)
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
            case .pencil: mark = "鉛"
            case .fountainPen: mark = "毛"
            case .crayon: mark = "蠟"
            case .watercolor: mark = "水"
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
        refreshPresetButtons()
    }

    func refreshPresetButtons() {
        for p in BrushStore.shared.presets {
            presetButtons[p.id]?.setImage(presetImage(p, selected: p.id == BrushStore.shared.currentID), for: .normal)
        }
        refreshPenStyleControls()
        updateDrawingRouting()
    }

    // MARK: 筆的線條樣式

    /// 細、中、粗（不同粗細的橫線圖示）＋虛線：改的是目前選的這支筆。長按粗細圖示可以自訂 pt
    func penStyleControls() -> [UIView] {
        let names = ["細", "中", "粗"]
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

        let dash = UIButton(configuration: .plain())
        dash.accessibilityLabel = "虛線"
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
        let editor = WidthSlotEditor(title: ["細", "中", "粗"][slot], range: style.widthRange,
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
        presentToolPopover(UIHostingController(rootView: view), from: button, size: CGSize(width: 320, height: 300))
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

    /// 粗細、虛線、筆刷設定的小視窗：開著時筆照樣可以在畫布上寫（一下筆就關掉），換工具也會關掉
    func presentToolPopover(_ vc: UIViewController, from source: UIView, size: CGSize) {
        dismissToolPopover()
        vc.modalPresentationStyle = .popover
        vc.preferredContentSize = size
        if let pop = vc.popoverPresentationController {
            pop.sourceView = source
            pop.sourceRect = source.bounds
            pop.passthroughViews = [canvas]
        }
        present(vc, animated: true)
    }

    /// 關掉小視窗。工具列重建時它依附的按鈕會被拿掉，不關的話可能卡在看不到的地方擋住所有觸控
    func dismissToolPopover() {
        guard let p = presentedViewController, p.modalPresentationStyle == .popover, !p.isBeingDismissed else { return }
        p.dismiss(animated: false)
    }

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
            UIAction(title: "調整", image: UIImage(systemName: "slider.horizontal.3")) { [weak self, weak source] _ in
                guard let self, let source, let p = BrushStore.shared.presets.first(where: { $0.id == id }) else { return }
                BrushStore.shared.select(id)
                self.setCanvasTool(p.tool)
                self.refreshPresetButtons()
                self.presentBrushSettings(p, from: source)
            },
            UIAction(title: "往左移", image: UIImage(systemName: "arrow.left")) { [weak self] _ in
                BrushStore.shared.moveLeft(id)
                self?.rebuildSubBar()
            },
            UIAction(title: "刪除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                BrushStore.shared.remove(id)
                self?.applyTool()
            },
        ])
    }

    func presentBrushSettings(_ preset: BrushPreset, from source: UIView) {
        let view = BrushSettingsView(preset: preset) { [weak self] p in
            BrushStore.shared.update(p)
            if BrushStore.shared.currentID == p.id { self?.setCanvasTool(BrushStore.shared.current.tool) }
            self?.refreshPresetButtons()
        }
        presentToolPopover(UIHostingController(rootView: view), from: source, size: CGSize(width: 340, height: 460))
    }

    // MARK: - Menus

    func makeInsertMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "表格…", image: UIImage(systemName: "tablecells")) { [weak self] _ in self?.promptInsertTable() },
            UIAction(title: "手繪新表格", image: UIImage(systemName: "pencil.and.outline")) { [weak self] _ in self?.setTool(.tableDraw) },
            UIAction(title: "文字框", image: UIImage(systemName: "character.textbox")) { [weak self] _ in self?.insertTextBox(at: nil) },
            UIAction(title: "照片…", image: UIImage(systemName: "photo")) { [weak self] _ in self?.presentPhotoPicker() },
            UIAction(title: "貼上", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.pasteFromClipboard(at: nil) },
        ])
    }

    @objc func pageLabelTapped() { presentPageOverview() }

    func makePageMenuItems() -> [UIMenuElement] {
        guard !pages.isEmpty else { return [] }
        let i = currentPageIndex
        var items: [UIMenuElement] = [
            UIAction(title: "全部頁面…", image: UIImage(systemName: "square.grid.2x2")) { [weak self] _ in self?.presentPageOverview() },
            UIAction(title: "跳到頁碼…", image: UIImage(systemName: "arrow.right.doc.on.clipboard")) { [weak self] _ in self?.presentJumpToPage() },
            UIAction(title: "在此頁後新增空白頁", image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in self?.addBlankPage(at: i + 1) },
            UIAction(title: "在此頁前新增空白頁", image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in self?.addBlankPage(at: i) },
            UIAction(title: "擴展此頁空白…", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [weak self] _ in self?.presentExpandSheet() },
        ]
        if !pages[i].insets.isZero {
            items.append(UIAction(title: "移除此頁擴展", image: UIImage(systemName: "arrow.down.right.and.arrow.up.left")) { [weak self] _ in
                self?.applyInsets(PageInsets(), pageIndex: i, toAll: false)
            })
        }
        let trashed = session.trashedPages.count
        items.append(UIAction(title: trashed > 0 ? "最近刪除的頁面（\(trashed)）…" : "最近刪除的頁面…",
                              image: UIImage(systemName: "trash.slash")) { [weak self] _ in
            self?.presentTrashedPages(from: nil)
        })
        items.append(UIAction(title: "刪除此頁", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.deletePage(i)
        })
        return items
    }

    /// 常用筆刷列靠左或靠右
    func applyPresetAlignment() {
        NSLayoutConstraint.deactivate(subBarLeftLayout + subBarRightLayout)
        NSLayoutConstraint.activate(settings.presetsOnRight ? subBarRightLayout : subBarLeftLayout)
    }

    func makeSettingsMenuItems() -> [UIMenuElement] {
        let s = settings
        let toggles = UIMenu(options: .displayInline, children: [
            UIAction(title: "Pencil 點兩下時顯示調色盤圖示", image: UIImage(systemName: "paintpalette"), state: s.paletteOnDoubleTap ? .on : .off) { _ in
                s.paletteOnDoubleTap.toggle()
            },
            UIMenu(title: "手掌防誤觸", image: UIImage(systemName: "hand.raised"), children: [
                UIAction(title: "右手寫字", state: s.palmRejection == "right" ? .on : .off) { _ in s.palmRejection = "right" },
                UIAction(title: "左手寫字", state: s.palmRejection == "left" ? .on : .off) { _ in s.palmRejection = "left" },
                UIAction(title: "關閉", state: s.palmRejection == "off" ? .on : .off) { _ in s.palmRejection = "off" },
            ]),
            UIAction(title: "筆刷列靠右", image: UIImage(systemName: "arrow.right.to.line"), state: s.presetsOnRight ? .on : .off) { [weak self] _ in
                s.presetsOnRight.toggle()
                self?.applyPresetAlignment()
            },
            UIAction(title: "用手指書寫", image: UIImage(systemName: "hand.draw"), state: s.fingerDrawing ? .on : .off) { [weak self] _ in
                s.fingerDrawing.toggle()
                self?.applyTool()
            },
            UIAction(title: "橡皮擦擦完自動切回筆", image: UIImage(systemName: "eraser"), state: s.eraserAutoReturn ? .on : .off) { [weak self] _ in
                s.eraserAutoReturn.toggle()
                if self?.tool == .eraser { self?.rebuildSubBar() }
            },
            UIAction(title: "螢光筆自動對齊 PDF 文字", image: UIImage(systemName: "highlighter"), state: s.smartHighlight ? .on : .off) { _ in
                s.smartHighlight.toggle()
            },
        ])
        let actions = UIMenu(options: .displayInline, children: [
            UIAction(title: "管理常用筆刷…", image: UIImage(systemName: "swatchpalette")) { [weak self] _ in
                self?.presentBrushManager()
            },
            UIAction(title: "匯出 PDF…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                guard let self else { return }
                self.exportPDF(from: self.settingsButton)
            },
            UIAction(title: "清除畫面上所有貼圖", image: UIImage(systemName: "pin.slash"), attributes: .destructive) { [weak self] _ in
                PinStore.shared.removeAll()
                self?.pinOverlay.reload()
            },
        ])
        return [toggles, actions]
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
            let a = UIAlertController(title: "第 \(i + 1) 頁", message: pages[i].note.isEmpty ? nil : pages[i].note, preferredStyle: .actionSheet)
            a.addAction(UIAlertAction(title: "編輯備註", style: .default) { [weak self] _ in self?.promptFavoriteNote(i, isNew: false) })
            a.addAction(UIAlertAction(title: "從我的最愛移除", style: .destructive) { [weak self] _ in
                guard let self else { return }
                self.session.document.pages[i].favorite = false
                self.afterFavoriteChange(i)
            })
            a.addAction(UIAlertAction(title: "取消", style: .cancel))
            a.popoverPresentationController?.sourceView = favoriteButton
            a.popoverPresentationController?.sourceRect = favoriteButton.bounds
            present(a, animated: true)
        } else {
            promptFavoriteNote(i, isNew: true)
        }
    }

    func promptFavoriteNote(_ i: Int, isNew: Bool) {
        let a = UIAlertController(title: isNew ? "加入我的最愛" : "編輯備註",
                                  message: "第 \(i + 1) 頁：寫下這頁有什麼資料，之後比較好找（可留空）",
                                  preferredStyle: .alert)
        a.addTextField { [weak self] tf in
            tf.text = self?.pages[i].note
            tf.placeholder = "例如：第三章公式整理"
            tf.clearButtonMode = .whileEditing
        }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: isNew ? "加入" : "儲存", style: .default) { [weak self, weak a] _ in
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
            Text("虛線樣式").font(.headline)
            DashPreview(preset: preset).frame(height: 44)
            HStack {
                Text("線段長度")
                Spacer()
                Text(String(format: "%.1f pt", Double(pattern.dash))).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { pattern.dash }, set: { preset.dashLength = ($0 * 10).rounded() / 10 }),
                   in: 0.3...30, step: 0.1)
            HStack {
                Text("間距")
                Spacer()
                Text(String(format: "%.1f pt", Double(pattern.gap))).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { pattern.gap }, set: { preset.gapLength = ($0 * 10).rounded() / 10 }),
                   in: 0.3...30, step: 0.1)
            Button("恢復預設") {
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
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: render(size: geo.size))
        }
    }

    private func render(size: CGSize) -> UIImage {
        let rect = CGRect(origin: .zero, size: size)
        guard size.width > 30 else { return UIImage() }
        let line = ShapeRecognizer.makeStroke(points: ShapeRecognizer.segment(CGPoint(x: 12, y: size.height / 2),
                                                                             CGPoint(x: size.width - 12, y: size.height / 2)),
                                              preset: preset)
        let pieces = DashedStroke.apply(line, dashed: true, lineWidth: preset.tool.width, preset: preset)
        return PKDrawing(strokes: pieces).image(from: rect, scale: scale)
    }
}
