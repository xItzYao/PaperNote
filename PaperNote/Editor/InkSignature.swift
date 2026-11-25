import PencilKit
import CryptoKit

extension PKDrawing {
    /// 筆跡內容的指紋（每一筆的墨水、顏色、變形、每個點）。
    /// 判斷筆跡有沒有改不能比 dataRepresentation()：同樣的筆跡讀進來再存出去，位元組不一定一樣，
    /// 每次存檔都會以為改過，雲端備份就一直重傳
    var contentSignature: Data {
        var hash = SHA256()
        var nums: [Double] = []
        func add(_ v: CGFloat) { nums.append(Double(v)) }
        for s in strokes {
            nums.removeAll(keepingCapacity: true)
            hash.update(data: Data(s.ink.inkType.rawValue.utf8))
            for c in s.ink.color.cgColor.components ?? [] { add(c) }
            let t = s.transform
            for v in [t.a, t.b, t.c, t.d, t.tx, t.ty] { add(v) }
            nums.append(Double(s.randomSeed))
            nums.append(s.path.creationDate.timeIntervalSince1970)
            if let m = s.mask?.bounds { for v in [m.minX, m.minY, m.width, m.height] { add(v) } }
            for p in s.path {
                for v in [p.location.x, p.location.y, p.size.width, p.size.height, p.opacity, p.force, p.azimuth, p.altitude] { add(v) }
                nums.append(p.timeOffset)
            }
            nums.withUnsafeBytes { hash.update(bufferPointer: $0) }
        }
        return Data(hash.finalize())
    }
}
