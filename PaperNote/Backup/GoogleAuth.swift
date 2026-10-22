import UIKit
import AuthenticationServices
import CryptoKit
import Security

enum BackupError: LocalizedError {
    case noClientID
    case notSignedIn
    case authFailed(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noClientID: return "還沒有設定 Google OAuth 用戶端 ID。"
        case .notSignedIn: return "還沒有連結 Google Drive。"
        case let .authFailed(msg): return "Google 登入失敗：\(msg)"
        case let .http(code, body): return "Google Drive 回應錯誤（\(code)）：\(body.prefix(200))"
        }
    }
}

/// 簡單的 Keychain 存取
enum Keychain {
    private static let service = "com.papernote.app.google"

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Google OAuth（PKCE，不需要 client secret），只要求 drive.file 權限：App 只能存取自己建立的檔案
final class GoogleAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleAuth()

    /// 你在 Google Cloud 建立的 iOS OAuth 用戶端 ID（也可以在 App 的備份設定裡貼上）
    static let builtInClientID = ""

    private static let scope = "https://www.googleapis.com/auth/drive.file"
    private var accessToken: String?
    private var expiry = Date.distantPast
    private var session: ASWebAuthenticationSession?

    var clientID: String {
        let custom = UserDefaults.standard.string(forKey: "google.clientID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? Self.builtInClientID : custom
    }

    var hasClientID: Bool { clientID.hasSuffix(".apps.googleusercontent.com") }
    var isSignedIn: Bool { Keychain.get("refreshToken") != nil }

    /// iOS 用戶端的 redirect：反轉的 client ID
    private var redirectScheme: String {
        let prefix = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(prefix)"
    }
    private var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }

    // MARK: 登入

    func signIn(completion: @escaping (Result<Void, Error>) -> Void) {
        guard hasClientID else { completion(.failure(BackupError.noClientID)); return }
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        let s = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: redirectScheme) { [weak self] url, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { completion(.failure(BackupError.authFailed(error.localizedDescription))) }
                return
            }
            guard let url, let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else {
                DispatchQueue.main.async { completion(.failure(BackupError.authFailed("沒有取得授權碼"))) }
                return
            }
            Task {
                do {
                    try await self.exchange(code: code, verifier: verifier)
                    await MainActor.run { completion(.success(())) }
                } catch {
                    await MainActor.run { completion(.failure(error)) }
                }
            }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        session = s
        s.start()
    }

    func signOut() {
        Keychain.set("refreshToken", nil)
        accessToken = nil
        expiry = .distantPast
    }

    private func exchange(code: String, verifier: String) async throws {
        let json = try await tokenRequest([
            "code": code, "client_id": clientID, "redirect_uri": redirectURI,
            "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        guard let refresh = json["refresh_token"] as? String else { throw BackupError.authFailed("沒有取得 refresh token") }
        Keychain.set("refreshToken", refresh)
        store(json)
    }

    /// 取得有效的 access token（過期就用 refresh token 換新的）
    func validAccessToken() async throws -> String {
        if let t = accessToken, expiry > Date().addingTimeInterval(60) { return t }
        guard let refresh = Keychain.get("refreshToken") else { throw BackupError.notSignedIn }
        let json = try await tokenRequest([
            "refresh_token": refresh, "client_id": clientID, "grant_type": "refresh_token",
        ])
        store(json)
        guard let t = accessToken else { throw BackupError.authFailed("無法更新登入狀態") }
        return t
    }

    func invalidateAccessToken() {
        accessToken = nil
        expiry = .distantPast
    }

    private func store(_ json: [String: Any]) {
        accessToken = json["access_token"] as? String
        let seconds = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? Int ?? 3600)
        expiry = Date().addingTimeInterval(seconds)
    }

    private func tokenRequest(_ params: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard code == 200 else {
            if code == 400 || code == 401, (json["error"] as? String) == "invalid_grant" {
                // refresh token 失效（例如在 Google 帳號撤銷授權）→ 需要重新連結
                Keychain.set("refreshToken", nil)
            }
            throw BackupError.authFailed((json["error_description"] as? String) ?? (json["error"] as? String) ?? "HTTP \(code)")
        }
        return json
    }

    private static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var out = ""
        for _ in 0..<n { out.append(chars[Int.random(in: 0..<chars.count)]) }
        return out
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
