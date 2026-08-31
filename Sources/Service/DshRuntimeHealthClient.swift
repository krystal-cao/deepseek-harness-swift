import Foundation

/// Credentials for one health request. The client never consults a shared or
/// persistent cookie jar; callers explicitly choose the cookies for each
/// request and the client sends them as one controlled Cookie header.
public struct DshRuntimeHealthCredentials: Sendable, Equatable {
    public let cookieHeader: String?

    public init(cookieHeader: String? = nil) {
        let trimmed = cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cookieHeader = trimmed?.isEmpty == true ? nil : trimmed
    }

    public static let anonymous = DshRuntimeHealthCredentials()
}

public struct DshRuntimeHealthResponse: Sendable {
    public let statusCode: Int
    public let body: Data
    public let finalURL: URL
    public let contentType: String?
    public let redirectCount: Int
    public let setCookieHeaders: [String]
}

/// Small, testable HTTP client for native runtime probes. Redirects are
/// limited to the original origin and never receive credentials implicitly.
public final class DshRuntimeHealthClient: @unchecked Sendable {
    public enum ClientError: Error, LocalizedError, Sendable {
        case nonHTTPResponse(String)
        case redirectRejected(String)
        case tooManyRedirects(String)
        case invalidFinalURL(String)
        case requestFailed(String)

        public var errorDescription: String? {
            switch self {
            case .nonHTTPResponse(let label):
                return "\(label) 没有返回有效的 HTTP 响应。"
            case .redirectRejected(let label):
                return "\(label) 的重定向超出了受支持的认证边界。"
            case .tooManyRedirects(let label):
                return "\(label) 的重定向次数超过限制。"
            case .invalidFinalURL(let label):
                return "\(label) 返回了不受支持的最终地址。"
            case .requestFailed(let label):
                return "\(label) 请求失败。"
            }
        }
    }

    public init() {}

    public func perform(
        request originalRequest: URLRequest,
        credentials: DshRuntimeHealthCredentials = .anonymous,
        label: String,
        requireCleanFinalURL: Bool = false,
        requireCleanRedirectTargets: Bool? = nil,
        maxRedirects: Int = 3
    ) async throws -> DshRuntimeHealthResponse {
        guard let requestURL = originalRequest.url,
              let origin = Origin(url: requestURL) else {
            throw ClientError.requestFailed(label)
        }

        var request = originalRequest
        request.setValue(credentials.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let redirectDelegate = RedirectDelegate(
            origin: origin,
            credentials: credentials,
            requireCleanRedirectTargets: requireCleanRedirectTargets ?? requireCleanFinalURL,
            maxRedirects: maxRedirects
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let body: Data
        let response: URLResponse
        do {
            (body, response) = try await session.data(for: request)
        } catch {
            if redirectDelegate.didRejectRedirect {
                throw ClientError.redirectRejected(label)
            }
            if redirectDelegate.didExceedRedirectLimit {
                throw ClientError.tooManyRedirects(label)
            }
            throw ClientError.requestFailed(label)
        }
        if redirectDelegate.didRejectRedirect {
            throw ClientError.redirectRejected(label)
        }
        if redirectDelegate.didExceedRedirectLimit {
            throw ClientError.tooManyRedirects(label)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.nonHTTPResponse(label)
        }
        guard let finalURL = httpResponse.url,
              let finalOrigin = Origin(url: finalURL),
              finalOrigin == origin else {
            throw ClientError.invalidFinalURL(label)
        }
        if requireCleanFinalURL && !Self.isCleanRoot(finalURL) {
            throw ClientError.invalidFinalURL(label)
        }

        return DshRuntimeHealthResponse(
            statusCode: httpResponse.statusCode,
            body: body,
            finalURL: finalURL,
            contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
            redirectCount: redirectDelegate.redirectCount,
            setCookieHeaders: redirectDelegate.setCookieHeaders
        )
    }

    public static func isHTMLPage(_ response: DshRuntimeHealthResponse) -> Bool {
        if response.contentType?.localizedCaseInsensitiveContains("text/html") == true {
            return true
        }
        guard let body = String(data: response.body, encoding: .utf8)?.lowercased() else {
            return false
        }
        return body.contains("<!doctype html") || body.contains("<html")
    }

    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        init?(url: URL) {
            guard let scheme = url.scheme?.lowercased(),
                  let host = url.host?.lowercased() else { return nil }
            let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
            guard port > 0 else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = port
        }
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
        let origin: Origin
        let credentials: DshRuntimeHealthCredentials
        let requireCleanRedirectTargets: Bool
        let maxRedirects: Int
        var redirectCount = 0
        var didRejectRedirect = false
        var didExceedRedirectLimit = false
        var setCookieHeaders: [String] = []

        init(
            origin: Origin,
            credentials: DshRuntimeHealthCredentials,
            requireCleanRedirectTargets: Bool,
            maxRedirects: Int
        ) {
            self.origin = origin
            self.credentials = credentials
            self.requireCleanRedirectTargets = requireCleanRedirectTargets
            self.maxRedirects = max(0, maxRedirects)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            if let value = response.value(forHTTPHeaderField: "Set-Cookie"), !value.isEmpty {
                setCookieHeaders.append(value)
            }
            guard redirectCount < maxRedirects else {
                didExceedRedirectLimit = true
                completionHandler(nil)
                return
            }
            guard let url = request.url,
                  let redirectOrigin = Origin(url: url),
                  redirectOrigin == origin,
                  url.fragment == nil,
                  !requireCleanRedirectTargets || DshRuntimeHealthClient.isCleanRoot(url) else {
                didRejectRedirect = true
                completionHandler(nil)
                return
            }

            var redirectedRequest = request
            redirectedRequest.setValue(credentials.cookieHeader, forHTTPHeaderField: "Cookie")
            redirectedRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            redirectCount += 1
            completionHandler(redirectedRequest)
        }
    }

    private static func isCleanRoot(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.fragment == nil,
              components.query == nil else { return false }
        return components.path.isEmpty || components.path == "/"
    }
}
