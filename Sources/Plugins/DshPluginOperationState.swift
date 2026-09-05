import Foundation

/// The operation is deliberately independent from Runtime/Profile-switch
/// transactions.  A record is written before the first package mutation and
/// is kept until the post-commit health window has been acknowledged.
public enum DshPluginOperationAction: String, Codable, Equatable, Hashable, Sendable {
    case install
    case update
    case updateAll
    case remove
}

/// Durable phases for one plugin operation.  There is intentionally no
/// implicit "failed" phase: an operation that cannot prove its rollback is in
/// `recoveryRequired`, and remains visible to the next launch.
public enum DshPluginOperationPhase: String, Codable, Equatable, Hashable, Sendable {
    case prepared
    case mutating
    case verifying
    case committed
    case restoring
    case recoveryRequired
}

/// The on-disk snapshot is owned by exactly one operation.  The path is
/// captured as an absolute string because application settings can change
/// while an asynchronous operation is running.
public struct DshPluginOperationSnapshotReference: Codable, Equatable, Sendable {
    public static let owner = "dsh-desktop-plugin-operation"

    public let snapshotID: String
    public let operationID: String
    public let profile: DshAppProfile
    public let profileDirectory: String
    public let baselineDigest: String
    public let createdAt: Date
    public let ownerID: String
    public let profileWasMissing: Bool

    public init(
        snapshotID: String,
        operationID: String,
        profile: DshAppProfile,
        profileDirectory: URL,
        baselineDigest: String,
        createdAt: Date = Date(),
        ownerID: String = DshPluginOperationSnapshotReference.owner,
        profileWasMissing: Bool = false
    ) {
        precondition(!snapshotID.isEmpty, "Plugin snapshot ID must not be empty")
        precondition(!operationID.isEmpty, "Plugin operation ID must not be empty")
        precondition(!baselineDigest.isEmpty, "Plugin snapshot digest must not be empty")
        self.snapshotID = snapshotID
        self.operationID = operationID
        self.profile = profile
        self.profileDirectory = profileDirectory.standardizedFileURL.path
        self.baselineDigest = baselineDigest
        self.createdAt = createdAt
        self.ownerID = ownerID
        self.profileWasMissing = profileWasMissing
    }

    public var url: URL {
        URL(fileURLWithPath: profileDirectory, isDirectory: true)
    }
}

/// Persisted owner record for an in-flight or just-committed plugin change.
/// `mutationDigest` is written before verification.  If the app is killed
/// while verifying, recovery can distinguish the app's last observed tree
/// from an externally changed tree without blindly restoring over it.
public struct DshPluginOperationState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let operationID: String
    public let profile: DshAppProfile
    public let targetPackage: String?
    public let targetPackages: [String]
    public let action: DshPluginOperationAction
    public let snapshot: DshPluginOperationSnapshotReference
    public let startedAt: Date
    public var phase: DshPluginOperationPhase
    public var mutationDigest: String?
    public var lastError: String?

    public init(
        schemaVersion: Int = DshPluginOperationState.currentSchemaVersion,
        operationID: String = UUID().uuidString,
        profile: DshAppProfile,
        targetPackage: String? = nil,
        targetPackages: [String] = [],
        action: DshPluginOperationAction,
        snapshot: DshPluginOperationSnapshotReference,
        startedAt: Date = Date(),
        phase: DshPluginOperationPhase = .prepared,
        mutationDigest: String? = nil,
        lastError: String? = nil
    ) {
        precondition(!operationID.isEmpty, "Plugin operation ID must not be empty")
        precondition(operationID == snapshot.operationID, "Snapshot must belong to plugin operation")
        precondition(profile == snapshot.profile, "Snapshot Profile must match plugin operation")
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.profile = profile
        self.targetPackage = targetPackage
        self.targetPackages = targetPackages
        self.action = action
        self.snapshot = snapshot
        self.startedAt = startedAt
        self.phase = phase
        self.mutationDigest = mutationDigest
        self.lastError = lastError
    }

    /// Persisted JSON is external input at startup. Do not rely on the
    /// public initializer's preconditions for decoding it: a structurally
    /// valid but forged/corrupt record must be classified as `.corrupt`, not
    /// terminate the app while the startup gate is probing the store.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let operationID = try container.decode(String.self, forKey: .operationID)
        let profile = try container.decode(DshAppProfile.self, forKey: .profile)
        let targetPackage = try container.decodeIfPresent(String.self, forKey: .targetPackage)
        let targetPackages = try container.decodeIfPresent([String].self, forKey: .targetPackages) ?? []
        let action = try container.decode(DshPluginOperationAction.self, forKey: .action)
        let snapshot = try container.decode(DshPluginOperationSnapshotReference.self, forKey: .snapshot)
        let startedAt = try container.decode(Date.self, forKey: .startedAt)
        let phase = try container.decode(DshPluginOperationPhase.self, forKey: .phase)
        let mutationDigest = try container.decodeIfPresent(String.self, forKey: .mutationDigest)
        let lastError = try container.decodeIfPresent(String.self, forKey: .lastError)

        guard schemaVersion == Self.currentSchemaVersion,
              !operationID.isEmpty,
              !snapshot.snapshotID.isEmpty,
              operationID == snapshot.operationID,
              profile == snapshot.profile,
              !snapshot.profileDirectory.isEmpty,
              snapshot.profileDirectory.hasPrefix("/"),
              !snapshot.baselineDigest.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .snapshot,
                in: container,
                debugDescription: "插件事务记录字段不一致"
            )
        }
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.profile = profile
        self.targetPackage = targetPackage
        self.targetPackages = targetPackages
        self.action = action
        self.snapshot = snapshot
        self.startedAt = startedAt
        self.phase = phase
        self.mutationDigest = mutationDigest
        self.lastError = lastError
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case operationID
        case profile
        case targetPackage
        case targetPackages
        case action
        case snapshot
        case startedAt
        case phase
        case mutationDigest
        case lastError
    }

    public func changing(
        phase: DshPluginOperationPhase,
        mutationDigest: String? = nil,
        lastError: String? = nil
    ) -> DshPluginOperationState {
        var next = self
        next.phase = phase
        if mutationDigest != nil {
            next.mutationDigest = mutationDigest
        }
        next.lastError = lastError
        return next
    }

    public var isTerminal: Bool {
        phase == .committed
    }

    public var requiresRecovery: Bool {
        phase == .recoveryRequired
    }
}

/// The durable operation owner has three meaningful read states.  Keep this
/// separate from `pendingOperation`: older callers use the optional property,
/// while launch/mutation gates must distinguish an absent record from a
/// corrupt one and fail closed for the latter.
public enum DshPluginOperationPersistedStatus: Equatable, Sendable {
    case absent
    case loaded(DshPluginOperationState)
    case corrupt(String)

    public var state: DshPluginOperationState? {
        if case .loaded(let state) = self { return state }
        return nil
    }

    public var isCorrupt: Bool {
        if case .corrupt = self { return true }
        return false
    }
}

/// Request passed to the coordinator.  It carries an immutable Profile path
/// so a settings refresh cannot redirect an operation to another Profile.
public struct DshPluginOperationRequest: Equatable, Sendable {
    public let action: DshPluginOperationAction
    public let profile: DshAppProfile
    public let profileDirectory: URL
    public let targetPackage: String?
    public let targetPackages: [String]

    public init(
        action: DshPluginOperationAction,
        profile: DshAppProfile = .desktop,
        profileDirectory: URL,
        targetPackage: String? = nil,
        targetPackages: [String] = []
    ) {
        self.action = action
        self.profile = profile
        self.profileDirectory = profileDirectory.standardizedFileURL
        self.targetPackage = targetPackage
        self.targetPackages = targetPackages
    }
}

/// Side effects are injected at the boundary.  This keeps the P01 core
/// testable without booting Node or touching a user's Profile; the eventual
/// product wiring can provide the service-stop/port check, pnpm command and
/// normal startup health gate independently.
public struct DshPluginOperationHooks: Sendable {
    public var prepareForMutation: @Sendable () async throws -> Void
    public var mutate: @Sendable (DshPluginOperationRequest) async throws -> Void
    public var verify: @Sendable (DshPluginOperationRequest) async throws -> Void
    /// Re-run the ordinary startup health gate after a rollback. This is
    /// separate from verify: verify validates the newly mutated tree, while
    /// this callback proves that the restored baseline is usable.
    public var verifyRestored: @Sendable (DshPluginOperationRequest) async throws -> Void

    public init(
        prepareForMutation: @escaping @Sendable () async throws -> Void = {},
        mutate: @escaping @Sendable (DshPluginOperationRequest) async throws -> Void,
        verify: @escaping @Sendable (DshPluginOperationRequest) async throws -> Void = { _ in },
        verifyRestored: @escaping @Sendable (DshPluginOperationRequest) async throws -> Void = { _ in }
    ) {
        self.prepareForMutation = prepareForMutation
        self.mutate = mutate
        self.verify = verify
        self.verifyRestored = verifyRestored
    }
}

public struct DshPluginOperationResult: Equatable, Sendable {
    public let operationID: String
    public let phase: DshPluginOperationPhase
    public let wasRestored: Bool

    public init(operationID: String, phase: DshPluginOperationPhase, wasRestored: Bool = false) {
        self.operationID = operationID
        self.phase = phase
        self.wasRestored = wasRestored
    }
}

public enum DshPluginOperationError: Error, LocalizedError, Equatable, Sendable {
    case desktopProfileRequired
    case unsafeProfileDirectory
    case operationAlreadyPending(String)
    case runtimeOrProfileRecoveryPending
    case staleProfileChanged
    case operationInterruptedDuringMutation
    case externalModification
    /// The snapshot copy could not prove that the destination volume has
    /// enough room.  Keep the measured values in the error so callers can
    /// render an actionable message and tests can exercise this contract
    /// without filling a real disk.
    case snapshotCapacityInsufficient(requiredBytes: Int64, availableBytes: Int64)
    case recoveryRequired(String)
    case persistenceConflict(expected: String, actual: String?)
    case invalidTransition(DshPluginOperationPhase, DshPluginOperationPhase)

    public var errorDescription: String? {
        switch self {
        case .desktopProfileRequired:
            return "插件事务目前只允许修改 desktop Profile。"
        case .unsafeProfileDirectory:
            return "插件事务目标 Profile 路径不安全，已拒绝写入。"
        case .operationAlreadyPending(let id):
            return "已有插件事务 \(id) 尚未解决，请先完成恢复。"
        case .runtimeOrProfileRecoveryPending:
            return "Runtime 或 Profile 恢复事务尚未完成，暂不能修改插件。"
        case .staleProfileChanged:
            return "快照建立后 Profile 已被其他进程修改，已暂停插件事务。"
        case .operationInterruptedDuringMutation:
            return "插件事务在包变更阶段中断，无法证明可安全回滚。"
        case .externalModification:
            return "检测到外部修改，为保护新改动未覆盖 Profile。"
        case .snapshotCapacityInsufficient(let requiredBytes, let availableBytes):
            let requiredGB = Double(max(requiredBytes, 0)) / 1_073_741_824.0
            let availableGB = Double(max(availableBytes, 0)) / 1_073_741_824.0
            return String(
                format: "快照所需磁盘空间不足，需要至少 %.2f GB，可用 %.2f GB。",
                requiredGB,
                availableGB
            )
        case .recoveryRequired(let detail):
            return "插件事务需要恢复：\(detail)"
        case .persistenceConflict(let expected, let actual):
            let observed = actual.map { "当前为 \($0)" } ?? "当前记录缺失"
            return "插件事务记录所有权校验失败：期望 \(expected)，\(observed)。已停止操作。"
        case .invalidTransition(let from, let to):
            return "插件事务阶段无效：\(from.rawValue) → \(to.rawValue)。"
        }
    }
}

public enum DshPluginOperationTransition {
    public static func canAdvance(
        from: DshPluginOperationPhase,
        to: DshPluginOperationPhase
    ) -> Bool {
        switch (from, to) {
        case (.prepared, .mutating),
             (.prepared, .recoveryRequired),
             (.mutating, .verifying),
             (.mutating, .restoring),
             (.mutating, .recoveryRequired),
             (.verifying, .committed),
             (.verifying, .restoring),
             (.verifying, .recoveryRequired),
             (.restoring, .recoveryRequired),
             (.recoveryRequired, .restoring):
            return true
        default:
            return false
        }
    }

    public static func advance(
        _ state: DshPluginOperationState,
        to phase: DshPluginOperationPhase,
        mutationDigest: String? = nil,
        lastError: String? = nil
    ) throws -> DshPluginOperationState {
        guard canAdvance(from: state.phase, to: phase) else {
            throw DshPluginOperationError.invalidTransition(state.phase, phase)
        }
        return state.changing(
            phase: phase,
            mutationDigest: mutationDigest,
            lastError: lastError
        )
    }
}
