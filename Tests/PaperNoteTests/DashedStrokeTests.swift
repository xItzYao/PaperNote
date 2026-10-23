import XCTest
import PencilKit
@testable import PaperNote

final class DashedStrokeTests: XCTestCase {
    private func line(length: CGFloat, width: CGFloat = 3) -> PKStroke {
        let preset = BrushPreset(style: .monoline, colorHex: "#1E1E1EFF", width: width)
        return ShapeRecognizer.makeStroke(points: ShapeRecognizer.segment(CGPoint(x: 20, y: 30), CGPoint(x: 20 + length, y: 30)),
                                          preset: preset)
    }

    func testSplitsIntoEvenDashes() {
        let pieces = DashedStroke.split(line(length: 200), dash: 10, gap: 5)
        // 200 / (10 + 5) ≈ 13 段
        XCTAssertGreaterThanOrEqual(pieces.count, 12)
        XCTAssertLessThanOrEqual(pieces.count, 15)
        for piece in pieces {
            let xs = piece.path.map(\.location.x)
            XCTAssertLessThanOrEqual(xs.max()! - xs.min()!, 12, "每一段不該比虛線長度長太多")
        }
        // 段與段之間要有空隙
        let starts = pieces.map { $0.path.map(\.location.x).min()! }
        let ends = pieces.map { $0.path.map(\.location.x).max()! }
        for i in 1..<pieces.count { XCTAssertGreaterThan(starts[i] - ends[i - 1], 3) }
    }

    func testPiecesKeepInkDateAndDrawVisibly() {
        let original = line(length: 150)
        let pieces = DashedStroke.split(original, dash: 12, gap: 6)
        XCTAssertTrue(pieces.allSatisfy { $0.path.creationDate == original.path.creationDate })
        XCTAssertTrue(pieces.allSatisfy { $0.ink.inkType == original.ink.inkType })
        let image = PKDrawing(strokes: pieces).image(from: CGRect(x: 0, y: 0, width: 200, height: 60), scale: 1)
        XCTAssertNotNil(image.cgImage)
        XCTAssertFalse(PKDrawing(strokes: pieces).bounds.isEmpty)
    }

    func testSolidPenIsUntouched() {
        let original = line(length: 150)
        XCTAssertEqual(DashedStroke.apply(original, dashed: false, lineWidth: 3).count, 1)
        XCTAssertGreaterThan(DashedStroke.apply(original, dashed: true, lineWidth: 3).count, 3)
    }

    func testShortStrokeStaysOneDash() {
        XCTAssertEqual(DashedStroke.split(line(length: 4), dash: 10, gap: 5).count, 1)
    }

    func testHighlighterIsNeverDashed() {
        var marker = BrushPreset(style: .marker, colorHex: "#FFD60AFF", width: 18)
        marker.dashed = true
        XCTAssertFalse(marker.isDashed)
        var pen = BrushPreset(style: .pen, colorHex: "#000000FF", width: 3)
        XCTAssertFalse(pen.isDashed)
        pen.dashed = true
        XCTAssertTrue(pen.isDashed)
    }

    func testDashedHoldLineReplacesHandStroke() {
        let t0 = Date(timeIntervalSince1970: 1000)
        func stroke(_ date: Date) -> PKStroke {
            let p = PKStrokePoint(location: .zero, timeOffset: 0, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [p, p], creationDate: date))
        }
        let old = stroke(t0), hand = stroke(t0.addingTimeInterval(10))
        let dashes = [stroke(t0.addingTimeInterval(20)), stroke(t0.addingTimeInterval(20))]
        let result = HoldToShape.replacingHandStroke(in: [old, hand], countBefore: 1, with: dashes)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.first?.path.creationDate, t0)
    }

    func testStyleWidthsAreInsideEachBrushRange() {
        for style in InkStyle.allCases {
            XCTAssertEqual(style.styleWidths.count, 3)
            for w in style.styleWidths { XCTAssertTrue(style.widthRange.contains(w), "\(style) \(w)") }
            XCTAssertEqual(style.styleWidths, style.styleWidths.sorted())
        }
    }
}
