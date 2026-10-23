import XCTest
import PencilKit
@testable import PaperNote

/// 量測：整本筆記的筆跡重新交給 PencilKit、存檔要多久（只印出時間，不判斷對錯）
final class PerformanceProbeTests: XCTestCase {
    private func bigDrawing(strokes n: Int) -> PKDrawing {
        let preset = BrushPreset(style: .monoline, colorHex: "#1A1A1AFF", width: 2.5)
        var strokes: [PKStroke] = []
        for i in 0..<n {
            let y = CGFloat(i / 20) * 18
            let x = CGFloat(i % 20) * 40
            let pts = (0..<40).map { k in CGPoint(x: x + CGFloat(k), y: y + sin(CGFloat(k) / 4) * 4) }
            strokes.append(ShapeRecognizer.makeStroke(points: pts, preset: preset))
        }
        return PKDrawing(strokes: strokes)
    }

    private func ms(_ block: () -> Void) -> Double {
        let t = CACurrentMediaTime()
        block()
        return (CACurrentMediaTime() - t) * 1000
    }

    func testSetDrawingCost() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        let canvas = PKCanvasView(frame: window.bounds)
        window.addSubview(canvas)
        window.makeKeyAndVisible()
        for n in [500, 2000, 6000] {
            let d = bigDrawing(strokes: n)
            let first = ms { canvas.drawing = d }
            var plusOne = d
            plusOne.strokes.append(d.strokes[0])
            let again = ms { canvas.drawing = plusOne }
            let pump = ms { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            let data = ms { _ = plusOne.dataRepresentation() }
            print("PERF strokes=\(n) setFirst=\(Int(first))ms setPlusOne=\(Int(again))ms runloop=\(Int(pump))ms data=\(Int(data))ms")
        }
    }
}
