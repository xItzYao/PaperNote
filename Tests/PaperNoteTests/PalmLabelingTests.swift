import XCTest
@testable import PaperNote

/// 手勢標記學習模式：每次手指或手掌碰完頁面，問這一下是手指還是手掌，連同觸碰的資料記下來（拿來找防誤觸的條件）
final class PalmLabelingTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var wasOn = false

    override func setUpWithError() throws {
        wasOn = EditorSettings.shared.palmLabeling
        EditorSettings.shared.palmLabeling = true
        PalmLabelStore.shared.clear()
        let meta = LibraryStore.shared.createNotebook(title: "PalmLabeling", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    override func tearDown() {
        EditorSettings.shared.palmLabeling = wasOn
        PalmLabelStore.shared.clear()
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    /// 手掌放下去：兩個觸碰一起按、移動一點、全部放開 → 跳出小框；選「手掌」就記下兩筆，各自的大小、移動都在
    func testAPalmGroupIsAskedOnceAndSavedWithItsTouches() throws {
        let rec = try XCTUnwrap(editor.palmLabelRecorder)
        XCTAssertTrue(rec.isEnabled)
        let a = FakeTouch(type: .direct, radius: 62.6, location: CGPoint(x: 600, y: 700))
        let b = FakeTouch(type: .direct, radius: 41.7, location: CGPoint(x: 660, y: 720))
        rec.touchesBegan([a, b], with: FakeEvent([a, b]))
        XCTAssertNil(editor.palmLabelPrompt, "還沒放開不問")
        a.point = CGPoint(x: 603, y: 704)
        a.fakePhase = .moved
        rec.touchesMoved([a], with: FakeEvent([a, b]))
        a.fakePhase = .ended
        rec.touchesEnded([a], with: FakeEvent([a, b]))
        XCTAssertNil(editor.palmLabelPrompt, "還有一個按著：還沒結束")
        b.fakePhase = .ended
        rec.touchesEnded([b], with: FakeEvent([b]))

        let prompt = try XCTUnwrap(editor.palmLabelPrompt, "全部放開：問這一下是什麼")
        XCTAssertNotNil(prompt.superview)
        prompt.palmButton.sendActions(for: .touchUpInside)
        XCTAssertNil(editor.palmLabelPrompt, "回答完小框就收起來")

        let saved = PalmLabelStore.shared.samples
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(Set(saved.map(\.label)), ["palm"])
        XCTAssertEqual(Set(saved.map(\.group)).count, 1, "同一下")
        XCTAssertEqual(PalmLabelStore.shared.labeledCount, 1)
        XCTAssertEqual(saved.map(\.touchesInGroup), [2, 2])
        XCTAssertEqual(saved.map(\.maxTogether), [2, 2])
        let first = try XCTUnwrap(saved.first { $0.radius > 60 })
        XCTAssertEqual(first.distance, 5, accuracy: 0.01, "移動了 (3, 4)")
        XCTAssertEqual(first.displacement, 5, accuracy: 0.01)
        XCTAssertTrue(first.appSaidPalm, "62.6 的觸碰 App 判成手掌")

        // 存到磁碟：重新讀得回來，分享出去的檔案也是這些
        let reloaded = PalmLabelStore(url: PalmLabelStore.shared.url)
        XCTAssertEqual(reloaded.samples, saved)
        let exported = try JSONSerialization.jsonObject(with: Data(contentsOf: PalmLabelStore.shared.exportFile())) as? [[String: Any]]
        XCTAssertEqual(exported?.count, 2)
        XCTAssertEqual(exported?.first?["label"] as? String, "palm")
    }

    func testSkippingOrAnsweringNothingSavesNothing() throws {
        let rec = try XCTUnwrap(editor.palmLabelRecorder)
        tap(rec, at: CGPoint(x: 300, y: 300))
        try XCTUnwrap(editor.palmLabelPrompt).skipButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(PalmLabelStore.shared.samples.isEmpty, "略過不記")

        tap(rec, at: CGPoint(x: 300, y: 300))
        let unanswered = try XCTUnwrap(editor.palmLabelPrompt)
        tap(rec, at: CGPoint(x: 320, y: 300))
        XCTAssertNil(unanswered.superview, "下一下開始問，上一個沒回答的收掉")
        try XCTUnwrap(editor.palmLabelPrompt).fingerButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(PalmLabelStore.shared.samples.map(\.label), ["finger"], "只記回答的那一下")
    }

    func testPencilTouchesAreNotAskedAbout() throws {
        let rec = try XCTUnwrap(editor.palmLabelRecorder)
        let pencil = FakeTouch(type: .pencil, location: CGPoint(x: 300, y: 300))
        rec.touchesBegan([pencil], with: FakeEvent([pencil]))
        pencil.fakePhase = .ended
        rec.touchesEnded([pencil], with: FakeEvent([pencil]))
        XCTAssertNil(editor.palmLabelPrompt)
    }

    func testTurningTheModeOffStopsAsking() throws {
        editor.setPalmLabeling(false)
        XCTAssertFalse(editor.palmLabelRecorder.isEnabled)
        XCTAssertFalse(EditorSettings.shared.palmLabeling)
        editor.setPalmLabeling(true)
        XCTAssertTrue(editor.palmLabelRecorder.isEnabled)
    }

    func testTheSettingsMenuHasTheLabelingMode() throws {
        func titles(_ items: [UIMenuElement]) -> [String] {
            items.flatMap { e -> [String] in
                if let m = e as? UIMenu { return [m.title] + titles(m.children) }
                return [e.title]
            }
        }
        let all = titles(editor.makeSettingsMenuItems())
        XCTAssertTrue(all.contains(L("手勢標記學習模式")))
        XCTAssertTrue(all.contains(L("標記每一下觸碰")))
        XCTAssertTrue(all.contains(L("分享標記資料（\(0) 次）")))
    }

    private func tap(_ rec: TouchLabelRecorder, at p: CGPoint) {
        let t = FakeTouch(type: .direct, radius: 20.8, location: p)
        rec.touchesBegan([t], with: FakeEvent([t]))
        t.fakePhase = .ended
        rec.touchesEnded([t], with: FakeEvent([t]))
    }
}
