import Foundation

/// The coarse stages of one desktop launch. A stage is a UI and diagnostic
/// label; it does not imply that the underlying operation is cancellable.
public enum DshLaunchPhase: String, Codable, CaseIterable, Sendable {
    case preparing
    case dependencyCheck
    case startingService
    case authentication
    case loadingInterface
    case connectionValidation
    case ready

    public var displayName: String {
        switch self {
        case .preparing: return "准备启动"
        case .dependencyCheck: return "检查依赖"
        case .startingService: return "启动服务"
        case .authentication: return "建立认证"
        case .loadingInterface: return "加载界面"
        case .connectionValidation: return "验证连接"
        case .ready: return "已就绪"
        }
    }
}

/// Stable, app-owned diagnostic codes. The values are persisted, so changing
/// a label in the UI must not rename a code. `unknown` deliberately remains a
/// valid result when upstream behavior cannot be classified safely.
public enum DshDiagnosticCode: String, Codable, CaseIterable, Sendable {
    case dependencyMissing
    case runtimeEntryMissing
    case nodeMissing
    case bootstrapMissing
    case portConflict
    case processExited
    case startupTimeout
    case invalidEndpoint
    case endpointConflict
    case generationMismatch
    case policyMismatch
    case authenticationFailed
    case pageLoadFailed
    case connectionFailed
    case pluginConfigurationInvalid
    case pluginPackageMissing
    case launchCancelled
    case unknown
}

public enum DshDiagnosticRetryability: String, Codable, Sendable {
    case retryable
    case notRetryable
    case unknown
}

public enum DshDiagnosticSource: String, Codable, Sendable {
    case native
    case processOutput
    case controlProtocol
    case healthCheck
    case webKit
    case pluginInspector
    case unknown
}

/// Evidence is intentionally separate from the top-level failure. A log line
/// can suggest a plugin without proving that the plugin caused the failure.
public enum DshDiagnosticConfidence: String, Codable, Sendable {
    case confirmed
    case suspected
    case unknown
}

public struct DshDiagnosticEvidence: Codable, Equatable, Sendable {
    public let source: DshDiagnosticSource
    public let confidence: DshDiagnosticConfidence
    public let summary: String
    public let pluginName: String?
    public let generationID: UUID?

    public init(
        source: DshDiagnosticSource,
        confidence: DshDiagnosticConfidence,
        summary: String,
        pluginName: String? = nil,
        generationID: UUID? = nil
    ) {
        self.source = source
        self.confidence = confidence
        self.summary = summary
        self.pluginName = pluginName
        self.generationID = generationID
    }
}

/// The immutable identity and launch metadata supplied by the caller. The
/// launch UUID is required so stale events from an earlier launch cannot be
/// accepted accidentally.
public struct DshDiagnosticLaunchContext: Codable, Equatable, Sendable {
    public let launchID: UUID
    public let generationID: UUID?
    public let runtimeVersion: String?
    public let profile: String?
    public let startedAt: Date

    public init(
        launchID: UUID,
        generationID: UUID? = nil,
        runtimeVersion: String? = nil,
        profile: String? = nil,
        startedAt: Date
    ) {
        self.launchID = launchID
        self.generationID = generationID
        self.runtimeVersion = runtimeVersion
        self.profile = profile
        self.startedAt = startedAt
    }
}

/// A normalized, redacted failure record suitable for native UI and bounded
/// persistence. `timestamp`/`lastSeenAt` and `occurrenceCount` let repeated
/// events be collapsed without losing the fact that they recurred.
public struct DshDiagnosticRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let launchID: UUID
    public let generationID: UUID?
    public let runtimeVersion: String?
    public let profile: String?
    public let timestamp: Date
    public var lastSeenAt: Date
    public let phase: DshLaunchPhase
    public let code: DshDiagnosticCode
    public let summary: String
    public let technicalDetail: String?
    public let retryability: DshDiagnosticRetryability
    public let source: DshDiagnosticSource
    public var evidence: [DshDiagnosticEvidence]
    public var occurrenceCount: Int

    public init(
        id: UUID = UUID(),
        launchID: UUID,
        generationID: UUID? = nil,
        runtimeVersion: String? = nil,
        profile: String? = nil,
        timestamp: Date,
        lastSeenAt: Date? = nil,
        phase: DshLaunchPhase,
        code: DshDiagnosticCode,
        summary: String,
        technicalDetail: String? = nil,
        retryability: DshDiagnosticRetryability,
        source: DshDiagnosticSource,
        evidence: [DshDiagnosticEvidence] = [],
        occurrenceCount: Int = 1
    ) {
        self.id = id
        self.launchID = launchID
        self.generationID = generationID
        self.runtimeVersion = runtimeVersion
        self.profile = profile
        self.timestamp = timestamp
        self.lastSeenAt = lastSeenAt ?? timestamp
        self.phase = phase
        self.code = code
        self.summary = summary
        self.technicalDetail = technicalDetail
        self.retryability = retryability
        self.source = source
        self.evidence = evidence
        self.occurrenceCount = max(1, occurrenceCount)
    }
}

public struct DshDiagnosticSnapshot: Codable, Equatable, Sendable {
    public let context: DshDiagnosticLaunchContext?
    public let phase: DshLaunchPhase?
    public let records: [DshDiagnosticRecord]
    public let log: String
    public let generatedAt: Date

    public init(
        context: DshDiagnosticLaunchContext?,
        phase: DshLaunchPhase?,
        records: [DshDiagnosticRecord],
        log: String,
        generatedAt: Date
    ) {
        self.context = context
        self.phase = phase
        self.records = records
        self.log = log
        self.generatedAt = generatedAt
    }
}
