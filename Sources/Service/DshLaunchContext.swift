import Foundation

/// Why a DSH process is being started. The purpose is part of the launch
/// contract: a process that was started to recover a transaction must never
/// be mistaken for the normal process that can commit that transaction.
public enum DshLaunchPurpose: String, Codable, Sendable, Equatable {
    case normal
    case runtimeVerification
    case runtimeRollback
    case profileSwitch
    /// Validate the original user Profile after an interrupted Profile switch.
    /// This is a normal user Profile path, not the isolated recovery workspace.
    case profileRollback
    case recovery
}

/// The access policy captured for one launch. A policy override (for example,
/// recovery's loopback-only policy) lives here instead of being read again
/// from mutable settings while the child process is starting.
public struct DshEffectiveAccessPolicy: Codable, Sendable, Equatable {
    public let browserAccessEnabled: Bool
    public let networkExposure: DshNetworkExposure

    public init(
        browserAccessEnabled: Bool,
        networkExposure: DshNetworkExposure = .loopback
    ) {
        self.browserAccessEnabled = browserAccessEnabled
        self.networkExposure = browserAccessEnabled ? networkExposure : .loopback
    }

    public static let loopbackOnly = DshEffectiveAccessPolicy(
        browserAccessEnabled: false,
        networkExposure: .loopback
    )
}

public enum DshLaunchContextError: Error, LocalizedError, Sendable {
    case invalidProfileName
    case profileDirectoryMismatch
    case invalidPort
    case staleContext
    case invalidRecoveryContext

    public var errorDescription: String? {
        switch self {
        case .invalidProfileName:
            return "DSH 启动 Profile 名称无效。"
        case .profileDirectoryMismatch:
            return "DSH 启动 Profile 路径与名称不一致。"
        case .invalidPort:
            return "DSH 启动端口无效。"
        case .staleContext:
            return "DSH 启动上下文已过期，目标事务发生了变化。"
        case .invalidRecoveryContext:
            return "DSH 安全恢复上下文必须使用隔离 Profile 和 loopback 访问策略。"
        }
    }
}

/// The immutable inputs for one DSH launch. Callers create this value once at
/// the operation boundary and pass it through all asynchronous work. In
/// particular, no method using this value should consult the current selected
/// Profile or Runtime to replace one of its fields.
public struct DshLaunchContext: Codable, Sendable, Equatable {
    public let launchID: UUID
    public let purpose: DshLaunchPurpose
    public let runtimeDescriptor: NpmRuntimeDescriptor
    /// The logical Profile that owns this launch. `profileDirectory` is the
    /// authoritative path and may point to an app-owned temporary recovery
    /// Profile whose name is not one of the two user-selectable Profiles.
    public let profile: DshAppProfile
    public let profileName: String
    /// DSH_HOME used by the child process. Recovery supplies an app-owned
    /// isolated home so the Runtime cannot re-open the user's home profiles.
    public let effectiveDshHome: URL
    public let profileDirectory: URL
    public let originalProfile: DshAppProfile
    public let effectiveAccessPolicy: DshEffectiveAccessPolicy
    public let port: Int
    /// The persisted transaction identity associated with this launch. A
    /// normal launch without an active transaction has no transaction ID.
    public let transactionID: String?

    public init(
        launchID: UUID = UUID(),
        purpose: DshLaunchPurpose = .normal,
        runtimeDescriptor: NpmRuntimeDescriptor,
        profile: DshAppProfile,
        profileName: String? = nil,
        profileDirectory: URL? = nil,
        effectiveDshHome: URL? = nil,
        originalProfile: DshAppProfile? = nil,
        effectiveAccessPolicy: DshEffectiveAccessPolicy,
        port: Int = 3080,
        transactionID: String? = nil
    ) {
        let resolvedHome = (effectiveDshHome ?? Self.defaultDshHome).standardizedFileURL
        let resolvedName = profileName ?? profileDirectory?.lastPathComponent ?? profile.rawValue
        let resolvedDirectory = profileDirectory
            ?? Self.profileDirectory(forName: resolvedName, dshHome: resolvedHome)
        self.launchID = launchID
        self.purpose = purpose
        self.runtimeDescriptor = runtimeDescriptor
        self.profile = profile
        self.profileName = resolvedName
        self.effectiveDshHome = resolvedHome
        self.profileDirectory = resolvedDirectory.standardizedFileURL
        self.originalProfile = originalProfile ?? profile
        self.effectiveAccessPolicy = effectiveAccessPolicy
        self.port = port
        self.transactionID = transactionID
    }

    /// Compatibility alias for callers that refer to the Runtime target as
    /// `runtime` rather than `runtimeDescriptor`.
    public var runtime: NpmRuntimeDescriptor { runtimeDescriptor }

    /// Compatibility alias used by access and health code.
    public var accessPolicy: DshEffectiveAccessPolicy { effectiveAccessPolicy }

    public var isRecoveryLaunch: Bool { purpose == .recovery }

    /// Validate the two representations of the target before they reach
    /// Node. This catches a stale/misconstructed context that would otherwise
    /// repair one Profile directory and launch another.
    public func validate() throws {
        guard Self.isValidProfileName(profileName) else {
            throw DshLaunchContextError.invalidProfileName
        }
        if purpose == .recovery {
            let range = NSRange(profileName.startIndex..., in: profileName)
            guard Self.recoveryProfilePattern.firstMatch(in: profileName, range: range) != nil,
                  effectiveAccessPolicy == .loopbackOnly else {
                throw DshLaunchContextError.invalidRecoveryContext
            }
        }
        let expectedDirectory = Self.profileDirectory(
            forName: profileName,
            dshHome: effectiveDshHome
        ).standardizedFileURL
        guard profileDirectory.standardizedFileURL.path == expectedDirectory.path else {
            throw DshLaunchContextError.profileDirectoryMismatch
        }
        guard (1024...65535).contains(port) else {
            throw DshLaunchContextError.invalidPort
        }
    }

    /// Compare an explicitly supplied context with one fresh state snapshot.
    /// This is checked while the caller owns the Runtime/Profile operation
    /// gate, before it can stop the child or touch any Profile files.
    public func isFresh(in state: DshStateConfig) -> Bool {
        guard (state.dshPort ?? 3080) == port else { return false }

        if purpose == .recovery {
            // An isolated recovery launch is owned by a separate persisted
            // RecoveryState (wired by the recovery manager). It must not use a
            // Runtime/Profile transaction ID as a surrogate owner, because an
            // ordinary startup failure may have no such transaction at all.
            return (try? validate()) != nil
        }

        guard let expected = Self.makeStartup(from: state, launchID: launchID) else {
            return false
        }
        return self == expected
    }

    /// Resolve a DSH profile without consulting application state. This is
    /// also the single path utility used by the plugin manager.
    public static func profileDirectory(for profile: DshAppProfile) -> URL {
        profileDirectory(forName: profile.rawValue)
    }

    public static var defaultDshHome: URL {
        let raw = ProcessInfo.processInfo.environment["DSH_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (raw?.isEmpty == false) ? raw! :
            (NSHomeDirectory() as NSString).appendingPathComponent(".dsh")
        let expanded: String
        if value == "~" {
            expanded = NSHomeDirectory()
        } else if value.hasPrefix("~/") {
            expanded = (NSHomeDirectory() as NSString).appendingPathComponent(
                String(value.dropFirst(2))
            )
        } else {
            expanded = value
        }
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
        if url.path.hasPrefix("/") {
            return url.standardizedFileURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(expanded, isDirectory: true)
            .standardizedFileURL
    }

    public static func profileDirectory(forName name: String, dshHome: URL? = nil) -> URL {
        let dshHome = (dshHome ?? defaultDshHome).standardizedFileURL
        return dshHome
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Construct the launch used by the normal app entry point from one
    /// state snapshot. Runtime/Profile transactions take precedence over the
    /// mutable user selection so their target is deterministic.
    public static func makeStartup(
        from state: DshStateConfig,
        launchID: UUID = UUID()
    ) -> DshLaunchContext? {
        let runtimeState = state.runtimeState

        let purpose: DshLaunchPurpose
        if let profileTransaction = state.pendingProfileSwitch {
            // A failed switch restores the old logical Profile while retaining
            // the transaction marker. That next start is recovery, rather than
            // another attempt to mutate the target Profile.
            purpose = state.appProfile == profileTransaction.to ? .profileSwitch : .profileRollback
        } else {
            switch runtimeState.phase {
            case .rollingBack:
                purpose = .runtimeRollback
            case .staging, .switching, .verifying:
                purpose = runtimeState.pending == nil ? .normal : .runtimeVerification
            case .confirmed, .idle:
                purpose = .normal
            }
        }

        let runtime: NpmRuntimeDescriptor?
        switch purpose {
        case .runtimeRollback:
            runtime = runtimeState.previous ?? runtimeState.active ?? runtimeState.pending
        case .runtimeVerification:
            runtime = runtimeState.pending ?? runtimeState.active ?? runtimeState.previous
        case .profileSwitch:
            runtime = runtimeState.active ?? runtimeState.pending ?? runtimeState.previous
        case .normal, .profileRollback, .recovery:
            runtime = runtimeState.active ?? runtimeState.pending ?? runtimeState.previous
        }

        let resolvedRuntime = runtime ?? state.selectedVersion.map {
            NpmRuntimeDescriptor(
                version: $0,
                registry: DshVersionManager.normalizedRegistry(state.npmRegistry)
            )
        }
        guard let resolvedRuntime else { return nil }

        let targetProfile: DshAppProfile
        let originalProfile: DshAppProfile
        let transactionID: String?
        switch purpose {
        case .profileSwitch:
            guard let transaction = state.pendingProfileSwitch else { return nil }
            targetProfile = state.appProfile
            originalProfile = transaction.from
            transactionID = transaction.transactionID
        case .runtimeRollback, .runtimeVerification:
            targetProfile = runtimeState.profile
            originalProfile = runtimeState.profile
            transactionID = runtimeState.transactionID
        case .profileRollback:
            guard let transaction = state.pendingProfileSwitch else { return nil }
            targetProfile = state.appProfile
            originalProfile = transaction.from
            transactionID = transaction.transactionID
        case .recovery:
            targetProfile = state.appProfile
            originalProfile = state.appProfile
            transactionID = nil
        case .normal:
            targetProfile = state.appProfile
            originalProfile = state.appProfile
            transactionID = runtimeState.phase == .confirmed
                ? runtimeState.transactionID
                : nil
        }

        return DshLaunchContext(
            launchID: launchID,
            purpose: purpose,
            runtimeDescriptor: resolvedRuntime,
            profile: targetProfile,
            profileDirectory: profileDirectory(for: targetProfile),
            effectiveDshHome: defaultDshHome,
            originalProfile: originalProfile,
            effectiveAccessPolicy: DshEffectiveAccessPolicy(
                browserAccessEnabled: state.browserAccessEnabled,
                networkExposure: state.networkExposure
            ),
            port: state.dshPort ?? 3080,
            transactionID: transactionID
        )
    }

    /// Construct a recovery launch with an explicit app-owned directory and
    /// loopback-only policy. It carries transaction identity for diagnostics
    /// and access checks, but its purpose can never authorize a transaction
    /// commit.
    public static func makeRecovery(
        launchID: UUID = UUID(),
        runtimeDescriptor: NpmRuntimeDescriptor,
        profile: DshAppProfile,
        profileDirectory: URL,
        originalProfile: DshAppProfile,
        transactionID: String?,
        port: Int = 3080
    ) -> DshLaunchContext {
        makeRecovery(
            launchID: launchID,
            runtimeDescriptor: runtimeDescriptor,
            profile: profile,
            profileName: profileDirectory.lastPathComponent,
            profileDirectory: profileDirectory,
            originalProfile: originalProfile,
            transactionID: transactionID,
            port: port
        )
    }

    /// Recovery variant for an app-owned temporary Profile. The logical owner
    /// remains one of the two app Profiles, while the control protocol receives
    /// the independently validated recovery label.
    public static func makeRecovery(
        launchID: UUID = UUID(),
        runtimeDescriptor: NpmRuntimeDescriptor,
        profile: DshAppProfile,
        profileName: String,
        profileDirectory: URL,
        effectiveDshHome: URL? = nil,
        originalProfile: DshAppProfile,
        transactionID: String?,
        port: Int = 3080
    ) -> DshLaunchContext {
        DshLaunchContext(
            launchID: launchID,
            purpose: .recovery,
            runtimeDescriptor: runtimeDescriptor,
            profile: profile,
            profileName: profileName,
            profileDirectory: profileDirectory,
            effectiveDshHome: effectiveDshHome
                ?? profileDirectory.deletingLastPathComponent().deletingLastPathComponent(),
            originalProfile: originalProfile,
            effectiveAccessPolicy: .loopbackOnly,
            port: port,
            transactionID: transactionID
        )
    }
}

public extension DshLaunchContext {
    /// Shared validation for the profile name sent over the control pipe.
    /// Names are labels under DSH_HOME/profiles, never paths supplied by the
    /// web page or a user command.
    static func isValidProfileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64,
              name != ".", name != "..",
              name.first != ".",
              name.first != "-",
              name.unicodeScalars.allSatisfy({ scalar in
            scalar.isASCII && (scalar == "-" || scalar == "_" || scalar == "."
                || (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122))
              }) else { return false }

        if DshAppProfile(rawValue: name) != nil { return true }
        let range = NSRange(name.startIndex..., in: name)
        return recoveryProfilePattern.firstMatch(in: name, range: range) != nil
    }

    private static let recoveryProfilePattern = try! NSRegularExpression(
        pattern: #"^dsh-recovery-[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
        options: .caseInsensitive
    )
}
