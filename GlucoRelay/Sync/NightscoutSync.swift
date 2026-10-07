import Foundation
import os.log

private let logger = Logger(subsystem: "glucorelay", category: "Nightscout")

enum NightscoutError: LocalizedError, Equatable {
    case noURL
    case noToken
    case invalidURL
    case invalidToken
    case unauthorized
    case serverError(Int)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .noURL: "No Nightscout URL configured."
        case .noToken: "No access token configured."
        case .invalidURL: "The Nightscout URL is invalid."
        case .invalidToken: "Nightscout does not recognise the access token."
        case .unauthorized: "Not authorised (HTTP 401/403). Check the token's roles (readable + careportal)."
        case .serverError(let code): "Server error (HTTP \(code))."
        case .networkError(let msg): "Network error: \(msg)"
        }
    }
}

/// Payload sent to `POST /api/v1/entries` for a meter blood glucose.
struct NightscoutEntry: Sendable {
    let mgdL: Double
    let date: Date
    let serialNumber: String

    var json: [String: Any] {
        [
            "type": "mbg",
            "mbg": Int(mgdL.rounded()),
            "date": Int64((date.timeIntervalSince1970 * 1000).rounded()),
            "dateString": ISO8601DateFormatter.nightscout.string(from: date),
            "device": "Accu-Chek Guide",
            "notes": "SN:\(serialNumber)"
        ]
    }
}

struct ConnectionTestResult: Sendable {
    var ok: Bool
    var message: String         // short summary
    var serverReachable: Bool = false
    var serverReachableDetail: String = ""
    var serverInfo: String? = nil
    var tokenValid: Bool = false
    var tokenSubject: String? = nil   // access token name/subject
    var canRead: Bool = false
    var canReadDetail: String = ""
    var canWrite: Bool = false
    var canWriteDetail: String = ""
}

/// Nightscout access exactly as nightscout-remote does it: the access token is exchanged for a
/// short-lived JWT via `GET /api/v2/authorization/request/<token>`; every API call then sends
/// `Authorization: Bearer <jwt>`. The JWT is cached, requested on launch and re-requested on 401.
enum NightscoutSync {

    private struct AuthSession: Sendable {
        let base: String
        let accessToken: String
        let jwt: String
        let permissions: [String]
        let subject: String?
        let expires: Date
    }

    private actor SessionCache {
        var session: AuthSession?
        func get(base: String, token: String) -> AuthSession? {
            guard let s = session, s.base == base, s.accessToken == token,
                  s.expires > Date().addingTimeInterval(60) else { return nil }
            return s
        }
        func set(_ s: AuthSession?) { session = s }
    }

    private static let cache = SessionCache()

    // MARK: Credentials

    static var isConfigured: Bool {
        !(KeychainManager.nightscoutURL ?? "").isEmpty && !(KeychainManager.accessToken ?? "").isEmpty
    }

    private static func storedCredentials() throws -> (base: String, token: String) {
        guard let url = KeychainManager.nightscoutURL, !url.isEmpty else { throw NightscoutError.noURL }
        guard let token = KeychainManager.accessToken, !token.isEmpty else { throw NightscoutError.noToken }
        return (normalizedBase(url), token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func normalizedBase(_ urlString: String) -> String {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.isEmpty, !s.lowercased().hasPrefix("http") { s = "https://" + s }
        return s
    }

    // MARK: JWT

    private static func authorize(base: String, token: String) async throws -> AuthSession {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = token.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "\(base)/api/v2/authorization/request/\(encoded)"),
              url.host != nil else { throw NightscoutError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, http) = try await perform(request)
        logger.info("JWT request: HTTP \(http.statusCode)")
        guard (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jwt = json["token"] as? String, !jwt.isEmpty else {
            if [200, 401, 403].contains(http.statusCode) { throw NightscoutError.invalidToken }
            throw NightscoutError.serverError(http.statusCode)
        }
        let groups = (json["permissionGroups"] as? [[String]]) ?? []
        let exp = (json["exp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(3600)
        return AuthSession(base: base, accessToken: token, jwt: jwt, permissions: groups.flatMap { $0 },
                           subject: json["sub"] as? String, expires: exp)
    }

    private static func session(base: String, token: String, forceRefresh: Bool = false) async throws -> AuthSession {
        if !forceRefresh, let cached = await cache.get(base: base, token: token) { return cached }
        let s = try await authorize(base: base, token: token)
        await cache.set(s)
        return s
    }

    /// Called on app launch so the first upload does not have to wait for the token exchange.
    static func prefetchJWT() async {
        guard let creds = try? storedCredentials() else { return }
        _ = try? await session(base: creds.base, token: creds.token, forceRefresh: true)
    }

    static func resetSession() async { await cache.set(nil) }

    /// Shiro-style permission match as used by Nightscout ("api:entries:create" etc.).
    static func permits(_ granted: [String], _ target: String) -> Bool {
        let t = target.split(separator: ":").map(String.init)
        return granted.contains { perm in
            let p = perm.split(separator: ":").map(String.init)
            for (i, part) in t.enumerated() {
                if i >= p.count { return true }
                let options = p[i].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if !(options.contains("*") || options.contains(part)) { return false }
            }
            return true
        }
    }

    // MARK: Upload

    /// Posts one meter BG entry. Retries once with a fresh JWT on 401/403.
    static func post(_ entry: NightscoutEntry) async throws {
        let creds = try storedCredentials()
        guard let url = URL(string: "\(creds.base)/api/v1/entries"), url.host != nil else {
            throw NightscoutError.invalidURL
        }
        let body = try JSONSerialization.data(withJSONObject: [entry.json])

        for attempt in 0..<2 {
            let auth = try await session(base: creds.base, token: creds.token, forceRefresh: attempt > 0)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(auth.jwt)", forHTTPHeaderField: "Authorization")
            request.httpBody = body

            let (_, http) = try await perform(request)
            logger.info("POST /api/v1/entries SN \(entry.serialNumber): HTTP \(http.statusCode)")
            switch http.statusCode {
            case 200..<300: return
            case 401, 403:
                await cache.set(nil)
                if attempt == 0 { continue }
                throw NightscoutError.unauthorized
            default:
                throw NightscoutError.serverError(http.statusCode)
            }
        }
    }

    // MARK: Connection test

    /// Mirrors nightscout-remote's NightscoutService.testConnection: token exchange (reachability +
    /// token validity), server info, a real read and the write permission derived from the token's
    /// roles. Nothing is written during the test.
    static func testConnection(urlString: String, token rawToken: String) async -> ConnectionTestResult {
        var result = ConnectionTestResult(ok: false, message: "")
        let base = normalizedBase(urlString)
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        await cache.set(nil)

        guard !base.isEmpty, let statusURL = URL(string: "\(base)/api/v1/status.json"), statusURL.host != nil else {
            result.serverReachableDetail = base.isEmpty ? NightscoutError.noURL.localizedDescription : "Invalid URL"
            result.message = result.serverReachableDetail
            return result
        }
        guard !token.isEmpty else {
            result.serverReachableDetail = "Not tested"
            result.message = NightscoutError.noToken.localizedDescription
            return result
        }

        // 1) Access token -> JWT (also proves the server is reachable)
        let auth: AuthSession
        do {
            auth = try await authorize(base: base, token: token)
            result.serverReachable = true
            result.serverReachableDetail = "Server reachable"
            result.tokenValid = true
            result.tokenSubject = auth.subject
        } catch NightscoutError.invalidToken {
            result.serverReachable = true
            result.serverReachableDetail = "Server reachable"
            result.canReadDetail = "Access token not recognised – copy it exactly from Nightscout ▸ Admin Tools"
            result.canWriteDetail = result.canReadDetail
            result.message = NightscoutError.invalidToken.localizedDescription
            return result
        } catch NightscoutError.serverError(let code) {
            result.serverReachableDetail = code == 404
                ? "No Nightscout (or a version without API v2) at this URL (HTTP 404)"
                : "Server responded with HTTP \(code)"
            result.message = result.serverReachableDetail
            return result
        } catch {
            result.serverReachableDetail = error.localizedDescription
            result.message = result.serverReachableDetail
            return result
        }

        // 2) Server info
        if let resp = try? await perform(bearer(statusURL, jwt: auth.jwt)),
           (200..<300).contains(resp.1.statusCode),
           let json = try? JSONSerialization.jsonObject(with: resp.0) as? [String: Any] {
            let name = json["name"] as? String ?? "Nightscout"
            let version = json["version"] as? String ?? "?"
            result.serverInfo = "\(name) \(version)"
        }

        // 3) Read: real read of the latest entry; token permission as fallback
        let readPermitted = permits(auth.permissions, "api:entries:read")
        if let readURL = URL(string: "\(base)/api/v1/entries.json?count=1"),
           let resp = try? await perform(bearer(readURL, jwt: auth.jwt)) {
            result.canRead = (200..<300).contains(resp.1.statusCode)
        } else {
            result.canRead = readPermitted
        }

        // 4) Write: derived from the token's permissions
        result.canWrite = permits(auth.permissions, "api:entries:create")

        let roles = auth.permissions.isEmpty ? "none" : auth.permissions.joined(separator: ", ")
        result.canReadDetail = result.canRead
            ? "Glucose entries can be read"
            : "No read access – give the token e.g. the role “readable” (has: \(roles))"
        result.canWriteDetail = result.canWrite
            ? "Glucose entries can be written"
            : "No write access – give the token e.g. the role “careportal” (has: \(roles))"

        result.ok = result.serverReachable && result.tokenValid && result.canRead && result.canWrite
        result.message = result.ok
            ? "Connected – token can read and write glucose entries."
            : (result.canWrite ? result.canReadDetail : result.canWriteDetail)
        return result
    }

    private static func bearer(_ url: URL, jwt: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    // MARK: Helpers

    private static func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NightscoutError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw NightscoutError.networkError("Invalid response") }
        return (data, http)
    }
}

extension ISO8601DateFormatter {
    /// `2026-10-07T10:30:00.000Z`
    nonisolated(unsafe) static let nightscout: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
