import Foundation

/// The message kinds understood by the native desktop bridge. Keeping this
/// list in one value makes capability selection explicit for normal,
/// recovery, and other app-owned pages.
public enum DshBridgeMessageType: String, CaseIterable, Hashable, Codable, Sendable {
    case ready
    case openSettings
    case theme
    case locale
    case notify
    case windowDragPrepare
    case windowDragStart
    case windowDragMove
    case windowDragEnd
    case windowTitlebarDoubleClick
    case debug

    public static let normalCapability: Set<DshBridgeMessageType> =
        Set(Self.allCases).subtracting([.debug])

    /// Recovery pages can report readiness and presentation state, but they
    /// do not receive arbitrary native actions. The set is intentionally
    /// independent from the normal page's capability set.
    public static let recoveryCapability: Set<DshBridgeMessageType> = [
        .ready,
        .openSettings,
        .theme,
        .locale,
        .notify,
        .windowDragPrepare,
        .windowDragStart,
        .windowDragMove,
        .windowDragEnd,
        .windowTitlebarDoubleClick
    ]
}

/// An opaque identity for a WebKit view. The WebKit adapter creates this from
/// the actual WKWebView object; harnesses can construct deterministic values
/// without creating WebKit objects.
public struct DshBridgeWebViewIdentity: Hashable, Codable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(object: AnyObject) {
        self.rawValue = UInt64(UInt(bitPattern: ObjectIdentifier(object)))
    }
}

/// The exact origin observed by WebKit for a bridge request.
public struct DshBridgeOrigin: Equatable, Codable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int

    public init(scheme: String, host: String, port: Int) {
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    /// Construct an origin from a URL without accepting path, query, or
    /// fragment data. The bridge only authorizes the security-origin tuple.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              let port = url.port else { return nil }
        self.init(scheme: scheme, host: host, port: port)
    }
}

/// A snapshot of the only session that may use the bridge at this instant.
/// The launch and generation IDs are both required: a new process generation
/// can be created while the same WebView object remains alive.
public struct DshBridgeValidationContext: Equatable, Sendable {
    public let webViewIdentity: DshBridgeWebViewIdentity
    public let launchID: UUID
    public let generationID: UUID
    public let origin: DshBridgeOrigin
    public let allowedMessageTypes: Set<DshBridgeMessageType>

    public init(
        webViewIdentity: DshBridgeWebViewIdentity,
        launchID: UUID,
        generationID: UUID,
        origin: DshBridgeOrigin,
        allowedMessageTypes: Set<DshBridgeMessageType> = DshBridgeMessageType.normalCapability
    ) {
        self.webViewIdentity = webViewIdentity
        self.launchID = launchID
        self.generationID = generationID
        self.origin = origin
        self.allowedMessageTypes = allowedMessageTypes
    }
}

/// The source metadata extracted from WKScriptMessage plus its untrusted body.
/// `body` intentionally remains `Any`; the validator performs the type and
/// shape checks before the handler reads any payload field.
public struct DshBridgeIncomingMessage {
    public let handlerName: String
    public let isMainFrame: Bool
    public let webViewIdentity: DshBridgeWebViewIdentity?
    public let origin: DshBridgeOrigin
    public let body: Any

    public init(
        handlerName: String,
        isMainFrame: Bool,
        webViewIdentity: DshBridgeWebViewIdentity?,
        origin: DshBridgeOrigin,
        body: Any
    ) {
        self.handlerName = handlerName
        self.isMainFrame = isMainFrame
        self.webViewIdentity = webViewIdentity
        self.origin = origin
        self.body = body
    }
}

public enum DshBridgeMessageValidationError: Error, LocalizedError, Equatable, Sendable {
    case noCurrentSession
    case wrongHandler
    case notMainFrame
    case missingWebView
    case webViewMismatch
    case invalidExpectedOrigin
    case wrongOriginScheme
    case wrongOriginHost
    case wrongOriginPort
    case invalidBody
    case bodyTooLarge
    case unsupportedBodyField(String)
    case invalidType
    case unknownType
    case messageNotAllowed
    case missingLaunchID
    case invalidLaunchID
    case launchMismatch
    case missingGenerationID
    case invalidGenerationID
    case generationMismatch
    case payloadRequired
    case payloadForbidden
    case invalidPayload
    case payloadTooLarge
    case unsupportedPayloadField(String)
    case payloadValueTooLong(String)

    public var errorDescription: String? {
        switch self {
        case .noCurrentSession: return "桥接当前没有有效的 DSH 会话。"
        case .wrongHandler: return "桥接消息处理器名称无效。"
        case .notMainFrame: return "桥接消息必须来自主页面。"
        case .missingWebView: return "桥接消息缺少 WebView 来源。"
        case .webViewMismatch: return "桥接消息不是来自当前 WebView。"
        case .invalidExpectedOrigin: return "桥接会话来源配置无效。"
        case .wrongOriginScheme: return "桥接消息协议不是受支持的 HTTP 来源。"
        case .wrongOriginHost: return "桥接消息来源不是受支持的 loopback 主机。"
        case .wrongOriginPort: return "桥接消息端口与当前会话不一致。"
        case .invalidBody: return "桥接消息格式无效。"
        case .bodyTooLarge: return "桥接消息超过大小上限。"
        case .unsupportedBodyField(let field): return "桥接消息包含不受支持的字段：\(field)。"
        case .invalidType: return "桥接消息类型无效。"
        case .unknownType: return "桥接消息类型不受支持。"
        case .messageNotAllowed: return "当前页面没有执行此桥接动作的权限。"
        case .missingLaunchID: return "桥接消息缺少启动代际标识。"
        case .invalidLaunchID: return "桥接消息启动标识无效。"
        case .launchMismatch: return "桥接消息属于旧启动。"
        case .missingGenerationID: return "桥接消息缺少进程代际标识。"
        case .invalidGenerationID: return "桥接消息进程标识无效。"
        case .generationMismatch: return "桥接消息属于旧进程代际。"
        case .payloadRequired: return "桥接消息缺少所需 payload。"
        case .payloadForbidden: return "此桥接消息不接受 payload。"
        case .invalidPayload: return "桥接 payload 类型或结构无效。"
        case .payloadTooLarge: return "桥接 payload 超过大小上限。"
        case .unsupportedPayloadField(let field): return "桥接 payload 包含不受支持的字段：\(field)。"
        case .payloadValueTooLong(let field): return "桥接 payload 字段过长：\(field)。"
        }
    }
}

/// A typed result handed to DshBridgeHandler after all source and payload
/// checks have passed.
public struct DshBridgeValidatedMessage {
    public let type: DshBridgeMessageType
    public let launchID: UUID
    public let generationID: UUID
    public let payload: Any?

    public init(type: DshBridgeMessageType, launchID: UUID, generationID: UUID, payload: Any?) {
        self.type = type
        self.launchID = launchID
        self.generationID = generationID
        self.payload = payload
    }
}

/// Pure, injectable bridge validator. It has no WebKit dependency so the
/// boundary behavior can be exercised with deterministic Swift fixtures.
public final class DshBridgeMessageValidator: @unchecked Sendable {
    public static let handlerName = "dshDesktop"
    public static let maximumBodyBytes = 64 * 1024
    public static let maximumPayloadBytes = 16 * 1024
    public static let maximumStringBytes = 4 * 1024
    public static let maximumDictionaryDepth = 5

    private let currentContext: () -> DshBridgeValidationContext?

    public init(
        currentContext: @escaping () -> DshBridgeValidationContext?
    ) {
        self.currentContext = currentContext
    }

    /// A rejecting default makes an unconfigured handler fail closed. The
    /// launch coordinator must supply a current context before loading a page.
    public convenience init() {
        self.init(currentContext: { nil })
    }

    public func validate(
        _ message: DshBridgeIncomingMessage
    ) -> Result<DshBridgeValidatedMessage, DshBridgeMessageValidationError> {
        guard let context = currentContext() else { return .failure(.noCurrentSession) }
        return validate(message, context: context)
    }

    /// Validate against one captured context. The WebKit adapter uses this
    /// overload after taking a single context snapshot, so a concurrent
    /// navigation/restart cannot mix the old message with a new generation.
    public func validate(
        _ message: DshBridgeIncomingMessage,
        context: DshBridgeValidationContext
    ) -> Result<DshBridgeValidatedMessage, DshBridgeMessageValidationError> {
        guard context.origin.scheme == "http" else { return .failure(.invalidExpectedOrigin) }
        guard context.origin.host == "127.0.0.1" else { return .failure(.invalidExpectedOrigin) }
        guard (1024...65535).contains(context.origin.port) else { return .failure(.invalidExpectedOrigin) }

        guard message.handlerName == Self.handlerName else { return .failure(.wrongHandler) }
        guard message.isMainFrame else { return .failure(.notMainFrame) }
        guard let webViewIdentity = message.webViewIdentity else { return .failure(.missingWebView) }
        guard webViewIdentity == context.webViewIdentity else { return .failure(.webViewMismatch) }
        guard message.origin.scheme == "http" else { return .failure(.wrongOriginScheme) }
        guard message.origin.host == "127.0.0.1" else { return .failure(.wrongOriginHost) }
        guard message.origin.port == context.origin.port else { return .failure(.wrongOriginPort) }

        guard let body = message.body as? [String: Any] else { return .failure(.invalidBody) }
        guard encodedByteCount(body) <= Self.maximumBodyBytes else {
            return .failure(.bodyTooLarge)
        }
        let allowedBodyFields: Set<String> = ["type", "launchID", "generationID", "payload"]
        for field in body.keys where !allowedBodyFields.contains(field) {
            return .failure(.unsupportedBodyField(field))
        }

        guard let typeString = body["type"] as? String,
              !typeString.isEmpty,
              Data(typeString.utf8).count <= 128 else {
            return .failure(.invalidType)
        }
        guard let type = DshBridgeMessageType(rawValue: typeString) else {
            return .failure(.unknownType)
        }
        guard context.allowedMessageTypes.contains(type) else {
            return .failure(.messageNotAllowed)
        }

        guard let launchString = body["launchID"] as? String else {
            return .failure(.missingLaunchID)
        }
        guard let launchID = UUID(uuidString: launchString) else {
            return .failure(.invalidLaunchID)
        }
        guard launchID == context.launchID else { return .failure(.launchMismatch) }

        guard let generationString = body["generationID"] as? String else {
            return .failure(.missingGenerationID)
        }
        guard let generationID = UUID(uuidString: generationString) else {
            return .failure(.invalidGenerationID)
        }
        guard generationID == context.generationID else { return .failure(.generationMismatch) }

        let payload = body["payload"]
        switch validatePayload(payload, for: type) {
        case .failure(let error): return .failure(error)
        case .success: break
        }

        return .success(DshBridgeValidatedMessage(
            type: type,
            launchID: launchID,
            generationID: generationID,
            payload: payload
        ))
    }

    private func validatePayload(
        _ payload: Any?,
        for type: DshBridgeMessageType
    ) -> Result<Void, DshBridgeMessageValidationError> {
        let objectTypes: Set<DshBridgeMessageType> = [.theme, .locale, .notify]
        if type == .debug {
            guard let payload else { return .failure(.payloadRequired) }
            guard let value = payload as? String else { return .failure(.invalidPayload) }
            guard Data(value.utf8).count <= Self.maximumStringBytes else {
                return .failure(.payloadValueTooLong("debug"))
            }
            guard encodedByteCount(payload) <= Self.maximumPayloadBytes else {
                return .failure(.payloadTooLarge)
            }
            return .success(())
        }

        if objectTypes.contains(type) {
            guard let payload else { return .failure(.payloadRequired) }
            guard let object = payload as? [String: Any] else { return .failure(.invalidPayload) }
            guard encodedByteCount(object) <= Self.maximumPayloadBytes else {
                return .failure(.payloadTooLarge)
            }
            let allowed: Set<String>
            switch type {
            case .theme: allowed = ["colorScheme", "externalTheme"]
            case .locale: allowed = ["language"]
            case .notify: allowed = ["title", "cwd"]
            default: allowed = []
            }
            for key in object.keys where !allowed.contains(key) {
                return .failure(.unsupportedPayloadField(key))
            }
            for (key, value) in object {
                guard let string = value as? String else { return .failure(.invalidPayload) }
                guard Data(string.utf8).count <= Self.maximumStringBytes else {
                    return .failure(.payloadValueTooLong(key))
                }
            }
            if type == .locale {
                guard let language = object["language"] as? String, !language.isEmpty else {
                    return .failure(.invalidPayload)
                }
            }
            return .success(())
        }

        guard payload == nil else { return .failure(.payloadForbidden) }
        return .success(())
    }

    private func validJSONObject(_ value: Any, depth: Int = 0) -> Bool {
        guard depth <= Self.maximumDictionaryDepth else { return false }
        switch value {
        case let string as String:
            return Data(string.utf8).count <= Self.maximumStringBytes
        case let object as [String: Any]:
            return object.allSatisfy { key, child in
                Data(key.utf8).count <= Self.maximumStringBytes
                    && validJSONObject(child, depth: depth + 1)
            }
        case let array as [Any]:
            return array.allSatisfy { validJSONObject($0, depth: depth + 1) }
        default:
            // Numbers, booleans, null, dates, and arbitrary NSObject values
            // are deliberately excluded from this bridge contract.
            return false
        }
    }

    private func encodedByteCount(_ value: Any) -> Int {
        if let string = value as? String {
            // JSONSerialization historically requires an array/dictionary
            // root on older macOS releases; account for a JSON string here.
            return Data(string.utf8).count + 2
        }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: []) {
            return data.count
        }
        return Int.max
    }
}
