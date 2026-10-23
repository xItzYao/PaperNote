import XCTest
import PencilKit
@testable import PaperNote

/// 程式產生的筆跡（停住變直線、螢光筆拉直）要真的畫得出來
final class StrokeTests: XCTestCase {
    /// 畫出來後有顏色的像素數
    private func inkedPixels(_ strokes: [PKStroke], in rect: CGRect) -> Int {
        let image = PKDrawing(strokes: strokes).image(from: rect, scale: 1)
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }
        return stride(from: 3, to: data.count, by: 4).filter { data[$0] > 8 }.count
    }

    private let area = CGRect(x: 0, y: 0, width: 240, height: 60)

    func testEveryInkDrawsAVisibleLine() {
        for style in InkStyle.allCases {
            let preset = BrushPreset(style: style, colorHex: "#1E1E1EFF", width: 6)
            let stroke = ShapeRecognizer.makeStroke(points: ShapeRecognizer.segment(CGPoint(x: 20, y: 30), CGPoint(x: 220, y: 30)),
                                                    preset: preset)
            XCTAssertGreaterThan(inkedPixels([stroke], in: area), 200, "\(style) 畫出來是透明的")
        }
    }

    func testLineCopiesTheHandStrokesWidth() {
        let preset = BrushPreset(style: .monoline, colorHex: "#C0392BFF", width: 3)
        let hand = ShapeRecognizer.makeStroke(points: [CGPoint(x: 20, y: 30), CGPoint(x: 120, y: 34), CGPoint(x: 220, y: 28)],
                                              preset: preset)
        let sample = ShapeRecognizer.samplePoint(of: hand)
        XCTAssertNotNil(sample)
        let line = ShapeRecognizer.makeStroke(points: ShapeRecognizer.segment(CGPoint(x: 20, y: 30), CGPoint(x: 220, y: 30)),
                                              ink: hand.ink, width: preset.width, sample: sample)
        XCTAssertEqual(line.path.first?.size, sample?.size)
        XCTAssertEqual(line.ink.inkType, hand.ink.inkType)
        XCTAssertGreaterThan(inkedPixels([line], in: area), 200)
    }

    func testHighlighterStraighteningStaysVisible() {
        let preset = BrushPreset(style: .marker, colorHex: "#FFD60AFF", width: 20)
        let wobbly = ShapeRecognizer.makeStroke(points: (0...40).map { CGPoint(x: 20 + CGFloat($0) * 5, y: 30 + ($0 % 2 == 0 ? 0.5 : -0.5)) },
                                                preset: preset)
        let straight = ShapeRecognizer.straightenIfNearlyStraight(wobbly, preset: preset)
        XCTAssertNotNil(straight)
        if let straight { XCTAssertGreaterThan(inkedPixels([straight], in: area), 200) }
    }

    func testRecoloredStrokeKeepsItsPath() {
        let preset = BrushPreset(style: .pen, colorHex: "#000000FF", width: 4)
        let old = ShapeRecognizer.makeStroke(points: ShapeRecognizer.segment(CGPoint(x: 20, y: 30), CGPoint(x: 220, y: 30)), preset: preset)
        let recolored = PKStroke(ink: PKInk(old.ink.inkType, color: .systemRed), path: old.path,
                                 transform: old.transform, mask: old.mask, randomSeed: old.randomSeed)
        XCTAssertEqual(recolored.path.count, old.path.count)
        XCTAssertEqual(recolored.renderBounds, old.renderBounds)
        XCTAssertGreaterThan(inkedPixels([recolored], in: area), 200)
    }
}

/// 停住變直線／圖形的計算
final class HoldToShapeTests: XCTestCase {
    private func stroke(at date: Date) -> PKStroke {
        let p = PKStrokePoint(location: .zero, timeOffset: 0, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [p, p], creationDate: date))
    }

    func testHandStrokeIsReplacedAndLaterStrokesKept() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let old = stroke(at: t0)
        let hand = stroke(at: t0.addingTimeInterval(10))
        let line = stroke(at: t0.addingTimeInterval(20))
        let later = stroke(at: t0.addingTimeInterval(30))
        let strokes = [old, hand, later]
        XCTAssertEqual(HoldToShape.handStrokeIndex(in: strokes, countBefore: 1, lineDate: line.path.creationDate), 1)
        let result = HoldToShape.replacingHandStroke(in: strokes, countBefore: 1, with: line)
        XCTAssertEqual(result.map(\.path.creationDate), [old, later, line].map(\.path.creationDate))
    }

    func testNoHandStrokeWhenNothingNewWasDrawn() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let strokes = [stroke(at: t0)]
        XCTAssertNil(HoldToShape.handStrokeIndex(in: strokes, countBefore: 1, lineDate: t0.addingTimeInterval(5)))
    }

    func testAnchorIsTheFarthestCorner() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50), CGPoint(x: 0, y: 50)]
        XCTAssertEqual(HoldToShape.anchorCorner(of: square, farthestFrom: CGPoint(x: 95, y: 5)), CGPoint(x: 0, y: 50))
    }

    func testDraggingResizesWidthAndHeightSeparately() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50), CGPoint(x: 0, y: 50)]
        let anchor = CGPoint(x: 0, y: 50)
        // 筆從右上角 (100, 0) 拖到 (200, 0)：寬度變兩倍，高度不變
        let wider = HoldToShape.scaled(square, grab: CGPoint(x: 100, y: 0), anchor: anchor, to: CGPoint(x: 200, y: 0))
        XCTAssertEqual(wider.map(\.x).max(), 200)
        XCTAssertEqual(wider.map(\.y).min(), 0)
        // 拖到 (100, -50)：高度變兩倍
        let taller = HoldToShape.scaled(square, grab: CGPoint(x: 100, y: 0), anchor: anchor, to: CGPoint(x: 100, y: -50))
        XCTAssertEqual(taller.map(\.y).min(), -50)
        XCTAssertEqual(taller.map(\.x).max(), 100)
    }
}
