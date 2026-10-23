import XCTest
@testable import PaperNote

final class TableDataTests: XCTestCase {
    func testMakeHasRequestedSize() {
        let t = TableData.make(rows: 3, cols: 4)
        XCTAssertEqual(t.rows, 3)
        XCTAssertEqual(t.cols, 4)
        XCTAssertEqual(t.cells.count, 3)
        XCTAssertEqual(t.cells.first?.count, 4)
    }

    func testMergeJoinsTextIntoTheTopLeftCell() {
        var t = TableData.make(rows: 2, cols: 2)
        t.setText("a", row: 0, col: 0)
        t.setText("b", row: 1, col: 1)
        t.mergeCells(CellRange((0, 0), (1, 1)))
        XCTAssertEqual(t.merges, [CellMerge(row: 0, col: 0, rowSpan: 2, colSpan: 2)])
        XCTAssertTrue(t.isAnchor(0, 0))
        XCTAssertFalse(t.isAnchor(1, 1))
        XCTAssertEqual(t.text(row: 0, col: 0), "a\nb")
        t.unmerge(1, 1)
        XCTAssertTrue(t.merges.isEmpty)
    }

    func testScaleKeepsProportions() {
        var t = TableData.make(rows: 2, cols: 2, cellWidth: 100, cellHeight: 50)
        t.scale(to: CGSize(width: 400, height: 200))
        XCTAssertEqual(t.colWidths, [200, 200])
        XCTAssertEqual(t.rowHeights, [100, 100])
    }
}

final class TrashTests: XCTestCase {
    func testRetention() {
        let day: TimeInterval = 86_400
        XCTAssertFalse(Trash.isExpired(Date()))
        XCTAssertFalse(Trash.isExpired(Date().addingTimeInterval(-29 * day)))
        XCTAssertTrue(Trash.isExpired(Date().addingTimeInterval(-31 * day)))
        XCTAssertEqual(Trash.daysLeft(Date().addingTimeInterval(-10 * day - 60)), 20)
        XCTAssertEqual(Trash.daysLeft(Date().addingTimeInterval(-40 * day)), 0)
    }
}

/// 每個工具的觸控規則（TouchRules.swift）
final class TouchRulesTests: XCTestCase {
    func testPencilKitToolsDoNotUseToolPan() {
        for tool in [EditorTool.pen, .highlighter, .eraser] {
            XCTAssertTrue(tool.isDrawing)
            XCTAssertFalse(tool.usesToolPan)
            XCTAssertFalse(tool.drawsWithPan)
        }
    }

    func testDrawingToolsArePencilOnlyByDefault() {
        for tool in [EditorTool.lasso, .capture, .textSelect, .tableDraw, .circuit] {
            XCTAssertTrue(tool.usesToolPan)
            XCTAssertTrue(tool.drawsWithPan, "\(tool)")
        }
        XCTAssertFalse(EditorTool.select.drawsWithPan)
        XCTAssertFalse(EditorTool.pageResize.drawsWithPan)
    }

    func testScrollFirstTools() {
        XCTAssertEqual([EditorTool.select, .pageResize, .lasso, .circuit].map(\.panYieldsToScroll), [true, true, true, true])
        XCTAssertEqual([EditorTool.capture, .textSelect, .tableDraw].map(\.panYieldsToScroll), [false, false, false])
    }
}
