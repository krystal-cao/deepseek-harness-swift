import Foundation

/// The authentication contract advertised by the runtime's ready URL.
///
/// `legacy` runtimes print a clean origin. `browserTokenCookie` runtimes print
/// a root URL carrying an upstream launch token which must be consumed by the
/// WebKit navigation layer and must never be used as the long-lived session
/// URL.
public enum DshAuthMode: String, Sendable, Equatable {
    case legacy
    case browserTokenCookie
}

/// The ready URL is the Runtime's authentication capability declaration. The
/// parser below intentionally validates the wire shape rather than the
/// Runtime version, so a compatible future release can be adopted without an
/// App update. The subsequent Renderer, anonymous, Browser URL, and health
/// checks remain the compatibility gate for the selected Runtime.
public enum DshWebEndpointError: Error, LocalizedError, Sendable, Equatable {
    case invalidScheme
    case invalidHost
    case missingPort
    case invalidPort
    case unexpectedPort
    case userInfoNotAllowed
    case fragmentNotAllowed
    case pathNotRoot
    case unsupportedQuery
    case missingToken
    case emptyToken

    public var errorDescription: String? {
        switch self {
        case .invalidScheme:
            return "DSH ready 地址使用了不受支持的协议。"
        case .invalidHost:
            return "DSH ready 地址不是受支持的 loopback 地址。"
        case .missingPort:
            return "DSH ready 地址缺少显式端口。"
        case .invalidPort:
            return "DSH ready 地址端口无效。"
        case .unexpectedPort:
            return "DSH ready 地址端口与本次启动不匹配。"
        case .userInfoNotAllowed:
            return "DSH ready 地址不允许包含用户信息。"
        case .fragmentNotAllowed:
            return "DSH ready 地址不允许包含 fragment。"
        case .pathNotRoot:
            return "DSH ready 地址必须指向根路径。"
        case .unsupportedQuery:
            return "DSH ready 地址包含不受支持的查询参数。"
        case .missingToken:
            return "DSH ready 地址缺少所需的认证 token。"
        case .emptyToken:
            return "DSH ready 地址的认证 token 为空。"
        }
    }
}

/// A validated DSH HTTP endpoint. The clean origin is safe for internal
/// requests and diagnostics. `bootstrapURL` is intentionally optional and is
/// only retained in memory for the first WebKit navigation.
public struct DshWebEndpoint: Sendable, Equatable {
    public let originURL: URL
    public let bootstrapURL: URL?
    public let authMode: DshAuthMode

    /// Return the same validated session endpoint without retaining the
    /// one-shot alpha launch URL. The bootstrap URL is intentionally not a
    /// long-lived application route because it carries a bearer credential.
    public func withoutBootstrap() -> DshWebEndpoint {
        DshWebEndpoint(originURL: originURL, bootstrapURL: nil, authMode: authMode)
    }

    public static func parse(_ url: URL, expectedPort: Int) throws -> DshWebEndpoint {
        guard (1024...65535).contains(expectedPort) else {
            throw DshWebEndpointError.invalidPort
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DshWebEndpointError.invalidHost
        }
        guard components.scheme == "http" else {
            throw DshWebEndpointError.invalidScheme
        }
        guard components.host == "127.0.0.1" else {
            throw DshWebEndpointError.invalidHost
        }
        guard components.port != nil else {
            throw DshWebEndpointError.missingPort
        }
        guard components.port == expectedPort else {
            throw DshWebEndpointError.unexpectedPort
        }
        guard components.user == nil, components.password == nil else {
            throw DshWebEndpointError.userInfoNotAllowed
        }
        guard components.fragment == nil else {
            throw DshWebEndpointError.fragmentNotAllowed
        }

        let path = components.path
        guard path.isEmpty || path == "/" else {
            throw DshWebEndpointError.pathNotRoot
        }

        let originURL = URL(string: "http://127.0.0.1:\(expectedPort)/")!
        guard let encodedQuery = components.percentEncodedQuery, !encodedQuery.isEmpty else {
            guard components.percentEncodedQuery == nil else {
                throw DshWebEndpointError.unsupportedQuery
            }
            return DshWebEndpoint(originURL: originURL, bootstrapURL: nil, authMode: .legacy)
        }

        guard !encodedQuery.contains("&"),
              let queryItems = components.queryItems,
              queryItems.count == 1,
              let item = queryItems.first,
              item.name == "token" else {
            throw DshWebEndpointError.unsupportedQuery
        }
        guard let token = item.value else {
            throw DshWebEndpointError.missingToken
        }
        let containsControl = token.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }), !containsControl else {
            throw DshWebEndpointError.emptyToken
        }

        // Keep the URL exactly as emitted by the runtime. URLComponents is
        // used only for validation; the original URL carries the token bytes
        // through the one controlled WebKit bootstrap navigation.
        guard encodedQuery != "token=" else {
            throw DshWebEndpointError.emptyToken
        }
        return DshWebEndpoint(originURL: originURL, bootstrapURL: url, authMode: .browserTokenCookie)
    }

    private init(originURL: URL, bootstrapURL: URL?, authMode: DshAuthMode) {
        self.originURL = originURL
        self.bootstrapURL = bootstrapURL
        self.authMode = authMode
    }
}
