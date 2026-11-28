import UIKit

// 手勢標記學習模式（右上角「⋯」→ Apple Pencil 設定 → 手勢標記學習模式）：
// 每次手指或手掌碰完頁面（全部離開螢幕），跳出一個小框問這一下是手指還是手掌，連同觸碰的資料記下來。
// 分享出去的資料拿來找出防誤觸的判斷條件（見 isPalmTouch）。只記觸碰的大小、位置、時間，不記筆記內容

/// 標記好的一個觸碰
struct PalmLabelSample: Codable, Equatable {
    /// 同一下（第一個觸碰按下到全部放開）的觸碰是同一個值
    var group: UUID
    /// "finger" 或 "palm"
    var label: String
    var time: Date
    /// 按下時的 majorRadius、majorRadiusTolerance
    var radius: Double
    var radiusTolerance: Double
    /// 這個觸碰從按下到放開最大的 majorRadius
    var maxRadius: Double
    /// 按下時螢幕上同時按著幾個手指觸碰（連它在內）、這一下最多同時幾個
    var together: Int
    var maxTogether: Int
    /// 這一下總共有幾個觸碰
    var touchesInGroup: Int
    /// 按下時筆尖正在接觸螢幕、距離筆尖上次移動幾秒、和筆尖最後位置差多少（畫面座標）
    var pencilDown: Bool
    var sincePencil: Double
    var fromPencilX: Double?
    var fromPencilY: Double?
    /// 按下的位置（畫面寬、高的比例，0～1）
    var x: Double
    var y: Double
    /// 按著多久、總共移動多長、起點到終點多遠
    var duration: Double
    var distance: Double
    var displacement: Double
    /// App 現在的判斷（isPalmTouch）
    var appSaidPalm: Bool
    var tool: String
}

/// 標記好的資料存在 App 自己的資料夾（不在筆記本裡，不會備份到雲端）
final class PalmLabelStore {
    static let shared = PalmLabelStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("palm-labels.json"))

    let url: URL
    private(set) var samples: [PalmLabelSample] = []

    init(url: URL) {
        self.url = url
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder.app.decode([PalmLabelSample].self, from: d) {
            samples = s
        }
    }

    /// 這一下有幾個不同的觸碰組（使用者標了幾次）
    var labeledCount: Int { Set(samples.map(\.group)).count }

    func add(_ new: [PalmLabelSample]) {
        guard !new.isEmpty else { return }
        samples += new
        write()
    }

    func clear() {
        samples = []
        try? FileManager.default.removeItem(at: url)
    }

    /// 分享用的檔案（暫存資料夾裡的一份）
    func exportFile() throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("PaperNote-palm-labels.json")
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        try e.encode(samples).write(to: out, options: .atomic)
        return out
    }

    private func write() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = try? JSONEncoder.app.encode(samples) else { return }
        try? d.write(to: url, options: .atomic)
    }
}

/// 記錄頁面上每一個手指觸碰：按下時的狀態、移動多少、按多久。全部放開時交出這一下的所有觸碰。
/// 只旁觀：不會開始、不擋其他手勢，也不會被其他手勢擋掉
final class TouchLabelRecorder: UIGestureRecognizer {
    /// 按下那一刻的狀態（由編輯畫面填：筆的狀態、App 的判斷）
    struct Context {
        var pencilDown: Bool
        var sincePencil: Double
        /// 和筆尖最後位置差多少（畫面座標）
        var fromPencil: CGPoint?
        var appSaidPalm: Bool
        var tool: String
    }

    var context: ((UITouch, Int) -> Context)?
    /// 這一下（全部觸碰都放開）記到的觸碰，還沒標記
    var onGroupEnded: (([PalmLabelSample]) -> Void)?

    private struct Tracked {
        var sample: PalmLabelSample
        var start: CGPoint
        var last: CGPoint
        var began: TimeInterval
    }

    private var active: [ObjectIdentifier: (touch: UITouch, info: Tracked)] = [:]
    private var finished: [PalmLabelSample] = []
    private var group = UUID()
    private var maxTogether = 0

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // 放開的消息沒送來的觸碰（見 UITouch.isOver）：不知道它怎麼結束的，不記
        for (key, a) in active where a.touch.isOver(in: event) { active[key] = nil }
        let together = event.allTouches?.filter { $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled }.count ?? touches.count
        maxTogether = max(maxTogether, together)
        for t in touches {
            guard t.type == .direct, let window = view?.window, let ctx = context?(t, max(together, 1)) else {
                ignore(t, for: event)
                continue
            }
            if active.isEmpty && finished.isEmpty {
                group = UUID()
                maxTogether = max(together, 1)
            }
            // 用畫面（視窗）座標：畫布座標會跟著捲動、縮放變
            let p = t.location(in: nil)
            let size = window.bounds.size
            let s = PalmLabelSample(
                group: group, label: "", time: Date(),
                radius: Double(t.majorRadius), radiusTolerance: Double(t.majorRadiusTolerance), maxRadius: Double(t.majorRadius),
                together: max(together, 1), maxTogether: 0, touchesInGroup: 0,
                pencilDown: ctx.pencilDown, sincePencil: ctx.sincePencil,
                fromPencilX: ctx.fromPencil.map { Double($0.x) }, fromPencilY: ctx.fromPencil.map { Double($0.y) },
                x: size.width > 0 ? Double(p.x / size.width) : 0, y: size.height > 0 ? Double(p.y / size.height) : 0,
                duration: 0, distance: 0, displacement: 0, appSaidPalm: ctx.appSaidPalm, tool: ctx.tool)
            active[ObjectIdentifier(t)] = (t, Tracked(sample: s, start: p, last: p, began: t.timestamp))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches {
            guard var a = active[ObjectIdentifier(t)]?.info else { continue }
            let p = t.location(in: nil)
            a.sample.distance += Double(hypot(p.x - a.last.x, p.y - a.last.y))
            a.sample.maxRadius = max(a.sample.maxRadius, Double(t.majorRadius))
            a.last = p
            active[ObjectIdentifier(t)] = (t, a)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }

    override func reset() {
        super.reset()
        active.removeAll()
        finished.removeAll()
    }

    private func lift(_ touches: Set<UITouch>) {
        for t in touches {
            let key = ObjectIdentifier(t)
            guard active[key] != nil else { continue }
            finish(key, at: t.location(in: nil), time: t.timestamp)
        }
        guard active.isEmpty else { return }
        let done = finished.map { s -> PalmLabelSample in
            var s = s
            s.maxTogether = maxTogether
            s.touchesInGroup = finished.count
            return s
        }
        finished.removeAll()
        maxTogether = 0
        // 這一下結束：交出去，回到可以收下一下的狀態
        state = .failed
        if !done.isEmpty { onGroupEnded?(done) }
    }

    private func finish(_ key: ObjectIdentifier, at end: CGPoint?, time: TimeInterval) {
        guard let a = active.removeValue(forKey: key) else { return }
        var s = a.info.sample
        let p = end ?? a.info.last
        s.distance += Double(hypot(p.x - a.info.last.x, p.y - a.info.last.y))
        s.displacement = Double(hypot(p.x - a.info.start.x, p.y - a.info.start.y))
        s.duration = max(0, time - a.info.began)
        finished.append(s)
    }
}

/// 問「剛才那一下是手指還是手掌？」的小框（不擋畫面：放在上方，不回答過一陣子自己消失、不記）
final class PalmLabelPrompt: UIView {
    static let timeout: TimeInterval = 8
    let fingerButton = UIButton(type: .system)
    let palmButton = UIButton(type: .system)
    let skipButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    var onAnswer: ((String?) -> Void)?
    private var timer: Timer?

    init(appSaidPalm: Bool, touches: Int, labeled: Int) {
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.82)
        layer.cornerRadius = 14
        accessibilityIdentifier = "palmLabelPrompt"
        let verdict = appSaidPalm ? L("手掌") : L("手指")
        titleLabel.text = L("剛才那一下是？（App 判成\(verdict)，\(touches) 個觸碰；已標 \(labeled) 次）")
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        for (b, title, answer) in [(fingerButton, L("手指"), "finger"), (palmButton, L("手掌"), "palm"), (skipButton, L("略過"), nil)] as [(UIButton, String, String?)] {
            var c = UIButton.Configuration.filled()
            c.title = title
            c.baseBackgroundColor = answer == nil ? .darkGray : (answer == "palm" ? .systemOrange : .systemBlue)
            c.baseForegroundColor = .white
            c.cornerStyle = .capsule
            c.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
            b.configuration = c
            b.addAction(UIAction { [weak self] _ in self?.answer(answer) }, for: .touchUpInside)
        }
        let buttons = UIStackView(arrangedSubviews: [fingerButton, palmButton, skipButton])
        buttons.spacing = 10
        let stack = UIStackView(arrangedSubviews: [titleLabel, buttons])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        timer = Timer.scheduledTimer(withTimeInterval: Self.timeout, repeats: false) { [weak self] _ in self?.answer(nil) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func answer(_ label: String?) {
        timer?.invalidate()
        timer = nil
        let done = onAnswer
        onAnswer = nil
        removeFromSuperview()
        done?(label)
    }
}

extension NotebookViewController {
    func setupPalmLabeling() {
        palmLabelRecorder = TouchLabelRecorder(target: nil, action: nil)
        palmLabelRecorder.context = { [weak self] t, together in
            guard let self else { return .init(pencilDown: false, sincePencil: 0, fromPencil: nil, appSaidPalm: false, tool: "") }
            let p = t.location(in: self.view)
            return .init(pencilDown: self.pencilDown,
                         sincePencil: CACurrentMediaTime() - self.lastPencilTime,
                         fromPencil: self.lastPencilPoint.map { CGPoint(x: p.x - $0.x, y: p.y - $0.y) },
                         appSaidPalm: self.isPalmTouch(t, together: together),
                         tool: "\(self.tool)")
        }
        palmLabelRecorder.onGroupEnded = { [weak self] samples in self?.askPalmLabel(samples) }
        palmLabelRecorder.isEnabled = settings.palmLabeling
        canvas.addGestureRecognizer(palmLabelRecorder)
    }

    /// 打開或關掉標記模式
    func setPalmLabeling(_ on: Bool) {
        settings.palmLabeling = on
        palmLabelRecorder.isEnabled = on
        if !on { palmLabelPrompt?.answer(nil) }
        showToast(on ? L("手勢標記學習模式：每次手指或手掌碰完頁面，選這一下是手指還是手掌") : L("已關閉手勢標記學習模式"))
    }

    /// 這一下結束：跳出小框問是手指還是手掌（上一個還沒回答的不記）
    func askPalmLabel(_ samples: [PalmLabelSample]) {
        palmLabelPrompt?.answer(nil)
        let prompt = PalmLabelPrompt(appSaidPalm: samples.contains(where: \.appSaidPalm), touches: samples.count,
                                     labeled: PalmLabelStore.shared.labeledCount)
        prompt.onAnswer = { label in
            guard let label else { return }
            PalmLabelStore.shared.add(samples.map { var s = $0; s.label = label; return s })
            DebugLog.add("palm label \(label) touches=\(samples.count) appSaidPalm=\(samples.map(\.appSaidPalm))")
        }
        prompt.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(prompt)
        NSLayoutConstraint.activate([
            prompt.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            prompt.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 12),
            prompt.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
        ])
        palmLabelPrompt = prompt
    }

    /// 分享標記好的資料（JSON）
    func sharePalmLabels(from source: UIView?) {
        guard !PalmLabelStore.shared.samples.isEmpty else {
            showToast(L("還沒有標記資料：先打開手勢標記學習模式"))
            return
        }
        do {
            let url = try PalmLabelStore.shared.exportFile()
            let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            vc.popoverPresentationController?.sourceView = source ?? view
            vc.popoverPresentationController?.sourceRect = (source ?? view).bounds
            present(vc, animated: true)
        } catch {
            showMessage(L("匯出失敗"), error.localizedDescription)
        }
    }

    func confirmClearPalmLabels() {
        let a = UIAlertController(title: L("清除手勢標記資料？"),
                                  message: L("已標記的 \(PalmLabelStore.shared.labeledCount) 次都會刪掉，不能復原。"),
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        a.addAction(UIAlertAction(title: L("清除"), style: .destructive) { _ in PalmLabelStore.shared.clear() })
        present(a, animated: true)
    }

    func palmLabelingMenu() -> UIMenu {
        let s = settings
        let count = PalmLabelStore.shared.labeledCount
        return UIMenu(title: L("手勢標記學習模式"), image: UIImage(systemName: "hand.raised.square"), children: [
            UIAction(title: L("標記每一下觸碰"), subtitle: L("碰完頁面時選是手指還是手掌"), state: s.palmLabeling ? .on : .off) { [weak self] _ in
                self?.setPalmLabeling(!s.palmLabeling)
            },
            UIAction(title: L("分享標記資料（\(count) 次）"), image: UIImage(systemName: "square.and.arrow.up"),
                     attributes: count == 0 ? .disabled : []) { [weak self] _ in
                self?.sharePalmLabels(from: self?.settingsButton)
            },
            UIAction(title: L("清除標記資料"), image: UIImage(systemName: "trash"),
                     attributes: count == 0 ? [.destructive, .disabled] : .destructive) { [weak self] _ in
                self?.confirmClearPalmLabels()
            },
        ])
    }
}
