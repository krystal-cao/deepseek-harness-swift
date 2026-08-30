import Foundation

public enum DshControlProtocolError: Error, LocalizedError, Sendable {
    case invalidGeneration
    case invalidBootstrap
    case invalidPolicy
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidGeneration:
            return "DSH 桌面控制握手参数无效。"
        case .invalidBootstrap:
            return "DSH 运行时启动参数无效。"
        case .invalidPolicy:
            return "DSH 桌面控制策略参数无效。"
        case .encodingFailed:
            return "无法编码 DSH 桌面控制消息。"
        }
    }
}

public struct DshGenerationMessage: Codable, Sendable {
    public let v: Int
    public let type: String
    public let generation: String
    public let rendererToken: String
    public let ordinaryBrowserEnabled: Bool
    public let networkExposure: DshNetworkExposure

    public init(generation: UUID, rendererToken: String, ordinaryBrowserEnabled: Bool, networkExposure: DshNetworkExposure) {
        self.v = 1
        self.type = "generation"
        self.generation = generation.uuidString
        self.rendererToken = rendererToken
        self.ordinaryBrowserEnabled = ordinaryBrowserEnabled
        self.networkExposure = networkExposure
    }
}

public struct DshBootstrapMessage: Codable, Sendable {
    public let v: Int
    public let type: String
    public let entryPath: String
    public let profile: String
    public let host: String
    public let port: Int
    public let generation: String
    public let rendererToken: String
    public let ordinaryBrowserEnabled: Bool
    public let networkExposure: DshNetworkExposure

    public init(
        entryPath: String,
        profile: String = "web",
        host: String = "127.0.0.1",
        port: Int,
        generation: UUID,
        rendererToken: String,
        ordinaryBrowserEnabled: Bool,
        networkExposure: DshNetworkExposure
    ) {
        self.v = 1
        self.type = "bootstrap"
        self.entryPath = entryPath
        self.profile = profile
        self.host = host
        self.port = port
        self.generation = generation.uuidString
        self.rendererToken = rendererToken
        self.ordinaryBrowserEnabled = ordinaryBrowserEnabled
        self.networkExposure = networkExposure
    }
}

public struct DshPolicyMessage: Codable, Sendable {
    public let v: Int
    public let type: String
    public let generation: String
    public let revision: Int
    public let ordinaryBrowserEnabled: Bool
    public let networkExposure: DshNetworkExposure

    public init(generation: UUID, revision: Int, ordinaryBrowserEnabled: Bool, networkExposure: DshNetworkExposure) {
        self.v = 1
        self.type = "policy"
        self.generation = generation.uuidString
        self.revision = revision
        self.ordinaryBrowserEnabled = ordinaryBrowserEnabled
        self.networkExposure = networkExposure
    }
}

public enum DshControlProtocol {
    public static let version = 1
    public static let maxLineBytes = 16 * 1024
    private static let tokenPattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_-]{43}$"#)

    public static func validateRendererToken(_ token: String) -> Bool {
        let range = NSRange(token.startIndex..., in: token)
        return tokenPattern.firstMatch(in: token, range: range) != nil
    }

    public static func validateNetworkExposure(_ exposure: DshNetworkExposure) -> Bool {
        exposure == .loopback || exposure == .lan
    }

    public static func encodeGeneration(_ message: DshGenerationMessage) throws -> Data {
        guard message.v == version,
              message.type == "generation",
              UUID(uuidString: message.generation) != nil,
              validateRendererToken(message.rendererToken),
              validateNetworkExposure(message.networkExposure),
              message.networkExposure == .loopback || message.ordinaryBrowserEnabled else {
            throw DshControlProtocolError.invalidGeneration
        }
        return try encode(message)
    }

    public static func encodeBootstrap(_ message: DshBootstrapMessage) throws -> Data {
        guard message.v == version,
              message.type == "bootstrap",
              message.entryPath.hasPrefix("/"),
              !message.entryPath.contains("\0"),
              message.profile == "web",
              message.host == "127.0.0.1",
              (1024...65535).contains(message.port),
              UUID(uuidString: message.generation) != nil,
              validateRendererToken(message.rendererToken),
              validateNetworkExposure(message.networkExposure),
              message.networkExposure == .loopback || message.ordinaryBrowserEnabled else {
            throw DshControlProtocolError.invalidBootstrap
        }
        return try encode(message)
    }

    public static func encodePolicy(_ message: DshPolicyMessage) throws -> Data {
        guard message.v == version,
              message.type == "policy",
              UUID(uuidString: message.generation) != nil,
              message.revision >= 1,
              validateNetworkExposure(message.networkExposure),
              message.networkExposure == .loopback || message.ordinaryBrowserEnabled else {
            throw DshControlProtocolError.invalidPolicy
        }
        return try encode(message)
    }

    private static func encode<T: Encodable>(_ message: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(message) + Data([0x0A])
        } catch {
            throw DshControlProtocolError.encodingFailed
        }
    }
}
