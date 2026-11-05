import Foundation

struct DriveFile: Decodable {
    let id: String
    let name: String
    let mimeType: String?
    /// 檔案內容的 MD5（資料夾沒有）
    var md5Checksum: String? = nil

    var isFolder: Bool { mimeType == DriveClient.folderMime }
}

/// 備份用到的 Google Drive 操作。不會真的刪除，只會移到 Google Drive 的垃圾桶：
/// trashFile 只收檔案，trashFolder 只收資料夾（連同裡面全部）
protocol DriveAPI {
    func findFolder(named name: String, in parent: String) async throws -> String?
    func findFile(named name: String, in parent: String) async throws -> DriveFile?
    func createFolder(named name: String, in parent: String) async throws -> String
    func children(of folder: String) async throws -> [DriveFile]
    func upload(_ fileURL: URL, name: String, parent: String, existingID: String?) async throws -> String
    func download(_ fileID: String, to destination: URL) async throws
    func trashFile(_ file: DriveFile) async throws
    func trashFolder(_ folder: DriveFile) async throws
}

/// Google Drive REST API v3（只用到 drive.file 權限）
final class DriveClient: DriveAPI {
    static let folderMime = "application/vnd.google-apps.folder"
    private let auth = GoogleAuth.shared
    private let accessToken: () async throws -> String

    init(accessToken: (() async throws -> String)? = nil) {
        self.accessToken = accessToken ?? { try await GoogleAuth.shared.validAccessToken() }
    }

    private func send(_ make: (String) throws -> URLRequest, retry: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let token = try await accessToken()
        let req = try make(token)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BackupError.http(0, "") }
        if http.statusCode == 401 && retry {
            auth.invalidateAccessToken()
            return try await send(make, retry: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BackupError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (data, http)
    }

    private func request(_ url: URL, _ method: String, _ token: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    private func list(query: String) async throws -> [DriveFile] {
        struct Page: Decodable { let files: [DriveFile]; let nextPageToken: String? }
        var out: [DriveFile] = []
        var pageToken: String?
        repeat {
            var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            var items = [URLQueryItem(name: "q", value: query),
                         URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,md5Checksum)"),
                         URLQueryItem(name: "pageSize", value: "1000"),
                         // 同名的檔案，最新的排最前面
                         URLQueryItem(name: "orderBy", value: "modifiedTime desc"),
                         URLQueryItem(name: "spaces", value: "drive")]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            comps.queryItems = items
            let url = comps.url!
            let (data, _) = try await send { self.request(url, "GET", $0) }
            let page = try JSONDecoder().decode(Page.self, from: data)
            out += page.files
            pageToken = page.nextPageToken
        } while pageToken != nil
        return out
    }

    func findFolder(named name: String, in parent: String) async throws -> String? {
        try await list(query: "name = '\(escape(name))' and mimeType = '\(Self.folderMime)' and trashed = false and '\(parent)' in parents").first?.id
    }

    func findFile(named name: String, in parent: String) async throws -> DriveFile? {
        try await list(query: "name = '\(escape(name))' and mimeType != '\(Self.folderMime)' and trashed = false and '\(parent)' in parents").first
    }

    func createFolder(named name: String, in parent: String) async throws -> String {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "mimeType": Self.folderMime, "parents": [parent]])
        let (data, _) = try await send { token in
            var r = self.request(url, "POST", token)
            r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
            return r
        }
        guard let id = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
            throw BackupError.http(0, L("建立資料夾失敗"))
        }
        return id
    }

    func children(of folder: String) async throws -> [DriveFile] {
        try await list(query: "'\(folder)' in parents and trashed = false")
    }

    /// 上傳檔案（existingID 有值就覆蓋原檔），回傳檔案 ID。用 resumable 上傳，大檔也沒問題。
    func upload(_ fileURL: URL, name: String, parent: String, existingID: String?) async throws -> String {
        let start: URL
        let method: String
        var meta: [String: Any] = [:]
        if let id = existingID {
            start = URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(id)?uploadType=resumable&fields=id")!
            method = "PATCH"
        } else {
            start = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id")!
            method = "POST"
            meta = ["name": name, "parents": [parent]]
        }
        let body = try JSONSerialization.data(withJSONObject: meta)
        let (_, resp) = try await send { token in
            var r = self.request(start, method, token)
            r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            r.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
            r.httpBody = body
            return r
        }
        guard let location = resp.value(forHTTPHeaderField: "Location"), let sessionURL = URL(string: location) else {
            throw BackupError.http(resp.statusCode, L("沒有取得上傳位址"))
        }
        let token = try await accessToken()
        var put = request(sessionURL, "PUT", token)
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, putResp) = try await URLSession.shared.upload(for: put, fromFile: fileURL)
        let code = (putResp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code),
              let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
            throw BackupError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return id
    }

    func download(_ fileID: String, to destination: URL) async throws {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)?alt=media")!
        let (data, _) = try await send { self.request(url, "GET", $0) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    /// 資料夾要走 trashFolder，不會誤丟整個資料夾
    func trashFile(_ file: DriveFile) async throws {
        guard let mime = file.mimeType, mime != Self.folderMime else {
            throw BackupError.http(0, L("不是檔案"))
        }
        try await moveToTrash(file.id)
    }

    func trashFolder(_ folder: DriveFile) async throws {
        guard folder.isFolder else { throw BackupError.http(0, L("不是資料夾")) }
        try await moveToTrash(folder.id)
    }

    /// 已經不在了就算丟好了
    private func moveToTrash(_ id: String) async throws {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)")!
        let body = try JSONSerialization.data(withJSONObject: ["trashed": true])
        do {
            _ = try await send { token in
                var r = self.request(url, "PATCH", token)
                r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
                r.httpBody = body
                return r
            }
        } catch BackupError.http(404, _) {
        }
    }
}
