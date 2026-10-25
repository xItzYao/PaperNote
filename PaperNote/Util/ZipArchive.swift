import Foundation
import Compression

enum ZipError: LocalizedError {
    case notZip
    case unsupported(String)
    case encrypted(String)
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .notZip: return "這不是 zip 檔，或檔案已經損壞。"
        case let .unsupported(name): return "「\(name)」用了不支援的壓縮方式。"
        case let .encrypted(name): return "「\(name)」有密碼保護，請先解除密碼再匯入。"
        case let .corrupt(name): return "「\(name)」在 zip 裡已經損壞。"
        }
    }
}

/// 讀 zip 檔（只讀不寫）。支援不壓縮與 deflate 壓縮、zip64（4GB 以上）、UTF-8 與 Big5 檔名，解出來會核對 CRC
struct ZipArchive {
    struct Entry {
        /// zip 裡的路徑（資料夾用「/」分隔，資料夾本身以「/」結尾）
        let path: String
        let method: UInt16
        let flags: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64

        var isDirectory: Bool { path.hasSuffix("/") }
        var name: String { (path as NSString).lastPathComponent }
    }

    let entries: [Entry]
    private let data: Data

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        entries = try Self.centralDirectory(data)
    }

    /// 把一個檔案解到 url
    func extract(_ e: Entry, to url: URL) throws {
        try contents(of: e).write(to: url)
    }

    func contents(of e: Entry) throws -> Data {
        if e.flags & 1 != 0 { throw ZipError.encrypted(e.name) }
        let h = Int(e.localHeaderOffset)
        guard h + 30 <= data.count, data.u32(h) == 0x0403_4b50 else { throw ZipError.corrupt(e.name) }
        let start = h + 30 + Int(data.u16(h + 26)) + Int(data.u16(h + 28))
        let csize = Int(e.compressedSize), usize = Int(e.uncompressedSize)
        guard start + csize <= data.count else { throw ZipError.corrupt(e.name) }
        let out: Data
        switch e.method {
        case 0:
            out = data.subdata(in: start..<(start + csize))
        case 8:
            guard usize > 0 else { out = Data(); break }
            var buf = Data(count: usize)
            let written = buf.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, usize,
                                              src.bindMemory(to: UInt8.self).baseAddress! + start, csize,
                                              nil, COMPRESSION_ZLIB)   // COMPRESSION_ZLIB＝zip 用的 raw deflate
                }
            }
            guard written == usize else { throw ZipError.corrupt(e.name) }
            out = buf
        default:
            throw ZipError.unsupported(e.name)
        }
        guard out.count == usize, CRC32.checksum(out) == e.crc32 else { throw ZipError.corrupt(e.name) }
        return out
    }

    // MARK: 讀目錄

    private static func centralDirectory(_ d: Data) throws -> [Entry] {
        // 檔尾的「目錄結尾」紀錄（後面可能還有最長 65535 bytes 的註解）
        guard d.count >= 22 else { throw ZipError.notZip }
        var eocd = -1
        var i = d.count - 22
        let lowest = max(0, d.count - 22 - 65_535)
        while i >= lowest {
            if d.u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        var count = UInt64(d.u16(eocd + 10))
        var offset = UInt64(d.u32(eocd + 16))
        // zip64：數量或位置放不下時，真正的值在 zip64 目錄結尾
        if count == 0xFFFF || offset == 0xFFFF_FFFF, eocd >= 20, d.u32(eocd - 20) == 0x0706_4b50 {
            let z = Int(d.u64(eocd - 20 + 8))
            guard z + 56 <= d.count, d.u32(z) == 0x0606_4b50 else { throw ZipError.notZip }
            count = d.u64(z + 32)
            offset = d.u64(z + 48)
        }

        var entries: [Entry] = []
        var p = Int(offset)
        for _ in 0..<count {
            guard p + 46 <= d.count, d.u32(p) == 0x0201_4b50 else { throw ZipError.notZip }
            let flags = d.u16(p + 8), method = d.u16(p + 10), crc = d.u32(p + 16)
            var csize = UInt64(d.u32(p + 20)), usize = UInt64(d.u32(p + 24))
            let nameLen = Int(d.u16(p + 28)), extraLen = Int(d.u16(p + 30)), commentLen = Int(d.u16(p + 32))
            var local = UInt64(d.u32(p + 42))
            let nameStart = p + 46, extraStart = nameStart + nameLen
            guard extraStart + extraLen + commentLen <= d.count else { throw ZipError.notZip }
            let rawName = d.subdata(in: nameStart..<extraStart)
            var name = decodeName(rawName, utf8: flags & 0x800 != 0)

            // 額外欄位：zip64 的大小與位置、Info-ZIP 的 UTF-8 檔名
            var e = extraStart
            while e + 4 <= extraStart + extraLen {
                let id = d.u16(e), size = Int(d.u16(e + 2))
                var q = e + 4
                if id == 0x0001 {
                    if usize == 0xFFFF_FFFF, q + 8 <= e + 4 + size { usize = d.u64(q); q += 8 }
                    if csize == 0xFFFF_FFFF, q + 8 <= e + 4 + size { csize = d.u64(q); q += 8 }
                    if local == 0xFFFF_FFFF, q + 8 <= e + 4 + size { local = d.u64(q) }
                } else if id == 0x7075, size > 5,
                          let s = String(data: d.subdata(in: (e + 9)..<(e + 4 + size)), encoding: .utf8) {
                    name = s
                }
                e += 4 + size
            }

            entries.append(Entry(path: name.replacingOccurrences(of: "\\", with: "/"), method: method, flags: flags, crc32: crc,
                                 compressedSize: csize, uncompressedSize: usize, localHeaderOffset: local))
            p = extraStart + extraLen + commentLen
        }
        return entries
    }

    /// 檔名：標了 UTF-8 就用 UTF-8；沒標的話 macOS 壓的通常也是 UTF-8，Windows 繁中壓的是 Big5
    private static func decodeName(_ raw: Data, utf8: Bool) -> String {
        if let s = String(data: raw, encoding: .utf8) { return s }
        if !utf8 {
            let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
            if let s = String(data: raw, encoding: big5) { return s }
        }
        return String(decoding: raw, as: UTF8.self)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
    func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) | UInt64(u32(i + 4)) << 32 }
}
