import XCTest
import PencilKit
@testable import PaperNote

final class LassoTests: XCTestCase {
    private func stroke(_ points: [CGPoint]) -> PKStroke {
        ShapeRecognizer.makeStroke(points: points, preset: BrushPreset(style: .monoline, colorHex: "#000000FF", width: 3))
    }

    private func lasso(_ rect: CGRect) -> (UIBezierPath, CGRect) {
        let path = UIBezierPath(rect: rect)
        return (path, path.bounds)
    }

    func testCirclingTheEndOfALongLineSelectsIt() {
        let line = stroke(ShapeRecognizer.segment(CGPoint(x: 0, y: 50), CGPoint(x: 400, y: 50)))
        // 只圈住線的最左邊一小段（中心點在 x = 200，不在圈裡）
        let (path, area) = lasso(CGRect(x: -10, y: 40, width: 40, height: 20))
        XCTAssertTrue(LassoGeometry.circles(line, path: path, area: area))
    }

    func testLassoAwayFromTheLineMissesIt() {
        let line = stroke(ShapeRecognizer.segment(CGPoint(x: 0, y: 50), CGPoint(x: 400, y: 50)))
        let (path, area) = lasso(CGRect(x: 100, y: 100, width: 50, height: 50))
        XCTAssertFalse(LassoGeometry.circles(line, path: path, area: area))
    }

    func testCirclingTextInsideABoxDoesNotGrabTheBox() {
        let box = stroke([CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 0), CGPoint(x: 300, y: 200), CGPoint(x: 0, y: 200), CGPoint(x: 0, y: 0)]
            .adjacentPairs().flatMap { ShapeRecognizer.segment($0, $1) })
        let word = stroke(ShapeRecognizer.segment(CGPoint(x: 130, y: 100), CGPoint(x: 170, y: 100)))
        let (path, area) = lasso(CGRect(x: 120, y: 80, width: 60, height: 40))
        XCTAssertFalse(LassoGeometry.circles(box, path: path, area: area))
        XCTAssertTrue(LassoGeometry.circles(word, path: path, area: area))
    }

    func testMovedStrokeUsesItsTransform() {
        var line = stroke(ShapeRecognizer.segment(CGPoint(x: 0, y: 50), CGPoint(x: 100, y: 50)))
        line.transform = CGAffineTransform(translationX: 500, y: 0)
        let (path, area) = lasso(CGRect(x: 520, y: 40, width: 20, height: 20))
        XCTAssertTrue(LassoGeometry.circles(line, path: path, area: area))
        let (oldPath, oldArea) = lasso(CGRect(x: 20, y: 40, width: 20, height: 20))
        XCTAssertFalse(LassoGeometry.circles(line, path: oldPath, area: oldArea))
    }
}

private extension Array {
    func adjacentPairs() -> [(Element, Element)] { Swift.zip(self, dropFirst()).map { ($0, $1) } }
}
