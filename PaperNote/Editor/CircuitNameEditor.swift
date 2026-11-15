import UIKit

/// 電路名稱的編輯器（像 Desmos）：打 _ 或按「下標」，游標就跑到字的右下方的虛線框裡，接著打的字直接是下標；
/// 打空白或按「→」回到一般的字。勾「純文字」改成直接打 R_{12}、x^2 這種寫法。存起來一律是純文字的寫法
final class CircuitNameEditorViewController: UIViewController, UITextViewDelegate {
    var onDone: ((String) -> Void)?

    static let fontSize: CGFloat = 44
    static let scriptKey = NSAttributedString.Key("circuitScript")
    /// 上次選的模式（純文字或下標）
    static let plainDefaultsKey = "circuitNamePlainText"

    let textView = UITextView()
    let plainToggle = UIButton(type: .system)
    let subButton = UIButton(type: .system)
    let supButton = UIButton(type: .system)
    let exitButton = UIButton(type: .system)
    /// 下標、上標的虛線框
    private let box = CAShapeLayer()
    private let initial: String
    private let hint: String?
    private let placeholder: String

    /// 接著打的字是一般、下標還是上標
    private(set) var mode: CircuitText.Script = .normal { didSet { updateChrome() } }
    private(set) var plain: Bool

    init(title: String, text: String, placeholder: String, hint: String? = nil) {
        initial = text
        self.hint = hint
        self.placeholder = placeholder
        plain = UserDefaults.standard.bool(forKey: Self.plainDefaultsKey)
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 字的樣子

    static func attributes(_ s: CircuitText.Script) -> [NSAttributedString.Key: Any] {
        let f = fontSize
        switch s {
        case .normal:
            return [.font: UIFont.systemFont(ofSize: f), .foregroundColor: UIColor.label, scriptKey: 0]
        case .sub:
            return [.font: UIFont.systemFont(ofSize: f * CircuitText.scriptScale), .foregroundColor: UIColor.label,
                    .baselineOffset: -f * 0.22, scriptKey: 1]
        case .sup:
            return [.font: UIFont.systemFont(ofSize: f * CircuitText.scriptScale), .foregroundColor: UIColor.label,
                    .baselineOffset: f * 0.38, scriptKey: 2]
        }
    }

    static let plainAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.monospacedSystemFont(ofSize: 34, weight: .regular), .foregroundColor: UIColor.label,
    ]

    /// 純文字的寫法 → 畫出來的樣子
    static func rich(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in CircuitText.runs(text) { out.append(NSAttributedString(string: run.text, attributes: attributes(run.script))) }
        return out
    }

    static func script(at i: Int, in s: NSAttributedString) -> CircuitText.Script {
        guard i >= 0, i < s.length else { return .normal }
        switch s.attribute(scriptKey, at: i, effectiveRange: nil) as? Int {
        case 1: return .sub
        case 2: return .sup
        default: return .normal
        }
    }

    /// 畫出來的樣子 → 純文字的寫法：一個英數字、後面不是英數字就寫 R_1，其他用大括號 V_{in}
    static func serialize(_ s: NSAttributedString) -> String {
        var runs: [CircuitText.Run] = []
        let ns = s.string as NSString
        var i = 0
        while i < s.length {
            let sc = script(at: i, in: s)
            var j = i
            while j < s.length, script(at: j, in: s) == sc { j += 1 }
            runs.append(CircuitText.Run(text: ns.substring(with: NSRange(location: i, length: j - i)), script: sc))
            i = j
        }
        var out = ""
        for (k, r) in runs.enumerated() {
            guard r.script != .normal else { out += r.text; continue }
            let mark = r.script == .sub ? "_" : "^"
            let next = runs.indices.contains(k + 1) ? runs[k + 1].text.first : nil
            let alnum = { (c: Character) in c.isLetter || c.isNumber }
            let bare = r.text.allSatisfy(alnum) && !r.text.isEmpty && !(next.map(alnum) ?? false)
            out += bare ? mark + r.text : mark + "{" + r.text + "}"
        }
        return out
    }

    /// 現在的內容（純文字的寫法）
    var value: String {
        plain ? textView.text : Self.serialize(textView.attributedText)
    }

    // MARK: 畫面

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        let done = UIBarButtonItem(primaryAction: UIAction(title: L("完成")) { [weak self] _ in self?.finish() })
        done.style = .done
        navigationItem.rightBarButtonItem = done

        textView.delegate = self
        textView.backgroundColor = .systemBackground
        textView.layer.cornerRadius = 14
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.textContainerInset = UIEdgeInsets(top: 30, left: 18, bottom: 26, right: 18)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.returnKeyType = .done
        textView.accessibilityIdentifier = "circuitName.field"
        textView.translatesAutoresizingMaskIntoConstraints = false
        box.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
        box.strokeColor = UIColor.systemBlue.cgColor
        box.lineWidth = 1.5
        box.lineDashPattern = [4, 3]
        textView.layer.addSublayer(box)

        func style(_ b: UIButton, _ title: String, _ symbol: String, id: String) {
            var c = UIButton.Configuration.tinted()
            c.title = title
            c.image = UIImage(systemName: symbol)
            c.imagePadding = 6
            c.buttonSize = .large
            b.configuration = c
            b.accessibilityIdentifier = id
        }
        style(subButton, L("下標"), "textformat.subscript", id: "circuitName.sub")
        style(supButton, L("上標"), "textformat.superscript", id: "circuitName.sup")
        style(exitButton, L("回到一般的字"), "arrow.right", id: "circuitName.exit")
        subButton.addAction(UIAction { [weak self] _ in self?.enter(.sub) }, for: .touchUpInside)
        supButton.addAction(UIAction { [weak self] _ in self?.enter(.sup) }, for: .touchUpInside)
        exitButton.addAction(UIAction { [weak self] _ in self?.enter(.normal) }, for: .touchUpInside)

        var pc = UIButton.Configuration.plain()
        pc.imagePadding = 8
        pc.title = L("純文字（直接打 R_1、x^2）")
        plainToggle.configuration = pc
        plainToggle.accessibilityIdentifier = "circuitName.plain"
        plainToggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setPlain(!self.plain)
        }, for: .touchUpInside)

        let keys = UIStackView(arrangedSubviews: [subButton, supButton, exitButton])
        keys.spacing = 10
        keys.distribution = .fillEqually
        let hintLabel = UILabel()
        hintLabel.text = hint
        hintLabel.font = .preferredFont(forTextStyle: .footnote)
        hintLabel.textColor = .secondaryLabel
        hintLabel.numberOfLines = 0
        hintLabel.isHidden = hint == nil
        let stack = UIStackView(arrangedSubviews: [textView, keys, plainToggle, hintLabel])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            // 預覽的框放大：下標在 iPad 上才看得清楚、點得到
            textView.heightAnchor.constraint(equalToConstant: 130),
        ])
        preferredContentSize = CGSize(width: 540, height: 360)
        load(initial)
        setPlain(plain)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateBox()
    }

    private func load(_ text: String) {
        textView.attributedText = plain ? NSAttributedString(string: text, attributes: Self.plainAttributes) : Self.rich(text)
        textView.selectedRange = NSRange(location: textView.attributedText.length, length: 0)
        syncModeWithCursor()
    }

    /// 切換純文字／下標的樣子（內容不變），記住下次用同一種
    func setPlain(_ on: Bool) {
        let v = value
        plain = on
        UserDefaults.standard.set(on, forKey: Self.plainDefaultsKey)
        load(v)
        plainToggle.configuration?.image = UIImage(systemName: on ? "checkmark.square.fill" : "square")
        plainToggle.accessibilityValue = on ? "1" : "0"
        textView.typingAttributes = on ? Self.plainAttributes : Self.attributes(mode)
        updateChrome()
    }

    /// 接著打的字變成下標（上標、一般的字）
    func enter(_ s: CircuitText.Script) {
        if plain {
            // 純文字：插入記號（游標在 {} 裡面）
            guard s != .normal else { return }
            insertPlain(s == .sub ? "_{}" : "^{}", cursorBack: 1)
            return
        }
        mode = s
        textView.typingAttributes = Self.attributes(s)
    }

    private func insertPlain(_ t: String, cursorBack: Int) {
        let r = textView.selectedRange
        let ns = (textView.text ?? "") as NSString
        let picked = ns.substring(with: r)
        let insert = picked.isEmpty ? t : String(t.dropLast()) + picked + "}"
        textView.textStorage.replaceCharacters(in: r, with: NSAttributedString(string: insert, attributes: Self.plainAttributes))
        let back = picked.isEmpty ? cursorBack : 0
        textView.selectedRange = NSRange(location: r.location + (insert as NSString).length - back, length: 0)
    }

    private var syncingSelection = false

    /// 游標移到哪裡，接著打的字就跟游標前面那個字一樣（在下標裡就繼續打下標）
    private func syncModeWithCursor() {
        guard !plain else { mode = .normal; return }
        let r = textView.selectedRange
        mode = Self.script(at: r.location - 1, in: textView.attributedText)
        textView.typingAttributes = Self.attributes(mode)
    }

    private func updateChrome() {
        guard isViewLoaded else { return }
        subButton.isSelected = !plain && mode == .sub
        supButton.isSelected = !plain && mode == .sup
        exitButton.isEnabled = !plain && mode != .normal
        updateBox()
    }

    /// 虛線框：游標在下標（上標）裡時框住那一段；還沒打字就是一個空的框，在游標的右下（右上）
    private func updateBox() {
        guard !plain, mode != .normal, let full = textView.attributedText else { box.path = nil; return }
        let caret = textView.selectedRange.location
        let f = Self.fontSize
        // 這一段下標的範圍
        var start = caret, end = caret
        while start > 0, Self.script(at: start - 1, in: full) == mode { start -= 1 }
        while end < full.length, Self.script(at: end, in: full) == mode { end += 1 }
        let small = f * CircuitText.scriptScale
        var rect: CGRect
        if start < end, let a = textView.position(from: textView.beginningOfDocument, offset: start),
           let b = textView.position(from: textView.beginningOfDocument, offset: end),
           let range = textView.textRange(from: a, to: b) {
            rect = textView.firstRect(for: range)
        } else if let p = textView.position(from: textView.beginningOfDocument, offset: caret) {
            let c = textView.caretRect(for: p)
            let base = c.maxY - f * 0.25
            let y = mode == .sub ? base - small * 0.55 : base - f * 0.38 - small * 0.95
            rect = CGRect(x: c.minX + 2, y: y, width: small * 0.62, height: small)
        } else {
            box.path = nil
            return
        }
        guard !rect.isNull, !rect.isInfinite else { box.path = nil; return }
        rect = rect.insetBy(dx: -3, dy: -2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.path = UIBezierPath(roundedRect: rect, cornerRadius: 4).cgPath
        CATransaction.commit()
    }

    // MARK: UITextViewDelegate

    func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n" {
            finish()
            return false
        }
        guard !plain else { return true }
        // _、^：進到下標（上標）的框裡；在框裡打空白：回到一般的字
        switch text {
        case "_": enter(.sub); return false
        case "^": enter(.sup); return false
        case " " where mode != .normal: enter(.normal); return false
        default:
            tv.typingAttributes = Self.attributes(mode)
            return true
        }
    }

    func textViewDidChange(_ tv: UITextView) {
        updateBox()
    }

    func textViewDidChangeSelection(_ tv: UITextView) {
        // 打字時游標跟著移動：模式不變（打完下標還在下標裡）
        let r = tv.selectedRange
        if !plain, r.length == 0, r.location > 0, Self.script(at: r.location - 1, in: tv.attributedText) == mode {
            updateBox()
            return
        }
        syncModeWithCursor()
    }

    /// 測試用：在游標的位置打字（和鍵盤打字一樣經過 shouldChangeTextIn）
    func type(_ s: String) {
        for ch in s {
            let t = String(ch)
            let r = textView.selectedRange
            if textView(textView, shouldChangeTextIn: r, replacementText: t) {
                textView.insertText(t)
            }
        }
    }

    private func finish() {
        let v = value
        let done = onDone
        textView.resignFirstResponder()
        dismiss(animated: true) { done?(v) }
    }
}

extension UIViewController {
    /// 跳出電路名稱的編輯器（表單大小的視窗）
    func presentCircuitNameEditor(title: String, text: String?, placeholder: String, hint: String? = nil, done: @escaping (String) -> Void) {
        let editor = CircuitNameEditorViewController(title: title, text: text ?? "", placeholder: placeholder, hint: hint)
        editor.onDone = done
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .formSheet
        nav.preferredContentSize = CGSize(width: 540, height: 400)
        present(nav, animated: true)
    }
}
