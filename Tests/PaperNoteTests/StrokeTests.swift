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
