import XCTest
import PencilKit
@testable import PaperNote

/// 回報的問題（11/26）：一本 10 頁的 PDF 作業，擦第 10 頁的螢光筆很卡（主執行緒卡好幾百毫秒，最久卡了 51 秒），
/// 空白筆記本、其他 PDF 都正常。那本的規模：10 頁共用一張畫布，PencilKit 筆跡 2533 筆（大多在第 7、8 頁），
/// 第 7～10 頁有約 660 筆自製筆刷的字，第 10 頁有一大塊來回塗的螢光筆和幾個螢光筆圖形
final class EraserScaleTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var savedPixel = false
    private var savedReturn = false

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "EraserScale", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        let session = try NotebookSession(id: meta.id)
        session.document.pages = (0..<10).map { _ in Page(background: .paper(width: 595, height: 842, style: .blank)) }
        let pages = session.document.pages
        // 第 7、8 頁：PencilKit 寫滿的字（每筆 24 個點）
        for (pageIndex, count) in [(6, 1500), (7, 1000)] {
            let strokes = (0..<count).map { k -> PKStroke in
                let row = k / 40, col = k % 40
                let x = 30 + CGFloat(col) * 13, y = 30 + CGFloat(row % 60) * 13
                let pts = (0..<24).map { i in
                    PKStrokePoint(location: CGPoint(x: x + CGFloat(i) * 0.4, y: y + sin(CGFloat(i + k)) * 4), timeOffset: Double(i) * 0.008,
                                  size: CGSize(width: 2.5, height: 2.5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                return PKStroke(ink: PKInk(.pen, color: .systemBlue),
                                path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSinceNow: -Double(10_000 - k))))
            }
            session.drawings[pages[pageIndex].id] = PKDrawing(strokes: strokes)
        }
        // 第 7～10 頁：自製筆刷的字（每筆 65 個點）
        for pageIndex in 6...9 {
            session.document.pages[pageIndex].ink = (0..<165).map { k in
                let x = 40 + CGFloat(k % 15) * 34, y = 60 + CGFloat(k / 15) * 60
                return InkStroke(colorHex: "#1E3A8AFF", points: (0..<65).map { i in
                    InkPoint(CGPoint(x: x + CGFloat(i) * 0.45, y: y + sin(CGFloat(i) / 4) * 8), width: 2.2)
                })
            }
        }
        // 第 10 頁：一大塊來回塗的螢光筆、一條直的、三個圓
        let yellow = PKInk(.monoline, color: UIColor.systemYellow.withAlphaComponent(0.35))
        func highlighter(_ pts: [CGPoint], _ ago: Double) -> PKStroke {
            PKStroke(ink: yellow, path: PKStrokePath(controlPoints: pts.enumerated().map { i, p in
                PKStrokePoint(location: p, timeOffset: Double(i) * 0.008, size: CGSize(width: 12, height: 12),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }, creationDate: Date(timeIntervalSinceNow: -ago)))
        }
        var scribble: [CGPoint] = []
        for pass in 0..<14 {
            for i in 0...60 {
                let t = CGFloat(i) / 60
                let x = pass % 2 == 0 ? 120 + t * 360 : 480 - t * 360
                scribble.append(CGPoint(x: x, y: 150 + CGFloat(pass) * 16 + t * 30 + sin(t * 9) * 6))
            }
        }
        let circles = (0..<3).map { c in
            highlighter((0...120).map { i in
                let a = CGFloat(i) / 120 * 2 * .pi
                return CGPoint(x: 180 + CGFloat(c) * 140 + cos(a) * 50, y: 560 + sin(a) * 50)
            }, 30 - Double(c))
        }
        session.drawings[pages[9].id] = PKDrawing(strokes: [
            highlighter(scribble, 100),
            highlighter(stride(from: CGFloat(150), through: 450, by: 3).map { CGPoint(x: $0, y: 480) }, 90),
        ] + circles)
        session.save()

        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        editor.scrollToPage(9, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        savedPixel = EditorSettings.shared.pixelEraser
        savedReturn = EditorSettings.shared.eraserAutoReturn
        EditorSettings.shared.eraserAutoReturn = false
    }

    override func tearDown() {
        EditorSettings.shared.pixelEraser = savedPixel
        EditorSettings.shared.eraserAutoReturn = savedReturn
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    /// 在第 10 頁來回擦過螢光筆，回傳每移動一下最久多久、全部多久；印出時間花在哪
    private func eraseAcrossTheHighlights(partial: Bool) -> (moves: FrameTimes, total: Double) {
        let o = editor.contentOrigin(9)
        var path: [CGPoint] = []
        for k in 0..<80 { path.append(CGPoint(x: o.x + 140 + CGFloat(k) * 4, y: o.y + 160 + sin(CGFloat(k) / 5) * 90)) }
        for k in 0..<80 { path.append(CGPoint(x: o.x + 460 - CGFloat(k) * 4, y: o.y + 330 + CGFloat(k % 9) * 30)) }
        return erase(along: path, partial: partial, label: "ERASESCALE")
    }

    /// 沿著 path 擦（每個點是一次移動），回傳每移動一下各花多久、全部多久
    private func erase(along path: [CGPoint], partial: Bool, label: String) -> (moves: FrameTimes, total: Double) {
        EditorSettings.shared.pixelEraser = partial
        editor.setTool(.eraser)
        XCTAssertEqual(editor.canvas.drawing.strokes.count, 2505, "測試的前提：整本的 PencilKit 筆跡都在畫布上")
        StrokeEraser.counts = .init()
        var worst = 0.0, worstLine = "", moves = FrameTimes()
        let start = CACurrentMediaTime()
        editor.eraserBegan(at: path[0])
        for p in path.dropFirst() {
            let c0 = StrokeEraser.counts.seconds
            let t = CACurrentMediaTime()
            editor.eraserMoved([p])
            let dt = CACurrentMediaTime() - t
            moves.add(dt)
            if dt > worst {
                worst = dt
                worstLine = String(format: "move %.0fms (stroke eraser %.0fms, rest %.0fms)", dt * 1000,
                                   (StrokeEraser.counts.seconds - c0) * 1000, (dt - (StrokeEraser.counts.seconds - c0)) * 1000)
            }
        }
        editor.eraserEnded()
        let total = CACurrentMediaTime() - start
        let c = StrokeEraser.counts
        print(String(format: "%@ partial=%d moves=%d total=%.0fms worst=%@ %@ strokeEraser=%.0fms samples=%d inside=%d derived=%d strokes=%d",
                     label, partial ? 1 : 0, path.count - 1, total * 1000, worstLine, moves.summary, c.seconds * 1000, c.samples, c.inside, c.derived,
                     editor.canvas.drawing.strokes.count))
        return (moves, total)
    }

    /// 回報的問題（11/26）：快速來回擦一大片原子筆的字，擦掉的地方跟不上筆。
    /// 第 7 頁寫滿 PencilKit 的字；iPad 每一格畫面（1/60 秒）送一次位置，快速擦時一格走 20～30pt
    private func scrubAcrossPage7() -> [CGPoint] {
        editor.scrollToPage(6, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let o = editor.contentOrigin(6)
        var path: [CGPoint] = []
        for pass in 0..<6 {
            for k in 0...20 {
                let t = CGFloat(k) / 20
                let x = pass % 2 == 0 ? 40 + t * 500 : 540 - t * 500
                path.append(CGPoint(x: o.x + x, y: o.y + 60 + CGFloat(pass) * 40 + t * 30))
            }
        }
        return path
    }

    /// 照實際的速度擦：筆每 1/60 秒到一個新位置；主執行緒忙的時候，這段時間到的位置像 UIKit 一樣併成一次送來。
    /// 回傳每擦一次花多久、每一批位置從筆到那裡到被擦掉隔多久
    private func scrubInRealTime(_ path: [CGPoint], partial: Bool, label: String) -> (steps: FrameTimes, delays: FrameTimes) {
        EditorSettings.shared.pixelEraser = partial
        editor.setTool(.eraser)
        XCTAssertEqual(editor.canvas.drawing.strokes.count, 2505, "測試的前提：整本的 PencilKit 筆跡都在畫布上")
        let before = editor.canvas.drawing.strokes.count
        let frame = 1.0 / 60
        let start = CACurrentMediaTime()
        var next = 1, worstStep = 0.0, worstParts = "", stepTimes = FrameTimes(), delays = FrameTimes()
        editor.eraserBegan(at: path[0])
        while next < path.count {
            let now = CACurrentMediaTime()
            let oldest = start + Double(next) * frame
            var batch: [CGPoint] = []
            while next < path.count, start + Double(next) * frame <= now {
                batch.append(path[next])
                next += 1
            }
            guard !batch.isEmpty else {
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                continue
            }
            NotebookViewController.lastEraseStep = .init()
            editor.eraserMoved(batch)
            let done = CACurrentMediaTime()
            if done - now > worstStep { worstParts = NotebookViewController.lastEraseStep.summary + " points=\(batch.count)" }
            worstStep = max(worstStep, done - now)
            stepTimes.add(done - now)
            delays.add(done - oldest)
        }
        editor.eraserEnded()
        print(String(format: "%@ partial=%d moves=%d steps=%d worstStep=%.0fms (%@) step %@ delay %@ strokes %d→%d",
                     label, partial ? 1 : 0, path.count - 1, stepTimes.all.count, worstStep * 1000, worstParts, stepTimes.summary,
                     delays.summary, before, editor.canvas.drawing.strokes.count))
        // 一個都不漏：沿著走過的路再擦一次（半徑小一點，避開剛好切在圓邊的地方），沒有東西可擦
        XCTAssertNil(StrokeEraser.erase(editor.canvas.drawing.strokes, along: path, radius: editor.eraserRadius * 0.5, partial: partial),
                     "走過的地方都擦掉了")
        return (stepTimes, delays)
    }

    func testFastScrubbingAcrossPenWritingKeepsUp() {
        let r = scrubInRealTime(scrubAcrossPage7(), partial: true, label: "ERASEPEN")
        assertFast(r.steps, under: 0.05, "擦一次不超過 50ms（之前整本的筆跡組兩次，一次 57～76ms）")
        assertFast(r.delays, under: 0.1, "擦掉的地方落後筆不超過 0.1 秒")
    }

    func testFastWholeStrokeScrubbingAcrossPenWritingKeepsUp() {
        let r = scrubInRealTime(scrubAcrossPage7(), partial: false, label: "ERASEPENWHOLE")
        assertFast(r.steps, under: 0.05, "擦一次不超過 50ms（之前整本的筆跡組兩次，一次 57～76ms）")
        assertFast(r.delays, under: 0.1, "擦掉的地方落後筆不超過 0.1 秒")
    }

    /// 擦一下除了算擦哪裡，其他時間花在哪：讀畫布的筆跡、換上新的筆跡（PencilKit 重畫）、擦自製筆刷的字
    func testWhereTheRestOfAnEraseStepGoes() {
        EditorSettings.shared.pixelEraser = true
        editor.setTool(.eraser)
        func ms(_ n: Int = 20, _ body: () -> Void) -> Double {
            let t = CACurrentMediaTime()
            for _ in 0..<n { body() }
            return (CACurrentMediaTime() - t) / Double(n) * 1000
        }
        let read = ms { _ = editor.canvas.drawing.strokes.count }
        var flip = false
        let set = ms {
            var s = editor.canvas.drawing.strokes
            flip.toggle()
            s[s.count - 1].transform = CGAffineTransform(translationX: flip ? 1 : 0, y: 0)
            editor.setDrawing(PKDrawing(strokes: s))
        }
        let setAndRender = ms(10) {
            var s = editor.canvas.drawing.strokes
            flip.toggle()
            s[s.count - 1].transform = CGAffineTransform(translationX: flip ? 1 : 0, y: 0)
            editor.setDrawing(PKDrawing(strokes: s))
            CATransaction.flush()
            RunLoop.main.run(until: Date())
        }
        // set 再拆開：組 PKDrawing、交給 PencilKit、編輯器其他的事
        var strokes = editor.canvas.drawing.strokes
        let build = ms {
            flip.toggle()
            strokes[strokes.count - 1].transform = CGAffineTransform(translationX: flip ? 1 : 0, y: 0)
            _ = PKDrawing(strokes: strokes)
        }
        let rawSet = ms {
            flip.toggle()
            strokes[strokes.count - 1].transform = CGAffineTransform(translationX: flip ? 1 : 0, y: 0)
            let d = PKDrawing(strokes: strokes)
            editor.isApplyingDrawing = true
            editor.canvas.drawing = d
            editor.isApplyingDrawing = false
        }
        let sameSet = ms {
            let d = editor.canvas.drawing
            editor.isApplyingDrawing = true
            editor.canvas.drawing = d
            editor.isApplyingDrawing = false
        }
        print(String(format: "ERASESET build=%.1fms canvasSet=%.1fms (incl. build) sameDrawingSet=%.1fms", build, rawSet, sameSet))
        let ink = editor.pages[9].ink
        let inkErase = ms { _ = InkGeometry.erase(ink, at: CGPoint(x: 300, y: 300), radius: 10, partial: true) }
        let o = editor.contentOrigin(9)
        let step = ms(10) { editor.erase(along: [CGPoint(x: o.x + 300, y: o.y + 200), CGPoint(x: o.x + 306, y: o.y + 200)]) }
        print(String(format: "ERASEPARTS read=%.1fms set=%.1fms set+render=%.1fms inkErase=%.1fms eraseStep=%.1fms strokes=%d",
                     read, set, setAndRender, inkErase, step, editor.canvas.drawing.strokes.count))
    }

    func testPartialErasingHighlightsInABigNotebookStaysFast() {
        let r = eraseAcrossTheHighlights(partial: true)
        assertFast(r.moves, under: 0.1, "每移動一下不超過 100ms")
        XCTAssertLessThan(r.total, 4, "擦完不超過 4 秒")
    }

    func testWholeStrokeErasingInABigNotebookStaysFast() {
        let r = eraseAcrossTheHighlights(partial: false)
        assertFast(r.moves, under: 0.1, "每移動一下不超過 100ms")
        XCTAssertLessThan(r.total, 4, "擦完不超過 4 秒")
    }
}
