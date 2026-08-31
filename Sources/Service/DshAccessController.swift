import Foundation
import Security

public struct DshAccessGeneration: Sendable {
    public let id: UUID
    public let rendererToken: String
    public let ordinaryBrowserEnabled: Bool
    public let networkExposure: DshNetworkExposure

    public init(id: UUID = UUID(), rendererToken: String, ordinaryBrowserEnabled: Bool = false, networkExposure: DshNetworkExposure = .loopback) {
        self.id = id
        self.rendererToken = rendererToken
        self.ordinaryBrowserEnabled = ordinaryBrowserEnabled
        self.networkExposure = networkExposure
    }
}

public struct DshServiceSession: Sendable {
    public let endpoint: DshWebEndpoint
    public let access: DshAccessGeneration

    public init(endpoint: DshWebEndpoint, access: DshAccessGeneration) {
        self.endpoint = endpoint
        self.access = access
    }

    public var originURL: URL { endpoint.originURL }
}

/// Owns one desktop generation and the anonymous parent-to-Node control pipe.
public final class DshAccessController: @unchecked Sendable {
    public let generation: DshAccessGeneration
    public let controlReadHandle: FileHandle
    public let controlWriteHandle: FileHandle

    private let lock = NSLock()
    private var nextPolicyRevision = 0
    private var didSendGeneration = false
    private var didCloseWriteHandle = false
    private var currentOrdinaryBrowserEnabled: Bool
    private var currentNetworkExposure: DshNetworkExposure

    public init(ordinaryBrowserEnabled: Bool = false, networkExposure: DshNetworkExposure = .loopback) throws {
        self.generation = DshAccessGeneration(
            rendererToken: try Self.makeRendererToken(),
            ordinaryBrowserEnabled: ordinaryBrowserEnabled,
            networkExposure: networkExposure
        )
        self.currentOrdinaryBrowserEnabled = ordinaryBrowserEnabled
        self.currentNetworkExposure = networkExposure
        let pipe = Pipe()
        self.controlReadHandle = pipe.fileHandleForReading
        self.controlWriteHandle = pipe.fileHandleForWriting
    }

    public var currentPolicy: (ordinaryBrowserEnabled: Bool, networkExposure: DshNetworkExposure) {
        lock.lock()
        defer { lock.unlock() }
        return (currentOrdinaryBrowserEnabled, currentNetworkExposure)
    }

    public func sendBootstrap(entryPath: String, profile: DshAppProfile, port: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !didSendGeneration, !didCloseWriteHandle else { return }
        let message = DshBootstrapMessage(
            entryPath: entryPath,
            profile: profile.rawValue,
            port: port,
            generation: generation.id,
            rendererToken: generation.rendererToken,
            ordinaryBrowserEnabled: generation.ordinaryBrowserEnabled,
            networkExposure: generation.networkExposure
        )
        let data = try DshControlProtocol.encodeBootstrap(message)
        try controlWriteHandle.write(contentsOf: data)
        didSendGeneration = true
    }

    public func sendGeneration() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !didSendGeneration, !didCloseWriteHandle else { return }
        let message = DshGenerationMessage(
            generation: generation.id,
            rendererToken: generation.rendererToken,
            ordinaryBrowserEnabled: generation.ordinaryBrowserEnabled,
            networkExposure: generation.networkExposure
        )
        let data = try DshControlProtocol.encodeGeneration(message)
        try controlWriteHandle.write(contentsOf: data)
        didSendGeneration = true
    }

    /// Reserved for the browser-access phase. The revision is allocated only
    /// when the message is successfully written to the live control pipe.
    @discardableResult
    public func sendPolicy(ordinaryBrowserEnabled: Bool, networkExposure: DshNetworkExposure) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard didSendGeneration, !didCloseWriteHandle else {
            throw DshControlProtocolError.invalidPolicy
        }
        let revision = nextPolicyRevision + 1
        let message = DshPolicyMessage(
            generation: generation.id,
            revision: revision,
            ordinaryBrowserEnabled: ordinaryBrowserEnabled,
            networkExposure: networkExposure
        )
        let data = try DshControlProtocol.encodePolicy(message)
        try controlWriteHandle.write(contentsOf: data)
        nextPolicyRevision = revision
        currentOrdinaryBrowserEnabled = ordinaryBrowserEnabled
        currentNetworkExposure = networkExposure
        return revision
    }

    public func closeWriteHandle() {
        lock.lock()
        guard !didCloseWriteHandle else {
            lock.unlock()
            return
        }
        didCloseWriteHandle = true
        lock.unlock()
        try? controlWriteHandle.close()
    }

    private static func makeRendererToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(
                domain: "DshAccessController",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法生成安全的 DSH Renderer 凭证。"]
            )
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard DshControlProtocol.validateRendererToken(token) else {
            throw DshControlProtocolError.invalidGeneration
        }
        return token
    }
}
