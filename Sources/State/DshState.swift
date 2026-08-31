import Foundation

public enum DshNetworkExposure: String, Codable, Sendable {
    case loopback
    case lan
}

public enum DshRuntimeUpdatePolicy: String, Codable, Sendable {
    case notify
    case automaticStable
}

public enum DshRuntimeChannel: String, Codable, Sendable {
    case latest
    case next
    case alpha

    /// Resolve the release channel represented by an installed Runtime
    /// version. This is deliberately independent from the user's pending
    /// update-channel setting: changing that setting must not rewrite the
    /// channel shown for the Runtime that is already running.
    public static func inferred(from version: String) -> DshRuntimeChannel {
        guard let prerelease = version
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst()
            .first,
            let identifier = prerelease.split(separator: ".").first else {
            return .latest
        }

        switch identifier {
        case "alpha":
            return .alpha
        case "rc":
            return .next
        default:
            return .latest
        }
    }
}

/// The DSH profile used by the desktop app. The isolated desktop profile is
/// the default so terminal `dsh web` keeps its own dependency tree.
public enum DshAppProfile: String, Codable, CaseIterable, Hashable, Sendable {
    case desktop
    case web

    public var displayName: String {
        switch self {
        case .desktop: return "desktop（推荐）"
        case .web: return "web（与终端共享）"
        }
    }

    public var terminalImpactDescription: String {
        switch self {
        case .desktop:
            return "App 使用独立的 profiles/desktop；终端 dsh web 继续使用 profiles/web，插件和依赖互不影响。"
        case .web:
            return "App 与终端 dsh web 共用 profiles/web；插件变更可能影响终端启动，切回 desktop 时会清理 App 注入的桥接依赖。"
        }
    }
}

/// A Profile switch is persisted before the target Profile is started. The
/// app may be terminated while pnpm or Node is materializing the target tree;
/// on the next launch this record tells startup which Profile was known to be
/// healthy and must be restored.
public struct DshProfileSwitchTransaction: Codable, Equatable, Sendable {
    public var from: DshAppProfile
    public var to: DshAppProfile
    public var phase: DshProfileSwitchPhase
    public var startedAt: Date

    public init(
        from: DshAppProfile,
        to: DshAppProfile,
        phase: DshProfileSwitchPhase = .switching,
        startedAt: Date = Date()
    ) {
        self.from = from
        self.to = to
        self.phase = phase
        self.startedAt = startedAt
    }
}

/// The target service is not considered committed until its startup and
/// health gate pass. The finalizing phase is used only when switching away
/// from the shared web Profile: desktop is already healthy, while web bridge
/// cleanup remains retryable.
public enum DshProfileSwitchPhase: String, Codable, Sendable {
    case switching
    case finalizing
}

public enum DshRuntimeTransactionPhase: String, Codable, Sendable {
    case idle
    case staging
    case switching
    case verifying
    case confirmed
    case rollingBack
}

public struct NpmRuntimeDescriptor: Codable, Equatable, Sendable {
    public let version: String
    public let registry: String
    public let integrity: String?
    public let installedAt: Date

    public init(version: String, registry: String, integrity: String? = nil, installedAt: Date = Date()) {
        self.version = version
        self.registry = registry
        self.integrity = integrity
        self.installedAt = installedAt
    }
}

public struct DshRuntimeState: Codable, Equatable, Sendable {
    public var active: NpmRuntimeDescriptor?
    public var previous: NpmRuntimeDescriptor?
    public var pending: NpmRuntimeDescriptor?
    /// Profile that owns an in-flight Runtime transaction. This is persisted
    /// so a failed rollback can never restore a desktop snapshot into the
    /// shared web profile after a later app-profile change.
    public var profile: DshAppProfile
    public var phase: DshRuntimeTransactionPhase
    public var updatePolicy: DshRuntimeUpdatePolicy
    public var channel: DshRuntimeChannel
    public var dismissedVersion: String?
    public var dismissedAppVersion: String?
    public var webProfileSnapshotID: String?
    public var healthyStartCount: Int
    public var lastDiagnostic: String?

    public init(
        active: NpmRuntimeDescriptor? = nil,
        previous: NpmRuntimeDescriptor? = nil,
        pending: NpmRuntimeDescriptor? = nil,
        profile: DshAppProfile = .desktop,
        phase: DshRuntimeTransactionPhase = .idle,
        updatePolicy: DshRuntimeUpdatePolicy = .notify,
        channel: DshRuntimeChannel = .latest,
        dismissedVersion: String? = nil,
        dismissedAppVersion: String? = nil,
        webProfileSnapshotID: String? = nil,
        healthyStartCount: Int = 0,
        lastDiagnostic: String? = nil
    ) {
        self.active = active
        self.previous = previous
        self.pending = pending
        self.profile = profile
        self.phase = phase
        self.updatePolicy = channel == .latest ? updatePolicy : .notify
        self.channel = channel
        self.dismissedVersion = dismissedVersion
        self.dismissedAppVersion = dismissedAppVersion
        self.webProfileSnapshotID = webProfileSnapshotID
        self.healthyStartCount = healthyStartCount
        self.lastDiagnostic = lastDiagnostic
    }

    private enum CodingKeys: String, CodingKey {
        case active
        case previous
        case pending
        case profile
        case phase
        case updatePolicy
        case channel
        case dismissedVersion
        case dismissedAppVersion
        case webProfileSnapshotID
        case healthyStartCount
        case lastDiagnostic
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.active = try container.decodeIfPresent(NpmRuntimeDescriptor.self, forKey: .active)
        self.previous = try container.decodeIfPresent(NpmRuntimeDescriptor.self, forKey: .previous)
        self.pending = try container.decodeIfPresent(NpmRuntimeDescriptor.self, forKey: .pending)
        // Runtime updates have always been restricted to desktop. Missing
        // metadata therefore safely migrates legacy transactions to desktop.
        self.profile = try container.decodeIfPresent(DshAppProfile.self, forKey: .profile) ?? .desktop
        self.phase = try container.decodeIfPresent(DshRuntimeTransactionPhase.self, forKey: .phase) ?? .idle
        self.updatePolicy = try container.decodeIfPresent(DshRuntimeUpdatePolicy.self, forKey: .updatePolicy) ?? .notify
        self.channel = try container.decodeIfPresent(DshRuntimeChannel.self, forKey: .channel) ?? .latest
        if self.channel != .latest {
            self.updatePolicy = .notify
        }
        self.dismissedVersion = try container.decodeIfPresent(String.self, forKey: .dismissedVersion)
        self.dismissedAppVersion = try container.decodeIfPresent(String.self, forKey: .dismissedAppVersion)
        self.webProfileSnapshotID = try container.decodeIfPresent(String.self, forKey: .webProfileSnapshotID)
        self.healthyStartCount = try container.decodeIfPresent(Int.self, forKey: .healthyStartCount) ?? 0
        self.lastDiagnostic = try container.decodeIfPresent(String.self, forKey: .lastDiagnostic)
    }

    public static let `default` = DshRuntimeState()
}

public enum DshRuntimeRecoveryAction: Equatable, Sendable {
    case finalizeConfirmed(active: NpmRuntimeDescriptor)
    case rollback(active: NpmRuntimeDescriptor, candidate: NpmRuntimeDescriptor)
    case reset(candidate: NpmRuntimeDescriptor)
}

/// Pure recovery decision logic shared by startup and integration tests.
/// Filesystem deletion and service restart stay outside this planner.
public enum DshRuntimeRecoveryPlanner {
    public static func plan(
        state: DshStateConfig,
        installedVersions: Set<String>
    ) -> DshRuntimeRecoveryAction? {
        guard let pending = state.runtimeState.pending else { return nil }

        if state.runtimeState.phase == .confirmed,
           state.selectedVersion == pending.version,
           installedVersions.contains(pending.version) {
            return .finalizeConfirmed(active: pending)
        }

        if let previous = state.runtimeState.previous,
           installedVersions.contains(previous.version) {
            return .rollback(active: previous, candidate: pending)
        }

        return .reset(candidate: pending)
    }
}

/// Pure transaction transitions. Side effects such as npm installation,
/// service restart and filesystem cleanup remain in their callers, while the
/// persisted state shape is exercised by executable integration tests.
public enum DshRuntimeTransaction {
    public static func begin(
        active: NpmRuntimeDescriptor,
        candidate: NpmRuntimeDescriptor,
        updatePolicy: DshRuntimeUpdatePolicy,
        channel: DshRuntimeChannel,
        profile: DshAppProfile = .desktop
    ) -> DshRuntimeState {
        DshRuntimeState(
            active: active,
            previous: active,
            pending: candidate,
            profile: profile,
            phase: .staging,
            updatePolicy: updatePolicy,
            channel: channel,
            healthyStartCount: 0,
            lastDiagnostic: nil
        )
    }

    public static func attachWebProfileSnapshot(
        _ state: DshRuntimeState,
        id: String,
        profile: DshAppProfile? = nil
    ) -> DshRuntimeState {
        var next = state
        next.webProfileSnapshotID = id
        if let profile {
            next.profile = profile
        }
        return next
    }

    public static func activateCandidate(_ state: DshRuntimeState) -> DshRuntimeState {
        guard let candidate = state.pending else { return state }
        var next = state
        next.active = candidate
        next.phase = .switching
        return next
    }

    public static func beginVerification(_ state: DshRuntimeState) -> DshRuntimeState {
        var next = state
        next.phase = .verifying
        return next
    }

    public static func confirm(_ state: DshRuntimeState) -> DshRuntimeState {
        var next = state
        next.pending = nil
        next.phase = .confirmed
        next.dismissedVersion = nil
        next.dismissedAppVersion = nil
        next.healthyStartCount = 1
        next.lastDiagnostic = nil
        return next
    }

    public static func beginRollback(_ state: DshRuntimeState) -> DshRuntimeState {
        var next = state
        next.phase = .rollingBack
        return next
    }

    public static func recordRollbackFailure(
        _ state: DshRuntimeState,
        diagnostic: String
    ) -> DshRuntimeState {
        var next = state
        next.phase = .rollingBack
        next.lastDiagnostic = diagnostic
        return next
    }

    public static func finishRollback(
        _ state: DshRuntimeState,
        active: NpmRuntimeDescriptor,
        retainedWebProfileSnapshotID: String? = nil
    ) -> DshRuntimeState {
        var next = state
        next.active = active
        next.previous = nil
        next.pending = nil
        next.phase = .idle
        next.webProfileSnapshotID = retainedWebProfileSnapshotID
        next.healthyStartCount = 0
        return next
    }
}

/// Persistent configuration and state model for DSH Desktop.
public struct DshStateConfig: Codable, Equatable {
    public var selectedVersion: String?
    public var appProfile: DshAppProfile
    /// Non-nil while a Profile switch has not yet completed its startup and
    /// cleanup gates. This is intentionally separate from Runtime update
    /// state: switching to the shared web Profile must be recoverable without
    /// taking or restoring a Runtime snapshot.
    public var pendingProfileSwitch: DshProfileSwitchTransaction?
    public var dismissedLatest: String?
    public var autoFollowLatest: Bool
    public var npmRegistry: String?
    public var runtimeState: DshRuntimeState
    public var dshPort: Int?
    public var browserAccessEnabled: Bool
    public var networkExposure: DshNetworkExposure
    public var uiTheme: String
    public var translateCommands: Bool
    public var cachedUserPath: String?

    public init(
        selectedVersion: String? = nil,
        appProfile: DshAppProfile = .desktop,
        pendingProfileSwitch: DshProfileSwitchTransaction? = nil,
        dismissedLatest: String? = nil,
        autoFollowLatest: Bool = false,
        npmRegistry: String? = nil,
        runtimeState: DshRuntimeState = .default,
        dshPort: Int? = 3080,
        browserAccessEnabled: Bool = false,
        networkExposure: DshNetworkExposure = .loopback,
        uiTheme: String = "default",
        translateCommands: Bool = true,
        cachedUserPath: String? = nil
    ) {
        self.selectedVersion = selectedVersion
        self.appProfile = appProfile
        self.pendingProfileSwitch = pendingProfileSwitch
        self.dismissedLatest = dismissedLatest
        self.autoFollowLatest = autoFollowLatest
        self.npmRegistry = npmRegistry
        self.runtimeState = runtimeState
        self.dshPort = dshPort ?? 3080
        self.browserAccessEnabled = browserAccessEnabled
        self.networkExposure = browserAccessEnabled ? networkExposure : .loopback
        self.uiTheme = uiTheme
        self.translateCommands = translateCommands
        self.cachedUserPath = cachedUserPath
    }

    private enum CodingKeys: String, CodingKey {
        case selectedVersion
        case appProfile
        case pendingProfileSwitch
        case dismissedLatest
        case autoFollowLatest
        case npmRegistry
        case runtimeState
        case dshPort
        case browserAccessEnabled
        case networkExposure
        case uiTheme
        case translateCommands
        case cachedUserPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedVersion = try container.decodeIfPresent(String.self, forKey: .selectedVersion)
        // Legacy state files used the shared web profile. New app launches
        // intentionally migrate to an isolated desktop profile; the old web
        // directory is left untouched for terminal DSH usage.
        self.appProfile = try container.decodeIfPresent(DshAppProfile.self, forKey: .appProfile) ?? .desktop
        self.pendingProfileSwitch = try container.decodeIfPresent(DshProfileSwitchTransaction.self, forKey: .pendingProfileSwitch)
        self.dismissedLatest = try container.decodeIfPresent(String.self, forKey: .dismissedLatest)
        // New profiles default to notification-only updates. If an older
        // profile explicitly persisted autoFollowLatest, preserve that user
        // choice during migration.
        self.autoFollowLatest = try container.decodeIfPresent(Bool.self, forKey: .autoFollowLatest) ?? false
        self.npmRegistry = try container.decodeIfPresent(String.self, forKey: .npmRegistry)
        if let runtimeState = try container.decodeIfPresent(DshRuntimeState.self, forKey: .runtimeState) {
            self.runtimeState = runtimeState
            // Keep the legacy field coherent for older app builds that may
            // still decode the same state file.
            self.autoFollowLatest = runtimeState.updatePolicy == .automaticStable
        } else {
            self.runtimeState = DshRuntimeState(
                updatePolicy: self.autoFollowLatest ? .automaticStable : .notify,
                dismissedVersion: self.dismissedLatest
            )
        }
        self.dshPort = try container.decodeIfPresent(Int.self, forKey: .dshPort) ?? 3080
        // Missing in pre-2A state files means browser access remains closed.
        self.browserAccessEnabled = try container.decodeIfPresent(Bool.self, forKey: .browserAccessEnabled) ?? false
        let decodedExposure = try container.decodeIfPresent(DshNetworkExposure.self, forKey: .networkExposure) ?? .loopback
        self.networkExposure = self.browserAccessEnabled ? decodedExposure : .loopback
        self.uiTheme = try container.decodeIfPresent(String.self, forKey: .uiTheme) ?? "default"
        self.translateCommands = try container.decodeIfPresent(Bool.self, forKey: .translateCommands) ?? true
        self.cachedUserPath = try container.decodeIfPresent(String.self, forKey: .cachedUserPath)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(selectedVersion, forKey: .selectedVersion)
        try container.encode(appProfile, forKey: .appProfile)
        try container.encodeIfPresent(pendingProfileSwitch, forKey: .pendingProfileSwitch)
        try container.encodeIfPresent(dismissedLatest, forKey: .dismissedLatest)
        try container.encode(autoFollowLatest, forKey: .autoFollowLatest)
        try container.encodeIfPresent(npmRegistry, forKey: .npmRegistry)
        try container.encode(runtimeState, forKey: .runtimeState)
        try container.encode(dshPort, forKey: .dshPort)
        try container.encode(browserAccessEnabled, forKey: .browserAccessEnabled)
        try container.encode(networkExposure, forKey: .networkExposure)
        try container.encode(uiTheme, forKey: .uiTheme)
        try container.encode(translateCommands, forKey: .translateCommands)
        try container.encodeIfPresent(cachedUserPath, forKey: .cachedUserPath)
    }

    public static let `default` = DshStateConfig()
}

public final class DshStateManager {
    public static let shared = DshStateManager()

    private let lock = NSLock()
    private var config: DshStateConfig
    private let fileURL: URL

    public static var appSupportDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dshDir = appSupport.appendingPathComponent("DSH", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dshDir.path) {
            try? FileManager.default.createDirectory(at: dshDir, withIntermediateDirectories: true)
        }
        return dshDir
    }

    public static var versionsDirectory: URL {
        let dir = appSupportDirectory.appendingPathComponent("dsh-versions", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private init() {
        self.fileURL = Self.appSupportDirectory.appendingPathComponent("dsh-state.json")
        self.config = Self.load(from: fileURL)
    }

    private static func load(from url: URL) -> DshStateConfig {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(DshStateConfig.self, from: data) else {
            return .default
        }
        return decoded
    }

    public var current: DshStateConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    public func update(_ mutate: (inout DshStateConfig) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        mutate(&config)
        save()
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[DshStateManager] Failed to save state:", error)
        }
    }
}
