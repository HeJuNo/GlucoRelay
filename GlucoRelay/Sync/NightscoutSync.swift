import Foundation
import os.log

private let logger = Logger(subsystem: "glucorelay", category: "Nightscout")

enum NightscoutError: LocalizedError {
    case noURL
    case noToken
    case invalidURL
    case invalidToken
    case unauthorized
    case serverError(Int)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .noURL:        return "No Nightscout URL configured. Please enter one in Settings."
        case .noToken:      return "No access token configured. Please enter one in Settings."
        case .invalidURL:   return "The Nightscout URL is invalid."
        case .invalidToken: return "Access token not recognised by Nightscout. Please check the token."
        case .unauthorized: return "Not authorised (HTTP 401). Check the token's roles (readable + careportal)."
        case .serverError(let code): return "Server error (HTTP \(code)). Check URL and access token."
        case .networkError(let msg): return "Network error: \(msg)"
        }
    }
}

// MARK: - Connection test result

struct ConnectionTestResult: Sendable {
    enum Status: Sendable { case ok, failed, unknown }

    var reachable: Status = .unknown
    var reachableDetail: String = ""
    var canRead: Status = .unknown
    var readDetail: String = ""
    var canWrite: Status = .unknown
    var writeDetail: String = ""
    var serverInfo: String? = nil
    var subject: String? = nil

    var allOK: Bool { reachable == .ok && canRead == .ok && canWrite == .ok }
}

// MARK: - BG entry payload

/// Payload sent to `POST /api/v1/treatments` for a meter blood glucose reading.
struct NightscoutEntry: Sendable {
    let mgdL: Double
    let date: Date
    let serialNumber: String

    var json: [String: Any] {
        [
            "eventType": "BG Check",
            "glucose": Int(mgdL.rounded()),
            "glucoseType": "Finger",
            "units": "mg/dl",
            "created_at": ISO8601DateFormatter.nightscout.string(from: date),
            "enteredBy": NightscoutSync.enteredBy,
            "notes": "SN:\(serialNumber)"
        ]
    }
}

// MARK: - Service

/// Nightscout access mirroring nightscout-remote/NightscoutService.swift:
/// exchange the access token for a short-lived JWT via
/// `GET /api/v2/authorization/request/<token>`, then send
/// `Authorization: Bearer <jwt>` on every API call. The JWT is cached and
/// refreshed automatically on 401.
enum NightscoutSync {

    static let enteredBy = "GlucoRelay"

    // MARK: Auth types

    private struct AuthSession: Sendable {
        let base: String
        let accessToken: String
        let jwt: String
        let permissions: [String]
        let subject: String?
        let expires: Date
    }

    private enum AuthOutcome: Sendable {
        case session(AuthSession)
        case invalidToken(Int)   // server reachable but token not recognised
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
        !(KeychainManager.nightscoutURL ?? "").isEmpty &&
        !(KeychainManager.accessToken ?? "").isEmpty
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

    /// Nightscout access tokens look like `<subjectname>-<16 hex chars>`,
    /// e.g. `glucorelay-1a2b3c4d5e6f7a8b`.
    static func looksLikeAccessToken(_ raw: String) -> Bool {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.range(of: #"^[^\s/]+-[0-9a-fA-F]{16}$"#, options: .regularExpression) != nil
    }

    // MARK: JWT

    private static func authorize(base: String, token: String) async throws -> AuthOutcome {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = token.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "\(base)/api/v2/authorization/request/\(encoded)"),
              url.host != nil else { throw NightscoutError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, http) = try await perform(request)
        logger.info("Token exchange: HTTP \(http.statusCode), token length \(token.count), looksValid \(looksLikeAccessToken(token))")

        guard (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jwt = json["token"] as? String, !jwt.isEmpty else {
            // Server responded but token was not accepted — distinguish from server down
            if http.statusCode == 401 || http.statusCode == 403 || (200..<300).contains(http.statusCode) {
                return .invalidToken(http.statusCode)
            }
            throw NightscoutError.serverError(http.statusCode)
        }

        let groups = (json["permissionGroups"] as? [[String]]) ?? []
        let permissions = groups.flatMap { $0 }
        let exp = (json["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
            ?? Date().addingTimeInterval(3600)
        let session = AuthSession(base: base, accessToken: token, jwt: jwt,
                                  permissions: permissions,
                                  subject: json["sub"] as? String,
                                  expires: exp)
        logger.info("Token OK – subject \(session.subject ?? "?"), permissions \(permissions.joined(separator: ","))")
        return .session(session)
    }

    private static func session(base: String, token: String) async throws -> AuthSession {
        if let cached = await cache.get(base: base, token: token) { return cached }
        switch try await authorize(base: base, token: token) {
        case .session(let s):
            await cache.set(s)
            return s
        case .invalidToken:
            throw NightscoutError.invalidToken
        }
    }

    /// Pre-fetches the JWT on app launch so the first upload is instant.
    static func prefetchJWT() async {
        guard let creds = try? storedCredentials() else { return }
        _ = try? await session(base: creds.base, token: creds.token)
    }

    static func resetSession() async { await cache.set(nil) }

    // MARK: Shiro permission check (same as nightscout-remote)

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

    /// Posts one BG Check treatment. Retries once with a fresh JWT on 401/403.
    static func post(_ entry: NightscoutEntry) async throws {
        let creds = try storedCredentials()
        guard let url = URL(string: "\(creds.base)/api/v1/treatments"), url.host != nil else {
            throw NightscoutError.invalidURL
        }
        let body = try JSONSerialization.data(withJSONObject: [entry.json])

        for attempt in 0..<2 {
            let auth: AuthSession
            if attempt == 0 {
                auth = try await session(base: creds.base, token: creds.token)
            } else {
                // force refresh on retry
                await cache.set(nil)
                auth = try await session(base: creds.base, token: creds.token)
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(auth.jwt)", forHTTPHeaderField: "Authorization")
            request.httpBody = body

            let (_, http) = try await perform(request)
            logger.info("POST /api/v1/treatments SN \(entry.serialNumber): HTTP \(http.statusCode)")
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

    static func testConnection(urlString: String, token rawToken: String) async -> ConnectionTestResult {
        var result = ConnectionTestResult()
        let base = normalizedBase(urlString)
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        await cache.set(nil)

        guard !base.isEmpty,
              let statusURL = URL(string: "\(base)/api/v1/status.json"),
              statusURL.host != nil else {
            result.reachable = .failed
            result.reachableDetail = "Invalid URL"
            return result
        }

        // 1) Exchange access token → JWT (proves server is reachable)
        let auth: AuthSession
        do {
            switch try await authorize(base: base, token: token) {
            case .session(let s):
                auth = s
                result.reachable = .ok
                result.reachableDetail = "Server reachable, access token valid"
                result.subject = s.subject
            case .invalidToken(let code):
                result.reachable = .ok
                result.reachableDetail = "Server reachable – access token not recognised (HTTP \(code))"
                result.canRead = .failed
                result.canWrite = .failed
                result.readDetail = "Access token invalid – copy it exactly from Nightscout Admin Tools"
                result.writeDetail = result.readDetail
                return result
            }
        } catch NightscoutError.serverError(let code) {
            result.reachable = .failed
            result.reachableDetail = code == 404
                ? "No Nightscout instance (or version without API v2) at this URL (HTTP 404)"
                : "Server responded with HTTP \(code)"
            return result
        } catch {
            result.reachable = .failed
            result.reachableDetail = error.localizedDescription
            return result
        }

        // 2) Server info
        if let resp = try? await perform(bearerRequest(statusURL, jwt: auth.jwt)),
           (200..<300).contains(resp.1.statusCode),
           let json = try? JSONSerialization.jsonObject(with: resp.0) as? [String: Any] {
            let name = json["name"] as? String ?? "Nightscout"
            let version = json["version"] as? String ?? "?"
            result.serverInfo = "\(name) \(version)"
        }

        // 3) Read: real read of a treatment; permission check as fallback
        if let readURL = URL(string: "\(base)/api/v1/treatments.json?count=1"),
           let resp = try? await perform(bearerRequest(readURL, jwt: auth.jwt)) {
            result.canRead = (200..<300).contains(resp.1.statusCode) ? .ok : .failed
        } else {
            result.canRead = permits(auth.permissions, "api:treatments:read") ? .ok : .failed
        }

        // 4) Write: derived from the token's permissions (nothing is written during the test)
        result.canWrite = permits(auth.permissions, "api:treatments:create") ? .ok : .failed

        let roles = auth.permissions.isEmpty ? "none" : auth.permissions.joined(separator: ", ")
        result.readDetail = result.canRead == .ok
            ? "Treatments can be read"
            : "No read access – add role e.g. \"readable\" to the token (has: \(roles))"
        result.writeDetail = result.canWrite == .ok
            ? "BG Check treatments can be written"
            : "No write access – add role e.g. \"careportal\" to the token (has: \(roles))"
        return result
    }

    // MARK: Helpers

    private static func bearerRequest(_ url: URL, jwt: String, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private static func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NightscoutError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NightscoutError.networkError("Invalid response")
        }
        return (data, http)
    }
}

// MARK: - ISO8601

extension ISO8601DateFormatter {
    /// `2026-10-07T10:30:00.000Z`
    nonisolated(unsafe) static let nightscout: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
