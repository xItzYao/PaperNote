import XCTest

/// 速度測試量到的每一格（每移動一下、每捲一格）花的時間。
/// 看慢的那幾格整體多慢（第 95 百分位），不是只看最慢的一格：CI 的機器是共用的，偶爾一兩格被別的工作卡住，
/// 和程式無關（同一份程式最慢的一格 46ms、下一輪 73ms）；程式真的變慢的話，慢的不會只有一兩格。
/// 最慢的一格還是要在上限的兩倍以內，大卡頓照樣抓得到
struct FrameTimes {
    private(set) var all: [Double] = []

    mutating func add(_ t: Double) { all.append(t) }

    var worst: Double { all.max() ?? 0 }
    /// 第 95 百分位：比它慢的只有 5%
    var slow: Double {
        guard !all.isEmpty else { return 0 }
        let sorted = all.sorted()
        return sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1))]
    }
    var average: Double { all.isEmpty ? 0 : all.reduce(0, +) / Double(all.count) }
    var summary: String { String(format: "95%%=%.1fms worst=%.1fms avg=%.1fms n=%d", slow * 1000, worst * 1000, average * 1000, all.count) }
}

/// 95% 的格子在 limit 以內，最慢的一格在 limit 的兩倍以內
func assertFast(_ f: FrameTimes, under limit: Double, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    let ms = Int((limit * 1000).rounded())
    XCTAssertLessThan(f.slow, limit, "\(what)：95% 的格子要在 \(ms)ms 以內（\(f.summary)）", file: file, line: line)
    XCTAssertLessThan(f.worst, limit * 2, "\(what)：最慢的一格也不能超過 \(ms * 2)ms（\(f.summary)）", file: file, line: line)
}

final class FrameTimesTests: XCTestCase {
    func testOneSlowFrameDoesNotCountButManyDo() {
        var f = FrameTimes()
        for _ in 0..<59 { f.add(0.010) }
        f.add(0.070)
        XCTAssertEqual(f.slow, 0.010, accuracy: 1e-9, "60 格裡只有一格慢：不算")
        XCTAssertEqual(f.worst, 0.070, accuracy: 1e-9)
        for _ in 0..<10 { f.add(0.070) }
        XCTAssertEqual(f.slow, 0.070, accuracy: 1e-9, "慢的有 11/70 格：算")
    }
}
