import Foundation
import WebKit

@MainActor
public final class DshRendererCookieStore {
    public static let cookieName = "dsh_swift_renderer"

    public enum CookieError: Error, LocalizedError, Sendable {
        case invalidOrigin
        case constructionFailed
        case writeFailed
        case verificationFailed

        public var errorDescription: String? {
            switch self {
            case .invalidOrigin:
                return "DSH 服务地址不是受支持的本机地址。"
            case .constructionFailed:
                return "无法创建 DSH Renderer 凭证 Cookie。"
            case .writeFailed:
                return "无法写入 DSH Renderer 凭证 Cookie。"
            case .verificationFailed:
                return "DSH Renderer 凭证 Cookie 写入校验失败。"
            }
        }
    }

    private let store: WKHTTPCookieStore

    public init(dataStore: WKWebsiteDataStore) {
        self.store = dataStore.httpCookieStore
    }

    public func install(for session: DshServiceSession) async throws {
        guard session.url.scheme == "http",
              session.url.host == "127.0.0.1",
              let originURL = URL(string: "http://127.0.0.1") else {
            throw CookieError.invalidOrigin
        }

        let oldCookies = await allCookies()
        for cookie in oldCookies where cookie.name == Self.cookieName {
            await delete(cookie)
        }

        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: Self.cookieName,
            .value: session.access.rendererToken,
            .originURL: originURL,
            .path: "/",
            .discard: true,
            .sameSitePolicy: HTTPCookieStringPolicy.sameSiteStrict,
            // Foundation does not expose a typed HTTPOnly construction key,
            // but WKWebView accepts the standard property and preserves it.
            HTTPCookiePropertyKey("HttpOnly"): true
        ]
        guard let cookie = HTTPCookie(properties: properties) else {
            throw CookieError.constructionFailed
        }

        do {
            try await set(cookie)
        } catch {
            throw CookieError.writeFailed
        }

        let installed = await allCookies().first {
            $0.name == Self.cookieName &&
            $0.value == session.access.rendererToken &&
            $0.domain == "127.0.0.1" &&
            $0.path == "/"
        }
        guard let installed,
              installed.isHTTPOnly,
              installed.sameSitePolicy == HTTPCookieStringPolicy.sameSiteStrict,
              installed.isSessionOnly else {
            throw CookieError.verificationFailed
        }
    }

    private func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func set(_ cookie: HTTPCookie) async throws {
        try await withCheckedThrowingContinuation { continuation in
            store.setCookie(cookie) {
                continuation.resume()
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
