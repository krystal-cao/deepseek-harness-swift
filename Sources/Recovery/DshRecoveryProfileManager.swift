import CryptoKit
import Foundation

/// Filesystem operations are injected so recovery behavior can be exercised
/// entirely inside temporary directories and cleanup failures can be made
/// deterministic without touching a user's DSH_HOME.
public protocol DshRecoveryFileSystem: AnyObject {
    func fileExists(_ url: URL) -> Bool
    func isDirectory(_ url: URL) -> Bool
    func isSymbolicLink(_ url: URL) -> Bool
    func createDirectory(_ url: URL) throws
    func write(_ data: Data, to url: URL) throws
    func read(_ url: URL, maximumBytes: Int) throws -> Data
    func remove(_ url: URL) throws
    func list(_ url: URL) throws -> [URL]
}

public final class DshLocalRecoveryFileSystem: DshRecoveryFileSystem {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func fileExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    public func isDirectory(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }

    public func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    public func createDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    public func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > maximumBytes {
            throw DshRecoveryFilesystemError.readLimitExceeded
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumBytes else {
            throw DshRecoveryFilesystemError.readLimitExceeded
        }
        return data
    }

    public func remove(_ url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    public func list(_ url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            // A pnpm tree contains hidden directories (for example `.pnpm`).
            // Cleanup must inspect those entries too. A symlink is handled as
            // a leaf below, so enumerating it never follows its destination.
            options: []
        )
    }
}

private enum DshRecoveryFilesystemError: Error {
    case readLimitExceeded
}

/// Only vetted, app-owned seed bytes may be supplied to a recovery Profile.
/// These bytes represent the official Runtime base/web seed and this
/// project's bridge metadata; they are not copied from a user Profile or
/// treated as proof that Runtime packages have been materialized. The manager
/// never reads or copies the selected normal Profile. File paths are relative
/// names under the new Profile and cannot request node_modules or a patch
/// file.
public struct DshRecoveryProfileTemplate: Equatable, Sendable {
    public let officialBaseWebAppFiles: [String: Data]
    public let bridgeConfigurationFiles: [String: Data]

    public init(
        officialBaseWebAppFiles: [String: Data],
        bridgeConfigurationFiles: [String: Data]
    ) {
        self.officialBaseWebAppFiles = officialBaseWebAppFiles
        self.bridgeConfigurationFiles = bridgeConfigurationFiles
    }
}

public struct DshRecoveryLaunch: Equatable, Sendable {
    public let state: DshRecoveryState
    public let context: DshLaunchContext
    /// The runtime must receive this as its explicit DSH_HOME. It is separate
    /// from the normal user's DSH_HOME because upstream boot reads its patch
    /// file unconditionally.
    public let recoveryHomeDirectory: URL
    /// `requiresPreparation` is returned until the launch coordinator has
    /// materialized the Runtime-provided official bundles and this project's
    /// bridge in the seed Profile.
    public let preparation: DshRecoveryPreparation
    /// The only currently supported data bridge is an explicit session root
    /// verified against the selected Runtime contract. Settings and
    /// credentials deliberately remain unavailable.
    public let sessionReuseCapability: DshRecoverySessionReuseCapability

    public var launchEnvironment: [String: String] {
        ["DSH_HOME": recoveryHomeDirectory.path]
    }
}

/// Session reuse is deliberately unavailable until a Runtime-specific,
/// explicit root data interface has been verified. In particular, recovery
/// never discovers or copies a user's home, sessions, patch, or module tree.
public enum DshRecoverySessionReuseCapability: Equatable, Sendable {
    case unavailable(reason: String)
    case explicitRoot(URL)

    public var isAvailable: Bool {
        if case .explicitRoot = self { return true }
        return false
    }

    public var explicitRoot: URL? {
        guard case .explicitRoot(let root) = self else { return nil }
        return root
    }

    public var reason: String? {
        guard case .unavailable(let value) = self else { return nil }
        return value
    }
}

public enum DshRecoveryError: Error, LocalizedError, Equatable, Sendable {
    case invalidPort
    case invalidRecoveryID
    case invalidTemplatePath(String)
    case duplicateTemplatePath(String)
    case recoveryDirectoryExists
    case recoveryHomePatchExists
    case recoveryRecordExists
    case recoveryRecordMissing
    case recoveryRecordCorrupted(String)
    case unsupportedSchema(Int)
    case stateIdentityMismatch
    case invalidStatePhase
    case unsafePath
    case symbolicLinkDetected
    case recoveryDirectoryMissing
    case activeReference
    case preparationRequired
    case preparationProofRequired
    case preparationProofInvalid(String)
    case recoveryHomePatchOwnershipMismatch
    case cleanupFailed(String)
    case filesystem(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "恢复服务端口无效。"
        case .invalidRecoveryID:
            return "恢复目录标识无效。"
        case .invalidTemplatePath(let path):
            return "恢复模板路径不安全：\(path)"
        case .duplicateTemplatePath(let path):
            return "恢复模板包含重复路径：\(path)"
        case .recoveryDirectoryExists:
            return "恢复目录已存在，未覆盖现有内容。"
        case .recoveryHomePatchExists:
            return "恢复 DSH_HOME 已存在 patch 文件，未覆盖调用者内容。"
        case .recoveryRecordExists:
            return "已有恢复记录，未创建第二个恢复会话。"
        case .recoveryRecordMissing:
            return "恢复记录不存在。"
        case .recoveryRecordCorrupted(let detail):
            return "恢复记录损坏：\(detail)"
        case .unsupportedSchema(let version):
            return "不支持的恢复记录版本：\(version)"
        case .stateIdentityMismatch:
            return "恢复记录身份与请求不一致。"
        case .invalidStatePhase:
            return "恢复记录当前阶段不能执行此操作。"
        case .unsafePath:
            return "恢复路径与应用拥有的目录不一致。"
        case .symbolicLinkDetected:
            return "恢复路径包含符号链接，已停止操作。"
        case .recoveryDirectoryMissing:
            return "恢复目录不存在。"
        case .activeReference:
            return "恢复目录仍被活动会话引用。"
        case .preparationRequired:
            return "恢复 Profile 尚未完成 Runtime 依赖准备。"
        case .preparationProofRequired:
            return "恢复 Profile 缺少协调者提交的准备证明。"
        case .preparationProofInvalid(let detail):
            return "恢复 Profile 准备证明无效：\(detail)"
        case .recoveryHomePatchOwnershipMismatch:
            return "恢复 DSH_HOME 的 patch 文件不属于当前恢复记录，未删除。"
        case .cleanupFailed(let detail):
            return "恢复目录清理失败：\(detail)"
        case .filesystem(let detail):
            return "恢复文件操作失败：\(detail)"
        }
    }
}

/// Creates and tracks an isolated, app-owned recovery DSH_HOME. It has no
/// authority over selectedProfile, pending transactions, or healthy-start
/// counters, and it never downloads or installs a Runtime.
public final class DshRecoveryProfileManager {
    public static let stateReadMaximumBytes = 64 * 1024
    public static let appOwnedRecoveryDirectoryName = "dsh-recovery-home"
    public static let homePatchMaximumBytes = 16 * 1024
    /// These Runtime packages are owned by the managed install under
    /// `Application Support/DSH/dsh-versions/<runtime>/node_modules`; they
    /// must never be copied into the recovery Profile.
    public static let managedRuntimePreparationPackageNames: Set<String> = [
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app"
    ]
    /// These bridge packages are materialized into the app-owned recovery
    /// Profile by the launch coordinator.
    public static let recoveryProfilePreparationPackageNames: Set<String> = [
        "dsh-desktop-host",
        "@deepseek-ai/dsh-host-webserver"
    ]
    /// All package identities required by the recovery launch.
    public static let requiredPreparationPackageNames: Set<String> =
        managedRuntimePreparationPackageNames.union(recoveryProfilePreparationPackageNames)

    public let recoveryHomeDirectory: URL
    public let profilesDirectory: URL
    public let stateFileURL: URL

    private let fileSystem: DshRecoveryFileSystem
    private let hasActiveReference: (URL) -> Bool
    /// Injected in tests so proof validation never consults a user's real
    /// Runtime tree. Production callers pass the app-owned Application Support
    /// root and therefore resolve this to its `dsh-versions` child.
    private let managedVersionsDirectory: URL?

    /// The capability gate stays closed until the selected Runtime exposes a
    /// verified explicit-root data API. This is intentionally a value rather
    /// than a path inferred from `originalDshHome`.
    public private(set) var sessionReuseCapability: DshRecoverySessionReuseCapability =
        .unavailable(reason: "所选 Runtime 的显式会话根接口尚未验证。")

    /// Return the app-owned recovery DSH_HOME location. The caller supplies
    /// the app's Application Support directory; this path is never derived
    /// from the user's DSH_HOME.
    public static func appOwnedRecoveryHome(in applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory.standardizedFileURL
            .appendingPathComponent(Self.appOwnedRecoveryDirectoryName, isDirectory: true)
            .standardizedFileURL
    }

    public init(
        recoveryHomeDirectory: URL,
        fileSystem: DshRecoveryFileSystem = DshLocalRecoveryFileSystem(),
        managedVersionsDirectory: URL? = nil,
        hasActiveReference: @escaping (URL) -> Bool = { _ in false }
    ) {
        self.recoveryHomeDirectory = recoveryHomeDirectory.standardizedFileURL
        self.profilesDirectory = recoveryHomeDirectory
            .appendingPathComponent("profiles", isDirectory: true)
            .standardizedFileURL
        self.stateFileURL = recoveryHomeDirectory
            .appendingPathComponent("dsh-recovery-state.json")
            .standardizedFileURL
        self.fileSystem = fileSystem
        self.managedVersionsDirectory = managedVersionsDirectory?.standardizedFileURL
        self.hasActiveReference = hasActiveReference
    }

    public convenience init(
        applicationSupportDirectory: URL,
        fileSystem: DshRecoveryFileSystem = DshLocalRecoveryFileSystem(),
        hasActiveReference: @escaping (URL) -> Bool = { _ in false }
    ) {
        self.init(
            recoveryHomeDirectory: Self.appOwnedRecoveryHome(in: applicationSupportDirectory),
            fileSystem: fileSystem,
            managedVersionsDirectory: applicationSupportDirectory.standardizedFileURL
                .appendingPathComponent("dsh-versions", isDirectory: true),
            hasActiveReference: hasActiveReference
        )
    }

    /// Create one isolated Profile from explicit app-owned template bytes.
    /// `originalProfile` is recorded for later recovery decisions only; no
    /// file is read from that normal Profile.
    public func enterRecovery(
        originalProfile: DshAppProfile,
        originalDshHome: URL?,
        runtimeDescriptor: NpmRuntimeDescriptor,
        transactionID: String?,
        port: Int,
        template: DshRecoveryProfileTemplate,
        launchID: UUID = UUID(),
        recoveryID: UUID = UUID()
    ) throws -> DshRecoveryLaunch {
        guard (1024...65535).contains(port) else {
            throw DshRecoveryError.invalidPort
        }
        let profileName = try recoveryProfileName(for: recoveryID)
        // Validate every existing ancestor before creating anything. This
        // prevents a symlink in an Application Support path from redirecting
        // `createDirectory` outside the app-owned tree.
        try validatePathAncestors(of: recoveryHomeDirectory)
        try ensureDirectory(recoveryHomeDirectory)
        try ensureDirectory(profilesDirectory)

        if pathExists(stateFileURL) {
            throw fileSystem.isSymbolicLink(stateFileURL)
                ? DshRecoveryError.symbolicLinkDetected
                : DshRecoveryError.recoveryRecordExists
        }

        let profileDirectory = profilesDirectory
            .appendingPathComponent(profileName, isDirectory: true)
            .standardizedFileURL
        if pathExists(profileDirectory) {
            throw fileSystem.isSymbolicLink(profileDirectory)
                ? DshRecoveryError.symbolicLinkDetected
                : DshRecoveryError.recoveryDirectoryExists
        }

        let homePatchURL = recoveryHomeDirectory
            .appendingPathComponent("cordis.patch.yml", isDirectory: false)
        if pathExists(homePatchURL) {
            // A pre-existing home patch could belong to an older recovery or
            // to a caller. Refuse the operation rather than overwrite it.
            throw fileSystem.isSymbolicLink(homePatchURL)
                ? DshRecoveryError.symbolicLinkDetected
                : DshRecoveryError.recoveryHomePatchExists
        }

        let fileEntries = try validatedTemplateEntries(template)
        let sessionReuseCapability = makeSessionReuseCapability(
            runtimeDescriptor: runtimeDescriptor,
            originalDshHome: originalDshHome
        )
        self.sessionReuseCapability = sessionReuseCapability
        let homePatchMarker = sessionReuseCapability.explicitRoot.map { _ in
            homePatchOwnershipMarker(for: recoveryID)
        }
        let homePatch = sessionReuseCapability.explicitRoot.flatMap { root in
            homePatchMarker.map { fixedSessionRootPatch(root: root, marker: $0) }
        }
        // Persist ownership before creating the Profile or writing any
        // template file. A process interruption during materialization must
        // leave a readable entry point rather than an untracked directory.
        let state = DshRecoveryState(
            recoveryID: recoveryID,
            recoveryProfileName: profileName,
            originalProfile: originalProfile,
            originalDshHome: originalDshHome?.standardizedFileURL,
            runtimeDescriptor: runtimeDescriptor,
            transactionID: transactionID,
            port: port,
            homePatchOwnershipMarker: homePatchMarker,
            preparation: .requiresPreparation,
            phase: .entered
        )
        try writeState(state)

        do {
            try fileSystem.createDirectory(profileDirectory)
            try writeTemplate(fileEntries, to: profileDirectory)
            if let homePatch {
                try writeHomePatch(homePatch, to: recoveryHomeDirectory)
            }

            let context = DshLaunchContext.makeRecovery(
                launchID: launchID,
                runtimeDescriptor: runtimeDescriptor,
                profile: originalProfile,
                profileDirectory: profileDirectory,
                originalProfile: originalProfile,
                transactionID: transactionID,
                port: port
            )
            return DshRecoveryLaunch(
                state: state,
                context: context,
                recoveryHomeDirectory: recoveryHomeDirectory,
                preparation: state.preparation,
                sessionReuseCapability: sessionReuseCapability
            )
        } catch let error as DshRecoveryError {
            try? removeOwnedRecoveryDirectory(profileDirectory)
            throw error
        } catch {
            try? removeOwnedRecoveryDirectory(profileDirectory)
            throw DshRecoveryError.filesystem(safeErrorText(error))
        }
    }

    /// Read the persisted entry point without treating corruption as absence.
    public func readState() -> DshRecoveryStateReadResult {
        do {
            try validatePathAncestors(of: stateFileURL)
        } catch let error as DshRecoveryError {
            return .corrupted(error.localizedDescription)
        } catch {
            return .corrupted(Self.truncated(safeErrorText(error), maxCharacters: 512))
        }
        guard pathExists(stateFileURL) else { return .absent }
        if fileSystem.isSymbolicLink(stateFileURL) {
            return .corrupted("恢复记录文件是符号链接")
        }
        do {
            let data = try fileSystem.read(stateFileURL, maximumBytes: Self.stateReadMaximumBytes)
            let state = try JSONDecoder().decode(DshRecoveryState.self, from: data)
            try validateState(state)
            return .loaded(state)
        } catch let error as DshRecoveryError {
            return .corrupted(error.localizedDescription)
        } catch {
            return .corrupted(Self.truncated(safeErrorText(error), maxCharacters: 512))
        }
    }

    /// Authorize the one write window used to materialize a fresh recovery
    /// Profile. This is deliberately stricter than the normal F03 gate: the
    /// durable record, recovery context, app-owned directory, and seed bytes
    /// must all agree before the coordinator may install Runtime packages.
    /// Once `.prepared` is persisted, callers must use the ordinary strict
    /// inspection path again.
    public func validateRecoveryPreparationTarget(
        state: DshRecoveryState,
        context: DshLaunchContext,
        expectedTemplate: DshRecoveryProfileTemplate
    ) throws {
        let persisted = try requireCurrentState(state.recoveryID)
        guard persisted == state,
              state.phase == .entered,
              state.preparation == .requiresPreparation,
              state.preparationProof == nil else {
            throw DshRecoveryError.preparationProofInvalid("恢复记录不允许进行首次准备")
        }
        guard context.purpose == .recovery,
              context.profile == state.originalProfile,
              context.originalProfile == state.originalProfile,
              context.runtimeDescriptor == state.runtimeDescriptor,
              context.transactionID == state.transactionID else {
            throw DshRecoveryError.stateIdentityMismatch
        }
        let profileDirectory = try ownedProfileDirectory(for: state)
        guard context.profileDirectory.standardizedFileURL.path == profileDirectory.path,
              context.effectiveDshHome.standardizedFileURL.path == recoveryHomeDirectory.path,
              recoveryHomeDirectory.lastPathComponent == Self.appOwnedRecoveryDirectoryName else {
            throw DshRecoveryError.unsafePath
        }
        try context.validate()
        try proveOwnedTree(profileDirectory)
        try validateExpectedTemplate(expectedTemplate, profileDirectory: profileDirectory)
    }

    /// Validate the persisted home overlay immediately before a resumed
    /// recovery process is launched. A capability is returned only when the
    /// current record, its exact generated patch bytes, its ownership marker,
    /// and its single explicit sessions root all agree. Every failure is
    /// represented as `.unavailable` so callers can fail closed without
    /// accidentally treating a stale or tampered patch as a usable bridge.
    @discardableResult
    public func validatePersistedSessionReuseCapability(
        for state: DshRecoveryState
    ) -> DshRecoverySessionReuseCapability {
        func unavailable(_ reason: String) -> DshRecoverySessionReuseCapability {
            let result = DshRecoverySessionReuseCapability.unavailable(reason: reason)
            self.sessionReuseCapability = result
            return result
        }

        do {
            let persisted = try requireCurrentState(state.recoveryID)
            guard persisted == state else {
                return unavailable(DshRecoveryError.stateIdentityMismatch.localizedDescription)
            }
            guard state.phase != .cleaned, state.phase != .cleanupPending else {
                return unavailable("恢复记录当前阶段不能复用会话。")
            }
            guard let originalDshHome = state.originalDshHome else {
                return unavailable("未提供原始 DSH_HOME，无法安全复用会话。")
            }
            let baseCapability = makeSessionReuseCapability(
                runtimeDescriptor: state.runtimeDescriptor,
                originalDshHome: originalDshHome
            )
            guard let sessionsRoot = baseCapability.explicitRoot else {
                return unavailable(baseCapability.reason ?? "显式会话根接口不可用。")
            }
            guard let marker = state.homePatchOwnershipMarker else {
                return unavailable("恢复记录没有 home patch 所有权标识。")
            }
            try validateGeneratedHomePatch(
                state: state,
                sessionsRoot: sessionsRoot,
                marker: marker
            )
            let result = DshRecoverySessionReuseCapability.explicitRoot(sessionsRoot)
            self.sessionReuseCapability = result
            return result
        } catch let error as DshRecoveryError {
            return unavailable(error.localizedDescription)
        } catch {
            return unavailable(safeErrorText(error))
        }
    }

    /// Reconstruct a launch after interruption. The port remains an explicit
    /// caller input, while DSH_HOME is returned on the launch object so the
    /// coordinator can pass it to the child process.
    public func makeRecoveryContext(
        from state: DshRecoveryState,
        launchID: UUID = UUID(),
        port: Int? = nil
    ) throws -> DshLaunchContext {
        let resolvedPort = port ?? state.port
        guard (1024...65535).contains(resolvedPort) else {
            throw DshRecoveryError.invalidPort
        }
        let persisted = try requireCurrentState(state.recoveryID)
        guard persisted == state else { throw DshRecoveryError.stateIdentityMismatch }
        guard state.phase != .cleaned, state.phase != .cleanupPending else {
            throw DshRecoveryError.invalidStatePhase
        }
        let profileDirectory = try ownedProfileDirectory(for: state)
        guard fileSystem.fileExists(profileDirectory) else {
            throw DshRecoveryError.recoveryDirectoryMissing
        }
        try proveOwnedTree(profileDirectory)
        if state.preparation == .prepared {
            guard let proof = state.preparationProof else {
                throw DshRecoveryError.preparationProofRequired
            }
            try validatePreparationProof(proof, state: state, profileDirectory: profileDirectory)
        }
        return DshLaunchContext.makeRecovery(
            launchID: launchID,
            runtimeDescriptor: state.runtimeDescriptor,
            profile: state.originalProfile,
            profileDirectory: profileDirectory,
            originalProfile: state.originalProfile,
            transactionID: state.transactionID,
            port: resolvedPort
        )
    }

    @discardableResult
    public func markLaunched(recoveryID: UUID) throws -> DshRecoveryState {
        let current = try requireCurrentState(recoveryID)
        guard current.phase == .entered else { throw DshRecoveryError.invalidStatePhase }
        guard current.preparation == .prepared else {
            throw DshRecoveryError.preparationRequired
        }
        guard let proof = current.preparationProof else {
            throw DshRecoveryError.preparationProofRequired
        }
        let profileDirectory = try ownedProfileDirectory(for: current)
        guard pathExists(profileDirectory) else {
            throw DshRecoveryError.recoveryDirectoryMissing
        }
        try proveOwnedTree(profileDirectory)
        try validatePreparationProof(proof, state: current, profileDirectory: profileDirectory)
        var state = current
        state.phase = .launched
        try writeState(state)
        return state
    }

    /// Confirm that the outer launch coordinator has materialized the
    /// Runtime-provided package tree and app bridge. This manager itself never
    /// installs a Runtime or runs pnpm; it only re-checks the owned tree before
    /// persisting the readiness bit.
    @discardableResult
    public func markPrepared(
        recoveryID: UUID,
        proof: DshRecoveryPreparationProof
    ) throws -> DshRecoveryState {
        var state = try requireCurrentState(recoveryID)
        guard state.phase == .entered,
              state.preparation == .requiresPreparation else {
            throw DshRecoveryError.invalidStatePhase
        }
        let profileDirectory = try ownedProfileDirectory(for: state)
        guard pathExists(profileDirectory) else {
            throw DshRecoveryError.recoveryDirectoryMissing
        }
        try proveOwnedTree(profileDirectory)
        try validatePreparationProof(proof, state: state, profileDirectory: profileDirectory)
        state.preparation = .prepared
        state.preparationProof = proof
        try writeState(state)
        return state
    }

    /// Compatibility entry point for callers that have not yet been updated
    /// to submit coordinator evidence. It deliberately fails closed instead
    /// of retaining the old directory-shape-only behavior.
    @available(*, deprecated, message: "submit DshRecoveryPreparationProof")
    public func markPrepared(recoveryID: UUID) throws -> DshRecoveryState {
        throw DshRecoveryError.preparationProofRequired
    }

    @discardableResult
    public func markReturned(recoveryID: UUID) throws -> DshRecoveryState {
        try transition(recoveryID: recoveryID, to: .returned, allowed: [.entered, .launched])
    }

    @discardableResult
    public func markCleanupPending(recoveryID: UUID) throws -> DshRecoveryState {
        try transition(
            recoveryID: recoveryID,
            to: .cleanupPending,
            allowed: [.entered, .launched, .returned, .cleanupPending]
        )
    }

    /// Delete only the exact recovery directory whose identity is proven by
    /// the record, whose path is under the recovery home, whose tree has no
    /// symlink, and which the injected coordinator says has no active user.
    @discardableResult
    public func cleanup(recoveryID: UUID) throws -> DshRecoveryState {
        let current = try requireCurrentState(recoveryID)
        let profileDirectory = try ownedProfileDirectory(for: current)
        guard !hasActiveReference(profileDirectory) else {
            throw DshRecoveryError.activeReference
        }

        // A crash after persisting `.cleaned` but before deleting the record
        // is a normal recoverable interruption. Finish the two idempotent
        // housekeeping steps instead of treating the marker as a bad phase.
        if current.phase == .cleaned {
            return try finishCleaned(current, profileDirectory: profileDirectory)
        }

        var pending = current
        pending.phase = .cleanupPending
        do {
            try writeState(pending)
            if pathExists(profileDirectory) {
                try proveOwnedTree(profileDirectory)
                try removeOwnedTree(profileDirectory)
                guard !pathExists(profileDirectory) else {
                    throw DshRecoveryError.cleanupFailed("恢复目录删除后仍存在")
                }
            }

            var cleaned = pending
            cleaned.phase = .cleaned
            try writeState(cleaned)
            return try finishCleaned(cleaned, profileDirectory: profileDirectory)
        } catch let error as DshRecoveryError {
            throw error
        } catch {
            throw DshRecoveryError.cleanupFailed(safeErrorText(error))
        }
    }

    private func transition(
        recoveryID: UUID,
        to phase: DshRecoveryPhase,
        allowed: Set<DshRecoveryPhase>
    ) throws -> DshRecoveryState {
        var state = try requireCurrentState(recoveryID)
        guard allowed.contains(state.phase) else { throw DshRecoveryError.invalidStatePhase }
        state.phase = phase
        try writeState(state)
        return state
    }

    private func requireCurrentState(_ recoveryID: UUID) throws -> DshRecoveryState {
        switch readState() {
        case .absent:
            throw DshRecoveryError.recoveryRecordMissing
        case .corrupted(let detail):
            throw DshRecoveryError.recoveryRecordCorrupted(detail)
        case .loaded(let state):
            guard state.recoveryID == recoveryID else {
                throw DshRecoveryError.stateIdentityMismatch
            }
            return state
        }
    }

    private func writeState(_ state: DshRecoveryState) throws {
        try validateState(state)
        try validatePathAncestors(of: stateFileURL)
        if pathExists(stateFileURL) && fileSystem.isSymbolicLink(stateFileURL) {
            throw DshRecoveryError.symbolicLinkDetected
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try fileSystem.write(encoder.encode(state), to: stateFileURL)
        } catch let error as DshRecoveryError {
            throw error
        } catch {
            throw DshRecoveryError.filesystem(safeErrorText(error))
        }
    }

    private func validateState(_ state: DshRecoveryState) throws {
        guard state.schemaVersion == DshRecoveryState.currentSchemaVersion else {
            throw DshRecoveryError.unsupportedSchema(state.schemaVersion)
        }
        let expectedName = "dsh-recovery-" + state.recoveryID.uuidString.lowercased()
        guard state.recoveryProfileName == expectedName,
              DshLaunchContext.isValidProfileName(state.recoveryProfileName) else {
            throw DshRecoveryError.invalidRecoveryID
        }
        guard !state.runtimeDescriptor.version.isEmpty else {
            throw DshRecoveryError.recoveryRecordCorrupted("Runtime 版本为空")
        }
        guard (1024...65535).contains(state.port) else {
            throw DshRecoveryError.recoveryRecordCorrupted("恢复端口无效")
        }
        if let originalDshHome = state.originalDshHome,
           !originalDshHome.path.hasPrefix("/") {
            throw DshRecoveryError.recoveryRecordCorrupted("原始 DSH_HOME 路径不是绝对路径")
        }
        if let transactionID = state.transactionID,
           transactionID.isEmpty || transactionID.utf8.count > 512 {
            throw DshRecoveryError.recoveryRecordCorrupted("关联事务标识无效")
        }
        if let marker = state.homePatchOwnershipMarker,
           marker != homePatchOwnershipMarker(for: state.recoveryID) {
            throw DshRecoveryError.recoveryRecordCorrupted("恢复 home patch 所有权标识无效")
        }
        if state.preparation == .prepared, state.preparationProof == nil {
            throw DshRecoveryError.recoveryRecordCorrupted("准备完成但缺少协调者证明")
        }
        if state.preparation == .requiresPreparation, state.preparationProof != nil {
            throw DshRecoveryError.recoveryRecordCorrupted("准备未完成却包含准备证明")
        }
        if state.phase == .launched || state.phase == .returned,
           state.preparation != .prepared {
            throw DshRecoveryError.recoveryRecordCorrupted("恢复记录在准备完成前标记为已启动")
        }
    }

    private func recoveryProfileName(for recoveryID: UUID) throws -> String {
        let name = "dsh-recovery-" + recoveryID.uuidString.lowercased()
        guard DshLaunchContext.isValidProfileName(name) else {
            throw DshRecoveryError.invalidRecoveryID
        }
        return name
    }

    private func ownedProfileDirectory(for state: DshRecoveryState) throws -> URL {
        let expectedName = try recoveryProfileName(for: state.recoveryID)
        guard state.recoveryProfileName == expectedName else {
            throw DshRecoveryError.invalidRecoveryID
        }
        let directory = profilesDirectory
            .appendingPathComponent(expectedName, isDirectory: true)
            .standardizedFileURL
        guard directory.deletingLastPathComponent().standardizedFileURL.path
                == profilesDirectory.standardizedFileURL.path else {
            throw DshRecoveryError.unsafePath
        }
        try validatePathAncestors(of: directory)
        return directory
    }

    private func ensureDirectory(_ directory: URL, confinedTo root: URL? = nil) throws {
        let directory = directory.standardizedFileURL
        guard directory.path.hasPrefix("/") else { throw DshRecoveryError.unsafePath }
        if let root {
            let root = root.standardizedFileURL
            guard directory.path == root.path || directory.path.hasPrefix(root.path + "/") else {
                throw DshRecoveryError.unsafePath
            }
        }

        // Create one path component at a time. FileManager's
        // `withIntermediateDirectories` otherwise follows an existing
        // symlink in an ancestor before this manager can inspect it.
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in directory.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            if fileSystem.isSymbolicLink(current) {
                guard Self.isAllowedSystemAlias(current) else {
                    throw DshRecoveryError.symbolicLinkDetected
                }
            }
            if pathExists(current) {
                guard fileSystem.isDirectory(current) else {
                    throw DshRecoveryError.filesystem("恢复路径中的既有项不是目录")
                }
                continue
            }
            do {
                try fileSystem.createDirectory(current)
            } catch {
                throw DshRecoveryError.filesystem(safeErrorText(error))
            }
        }
    }

    private func validatedTemplateEntries(
        _ template: DshRecoveryProfileTemplate
    ) throws -> [(String, Data)] {
        var entries: [(String, Data)] = []
        var paths = Set<String>()
        for (path, data) in template.officialBaseWebAppFiles.sorted(by: { $0.key < $1.key }) {
            try addTemplateEntry(path, data: data, to: &entries, paths: &paths)
        }
        for (path, data) in template.bridgeConfigurationFiles.sorted(by: { $0.key < $1.key }) {
            try addTemplateEntry(path, data: data, to: &entries, paths: &paths)
        }
        return entries
    }

    private func addTemplateEntry(
        _ path: String,
        data: Data,
        to entries: inout [(String, Data)],
        paths: inout Set<String>
    ) throws {
        guard Self.isSafeTemplatePath(path) else {
            throw DshRecoveryError.invalidTemplatePath(path)
        }
        guard paths.insert(path).inserted else {
            throw DshRecoveryError.duplicateTemplatePath(path)
        }
        entries.append((path, data))
    }

    private func writeTemplate(_ entries: [(String, Data)], to directory: URL) throws {
        for (path, data) in entries {
            let target = directory.appendingPathComponent(path).standardizedFileURL
            guard target.path.hasPrefix(directory.path + "/") else {
                throw DshRecoveryError.unsafePath
            }
            let parent = target.deletingLastPathComponent()
            do {
                try ensureDirectory(parent, confinedTo: directory)
                if pathExists(target), fileSystem.isSymbolicLink(target) {
                    throw DshRecoveryError.symbolicLinkDetected
                }
                try fileSystem.write(data, to: target)
            } catch let error as DshRecoveryError {
                throw error
            } catch {
                throw DshRecoveryError.filesystem(safeErrorText(error))
            }
        }
    }

    private func proveOwnedTree(_ directory: URL) throws {
        guard !fileSystem.isSymbolicLink(directory), fileSystem.isDirectory(directory) else {
            if fileSystem.isSymbolicLink(directory) { throw DshRecoveryError.symbolicLinkDetected }
            throw DshRecoveryError.recoveryDirectoryMissing
        }
        do {
            for child in try fileSystem.list(directory) {
                let child = child.standardizedFileURL
                guard child.deletingLastPathComponent().path == directory.standardizedFileURL.path else {
                    throw DshRecoveryError.unsafePath
                }
                // Symlinks inside an owned tree are leaves. Cleanup removes
                // the link itself and never asks isDirectory/list on it, so a
                // pnpm link to an external store cannot escape or block retry.
                if fileSystem.isSymbolicLink(child) {
                    continue
                }
                if fileSystem.isDirectory(child) {
                    try proveOwnedTree(child)
                }
            }
        } catch let error as DshRecoveryError {
            throw error
        } catch {
            throw DshRecoveryError.filesystem(safeErrorText(error))
        }
    }

    private func removeOwnedRecoveryDirectory(_ directory: URL) throws {
        guard pathExists(directory) else { return }
        guard !fileSystem.isSymbolicLink(directory), fileSystem.isDirectory(directory) else { return }
        try proveOwnedTree(directory)
        try removeOwnedTree(directory)
    }

    /// Remove an already-proven tree without following any symlink. The
    /// explicit walk also makes the safety contract independent of whether a
    /// filesystem adapter implements recursive removal through the platform.
    private func removeOwnedTree(_ directory: URL) throws {
        guard !fileSystem.isSymbolicLink(directory), fileSystem.isDirectory(directory) else {
            throw DshRecoveryError.symbolicLinkDetected
        }
        for child in try fileSystem.list(directory) {
            let child = child.standardizedFileURL
            guard child.deletingLastPathComponent().path == directory.standardizedFileURL.path else {
                throw DshRecoveryError.unsafePath
            }
            if fileSystem.isSymbolicLink(child) {
                try fileSystem.remove(child)
                guard !pathExists(child) else {
                    throw DshRecoveryError.cleanupFailed("恢复符号链接删除后仍存在")
                }
            } else if fileSystem.isDirectory(child) {
                try removeOwnedTree(child)
                guard !pathExists(child) else {
                    throw DshRecoveryError.cleanupFailed("恢复子目录删除后仍存在")
                }
            } else if pathExists(child) {
                try fileSystem.remove(child)
                guard !pathExists(child) else {
                    throw DshRecoveryError.cleanupFailed("恢复文件删除后仍存在")
                }
            }
        }
        try fileSystem.remove(directory)
    }

    private func finishCleaned(
        _ state: DshRecoveryState,
        profileDirectory: URL
    ) throws -> DshRecoveryState {
        guard state.phase == .cleaned else { throw DshRecoveryError.invalidStatePhase }
        if pathExists(profileDirectory) {
            try proveOwnedTree(profileDirectory)
            try removeOwnedTree(profileDirectory)
            guard !pathExists(profileDirectory) else {
                throw DshRecoveryError.cleanupFailed("恢复目录删除后仍存在")
            }
        }
        try removeOwnedHomePatch(for: state)
        if pathExists(stateFileURL) {
            guard !fileSystem.isSymbolicLink(stateFileURL) else {
                throw DshRecoveryError.symbolicLinkDetected
            }
            try fileSystem.remove(stateFileURL)
            guard !pathExists(stateFileURL) else {
                throw DshRecoveryError.cleanupFailed("恢复记录删除后仍存在")
            }
        }
        return state
    }

    /// The alpha.5 contract is the only one verified by the local contract
    /// review. The manager emits one fixed home-level overlay for that
    /// contract; callers cannot provide arbitrary patch YAML or a path to
    /// settings/credentials. Other Runtime versions keep the recovery
    /// session bridge visibly unavailable.
    private func makeSessionReuseCapability(
        runtimeDescriptor: NpmRuntimeDescriptor,
        originalDshHome: URL?
    ) -> DshRecoverySessionReuseCapability {
        guard runtimeDescriptor.version == "0.1.2-alpha.5" else {
            return .unavailable(reason: "Runtime \(runtimeDescriptor.version) 的显式会话根接口未验证。")
        }
        guard let originalDshHome else {
            return .unavailable(reason: "未提供原始 DSH_HOME，无法安全复用会话。")
        }

        let sessionsRoot = originalDshHome
            .standardizedFileURL
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
        do {
            try validateExplicitDataRoot(sessionsRoot)
            return .explicitRoot(sessionsRoot)
        } catch let error as DshRecoveryError {
            return .unavailable(reason: error.localizedDescription)
        } catch {
            return .unavailable(reason: safeErrorText(error))
        }
    }

    /// Validate an explicit data root without creating it or reading its
    /// contents. A missing sessions directory is valid because the upstream
    /// persistence provider materializes it lazily; an existing symlink is
    /// never accepted as a data root.
    private func validateExplicitDataRoot(_ root: URL) throws {
        try validatePathAncestors(of: root)
        if pathExists(root) {
            guard !fileSystem.isSymbolicLink(root), fileSystem.isDirectory(root) else {
                throw DshRecoveryError.symbolicLinkDetected
            }
        }
    }

    private func validatePreparationProof(
        _ proof: DshRecoveryPreparationProof,
        state: DshRecoveryState,
        profileDirectory: URL
    ) throws {
        guard proof.runtimeVersion == state.runtimeDescriptor.version,
              !proof.runtimeVersion.isEmpty else {
            throw DshRecoveryError.preparationProofInvalid("证明中的 Runtime 版本与恢复记录不一致")
        }

        var seenNames = Set<String>()
        var seenPaths = Set<String>()
        for package in proof.packageManifests {
            guard Self.requiredPreparationPackageNames.contains(package.name) else {
                throw DshRecoveryError.preparationProofInvalid("包含未授权的包 \(package.name)")
            }
            guard !package.version.isEmpty else {
                throw DshRecoveryError.preparationProofInvalid("包 \(package.name) 的版本为空")
            }
            guard seenNames.insert(package.name).inserted else {
                throw DshRecoveryError.preparationProofInvalid("包 \(package.name) 重复")
            }
            guard seenPaths.insert(package.manifestRelativePath).inserted else {
                throw DshRecoveryError.preparationProofInvalid("包 manifest 路径重复")
            }

            let expectedSource: DshRecoveryPackageProofSource =
                Self.managedRuntimePreparationPackageNames.contains(package.name)
                    ? .managedRuntime
                    : .recoveryProfile
            guard package.source == expectedSource else {
                throw DshRecoveryError.preparationProofInvalid(
                    "包 \(package.name) 的证明来源不符合恢复安装边界"
                )
            }
            let expectedPath = Self.canonicalPackageManifestPath(for: package.name)
            guard package.manifestRelativePath == expectedPath else {
                throw DshRecoveryError.preparationProofInvalid(
                    "包 \(package.name) 的 manifest 路径不是 \(expectedPath)"
                )
            }
            let root: URL
            switch package.source {
            case .recoveryProfile:
                root = profileDirectory
            case .managedRuntime:
                root = try managedRuntimeRoot(for: state)
            }
            let manifestURL = try proofFileURL(package.manifestRelativePath, root: root)
            guard pathExists(manifestURL),
                  !fileSystem.isSymbolicLink(manifestURL),
                  !fileSystem.isDirectory(manifestURL) else {
                throw DshRecoveryError.preparationProofInvalid(
                    "包 \(package.name) 的 manifest 不存在或不是普通文件"
                )
            }
            let data: Data
            do {
                data = try fileSystem.read(manifestURL, maximumBytes: Self.stateReadMaximumBytes)
            } catch {
                throw DshRecoveryError.preparationProofInvalid(
                    "无法读取包 \(package.name) 的 manifest"
                )
            }
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let manifest = object as? [String: Any],
                  let actualName = manifest["name"] as? String,
                  let actualVersion = manifest["version"] as? String,
                  actualName == package.name,
                  actualVersion == package.version else {
                throw DshRecoveryError.preparationProofInvalid(
                    "包 \(package.name) 的 manifest name/version 不匹配"
                )
            }
        }

        guard seenNames == Self.requiredPreparationPackageNames else {
            let missing = Self.requiredPreparationPackageNames.subtracting(seenNames).sorted().joined(separator: ", ")
            throw DshRecoveryError.preparationProofInvalid("缺少官方包证明：\(missing)")
        }

        guard proof.bridge.manifestBytes.count <= Self.stateReadMaximumBytes,
              Self.isSHA256Fingerprint(proof.bridge.fingerprint) else {
            throw DshRecoveryError.preparationProofInvalid("bridge fingerprint 或 manifest 大小无效")
        }
        let bridgeURL = try proofFileURL(
            proof.bridge.manifestRelativePath,
            root: profileDirectory
        )
        guard pathExists(bridgeURL),
              !fileSystem.isSymbolicLink(bridgeURL),
              !fileSystem.isDirectory(bridgeURL) else {
            throw DshRecoveryError.preparationProofInvalid("bridge manifest 不存在或不是普通文件")
        }
        let bridgeData: Data
        do {
            bridgeData = try fileSystem.read(bridgeURL, maximumBytes: Self.stateReadMaximumBytes)
        } catch {
            throw DshRecoveryError.preparationProofInvalid("无法读取 bridge manifest")
        }
        guard bridgeData == proof.bridge.manifestBytes,
              Self.sha256Fingerprint(bridgeData) == proof.bridge.fingerprint,
              let bridgeObject = try? JSONSerialization.jsonObject(with: bridgeData),
              bridgeObject is [String: Any] else {
            throw DshRecoveryError.preparationProofInvalid("bridge manifest 内容或 fingerprint 不匹配")
        }
    }

    private func proofFileURL(_ relativePath: String, root: URL) throws -> URL {
        guard Self.isSafeProofPath(relativePath) else {
            throw DshRecoveryError.preparationProofInvalid("证明路径不安全")
        }
        let target = root
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        guard target.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw DshRecoveryError.preparationProofInvalid("证明路径越出允许的包根目录")
        }
        return target
    }

    private func validateExpectedTemplate(
        _ template: DshRecoveryProfileTemplate,
        profileDirectory: URL
    ) throws {
        let entries = try validatedTemplateEntries(template)
        for (relativePath, expectedData) in entries {
            let target = try proofFileURL(relativePath, root: profileDirectory)
            guard pathExists(target),
                  !fileSystem.isSymbolicLink(target),
                  !fileSystem.isDirectory(target) else {
                throw DshRecoveryError.preparationProofInvalid(
                    "恢复种子文件不存在或不是普通文件：(relativePath)"
                )
            }
            let actual: Data
            do {
                actual = try fileSystem.read(target, maximumBytes: Self.stateReadMaximumBytes)
            } catch {
                throw DshRecoveryError.preparationProofInvalid(
                    "无法读取恢复种子文件：(relativePath)"
                )
            }
            guard actual == expectedData else {
                throw DshRecoveryError.preparationProofInvalid(
                    "恢复种子文件内容不匹配：(relativePath)"
                )
            }
        }
    }

    private func managedRuntimeRoot(for state: DshRecoveryState) throws -> URL {
        guard DshVersionManager.isValidVersion(state.runtimeDescriptor.version) else {
            throw DshRecoveryError.preparationProofInvalid("Runtime 版本无效")
        }
        let versionsRoot = (managedVersionsDirectory ?? DshStateManager.versionsDirectory)
            .standardizedFileURL
        let runtimeRoot = versionsRoot
            .appendingPathComponent(state.runtimeDescriptor.version, isDirectory: true)
            .standardizedFileURL
        let nodeModules = runtimeRoot.appendingPathComponent("node_modules", isDirectory: true)
        try validatePathAncestors(of: nodeModules)
        guard pathExists(runtimeRoot), !fileSystem.isSymbolicLink(runtimeRoot),
              fileSystem.isDirectory(runtimeRoot), pathExists(nodeModules),
              !fileSystem.isSymbolicLink(nodeModules), fileSystem.isDirectory(nodeModules) else {
            throw DshRecoveryError.preparationProofInvalid(
                "受管 Runtime 的 node_modules 不存在或不是应用目录"
            )
        }
        return runtimeRoot
    }

    private func validateGeneratedHomePatch(
        state: DshRecoveryState,
        sessionsRoot: URL,
        marker: String
    ) throws {
        guard marker == homePatchOwnershipMarker(for: state.recoveryID) else {
            throw DshRecoveryError.recoveryHomePatchOwnershipMismatch
        }
        let patchURL = recoveryHomeDirectory.appendingPathComponent("cordis.patch.yml")
        guard pathExists(patchURL),
              !fileSystem.isSymbolicLink(patchURL),
              !fileSystem.isDirectory(patchURL) else {
            throw DshRecoveryError.recoveryHomePatchOwnershipMismatch
        }
        let actual: Data
        do {
            actual = try fileSystem.read(patchURL, maximumBytes: Self.homePatchMaximumBytes)
        } catch {
            throw DshRecoveryError.recoveryHomePatchOwnershipMismatch
        }
        let expected = fixedSessionRootPatch(root: sessionsRoot, marker: marker)
        guard actual == expected else {
            throw DshRecoveryError.recoveryHomePatchOwnershipMismatch
        }
        guard let text = String(data: actual, encoding: .utf8) else {
            throw DshRecoveryError.recoveryHomePatchOwnershipMismatch
        }
        let markerLine = "# \(marker)"
        guard text.split(whereSeparator: \.isNewline)
                .filter({ $0.trimmingCharacters(in: .whitespaces) == markerLine }).count == 1,
              Self.occurrenceCount(of: sessionsRoot.path, in: text) == 1,
              Self.occurrenceCount(of: "- id: session-persistence-jsonl", in: text) == 1 else {
            throw DshRecoveryError.recoveryHomePatchOwnershipMismatch
        }
    }

    private func homePatchOwnershipMarker(for recoveryID: UUID) -> String {
        "dsh-recovery-home-patch:" + recoveryID.uuidString.lowercased()
    }

    private func fixedSessionRootPatch(root: URL, marker: String) -> Data {
        // Double-quoted YAML is an ordinary scalar. Escape only the two
        // characters that can alter that scalar; backslashes are rejected by
        // the path validator on this platform but remain escaped defensively.
        let escaped = root.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let text = """
        # \(marker)
        - id: session-persistence-jsonl
          name: '@deepseek-ai/dsh-session-persistence-jsonl'
          config:
            root: "\(escaped)"
        """
        return Data(text.utf8)
    }

    private func removeOwnedHomePatch(for state: DshRecoveryState) throws {
        let patchURL = recoveryHomeDirectory.appendingPathComponent("cordis.patch.yml")
        guard pathExists(patchURL) else { return }
        guard !fileSystem.isSymbolicLink(patchURL) else {
            throw DshRecoveryError.symbolicLinkDetected
        }

        // A marker is necessary but not sufficient ownership proof. Require
        // the complete manager-generated bytes so cleanup cannot delete a
        // caller's patch merely because it copied our comment marker.
        guard let expectedMarker = state.homePatchOwnershipMarker else {
            throw DshRecoveryError.recoveryHomePatchOwnershipMismatch
        }
        do {
            guard let originalDshHome = state.originalDshHome else {
                throw DshRecoveryError.recoveryHomePatchOwnershipMismatch
            }
            let sessionsRoot = originalDshHome
                .standardizedFileURL
                .appendingPathComponent("sessions", isDirectory: true)
                .standardizedFileURL
            try validateExplicitDataRoot(sessionsRoot)
            try validateGeneratedHomePatch(
                state: state,
                sessionsRoot: sessionsRoot,
                marker: expectedMarker
            )
            try fileSystem.remove(patchURL)
            guard !pathExists(patchURL) else {
                throw DshRecoveryError.cleanupFailed("恢复 home patch 删除后仍存在")
            }
        } catch let error as DshRecoveryError {
            throw error
        } catch {
            throw DshRecoveryError.cleanupFailed(safeErrorText(error))
        }
    }

    private func writeHomePatch(_ data: Data, to home: URL) throws {
        let patchURL = home.appendingPathComponent("cordis.patch.yml", isDirectory: false)
        try ensureDirectory(home)
        if pathExists(patchURL), fileSystem.isSymbolicLink(patchURL) {
            throw DshRecoveryError.symbolicLinkDetected
        }
        do {
            try fileSystem.write(data, to: patchURL)
        } catch let error as DshRecoveryError {
            throw error
        } catch {
            throw DshRecoveryError.filesystem(safeErrorText(error))
        }
    }

    private func pathExists(_ url: URL) -> Bool {
        // FileManager.fileExists(atPath:) returns false for a broken symlink;
        // include isSymbolicLink so such an entry is never mistaken for an
        // absent, safe-to-create path.
        fileSystem.fileExists(url) || fileSystem.isSymbolicLink(url)
    }

    private func validatePathAncestors(of url: URL) throws {
        let normalized = url.standardizedFileURL
        guard normalized.path.hasPrefix("/") else { throw DshRecoveryError.unsafePath }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in normalized.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            if fileSystem.isSymbolicLink(current) {
                // macOS exposes /tmp and /var as stable aliases to their
                // private counterparts. They are system aliases, not an
                // app-controlled redirect; all other symlink ancestors are
                // rejected so an app-owned path cannot escape its root.
                // The system owns these two aliases. URL's symlink resolver
                // intentionally preserves their public spelling on some
                // macOS releases, so the component identity is the stable
                // check here; an app-created symlink at any other component
                // remains rejected.
                guard Self.isAllowedSystemAlias(current) else {
                    throw DshRecoveryError.symbolicLinkDetected
                }
            }
        }
    }

    private static func isAllowedSystemAlias(_ url: URL) -> Bool {
        url.standardizedFileURL.path == "/tmp" || url.standardizedFileURL.path == "/var"
    }

    private static func isSafeTemplatePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return false
        }
        let lower = components.map { $0.lowercased() }
        guard !lower.contains("node_modules"), !lower.contains("patch"), !lower.contains("patches") else {
            return false
        }
        guard !lower.contains(where: { $0.hasSuffix(".patch.yml") }) else { return false }
        return true
    }

    private static func isSafeProofPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return false
        }
        let lower = components.map { $0.lowercased() }
        // A proof must point at an installed artifact, never at the manager's
        // home overlay or a path whose spelling can be confused with one.
        guard !lower.contains("cordis.patch.yml"),
              !lower.contains(where: { $0.hasSuffix(".patch.yml") }) else {
            return false
        }
        return true
    }

    private static func canonicalPackageManifestPath(for name: String) -> String {
        "node_modules/" + name + "/package.json"
    }

    private static func isSHA256Fingerprint(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
            }
    }

    private static func sha256Fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func occurrenceCount(of needle: String, in value: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = value.startIndex
        while let range = value.range(of: needle, range: searchStart..<value.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    private static func truncated(_ value: String, maxCharacters: Int) -> String {
        guard value.count > maxCharacters else { return value }
        return String(value.prefix(maxCharacters))
    }

    private func safeErrorText(_ error: Error) -> String {
        Self.truncated(error.localizedDescription, maxCharacters: 512)
    }
}
