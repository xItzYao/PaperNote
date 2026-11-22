import CoreGraphics
import Foundation

/// 自訂元件的 JSON：貼上 AI 照 aiPrompt 產生的內容，或拷貝出去分享、備份。
/// 座標同元件座標（格點 10、原點在中心、y 往下）
enum CircuitSymbolJSON {
    static let format = "papernote-circuit-symbol"
    /// 座標的範圍（太大的是寫錯了）
    static let limit: CGFloat = 200

    struct File: Codable {
        var format: String?
        var version: Int?
        var name: String?
        var strokes: [Line]?
        var circles: [Circle]?
        var texts: [Text]?
        var pins: [[Double]]?
    }

    struct Text: Codable {
        var text: String
        var center: [Double]
        var size: Double?
    }

    struct Line: Codable {
        var points: [[Double]]
        var freehand: Bool?
    }

    struct Circle: Codable {
        var center: [Double]
        var radius: Double
    }

    enum ParseError: LocalizedError, Equatable {
        case notJSON(String)
        case badPoint
        case tooBig
        case noLines
        case noPins

        var errorDescription: String? {
            switch self {
            case let .notJSON(why): return L("格式不對：\(why)")
            case .badPoint: return L("每個點要寫成 [x, y]（兩個數字）。")
            case .tooBig: return L("座標要在 -\(Int(CircuitSymbolJSON.limit))～\(Int(CircuitSymbolJSON.limit)) 之間。")
            case .noLines: return L("沒有線條：strokes 至少要有一條兩個點以上的線（或 circles 有一個圓）。")
            case .noPins: return L("沒有接腳：pins 至少要有一個點。")
            }
        }
    }

    /// 讀 JSON（前後可以有 AI 回覆的文字、``` 程式碼區塊）。接腳吸到最近的格點
    static func parse(_ text: String) throws -> (name: String?, symbol: CircuitSymbol) {
        // 有 ``` 程式碼區塊就只看第一個區塊（AI 回覆前後常有說明文字）
        var body = Substring(text)
        if let fence = body.range(of: "```") {
            var rest = body[fence.upperBound...]
            if let newline = rest.firstIndex(of: "\n") { rest = rest[rest.index(after: newline)...] }
            if let end = rest.range(of: "```") { body = rest[..<end.lowerBound] }
        }
        guard let open = body.firstIndex(of: "{"), let close = body.lastIndex(of: "}"), open < close else {
            throw ParseError.notJSON(L("找不到 { … }"))
        }
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: Data(body[open...close].utf8))
        } catch let DecodingError.typeMismatch(_, c), let DecodingError.valueNotFound(_, c), let DecodingError.keyNotFound(_, c) {
            throw ParseError.notJSON(c.codingPath.map(\.stringValue).joined(separator: ".") + " " + c.debugDescription)
        } catch {
            throw ParseError.notJSON(L("不是 JSON"))
        }

        func point(_ a: [Double]) throws -> CGPoint {
            guard a.count == 2, a.allSatisfy(\.isFinite) else { throw ParseError.badPoint }
            let p = CGPoint(x: a[0], y: a[1])
            guard abs(p.x) <= limit, abs(p.y) <= limit else { throw ParseError.tooBig }
            return p
        }

        var strokes: [CircuitSymbol.Stroke] = []
        for line in file.strokes ?? [] {
            let pts = try line.points.map(point)
            if pts.count >= 2 { strokes.append(.init(points: pts, freehand: line.freehand ?? false)) }
        }
        for c in file.circles ?? [] {
            let center = try point(c.center)
            let r = CGFloat(c.radius)
            guard r.isFinite, r > 0 else { throw ParseError.badPoint }
            guard abs(center.x) + r <= limit, abs(center.y) + r <= limit else { throw ParseError.tooBig }
            let n = 48
            let pts = (0...n).map { i -> CGPoint in
                let t = CGFloat(i) / CGFloat(n) * 2 * .pi
                return CGPoint(x: center.x + r * cos(t), y: center.y + r * sin(t))
            }
            strokes.append(.init(points: pts, freehand: true))
        }
        guard !strokes.isEmpty else { throw ParseError.noLines }

        var texts: [CircuitSymbol.Label] = []
        for t in file.texts ?? [] {
            let s = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let center = try point(t.center)
            guard !s.isEmpty else { continue }
            let raw = t.size.map { CGFloat($0) } ?? CircuitSymbol.Label.defaultSize
            let size = raw.isFinite ? raw : CircuitSymbol.Label.defaultSize
            texts.append(.init(text: s, center: center,
                               size: min(max(size, CircuitSymbol.Label.sizeRange.lowerBound), CircuitSymbol.Label.sizeRange.upperBound)))
        }

        var pins: [CGPoint] = []
        for a in file.pins ?? [] {
            let q = CircuitData.snap(try point(a))
            if !pins.contains(q) { pins.append(q) }
        }
        guard !pins.isEmpty else { throw ParseError.noPins }
        return (file.name, CircuitSymbol(strokes: strokes, texts: texts, pins: pins))
    }

    static func export(_ symbol: CircuitSymbol, name: String) -> String {
        func a(_ p: CGPoint) -> [Double] { [(Double(p.x) * 100).rounded() / 100, (Double(p.y) * 100).rounded() / 100] }
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = File(format: format, version: 1, name: t.isEmpty ? nil : t,
                        strokes: symbol.strokes.map { Line(points: $0.points.map(a), freehand: $0.freehand ? true : nil) },
                        circles: nil,
                        texts: symbol.texts.isEmpty ? nil : symbol.texts.map { Text(text: $0.text, center: a($0.center), size: Double($0.size)) },
                        pins: symbol.pins.map(a))
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: (try? e.encode(file)) ?? Data(), as: UTF8.self)
    }

    /// 給 AI 的說明：附上手繪元件的照片，AI 回覆的 JSON 貼回「畫元件」→「JSON」→「貼上 JSON」
    static let aiPrompt = """
    請把我附上的手繪電路元件符號（照片或截圖）轉成 PaperNote 的自訂元件 JSON。只回覆一個 ```json 程式碼區塊，裡面是一個 JSON 物件，不要加註解或其他說明。

    ## 座標
    - 單位是點，格點間距 10。原點在符號中心，x 往右、y 往下。
    - 大小比照一般電路元件：兩端元件（電阻、電容、二極體…）的接腳在 [-30, 0] 和 [30, 0]，本體大約在 x -20～20、y -10～10。三端、四端元件的接腳通常在 ±30、±40 以內。所有座標都要在 -200～200 之間。
    - 接腳一定在格點上（x、y 都是 10 的倍數）。線條端點盡量對齊格點；伸到接腳的引線，端點要剛好等於那個接腳的座標。

    ## 格式
    {
      "format": "papernote-circuit-symbol",
      "version": 1,
      "name": "元件名稱",
      "strokes": [ { "points": [[x, y], [x, y]], "freehand": false } ],
      "circles": [ { "center": [x, y], "radius": 10 } ],
      "texts": [ { "text": "+", "center": [x, y], "size": 12 } ],
      "pins": [[x, y]]
    }
    - strokes：每一條是一條折線，依序把 points 連起來，至少 2 個點。直線、折線的 freehand 寫 false；弧線、波浪這類曲線用夠多的點（大約每 3 點一個）逼近，freehand 寫 true。要封閉的形狀，最後一個點寫回第一個點。
    - circles：完整的圓（例如電壓源、電表、燈泡的外框）；沒有就省略。
    - texts：符號上的字（文字方塊）。text 是字，center 是字的中心，size 是字級（字高，單位同座標；常用 8 是接腳旁的小字，12 是一般記號，16 是大字），省略就是 12。上下標寫成 R_1、V^2、V_{in}。字永遠是正的（元件旋轉、翻轉時只有位置跟著動），不要讓字壓到線條。沒有就省略。
    - pins：導線接上去的位置，至少一個。接腳只是位置，不要另外畫圓圈。
    - name 可以省略。

    ## 怎麼判讀手繪
    - 線條抖、歪的時候，畫成它想表達的乾淨圖形：接近水平或垂直就拉正，看起來等長就等長，對稱的符號就畫成對稱。
    - 符號上寫的字用 texts，不要用線條拼字：極性的 +、−，電表的 A、V，方塊裡的名字（例如 IC、MCU），接腳旁的名字（例如 VCC、GND、IN、OUT）。箭頭、圓圈這類圖形才用線條畫。
    - 元件名稱、數值、標號（例如 R1、10kΩ）不要寫進符號：放到頁面上可以另外替每個元件取名。
    - 引線從本體伸出去到接腳。圖上沒有標出接腳時，接腳放在每條引線的末端。

    ## 範例：電解電容（極性用文字）
    ```json
    {
      "format": "papernote-circuit-symbol",
      "version": 1,
      "name": "電解電容",
      "strokes": [
        { "points": [[-30, 0], [-4, 0]], "freehand": false },
        { "points": [[-4, -12], [-4, 12]], "freehand": false },
        { "points": [[4, -12], [4, 12]], "freehand": false },
        { "points": [[4, 0], [30, 0]], "freehand": false }
      ],
      "texts": [ { "text": "+", "center": [-14, -10], "size": 12 } ],
      "pins": [[-30, 0], [30, 0]]
    }
    ```

    ## 範例：電阻
    ```json
    {
      "format": "papernote-circuit-symbol",
      "version": 1,
      "name": "電阻",
      "strokes": [
        { "points": [[-30, 0], [-20, 0], [-15, -8], [-5, 8], [5, -8], [15, 8], [20, 0], [30, 0]], "freehand": false }
      ],
      "pins": [[-30, 0], [30, 0]]
    }
    ```
    """
}
