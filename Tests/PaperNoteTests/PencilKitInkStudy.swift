import XCTest
import PencilKit
@testable import PaperNote

/// 研究 PencilKit 的筆跡（自製引擎要照著做）：同樣的取樣點用 PencilKit 畫出來，存成圖片和數據，
/// 量線寬、深淺、顆粒、邊緣怎麼隨筆壓、傾斜、方向、速度變化。
/// 在模擬器上跑時存到電腦的 ~/ink-study（CI 上傳成 artifact）；其他地方只畫不存
final class PencilKitInkStudy: XCTestCase {
    struct Input: Codable {
        var name: String
        var ink: String
        var points: [Sample]
        var rect: [CGFloat]
        var scale: CGFloat
    }

    struct Sample: Codable {
        var x: CGFloat, y: CGFloat, t: Double, size: CGFloat, opacity: CGFloat, force: CGFloat, azimuth: CGFloat, altitude: CGFloat
    }

    /// PencilKit 自己內插出來的點（實際畫的路徑和粗細）
    struct Interpolated: Codable {
        var x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, opacity: CGFloat, force: CGFloat, azimuth: CGFloat, altitude: CGFloat
    }

    struct Record: Codable {
        var input: Input
        var interpolated: [Interpolated]
        var renderBounds: [CGFloat]
        var file: String
    }

    static let inks: [(String, PKInk.InkType)] = [
        ("pen", .pen), ("monoline", .monoline), ("fountainPen", .fountainPen), ("pencil", .pencil),
        ("marker", .marker), ("crayon", .crayon), ("watercolor", .watercolor),
    ]

    private var outDir: URL? {
        guard let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else { return nil }
        return URL(fileURLWithPath: home).appendingPathComponent("ink-study")
    }

    /// 一筆的取樣點。path：t 從 0 到 1 的位置；其他參數可以隨 t 變
    private func samples(count: Int = 120, dt: Double = 0.005, path: (CGFloat) -> CGPoint,
                         size: (CGFloat) -> CGFloat, force: (CGFloat) -> CGFloat = { _ in 1 },
                         azimuth: CGFloat = 0, altitude: CGFloat = .pi / 2) -> [Sample] {
        (0..<count).map { i in
            let t = CGFloat(i) / CGFloat(count - 1)
            let p = path(t)
            return Sample(x: p.x, y: p.y, t: Double(i) * dt, size: size(t), opacity: 1, force: force(t), azimuth: azimuth, altitude: altitude)
        }
    }

    private func line(_ t: CGFloat) -> CGPoint { CGPoint(x: 20 + 260 * t, y: 50) }

    private func cases() -> [(String, [Sample])] {
        var out: [(String, [Sample])] = []
        for w: CGFloat in [2, 8] {
            for f: CGFloat in [0.3, 1, 3] {
                out.append(("line_w\(Int(w))_f\(f)", samples(path: line, size: { _ in w }, force: { _ in f })))
            }
        }
        for (k, alt) in [("90", CGFloat.pi / 2), ("45", .pi / 4), ("18", .pi / 10)] {
            out.append(("tilt_alt\(k)", samples(path: line, size: { _ in 8 }, altitude: alt)))
        }
        for (k, az) in [("0", CGFloat(0)), ("90", .pi / 2), ("180", .pi)] {
            out.append(("azimuth\(k)_alt45", samples(path: line, size: { _ in 8 }, azimuth: az, altitude: .pi / 4)))
        }
        out.append(("circle_w8", samples(count: 240, path: { t in
            CGPoint(x: 150 + 60 * cos(t * 2 * .pi), y: 80 + 60 * sin(t * 2 * .pi))
        }, size: { _ in 8 })))
        for dt in [0.001, 0.02] {
            out.append(("speed_dt\(dt)", samples(dt: dt, path: line, size: { _ in 8 })))
        }
        out.append(("ramp_size2to16", samples(path: line, size: { 2 + 14 * $0 })))
        out.append(("ramp_force0to4", samples(path: line, size: { _ in 8 }, force: { 4 * $0 })))
        out.append(("zigzag_overlap", samples(count: 200, path: { t in
            CGPoint(x: 40 + 220 * t, y: 80 + 50 * sin(t * 6 * .pi))
        }, size: { _ in 10 })))
        out.append(("spacing_sparse", samples(count: 12, path: line, size: { _ in 8 })))
        return out
    }

    func testRecordPencilKitInks() throws {
        let scale: CGFloat = 2
        var records: [Record] = []
        if let dir = outDir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        for (inkName, type) in Self.inks {
            for (name, pts) in cases() {
                let ink = PKInk(type, color: .black)
                let path = PKStrokePath(controlPoints: pts.map {
                    PKStrokePoint(location: CGPoint(x: $0.x, y: $0.y), timeOffset: $0.t, size: CGSize(width: $0.size, height: $0.size),
                                  opacity: $0.opacity, force: $0.force, azimuth: $0.azimuth, altitude: $0.altitude, secondaryScale: 1)
                }, creationDate: Date(timeIntervalSinceReferenceDate: 0))
                let stroke = PKStroke(ink: ink, path: path)
                let rect = CGRect(x: 0, y: 0, width: 300, height: 160)
                let image = PKDrawing(strokes: [stroke]).image(from: rect, scale: scale)
                let file = "\(inkName)-\(name).png"
                let interp = stroke.path.interpolatedPoints(by: .distance(1)).map {
                    Interpolated(x: $0.location.x, y: $0.location.y, w: $0.size.width, h: $0.size.height, opacity: $0.opacity,
                                 force: $0.force, azimuth: $0.azimuth, altitude: $0.altitude)
                }
                XCTAssertFalse(interp.isEmpty, "\(inkName) \(name)")
                let rb = stroke.renderBounds
                records.append(Record(input: Input(name: name, ink: inkName, points: pts, rect: [rect.minX, rect.minY, rect.width, rect.height], scale: scale),
                                      interpolated: interp, renderBounds: [rb.minX, rb.minY, rb.width, rb.height], file: file))
                if let dir = outDir, let png = image.pngData() { try png.write(to: dir.appendingPathComponent(file)) }
            }
        }
        if let dir = outDir {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            try enc.encode(records).write(to: dir.appendingPathComponent("records.json"))
            let os = ProcessInfo.processInfo.operatingSystemVersionString
            try Data("iOS \(os)\n".utf8).write(to: dir.appendingPathComponent("version.txt"))
        }
    }
}
