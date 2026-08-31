import Foundation
import WebKit
import CryptoKit

/// Owns only the upstream BrowserAuth cookies created by the current WebKit
/// session. Renderer credentials remain in DshRendererCookieStore; keeping
/// these stores separate prevents a token exchange from being mistaken for
/// the native page credential.
@MainActor
public final class DshUpstreamCookieStore {
    public static let cookieNamePrefix = "dsh-auth-"

    public enum CookieError: Error, LocalizedError, Sendable {
        case invalidOrigin
        case missingCookie
        case ambiguousCookies

        public var errorDescription: String? {
            switch self {
            case .invalidOrigin:
                return "DSH 上游认证 Cookie 的来源不是受支持的本机地址。"
            case .missingCookie:
                return "DSH 页面未完成上游认证，请重新启动服务后重试。"
            case .ambiguousCookies:
                return "DSH 页面返回了不明确的上游认证状态，请重新启动服务后重试。"
            }
        }
    }

    private let store: WKHTTPCookieStore
    private let pollIntervalNanoseconds: UInt64

    public init(dataStore: WKWebsiteDataStore, pollIntervalNanoseconds: UInt64 = 100_000_000) {
        self.store = dataStore.httpCookieStore
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    /// Remove only app-managed upstream auth cookies. Other WebKit website
    /// data, including unrelated cookies and local storage, is preserved.
    /// Cookie domains do not carry ports, so clearing this app-owned prefix on
    /// the loopback host is the safe way to avoid reusing another authority's
    /// stale BrowserAuth cookie when a new port is selected.
    public func prepareForNewSession(for session: DshServiceSession) async throws {
        try validate(session)
        for cookie in await allCookies() where isManaged(cookie) {
            await delete(cookie)
        }
    }

    /// Wait for the cookie issued by alpha.2's token redirect. The preceding
    /// prepareForNewSession call makes the result a cookie from this startup,
    /// rather than an arbitrary old dsh-auth-* value.
    public func waitForAuthenticatedCookies(
        for session: DshServiceSession,
        timeout: TimeInterval = 10
    ) async throws -> [HTTPCookie] {
        try validate(session)
        guard session.endpoint.authMode == .browserTokenCookie else { return [] }

        let deadline = Date().addingTimeInterval(timeout)
        let expectedCookieName = try Self.expectedCookieName(for: session)
        while true {
            let cookies = await allCookies().filter {
                $0.name == expectedCookieName && isUsableUpstreamCookie($0)
            }
            if cookies.count == 1 {
                return cookies
            }
            if cookies.count > 1 {
                throw CookieError.ambiguousCookies
            }
            if Date() >= deadline {
                throw CookieError.missingCookie
            }
            do {
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            } catch {
                throw CookieError.missingCookie
            }
        }
    }

    private func validate(_ session: DshServiceSession) throws {
        guard session.originURL.scheme == "http",
              session.originURL.host == "127.0.0.1",
              session.originURL.port != nil else {
            throw CookieError.invalidOrigin
        }
    }

    private func isUsableUpstreamCookie(_ cookie: HTTPCookie) -> Bool {
        guard isManaged(cookie),
              cookie.isHTTPOnly,
              !cookie.isSecure,
              cookie.sameSitePolicy == HTTPCookieStringPolicy.sameSiteStrict else { return false }
        if let expiry = cookie.expiresDate, expiry <= Date() { return false }
        return true
    }

    /// alpha.2 names the BrowserAuth cookie with the SHA-256 of the exact
    /// authority, including the non-default port. This is only a cookie-name
    /// adapter; the signed cookie value remains entirely owned by upstream.
    public static func expectedCookieName(for session: DshServiceSession) throws -> String {
        guard let host = session.originURL.host?.lowercased(),
              let port = session.originURL.port else {
            throw CookieError.invalidOrigin
        }
        let authority = "\(host):\(port)"
        let digest = SHA256.hash(data: Data(authority.utf8))
        let encoded = Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.cookieNamePrefix + encoded
    }

    private func isManaged(_ cookie: HTTPCookie) -> Bool {
        let normalizedDomain = cookie.domain.hasPrefix(".")
            ? String(cookie.domain.dropFirst())
            : cookie.domain
        return cookie.name.hasPrefix(Self.cookieNamePrefix)
            && normalizedDomain == "127.0.0.1"
            && cookie.path == "/"
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func delete(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            store.delete(cookie) {
                continuation.resume()
            }
        }
    }
}
