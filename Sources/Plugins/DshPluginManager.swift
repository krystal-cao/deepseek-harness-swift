import Foundation
import CryptoKit

public struct DshPluginItem: Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let version: String?
    public let latestVersion: String?
    public let description: String?
    public let isManaged: Bool
    public let isLocal: Bool

    public var hasUpdate: Bool {
        guard let latest = latestVersion, let current = version else { return false }
        let cleanCurrent = current.replacingOccurrences(of: "^", with: "").replacingOccurrences(of: "~", with: "")
        return latest != cleanCurrent && !isLocal && !isManaged
    }

    public init(name: String, version: String? = nil, latestVersion: String? = nil, description: String? = nil, isManaged: Bool = false, isLocal: Bool = false) {
        self.name = name
        self.version = version
        self.latestVersion = latestVersion
        self.description = description
        self.isManaged = isManaged
        self.isLocal = isLocal
    }
}

public enum DshPendingPluginUpdate: Equatable, Sendable {
    case plugin(String)
    case all
}

/// Read-only classification used by launch integration before any Profile
/// bootstrap write. A missing manifest is safe to bootstrap only when the
/// selected directory is genuinely empty; an existing but incomplete tree is
/// preserved for inspection/recovery.
public enum DshProfileBootstrapReadiness: String, Sendable {
    case freshEmpty
    case initialized
    case existingUninitialized
    case invalid
}

public enum DshPluginStartupGateDecision: String, Sendable {
    case allowFreshProfileBootstrap
    case allowProfileMutation
    case blockProfileMutation
}

public enum DshPluginManagerStartupGate {
    /// The Inspector deliberately stays independent from this manager. The
    /// integration layer passes its boolean evidence here so this policy can
    /// be used without importing or executing Profile-side code.
    public static func decision(
        profileReadiness: DshProfileBootstrapReadiness,
        inspectionIsComplete: Bool,
        inspectionHasErrors: Bool,
        inspectionHasUnknowns: Bool = false
    ) -> DshPluginStartupGateDecision {
        if profileReadiness == .freshEmpty,
           !inspectionHasErrors,
           !inspectionHasUnknowns {
            return .allowFreshProfileBootstrap
        }
        guard inspectionIsComplete, !inspectionHasErrors, !inspectionHasUnknowns else {
            return .blockProfileMutation
        }
        return .allowProfileMutation
    }
}

public struct DshProfileSnapshotProgress: Sendable {
    public let phase: String
    public let fraction: Double?
    public let detail: String?

    public init(phase: String, fraction: Double? = nil, detail: String? = nil) {
        self.phase = phase
        self.fraction = fraction
        self.detail = detail
    }
}

private struct DshProcessExecutionResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

/// Drain pnpm's pipes while it is running. Waiting for the process before
/// reading its output can deadlock once pnpm fills the OS pipe buffer during
/// supply-chain verification.
private final class DshProcessOutputCollector: @unchecked Sendable {
    private let stdoutPipe: Pipe?
    private let stderrPipe: Pipe?
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()

    init(stdout: Pipe?, stderr: Pipe?) {
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
    }

    func start() {
        startReading(stdoutPipe, isStdout: true)
        startReading(stderrPipe, isStdout: false)
    }

    func wait() {
        group.wait()
    }

    func result() -> (stdout: Data, stderr: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdoutData, stderrData)
    }

    private func startReading(_ pipe: Pipe?, isStdout: Bool) {
        guard let pipe else { return }
        group.enter()
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave() }
            let data = handle.readDataToEndOfFile()
            lock.lock()
            if isStdout {
                stdoutData = data
            } else {
                stderrData = data
            }
            lock.unlock()
        }
    }
}

public final class DshPluginManager {
    public static let shared = DshPluginManager()

    public static let desktopHostPluginName = "dsh-desktop-host"
    /// Packages required by the managed desktop bridge but not user-managed
    /// plugins. They stay in the selected profile so the bridge's peer
    /// dependency and Cordis patch target remain resolvable.
    private static let internalPluginDependencyNames: Set<String> = [
        "@deepseek-ai/dsh-host-webserver",
    ]
    private static let desktopHostRequiredFiles = [
        "package.json",
        "index.js",
        "client.js",
        "webserver.js",
        "browser-url-route.js",
        "lan-url-route.js",
        "lan-http-ingress.js",
        "upstream-session-broker.js",
        "control.js",
        "access-state.js",
        "cordis.patch.yml",
    ]
    private static let standardProfileBundles = [
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app"
    ]
    private static let profileWorkspaceFileName = "pnpm-workspace.yaml"
    private static let webProfileSnapshotDirectoryName = "dsh-runtime-profile-snapshots"
    private static let missingProfileMarkerName = ".profile-was-missing"
    /// A cleanup marker is written only after the managed bridge and its
    /// internal peer have been installed and fingerprinted successfully.
    /// Package names alone are not ownership evidence: a terminal user may
    /// legitimately depend on a package with the same name.
    private static let desktopHostOwnershipMarkerName = ".dsh-desktop-host-ownership.json"

    public static func profileDirectory(for profile: DshAppProfile) -> URL {
        DshLaunchContext.profileDirectory(for: profile)
    }

    /// Kept for snapshot harnesses and migration tooling that explicitly
    /// targets the terminal-owned web profile.
    public static var webProfileDirectory: URL {
        profileDirectory(for: .web)
    }

    public static var activeProfileDirectory: URL {
        profileDirectory(for: DshStateManager.shared.current.appProfile)
    }

    private init() {}

    private static var webProfileSnapshotDirectory: URL {
        DshStateManager.appSupportDirectory
            .appendingPathComponent(Self.webProfileSnapshotDirectoryName, isDirectory: true)
    }

    private static func webProfileSnapshotURL(for id: String) throws -> URL {
        guard UUID(uuidString: id) != nil, !id.contains("/") else {
            throw NSError(
                domain: "DshPluginManager",
                code: -30,
                userInfo: [NSLocalizedDescriptionKey: "web Profile 快照标识无效"]
            )
        }
        return webProfileSnapshotDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private static let snapshotSafetyBytes: Int64 = 256 * 1024 * 1024

    private static func volumeIdentifier(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.volumeIdentifierKey]) else { return nil }
        return values.volumeIdentifier.map { String(describing: $0) }
    }

    private static func allocatedSize(of directory: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            if size > 0 {
                total += UInt64(size)
            }
        }
        return total
    }

    private static func ensureCapacity(for source: URL, at destinationParent: URL) throws {
        let required = allocatedSize(of: source)
        let availableValues = try destinationParent.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        let available: Int64
        if let important = availableValues.volumeAvailableCapacityForImportantUsage {
            available = important
        } else {
            available = Int64(availableValues.volumeAvailableCapacity ?? 0)
        }
        let requiredWithSafety = Int64(min(required, UInt64(Int64.max - snapshotSafetyBytes))) + snapshotSafetyBytes
        guard available >= requiredWithSafety else {
            let requiredGB = Double(requiredWithSafety) / 1_073_741_824.0
            let availableGB = Double(max(available, 0)) / 1_073_741_824.0
            throw NSError(
                domain: "DshPluginManager",
                code: -35,
                userInfo: [NSLocalizedDescriptionKey: String(
                    format: "web Profile 所在磁盘空间不足，需要至少 %.2f GB，可用 %.2f GB",
                    requiredGB,
                    availableGB
                )]
            )
        }
    }

    /// APFS clone is effectively metadata-only for a large Profile. If the
    /// source is on another volume, or clone is unavailable, fall back to a
    /// regular copy only after checking the destination volume capacity.
    private static func copyDirectoryPreferClone(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let destinationParent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationParent, withIntermediateDirectories: true)

        let sourceVolume = volumeIdentifier(for: source)
        let destinationVolume = volumeIdentifier(for: destinationParent)
        var attemptedClone = false
        if sourceVolume != nil,
           sourceVolume == destinationVolume {
            attemptedClone = true
            if cloneDirectoryIfPossible(from: source, to: destination) {
                return
            }
        }

        // cp -cR can leave a partial destination after an I/O or filesystem
        // error. This destination is a transaction-local UUID path, so it is
        // safe and necessary to remove it before the ordinary-copy fallback.
        if attemptedClone, fileManager.fileExists(atPath: destination.path) {
            do {
                try fileManager.removeItem(at: destination)
            } catch {
                throw NSError(
                    domain: "DshPluginManager",
                    code: -36,
                    userInfo: [NSLocalizedDescriptionKey: "APFS clone 失败且无法清理临时目标：\(error.localizedDescription)"]
                )
            }
        }

        try ensureCapacity(for: source, at: destinationParent)
        try fileManager.copyItem(at: source, to: destination)
    }

    private static func cloneDirectoryIfPossible(from source: URL, to destination: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        // `-c` asks APFS for a clone; there is no shell interpolation here.
        process.arguments = ["-cR", source.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func createWebProfileSnapshotSynchronously(
        profile: DshAppProfile,
        profileDirectory: URL? = nil,
        onProgress: @escaping @Sendable (DshProfileSnapshotProgress) -> Void
    ) throws -> String {
        let id = UUID().uuidString
        let snapshotURL = try webProfileSnapshotURL(for: id)
        let profileURL = profileDirectory ?? Self.profileDirectory(for: profile)
        let snapshotDirectory = webProfileSnapshotDirectory
        let fileManager = FileManager.default

        onProgress(DshProfileSnapshotProgress(
            phase: "正在保护 web Profile...",
            fraction: 0,
            detail: "优先使用 APFS clone；跨卷时将检查可用空间"
        ))
        try fileManager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: snapshotURL, withIntermediateDirectories: true)

        do {
            if fileManager.fileExists(atPath: profileURL.path) {
                try copyDirectoryPreferClone(
                    from: profileURL,
                    to: snapshotURL.appendingPathComponent("profile", isDirectory: true)
                )
            } else {
                let marker = snapshotURL.appendingPathComponent(missingProfileMarkerName)
                try Data().write(to: marker, options: .atomic)
            }
        } catch {
            try? fileManager.removeItem(at: snapshotURL)
            throw NSError(
                domain: "DshPluginManager",
                code: -31,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 web Profile 更新快照：\(error.localizedDescription)"]
            )
        }
        onProgress(DshProfileSnapshotProgress(
            phase: "web Profile 快照已创建",
            fraction: 1,
            detail: "快照 \(id)"
        ))
        return id
    }

    private static func restoreWebProfileSnapshotSynchronously(
        _ id: String,
        profile: DshAppProfile,
        profileDirectory: URL? = nil,
        onProgress: @escaping @Sendable (DshProfileSnapshotProgress) -> Void
    ) throws {
        let snapshotURL = try webProfileSnapshotURL(for: id)
        let profileURL = profileDirectory ?? Self.profileDirectory(for: profile)
        let savedProfileURL = snapshotURL.appendingPathComponent("profile", isDirectory: true)
        let missingMarkerURL = snapshotURL.appendingPathComponent(missingProfileMarkerName)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            throw NSError(
                domain: "DshPluginManager",
                code: -32,
                userInfo: [NSLocalizedDescriptionKey: "找不到 web Profile 更新快照 \(id)"]
            )
        }

        onProgress(DshProfileSnapshotProgress(
            phase: "正在恢复 web Profile...",
            fraction: 0,
            detail: "正在停止对旧 Profile 的写入并还原快照"
        ))

        // Keep the displaced copy beside the live Profile. This is important
        // when Application Support and DSH_HOME are on different volumes:
        // moving the current Profile must remain same-volume and atomic.
        let displacedURL = profileURL.deletingLastPathComponent()
            .appendingPathComponent(".dsh-profile-restore-\(UUID().uuidString)", isDirectory: true)
        var displacedCurrent = false

        do {
            if fileManager.fileExists(atPath: profileURL.path) {
                try fileManager.moveItem(at: profileURL, to: displacedURL)
                displacedCurrent = true
            }

            if !fileManager.fileExists(atPath: missingMarkerURL.path) {
                guard fileManager.fileExists(atPath: savedProfileURL.path) else {
                    throw NSError(
                        domain: "DshPluginManager",
                        code: -33,
                        userInfo: [NSLocalizedDescriptionKey: "web Profile 快照内容不完整"]
                    )
                }
                try fileManager.createDirectory(
                    at: profileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try copyDirectoryPreferClone(from: savedProfileURL, to: profileURL)
            }

            if displacedCurrent {
                try? fileManager.removeItem(at: displacedURL)
            }
        } catch {
            try? fileManager.removeItem(at: profileURL)
            if displacedCurrent {
                try? fileManager.moveItem(at: displacedURL, to: profileURL)
            }
            throw NSError(
                domain: "DshPluginManager",
                code: -34,
                userInfo: [NSLocalizedDescriptionKey: "无法恢复 web Profile 更新快照：\(error.localizedDescription)"]
            )
        }
        onProgress(DshProfileSnapshotProgress(
            phase: "web Profile 已恢复",
            fraction: 1,
            detail: nil
        ))
    }

    /// Take a complete copy of the shared web Profile before a Runtime
    /// transaction lets pnpm change package.json, the lockfile, or
    /// node_modules. The snapshot is referenced by persisted transaction
    /// state and is kept until the new Runtime has survived two starts.
    public func createWebProfileSnapshot(
        profile: DshAppProfile = .web,
        profileDirectory: URL? = nil,
        onProgress: @escaping @Sendable (DshProfileSnapshotProgress) -> Void = { _ in }
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            try Self.createWebProfileSnapshotSynchronously(
                profile: profile,
                profileDirectory: profileDirectory,
                onProgress: onProgress
            )
        }.value
    }

    /// Restore a previously persisted Profile snapshot. Replacement is
    /// recoverable: the current Profile is moved aside until the snapshot
    /// copy succeeds, so a failed copy does not silently destroy both states.
    public func restoreWebProfileSnapshot(
        _ id: String,
        profile: DshAppProfile = .web,
        profileDirectory: URL? = nil,
        onProgress: @escaping @Sendable (DshProfileSnapshotProgress) -> Void = { _ in }
    ) async throws {
        try await Task.detached(priority: .utility) {
            try Self.restoreWebProfileSnapshotSynchronously(
                id,
                profile: profile,
                profileDirectory: profileDirectory,
                onProgress: onProgress
            )
        }.value
    }

    /// Remove one exact, no-longer-needed Profile snapshot.
    public func deleteWebProfileSnapshot(_ id: String) async throws {
        try await Task.detached(priority: .utility) {
            let snapshotURL = try Self.webProfileSnapshotURL(for: id)
            guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return }
            try FileManager.default.removeItem(at: snapshotURL)
        }.value
    }

    /// Remove snapshots that are no longer referenced by persisted Runtime
    /// state. Snapshot directories are UUID-named, so unrelated Profile data
    /// cannot be selected by this cleanup.
    @discardableResult
    public func cleanupOrphanedWebProfileSnapshots(keeping retainedID: String?) async -> [String] {
        await Task.detached(priority: .utility) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: Self.webProfileSnapshotDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return [] }

            var removed: [String] = []
            for entry in entries {
                let id = entry.lastPathComponent
                guard UUID(uuidString: id) != nil, id != retainedID else { continue }
                do {
                    try FileManager.default.removeItem(at: entry)
                    removed.append(id)
                } catch {
                    print("[DshPluginManager] Failed to remove orphaned Profile snapshot \(id):", error)
                }
            }
            return removed
        }.value
    }

    /// List all installed plugins in the selected DSH profile.
    public func listPlugins(outdatedMap: [String: String] = [:]) -> [DshPluginItem] {
        listPlugins(at: Self.activeProfileDirectory, outdatedMap: outdatedMap)
    }

    /// List plugins from an explicitly captured Profile directory. This is
    /// the path used by launch/recovery flows; it cannot move when settings
    /// change while an asynchronous refresh is in flight.
    public func listPlugins(at profileDir: URL, outdatedMap: [String: String] = [:]) -> [DshPluginItem] {
        let pkgUrl = profileDir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: pkgUrl),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deps = json["dependencies"] as? [String: String] else {
            return []
        }

        var list: [DshPluginItem] = []
        for (name, spec) in deps {
            guard !Self.internalPluginDependencyNames.contains(name) else { continue }
            let isManaged = (name == Self.desktopHostPluginName)
            let isLocal = spec.hasPrefix("file:") || spec.hasPrefix("link:")
            let latest = outdatedMap[name]
            let description = readPluginDescription(name: name, profileDir: profileDir)
            list.append(DshPluginItem(
                name: name,
                version: spec,
                latestVersion: latest,
                description: description,
                isManaged: isManaged,
                isLocal: isLocal
            ))
        }

        // Pinned managed plugin at bottom, others alphabetical
        return list.sorted { a, b in
            if a.isManaged != b.isManaged { return !a.isManaged }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    /// Read display metadata from the installed plugin tree.
    ///
    /// Keep this aligned with Electron's `enrichPluginMetadata`: descriptions
    /// are optional metadata from the exact package currently installed in the
    /// profile, rather than data fetched from the registry. `node_modules`
    /// entries may be symlinks created by pnpm; Data(contentsOf:) follows them.
    private func readPluginDescription(name: String, profileDir: URL) -> String? {
        let manifestURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("package.json")

        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let description = manifest["description"] as? String,
              !description.isEmpty else {
            return nil
        }
        return description
    }

    /// Match Electron's external-theme detection for the native settings UI.
    ///
    /// Themes are declared either as direct profile dependencies or as profile
    /// bundles. DSH's own packages and the shell bridge are deliberately
    /// excluded because they are part of the built-in profile, not user themes.
    public func detectExternalTheme() -> String? {
        detectExternalTheme(at: Self.activeProfileDirectory)
    }

    public func detectExternalTheme(at profileDir: URL) -> String? {
        let packageURL = profileDir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var names: [String] = []
        if let dependencies = root["dependencies"] as? [String: Any] {
            names.append(contentsOf: dependencies.keys.sorted())
        }
        if let dsh = root["dsh"] as? [String: Any],
           let profile = dsh["profile"] as? [String: Any],
           let bundles = profile["bundles"] as? [String] {
            names.append(contentsOf: bundles)
        }

        var seen = Set<String>()
        for name in names where seen.insert(name).inserted {
            if name.hasPrefix("@deepseek-ai/") { continue }
            if name == Self.desktopHostPluginName || name == "dsh-desktop-claude" { continue }
            if name.range(of: "theme|skin", options: [.regularExpression, .caseInsensitive]) != nil {
                return name
            }
        }
        return nil
    }

    /// Check npm registry for outdated plugins using pnpm outdated --json.
    public func checkOutdatedPlugins() async throws -> [String: String] {
        let state = DshStateManager.shared.current
        return try await checkOutdatedPlugins(
            at: Self.profileDirectory(for: state.appProfile),
            profile: state.appProfile,
            registry: state.npmRegistry
        )
    }

    public func checkOutdatedPlugins(
        at profileDir: URL,
        profile: DshAppProfile? = nil,
        registry: String? = nil
    ) async throws -> [String: String] {
        let stateSnapshot = DshStateManager.shared.current
        let capturedRegistry = DshVersionManager.normalizedRegistry(registry ?? stateSnapshot.npmRegistry)
        guard let pnpm = NodeRuntime.shared.resolvePnpmBinary(),
              let node = NodeRuntime.shared.resolveNodeBinary() else {
            throw NSError(domain: "DshPluginManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少 Node 或 pnpm"])
        }

        guard FileManager.default.fileExists(atPath: profileDir.appendingPathComponent("package.json").path) else {
            return [:]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        // pnpm 11's `outdated` command does not accept `--registry` as a
        // command-specific option. Keep the registry in the environment,
        // and disable the default 24-hour release-age gate for this read-only
        // metadata check so a newly published plugin can be reported at once.
        proc.arguments = [
            "outdated",
            "--format", "json",
            "--config.minimum-release-age=0"
        ]

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        env["npm_config_registry"] = capturedRegistry
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        let result = try await runProcess(proc, stdout: stdout, stderr: stderr)
        let data = result.stdout
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            guard result.status == 0 else {
                let detail = processOutput(result)
                throw NSError(
                    domain: "DshPluginManager",
                    code: -9,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "检测插件更新失败（退出码 \(result.status)）\(detail)"
                    ]
                )
            }
            return [:]
        }

        // pnpm outdated exits with status 1 when it finds at least one
        // outdated dependency. A valid JSON payload is the authoritative
        // result, so accept both the clean and the "updates found" statuses.
        guard result.status == 0 || result.status == 1 else {
            let detail = processOutput(result)
            throw NSError(
                domain: "DshPluginManager",
                code: -9,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "检测插件更新失败（退出码 \(result.status)）\(detail)"
                ]
            )
        }

        var outdated: [String: String] = [:]
        for (pkgName, info) in json {
            guard !Self.internalPluginDependencyNames.contains(pkgName) else { continue }
            if let infoDict = info as? [String: Any],
               let latestVer = infoDict["latest"] as? String {
                outdated[pkgName] = latestVer
            }
        }
        return outdated
    }

    /// Add a plugin by name or npm specifier.
    public func addPlugin(
        spec: String,
        ignoringMinimumReleaseAge: Bool = false,
        profileDirectory: URL? = nil,
        profile: DshAppProfile? = nil,
        registry: String? = nil
    ) async throws {
        let stateSnapshot = DshStateManager.shared.current
        let targetProfile = profile ?? stateSnapshot.appProfile
        let profileDir = profileDirectory ?? Self.profileDirectory(for: targetProfile)
        let capturedRegistry = DshVersionManager.normalizedRegistry(registry ?? stateSnapshot.npmRegistry)
        if let packageName = packageName(from: spec),
           Self.internalPluginDependencyNames.contains(packageName) {
            throw NSError(
                domain: "DshPluginManager",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: "不能直接安装 DSH 内部依赖 \(packageName)"]
            )
        }
        try await validateRegistryPackageIfNeeded(spec: spec, registry: capturedRegistry)

        guard let pnpm = NodeRuntime.shared.resolvePnpmBinary(),
              let node = NodeRuntime.shared.resolveNodeBinary() else {
            throw NSError(domain: "DshPluginManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少 Node 或 pnpm"])
        }

        try bootstrapWebProfileManifestIfMissing(at: profileDir, profile: targetProfile)
        if let hostBundle = NodeRuntime.shared.resolveDesktopHostBundlePath() {
            _ = repairDesktopHostDependency(hostBundle, profileDirectory: profileDir)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        var arguments = ["add", spec] + registryArguments(capturedRegistry)
        if ignoringMinimumReleaseAge {
            arguments.append("--config.minimum-release-age=0")
        }
        arguments.append("--reporter=append-only")
        proc.arguments = arguments

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        let result = try await runProcess(proc, stdout: stdout, stderr: stderr)

        guard result.status == 0 else {
            let detail = processOutput(result)
            throw NSError(domain: "DshPluginManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "安装插件 \(spec) 失败（退出码 \(result.status)）\(detail)"])
        }
        if let packageName = packageName(from: spec) {
            try updateProfileBundle(packageName, removing: false, profileDir: profileDir)
        }
    }

    /// The UI uses this marker to offer a one-time opt-in retry. Keep the
    /// policy override scoped to the requested install instead of changing
    /// global pnpm configuration.
    public static func isMinimumReleaseAgeViolation(_ error: Error) -> Bool {
        let nsError = error as NSError
        let messages = [
            error.localizedDescription,
            nsError.userInfo[NSLocalizedDescriptionKey] as? String,
            nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String
        ].compactMap { $0 }
        return messages.contains { $0.contains("MINIMUM_RELEASE_AGE_VIOLATION") }
    }

    /// Update a specific plugin to its latest version.
    ///
    /// The normal path keeps pnpm's supply-chain release-age policy. The UI
    /// retries with `ignoringMinimumReleaseAge` only after the user confirms
    /// the one-time override for a newly published dependency.
    public func updatePlugin(
        name: String,
        ignoringMinimumReleaseAge: Bool = false,
        profileDirectory: URL? = nil,
        profile: DshAppProfile? = nil,
        registry: String? = nil
    ) async throws {
        let stateSnapshot = DshStateManager.shared.current
        let targetProfile = profile ?? stateSnapshot.appProfile
        let profileDir = profileDirectory ?? Self.profileDirectory(for: targetProfile)
        let capturedRegistry = DshVersionManager.normalizedRegistry(registry ?? stateSnapshot.npmRegistry)
        guard !Self.internalPluginDependencyNames.contains(name) else {
            throw NSError(
                domain: "DshPluginManager",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: "不能直接更新 DSH 内部依赖 \(name)"]
            )
        }
        guard let pnpm = NodeRuntime.shared.resolvePnpmBinary(),
              let node = NodeRuntime.shared.resolveNodeBinary() else {
            throw NSError(domain: "DshPluginManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少 Node 或 pnpm"])
        }

        // pnpm validates every direct dependency before updating one plugin.
        // Heal a stale Electron-era file: dependency first, otherwise any
        // plugin update is rejected before pnpm reaches the requested name.
        if let hostBundle = NodeRuntime.shared.resolveDesktopHostBundlePath() {
            _ = repairDesktopHostDependency(hostBundle, profileDirectory: profileDir)
        }

        try ensureManagedProfileWorkspaceConfiguration(at: profileDir, profile: targetProfile)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        var arguments = ["update", name, "--latest"]
        if ignoringMinimumReleaseAge {
            arguments.append("--config.minimum-release-age=0")
        }
        proc.arguments = arguments + registryArguments(capturedRegistry) + ["--reporter=append-only"]

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        let result = try await runProcess(proc, stdout: stdout, stderr: stderr)

        guard result.status == 0 else {
            let detail = processOutput(result)
            throw NSError(domain: "DshPluginManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "更新插件 \(name) 失败（退出码 \(result.status)）\(detail)"])
        }
    }

    /// Update all installed plugins to their latest versions.
    public func updateAllPlugins(
        ignoringMinimumReleaseAge: Bool = false,
        profileDirectory: URL? = nil,
        profile: DshAppProfile? = nil,
        registry: String? = nil
    ) async throws {
        let stateSnapshot = DshStateManager.shared.current
        let targetProfile = profile ?? stateSnapshot.appProfile
        let profileDir = profileDirectory ?? Self.profileDirectory(for: targetProfile)
        let capturedRegistry = DshVersionManager.normalizedRegistry(registry ?? stateSnapshot.npmRegistry)
        guard let pnpm = NodeRuntime.shared.resolvePnpmBinary(),
              let node = NodeRuntime.shared.resolveNodeBinary() else {
            throw NSError(domain: "DshPluginManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少 Node 或 pnpm"])
        }

        if let hostBundle = NodeRuntime.shared.resolveDesktopHostBundlePath() {
            _ = repairDesktopHostDependency(hostBundle, profileDirectory: profileDir)
        }

        let pluginNames = listPlugins(at: profileDir)
            .filter { !$0.isManaged && !$0.isLocal }
            .map(\.name)
        guard !pluginNames.isEmpty else { return }
        try ensureManagedProfileWorkspaceConfiguration(at: profileDir, profile: targetProfile)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        var arguments = ["update"] + pluginNames + ["--latest"]
        if ignoringMinimumReleaseAge {
            arguments.append("--config.minimum-release-age=0")
        }
        proc.arguments = arguments + registryArguments(capturedRegistry) + ["--reporter=append-only"]

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        let result = try await runProcess(proc, stdout: stdout, stderr: stderr)

        guard result.status == 0 else {
            let detail = processOutput(result)
            throw NSError(domain: "DshPluginManager", code: -4, userInfo: [NSLocalizedDescriptionKey: "批量更新插件失败（退出码 \(result.status)）\(detail)"])
        }
    }

    /// Remove a plugin by name.
    public func removePlugin(
        name: String,
        profileDirectory: URL? = nil,
        profile: DshAppProfile? = nil,
        registry: String? = nil
    ) async throws {
        let stateSnapshot = DshStateManager.shared.current
        let targetProfile = profile ?? stateSnapshot.appProfile
        let profileDir = profileDirectory ?? Self.profileDirectory(for: targetProfile)
        let capturedRegistry = DshVersionManager.normalizedRegistry(registry ?? stateSnapshot.npmRegistry)
        guard !Self.internalPluginDependencyNames.contains(name) else {
            throw NSError(
                domain: "DshPluginManager",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: "不能直接卸载 DSH 内部依赖 \(name)"]
            )
        }
        guard name != Self.desktopHostPluginName else {
            throw NSError(domain: "DshPluginManager", code: -5, userInfo: [NSLocalizedDescriptionKey: "不能删除系统内置桥接插件"])
        }
        guard let pnpm = NodeRuntime.shared.resolvePnpmBinary(),
              let node = NodeRuntime.shared.resolveNodeBinary() else {
            throw NSError(domain: "DshPluginManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少 Node 或 pnpm"])
        }

        try bootstrapWebProfileManifestIfMissing(at: profileDir, profile: targetProfile)
        if let hostBundle = NodeRuntime.shared.resolveDesktopHostBundlePath() {
            _ = repairDesktopHostDependency(hostBundle, profileDirectory: profileDir)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        // pnpm 11's `remove` command does not accept `--registry`. Removal
        // only operates on the existing lockfile, so keep the registry in
        // the environment for any incidental resolution instead of passing
        // it as an unsupported command-specific option.
        proc.arguments = ["remove", name, "--config.minimum-release-age=0", "--reporter=append-only"]

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        env["npm_config_registry"] = capturedRegistry
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        let result = try await runProcess(proc, stdout: stdout, stderr: stderr)

        guard result.status == 0 else {
            let detail = processOutput(result)
            throw NSError(
                domain: "DshPluginManager",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "卸载插件 \(name) 失败（退出码 \(result.status)）\(detail)"]
            )
        }
        try updateProfileBundle(name, removing: true, profileDir: profileDir)
    }

    private func updateProfileBundle(
        _ name: String,
        removing: Bool,
        profileDir: URL? = nil
    ) throws {
        let profileDir = profileDir ?? Self.activeProfileDirectory
        let packageURL = profileDir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var dsh = root["dsh"] as? [String: Any],
              var profile = dsh["profile"] as? [String: Any],
              var bundles = profile["bundles"] as? [String] else {
            throw NSError(
                domain: "DshPluginManager",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "web Profile manifest 缺少 dsh.profile.bundles"]
            )
        }

        if removing {
            bundles.removeAll { $0 == name }
        } else if !bundles.contains(name) {
            bundles.append(name)
        }

        profile["bundles"] = bundles
        dsh["profile"] = profile
        root["dsh"] = dsh
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: packageURL, options: .atomic)
    }

    /// Remove the desktop shell bridge from an explicitly selected profile.
    /// This is used only when leaving the shared web profile so terminal
    /// `dsh web` is returned to its normal upstream dependency tree.
    public func removeDesktopHostArtifacts(
        from profile: DshAppProfile,
        profileDirectory: URL? = nil,
        registry: String? = nil
    ) async throws {
        guard profile == .web else { return }
        let stateSnapshot = DshStateManager.shared.current
        let profileDir = profileDirectory ?? Self.profileDirectory(for: profile)
        let capturedRegistry = DshVersionManager.normalizedRegistry(registry ?? stateSnapshot.npmRegistry)
        let packageURL = profileDir.appendingPathComponent("package.json")
        let root: [String: Any]?
        if let data = try? Data(contentsOf: packageURL) {
            root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } else {
            root = nil
        }

        let dependencies = root?["dependencies"] as? [String: String] ?? [:]
        let dependenciesToRemove = [
            Self.desktopHostPluginName,
            "@deepseek-ai/dsh-host-webserver"
        ].filter { dependencies[$0] != nil }

        let fileManager = FileManager.default
        let stalePaths = [
            profileDir.appendingPathComponent("node_modules/dsh-desktop-host", isDirectory: true),
            profileDir.appendingPathComponent("node_modules/@deepseek-ai/dsh-host-webserver", isDirectory: true)
        ]
        let hasStaleBridgePath = stalePaths.contains { fileManager.fileExists(atPath: $0.path) }
        let hasBridgeBundle: Bool
        if let dsh = root?["dsh"] as? [String: Any],
           let profile = dsh["profile"] as? [String: Any],
           let bundles = profile["bundles"] as? [String] {
            hasBridgeBundle = bundles.contains(Self.desktopHostPluginName)
        } else {
            hasBridgeBundle = false
        }

        // Removal is destructive even when pnpm has already removed the
        // direct dependencies. Require the durable proof whenever any bridge
        // artifact is present, including an orphaned node_modules path.
        guard !dependenciesToRemove.isEmpty || hasStaleBridgePath || hasBridgeBundle else {
            return
        }
        try verifyDesktopHostOwnershipProof(
            profileDir: profileDir,
            packageRoot: root
        )

        if !dependenciesToRemove.isEmpty {
            guard let pnpm = NodeRuntime.shared.resolvePnpmBinary(),
                  let node = NodeRuntime.shared.resolveNodeBinary() else {
                throw NSError(domain: "DshPluginManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少 Node 或 pnpm，无法清理 web Profile 桥接依赖"])
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: pnpm)
            proc.currentDirectoryURL = profileDir
            proc.arguments = ["remove"] + dependenciesToRemove + [
                "--config.minimum-release-age=0",
                "--reporter=append-only"
            ]

            var env = NodeRuntime.shared.buildEnvironment()
            env["DSH_NODE_BIN"] = node
            env["npm_config_registry"] = capturedRegistry
            proc.environment = env

            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr

            let result = try await runProcess(proc, stdout: stdout, stderr: stderr)
            guard result.status == 0 else {
                let detail = processOutput(result)
                throw NSError(
                    domain: "DshPluginManager",
                    code: -18,
                    userInfo: [NSLocalizedDescriptionKey: "清理 web Profile 桥接依赖失败（退出码 \(result.status)）\(detail)"]
                )
            }
        }

        // pnpm removes direct links and lockfile entries. Keep DSH's bundle
        // manifest synchronized as well; otherwise the next `dsh web` boot
        // would try to load the deleted bridge again.
        try updateProfileBundle(
            Self.desktopHostPluginName,
            removing: true,
            profileDir: profileDir
        )

        // Clean stale links left by interrupted pnpm operations. These are
        // exact children of the selected profile and never touch pnpm's store.
        for path in stalePaths where fileManager.fileExists(atPath: path.path) {
            try fileManager.removeItem(at: path)
        }

        let ownershipMarker = profileDir.appendingPathComponent(Self.desktopHostOwnershipMarkerName)
        if fileManager.fileExists(atPath: ownershipMarker.path) {
            try fileManager.removeItem(at: ownershipMarker)
        }
    }

    private func packageName(from spec: String) -> String? {
        let value = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.hasPrefix("github:"),
              !value.hasPrefix("file:"),
              !value.hasPrefix("link:"),
              !value.hasPrefix("./"),
              !value.hasPrefix("../") else {
            return nil
        }

        if value.hasPrefix("@"), let slash = value.firstIndex(of: "/") {
            let suffix = value.index(after: slash)
            let end = value[suffix...].firstIndex(of: "@") ?? value.endIndex
            return String(value[..<end])
        }

        let end = value.firstIndex(of: "@") ?? value.endIndex
        return String(value[..<end])
    }

    /// Match Electron's preflight check for npm registry plugins. A clear
    /// 404 is actionable; network and other registry failures are left to
    /// pnpm so its native error remains the source of truth.
    private func validateRegistryPackageIfNeeded(spec: String, registry: String) async throws {
        let value = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.hasPrefix("github:"),
              !value.hasPrefix("file:"),
              !value.hasPrefix("link:"),
              !value.hasPrefix("workspace:"),
              !value.hasPrefix("./"),
              !value.hasPrefix("../"),
              let name = packageName(from: value),
              let encodedName = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return
        }

        let base = registry.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/\(encodedName)") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/vnd.npm.install-v1+json", forHTTPHeaderField: "Accept")

        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            return
        }

        guard (response as? HTTPURLResponse)?.statusCode == 404 else { return }
        throw NSError(
            domain: "DshPluginManager",
            code: -7,
            userInfo: [NSLocalizedDescriptionKey: "未找到 npm 包 \(name)（HTTP 404），请检查拼写或确认该包已发布到当前镜像"]
        )
    }

    /// Keep the local bridge dependency and pnpm lockfile aligned with the
    /// currently running shell. Older Electron builds stored the bridge under
    /// app.asar.unpacked; Swift packages store it directly under Resources.
    @discardableResult
    private func repairDesktopHostDependency(_ hostBundle: String, profileDirectory: URL? = nil) -> Bool {
        let profileDir = profileDirectory ?? Self.activeProfileDirectory
        let packageURL = profileDir.appendingPathComponent("package.json")
        let lockURL = profileDir.appendingPathComponent("pnpm-lock.yaml")
        let hostSpec = "file:\(hostBundle)"
        let relativeHostPath = relativePath(from: profileDir, to: URL(fileURLWithPath: hostBundle))
        var changed = false

        if let data = try? Data(contentsOf: packageURL),
           var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var dependencies = root["dependencies"] as? [String: String],
           dependencies[Self.desktopHostPluginName] != hostSpec {
            dependencies[Self.desktopHostPluginName] = hostSpec
            root["dependencies"] = dependencies
            if let updated = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                try? updated.write(to: packageURL, options: .atomic)
                changed = true
            }
        }

        // Keep the lockfile in sync as well. It stores the absolute importer
        // specifier but relative package/snapshot references, and an old
        // Electron lockfile can otherwise keep pnpm resolving the dead path.
        if let lockData = try? Data(contentsOf: lockURL),
           var lock = String(data: lockData, encoding: .utf8) {
            var lines = lock.components(separatedBy: "\n")
            for index in lines.indices where lines[index].contains("dsh-desktop-host") {
                let line = lines[index]
                if let marker = line.range(of: "specifier:") {
                    let updatedLine = String(line[..<marker.upperBound]) + " " + hostSpec
                    if updatedLine != line {
                        lines[index] = updatedLine
                        changed = true
                    }
                } else if let marker = line.range(of: "version: file:") ?? line.range(of: "version: link:") {
                    let updatedLine = String(line[..<marker.upperBound]) + relativeHostPath
                    if updatedLine != line {
                        lines[index] = updatedLine
                        changed = true
                    }
                } else if let marker = line.range(of: "resolution: {directory: "),
                          let end = line.range(of: ", type: directory}", range: marker.upperBound..<line.endIndex) {
                    let updatedLine = String(line[..<marker.upperBound]) + relativeHostPath + String(line[end.lowerBound...])
                    if updatedLine != line {
                        lines[index] = updatedLine
                        changed = true
                    }
                } else if let marker = line.range(of: "@file:"),
                          let end = line.lastIndex(of: ":"), end > marker.upperBound {
                    let updatedLine = String(line[..<marker.upperBound]) + relativeHostPath + String(line[end...])
                    if updatedLine != line {
                        lines[index] = updatedLine
                        changed = true
                    }
                }
            }
            lock = lines.joined(separator: "\n")
            if let updated = lock.data(using: .utf8) {
                try? updated.write(to: lockURL, options: .atomic)
            }
        }

        return changed
    }

    private func relativePath(from base: URL, to target: URL) -> String {
        let baseComponents = base.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        var common = 0
        while common < baseComponents.count,
              common < targetComponents.count,
              baseComponents[common] == targetComponents[common] {
            common += 1
        }

        let parentSteps = Array(repeating: "..", count: max(0, baseComponents.count - common))
        let targetSteps = Array(targetComponents.dropFirst(common))
        return (parentSteps + targetSteps).joined(separator: "/")
    }

    private func runProcess(
        _ proc: Process,
        stdout: Pipe? = nil,
        stderr: Pipe? = nil
    ) async throws -> DshProcessExecutionResult {
        let collector = DshProcessOutputCollector(stdout: stdout, stderr: stderr)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    proc.standardInput = FileHandle.nullDevice
                    try proc.run()
                    collector.start()
                    proc.waitUntilExit()
                    collector.wait()
                    let output = collector.result()
                    continuation.resume(returning: DshProcessExecutionResult(
                        status: proc.terminationStatus,
                        stdout: output.stdout,
                        stderr: output.stderr
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static let processOutputByteLimit = 32 * 1024
    private static let processOutputCharacterLimit = 8 * 1024
    private static let processOutputTruncationMarker = "\n[output truncated]"

    private func redactedProcessOutput(_ data: Data) -> String {
        let bounded = data.count > Self.processOutputByteLimit
            ? data.prefix(Self.processOutputByteLimit)
            : data[...]
        let text = String(decoding: bounded, as: UTF8.self)
        return DshSecretRedactor().redact(text)
    }

    private func capProcessOutputCharacters(_ text: String) -> String {
        guard text.count > Self.processOutputCharacterLimit else { return text }
        let marker = Self.processOutputTruncationMarker
        let keepCount = max(0, Self.processOutputCharacterLimit - marker.count)
        return String(text.prefix(keepCount)) + marker
    }

    private func capProcessOutputBytes(_ text: String) -> String {
        let data = Data(text.utf8)
        guard data.count > Self.processOutputByteLimit else { return text }
        let marker = Data(Self.processOutputTruncationMarker.utf8)
        let keepCount = max(0, Self.processOutputByteLimit - marker.count)
        return String(decoding: data.prefix(keepCount), as: UTF8.self) + Self.processOutputTruncationMarker
    }

    private func processOutput(_ result: DshProcessExecutionResult) -> String {
        let out = redactedProcessOutput(result.stdout)
        let err = redactedProcessOutput(result.stderr)
        var detail = [out, err]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        detail = capProcessOutputCharacters(detail)
        detail = capProcessOutputBytes(detail)
        return detail.isEmpty ? "" : "：\n\(detail)"
    }

    private func currentDshVersion() -> String? {
        guard let entry = DshVersionManager.shared.resolveCurrentEntry() else { return nil }
        let packageURL = URL(fileURLWithPath: entry)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              package["name"] as? String == "@deepseek-ai/dsh",
              let version = package["version"] as? String,
              DshVersionManager.isValidVersion(version) else {
            return nil
        }
        return version
    }

    /// Keep the application-owned desktop Profile compatible with pnpm's
    /// DSH workspace defaults. The Web profile is shared with the terminal
    /// CLI, so it is intentionally left untouched here.
    private func ensureManagedProfileWorkspaceConfiguration(
        at profileDir: URL,
        profile: DshAppProfile? = nil
    ) throws {
        guard (profile ?? DshStateManager.shared.current.appProfile) == .desktop else { return }
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

        let workspaceURL = profileDir.appendingPathComponent(Self.profileWorkspaceFileName)
        let canonical = """
        packages:
          - .

        nodeLinker: hoisted
        autoInstallPeers: false
        """

        guard FileManager.default.fileExists(atPath: workspaceURL.path) else {
            try canonical.write(to: workspaceURL, atomically: true, encoding: .utf8)
            return
        }

        guard let data = try? Data(contentsOf: workspaceURL),
              let source = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "DshPluginManager",
                code: -23,
                userInfo: [NSLocalizedDescriptionKey: "无法读取 Desktop Profile 的 pnpm workspace 配置"]
            )
        }

        // Preserve custom settings such as allowBuilds and
        // minimumReleaseAgeExclude. Only repair the DSH workspace invariants
        // that affect peer resolution and the profile package layout.
        var updated = source
        if !Self.hasTopLevelWorkspaceKey("packages", in: updated) {
            updated = Self.appendWorkspaceText("packages:\n  - .", to: updated)
        }
        updated = Self.setTopLevelWorkspaceValue("nodeLinker", value: "hoisted", in: updated)
        updated = Self.setTopLevelWorkspaceValue("autoInstallPeers", value: "false", in: updated)

        guard updated != source else { return }
        try updated.write(to: workspaceURL, atomically: true, encoding: .utf8)
    }

    private static func hasTopLevelWorkspaceKey(_ key: String, in source: String) -> Bool {
        source.components(separatedBy: "\n").contains { line in
            !line.hasPrefix(" ") &&
            !line.hasPrefix("\t") &&
            line.hasPrefix("\(key):")
        }
    }

    private static func setTopLevelWorkspaceValue(
        _ key: String,
        value: String,
        in source: String
    ) -> String {
        var lines = source.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { line in
            !line.hasPrefix(" ") &&
            !line.hasPrefix("\t") &&
            line.hasPrefix("\(key):")
        }) {
            lines[index] = "\(key): \(value)"
            return lines.joined(separator: "\n")
        }
        return appendWorkspaceText("\(key): \(value)", to: source)
    }

    private static func appendWorkspaceText(_ text: String, to source: String) -> String {
        var result = source
        if !result.isEmpty && !result.hasSuffix("\n") {
            result += "\n"
        }
        if !result.isEmpty && !result.hasSuffix("\n\n") {
            result += "\n"
        }
        result += text
        if !result.hasSuffix("\n") {
            result += "\n"
        }
        return result
    }

    /// Create the canonical selected-profile manifest before pnpm is invoked.
    ///
    /// DSH normally creates this file during its first boot. That ordering is
    /// unsafe for the desktop shell because the first boot would use the
    /// upstream, unprotected WebServer before the managed host can be added.
    /// The shape mirrors DSH's standard profile initializer and preserves
    /// any existing user dependencies and bundle order.
    public func bootstrapWebProfileManifestIfMissing() throws {
        let selectedProfile = DshStateManager.shared.current.appProfile
        try bootstrapWebProfileManifestIfMissing(
            at: Self.activeProfileDirectory,
            profile: selectedProfile
        )
    }

    /// Bootstrap an explicitly selected Profile directory. `profile` is only
    /// the logical owner used for workspace rules; the supplied URL remains
    /// the sole filesystem target.
    public func bootstrapWebProfileManifestIfMissing(
        at profileDir: URL,
        profile selectedProfile: DshAppProfile
    ) throws {
        let readiness = bootstrapReadiness(at: profileDir)
        switch readiness {
        case .initialized:
            return
        case .existingUninitialized:
            throw NSError(
                domain: "DshPluginManager",
                code: -25,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "拒绝自动创建 \(selectedProfile.rawValue) Profile manifest：现有 Profile 未完成初始化，请先完成只读依赖检查或恢复"
                ]
            )
        case .invalid:
            throw NSError(
                domain: "DshPluginManager",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "无法读取 \(selectedProfile.rawValue) Profile manifest"]
            )
        case .freshEmpty:
            break
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try ensureManagedProfileWorkspaceConfiguration(at: profileDir, profile: selectedProfile)
        let root: [String: Any] = [
            "name": "dsh-profile-\(selectedProfile.rawValue)",
            "private": true,
            "dependencies": [String: String](),
            "dsh": [
                "profile": ["bundles": Self.standardProfileBundles]
            ]
        ]
        let packageURL = profileDir.appendingPathComponent("package.json")
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: packageURL, options: .atomic)
    }

    /// Repair the profile manifest created by an older Swift shell.
    ///
    /// Existing Profiles are deliberately left untouched. F03 startup must
    /// inspect or recover a non-empty incomplete tree before any write; only a
    /// genuinely empty Profile may receive the canonical bootstrap manifest.
    public func repairWebProfileManifestIfNeeded() {
        let profileDir = Self.activeProfileDirectory
        guard bootstrapReadiness(at: profileDir) == .freshEmpty else { return }
        try? bootstrapWebProfileManifestIfMissing(
            at: profileDir,
            profile: DshStateManager.shared.current.appProfile
        )
    }

    /// Whether the web profile has already been initialized enough for pnpm
    /// to add a local bridge bundle without recreating a partial manifest.
    /// A completely new profile is intentionally left for the first DSH boot
    /// so DSH can write its canonical package metadata first.
    public func hasInitializedWebProfileManifest() -> Bool {
        hasInitializedWebProfileManifest(at: Self.activeProfileDirectory)
    }

    public func hasInitializedWebProfileManifest(at profileDir: URL) -> Bool {
        bootstrapReadiness(at: profileDir) == .initialized
    }

    /// Classify a captured Profile path without creating directories or
    /// repairing its manifest. Launchers must use this result together with
    /// the Inspector evidence before calling a bootstrap mutator.
    public func bootstrapReadiness(at profileDir: URL) -> DshProfileBootstrapReadiness {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: profileDir.path) else { return .freshEmpty }
        guard let values = try? profileDir.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else {
            return .invalid
        }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: profileDir,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return .invalid
        }
        guard !entries.isEmpty else { return .freshEmpty }

        let packageURL = profileDir.appendingPathComponent("package.json")
        guard fileManager.fileExists(atPath: packageURL.path) else {
            return .existingUninitialized
        }
        guard let data = try? Data(contentsOf: packageURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalid
        }
        guard let dsh = root["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String],
              !bundles.isEmpty else {
            return .existingUninitialized
        }
        return .initialized
    }

    /// Ensure the built-in desktop host bridge plugin is installed and valid
    /// in the selected profile. Failure is thrown so callers cannot start a bare
    /// WebServer as a fallback.
    public func ensureDesktopHostPlugin(
        registry: String? = nil,
        profileDirectory: URL? = nil,
        profile: DshAppProfile? = nil,
        runtimeVersion: String? = nil
    ) async throws -> Bool {
        let stateSnapshot = DshStateManager.shared.current
        let targetProfile = profile ?? stateSnapshot.appProfile
        let capturedRegistry = DshVersionManager.normalizedRegistry(registry ?? stateSnapshot.npmRegistry)
        guard let hostBundle = NodeRuntime.shared.resolveDesktopHostBundlePath() else {
            throw NSError(domain: "DshPluginManager", code: -12, userInfo: [NSLocalizedDescriptionKey: "找不到内置 dsh-desktop-host Bundle"])
        }
        guard let dshVersion = runtimeVersion ?? currentDshVersion() else {
            throw NSError(domain: "DshPluginManager", code: -18, userInfo: [NSLocalizedDescriptionKey: "无法确定当前 DSH 版本，拒绝启动未验证的桌面 Host"])
        }
        guard let pnpm = NodeRuntime.shared.resolvePnpmBinary(),
              let node = NodeRuntime.shared.resolveNodeBinary() else {
            throw NSError(domain: "DshPluginManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少 Node 或 pnpm"])
        }
        try validateDesktopHostBundle(hostBundle)
        let profileDir = profileDirectory ?? Self.profileDirectory(for: targetProfile)

        let hostSpec = "file:\(hostBundle)"
        let installedHostIsCurrent = isInstalledDesktopHostBundle(
            profileDir: profileDir,
            sourceBundle: hostBundle
        )

        // A package with the bridge's name may belong to the terminal user.
        // Before repairing or replacing any existing node_modules entry,
        // require the durable proof established by a prior managed install.
        let installedHostURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(Self.desktopHostPluginName, isDirectory: true)
        let packageURL = profileDir.appendingPathComponent("package.json")
        let packageRoot = (try? Data(contentsOf: packageURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let hasBridgeDeclaration: Bool
        if let packageRoot,
           let dependencies = packageRoot["dependencies"] as? [String: Any] {
            let hasDependency = dependencies[Self.desktopHostPluginName] != nil
                || dependencies["@deepseek-ai/dsh-host-webserver"] != nil
            let hasBundle = (packageRoot["dsh"] as? [String: Any])
                .flatMap { $0["profile"] as? [String: Any] }
                .flatMap { $0["bundles"] as? [String] }?
                .contains(Self.desktopHostPluginName) == true
            hasBridgeDeclaration = hasDependency || hasBundle
        } else {
            hasBridgeDeclaration = false
        }
        if FileManager.default.fileExists(atPath: installedHostURL.path) || hasBridgeDeclaration {
            do {
                try verifyDesktopHostOwnershipProof(
                    profileDir: profileDir, packageRoot: packageRoot,
                    operation: "安装桌面桥接依赖")
            } catch {
                // Pre-marker installs predate the proof file. Adopt ownership
                // only when the installed bits provably came from this App;
                // partial installs fall through to pnpm add, which records
                // the proof once the tree is complete.
                let proofWritten = try adoptDesktopHostOwnershipProof(
                    profileDir: profileDir, packageRoot: packageRoot,
                    sourceBundle: hostBundle)
                if proofWritten {
                    let refreshedRoot = (try? Data(contentsOf: packageURL))
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    try verifyDesktopHostOwnershipProof(
                        profileDir: profileDir, packageRoot: refreshedRoot,
                        operation: "安装桌面桥接依赖")
                }
            }
        }

        try bootstrapWebProfileManifestIfMissing(at: profileDir, profile: targetProfile)

        let dependencyWasRepaired = repairDesktopHostDependency(hostBundle, profileDirectory: profileDir)
        let hostBundleNeedsRefresh = !installedHostIsCurrent || dependencyWasRepaired

        if !installedHostIsCurrent {
            try removeInstalledDesktopHostBundle(profileDir: profileDir, sourceBundle: hostBundle)
        }

        let plugins = listPlugins(at: profileDir)
        if let existing = plugins.first(where: { $0.name == Self.desktopHostPluginName }) {
            if existing.version == hostSpec && !hostBundleNeedsRefresh {
                if profileContainsBundle(Self.desktopHostPluginName, profileDir: profileDir),
                   isInstalledDesktopHostBundle(profileDir: profileDir, sourceBundle: hostBundle),
                   isInstalledWebServerPackage(profileDir: profileDir, version: dshVersion) {
                        try writeDesktopHostOwnershipProof(profileDir: profileDir, sourceBundle: hostBundle)
                        return false // Already installed and mounted.
                }
                try updateProfileBundle(Self.desktopHostPluginName, removing: false, profileDir: profileDir)
                // The local bridge may be mounted already while the matching
                // upstream WebServer dependency is missing from an older
                // profile. Let pnpm repair both pieces below.
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        proc.arguments = ["add"]
            + (hostBundleNeedsRefresh ? ["--force"] : [])
            + [
                "file:\(hostBundle)",
                "@deepseek-ai/dsh-host-webserver@\(dshVersion)",
                "--config.minimum-release-age=0",
                    "--registry", capturedRegistry,
                "--reporter=append-only"
            ]

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        proc.environment = env

        let result: DshProcessExecutionResult
        do {
            result = try await runProcess(proc, stdout: stdout, stderr: stderr)
        } catch {
            throw NSError(domain: "DshPluginManager", code: -13, userInfo: [NSLocalizedDescriptionKey: "无法启动 pnpm 安装内置桥接插件"])
        }
        guard result.status == 0 else {
            throw NSError(
                domain: "DshPluginManager",
                code: -14,
                userInfo: [NSLocalizedDescriptionKey: "安装内置桥接插件失败（退出码 \(result.status)）\(processOutput(result))"]
            )
        }

        try updateProfileBundle(Self.desktopHostPluginName, removing: false, profileDir: profileDir)
        guard profileContainsBundle(Self.desktopHostPluginName, profileDir: profileDir),
              isInstalledDesktopHostBundle(profileDir: profileDir, sourceBundle: hostBundle),
              isInstalledWebServerPackage(profileDir: profileDir, version: dshVersion) else {
            throw NSError(domain: "DshPluginManager", code: -15, userInfo: [NSLocalizedDescriptionKey: "内置桥接插件安装后未正确挂载"])
        }
        try writeDesktopHostOwnershipProof(profileDir: profileDir, sourceBundle: hostBundle)
        return true
    }

    /// Repair an incomplete application-owned Profile install before DSH is
    /// launched. `dsh plugin` deliberately forwards pnpm arguments verbatim,
    /// so a Profile created during a fresh DSH family release can be left with
    /// a lockfile but without a complete `node_modules` tree when pnpm's
    /// minimum-release-age policy rejects the just-published packages.
    ///
    /// This is intentionally lazy and scoped to the Profile used by the app:
    /// healthy profiles are not reinstalled, and the global pnpm configuration is never changed.
    /// The install is allowed to use zero
    /// release age only because the app is materializing its own pinned Profile
    /// lockfile; --frozen-lockfile prevents this repair from resolving new
    /// user dependencies, while pnpm still verifies the lockfile integrity and
    /// registry data.
    @discardableResult
    public func repairProfileDependenciesIfNeeded(
        registry: String? = nil,
        profileDirectory: URL? = nil,
        profile: DshAppProfile? = nil
    ) async throws -> Bool {
        let stateSnapshot = DshStateManager.shared.current
        let targetProfile = profile ?? stateSnapshot.appProfile
        let capturedRegistry = DshVersionManager.normalizedRegistry(registry ?? stateSnapshot.npmRegistry)
        guard targetProfile == .desktop else {
            // The web Profile is intentionally shared with the terminal CLI.
            // Never repair or reinstall that user-owned dependency tree during
            // an app launch.
            return false
        }
        let profileDir = profileDirectory ?? Self.profileDirectory(for: targetProfile)
        try ensureManagedProfileWorkspaceConfiguration(at: profileDir, profile: targetProfile)
        let packageURL = profileDir.appendingPathComponent("package.json")
        let lockfileURL = profileDir.appendingPathComponent("pnpm-lock.yaml")
        guard FileManager.default.fileExists(atPath: lockfileURL.path) else {
            // A new profile has no lockfile yet. The managed Host reconciliation
            // below the caller owns that first-install path.
            return false
        }
        guard let data = try? Data(contentsOf: packageURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = root["dependencies"] as? [String: Any],
              !dependencies.isEmpty else {
            return false
        }

        guard profileDependenciesNeedInstall(dependencies, profileDir: profileDir) else {
            return false
        }
        guard let pnpm = NodeRuntime.shared.resolvePnpmBinary(),
              let node = NodeRuntime.shared.resolveNodeBinary() else {
            throw NSError(
                domain: "DshPluginManager",
                code: -19,
                userInfo: [NSLocalizedDescriptionKey: "Desktop Profile 依赖不完整，但找不到 Node 或 pnpm，无法自动修复"]
            )
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        proc.arguments = [
            "install",
            "--frozen-lockfile",
            "--config.minimum-release-age=0",
                "--registry", capturedRegistry,
            "--prefer-offline",
            "--reporter=append-only"
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        proc.environment = env

        let result: DshProcessExecutionResult
        do {
            result = try await runProcess(proc, stdout: stdout, stderr: stderr)
        } catch {
            throw NSError(
                domain: "DshPluginManager",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "无法启动 Desktop Profile 依赖修复"]
            )
        }
        guard result.status == 0 else {
            let detail = processOutput(result)
            throw NSError(
                domain: "DshPluginManager",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "Desktop Profile 依赖修复失败（退出码 \(result.status)）。如果需要手动修复，请执行：dsh plugin --profile desktop install --config.minimum-release-age=0\(detail)"]
            )
        }

        guard !profileDependenciesNeedInstall(dependencies, profileDir: profileDir) else {
            throw NSError(
                domain: "DshPluginManager",
                code: -22,
                userInfo: [NSLocalizedDescriptionKey: "Desktop Profile 依赖修复完成，但仍有依赖未物化；请打开设置查看详细错误"]
            )
        }
        return true
    }

    private func profileDependenciesNeedInstall(
        _ dependencies: [String: Any],
        profileDir: URL
    ) -> Bool {
        let modulesManifest = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(".modules.yaml")
        guard FileManager.default.fileExists(atPath: modulesManifest.path) else {
            return true
        }

        return dependencies.keys.contains { name in
            guard let packageManifest = packageManifestURL(name: name, profileDir: profileDir) else {
                return true
            }
            return !FileManager.default.fileExists(atPath: packageManifest.path)
        }
    }

    private func packageManifestURL(name: String, profileDir: URL) -> URL? {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 1 || (parts.count == 2 && parts[0].hasPrefix("@")),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }

        let nodeModules = profileDir.appendingPathComponent("node_modules", isDirectory: true)
        let packageURL = parts.reduce(nodeModules) { $0.appendingPathComponent($1, isDirectory: true) }
            .appendingPathComponent("package.json")
        let root = nodeModules.standardizedFileURL.path
        let candidate = packageURL.standardizedFileURL.path
        guard candidate.hasPrefix(root + "/") else { return nil }
        return packageURL
    }

    private func validateDesktopHostBundle(_ path: String) throws {
        let bundleURL = URL(fileURLWithPath: path, isDirectory: true)
        guard Self.desktopHostRequiredFiles.allSatisfy({ FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent($0).path) }),
              let data = try? Data(contentsOf: bundleURL.appendingPathComponent("package.json")),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              package["name"] as? String == Self.desktopHostPluginName,
              let exports = package["exports"] as? [String: String],
              exports["./webserver"] == "./webserver.js" else {
            throw NSError(domain: "DshPluginManager", code: -16, userInfo: [NSLocalizedDescriptionKey: "内置 dsh-desktop-host Bundle 不完整"])
        }
    }

    private func isInstalledDesktopHostBundle(profileDir: URL, sourceBundle: String) -> Bool {
        let manifestURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(Self.desktopHostPluginName, isDirectory: true)
            .appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        guard package["name"] as? String == Self.desktopHostPluginName else { return false }
        return desktopHostBundleFingerprint(at: manifestURL.deletingLastPathComponent())
            == desktopHostBundleFingerprint(at: URL(fileURLWithPath: sourceBundle, isDirectory: true))
    }

    private func removeInstalledDesktopHostBundle(profileDir: URL, sourceBundle: String) throws {
        let installedURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(Self.desktopHostPluginName, isDirectory: true)
        let sourceURL = URL(fileURLWithPath: sourceBundle, isDirectory: true)
        guard installedURL.standardizedFileURL.path != sourceURL.standardizedFileURL.path,
              FileManager.default.fileExists(atPath: installedURL.path) else { return }
        try FileManager.default.removeItem(at: installedURL)
    }

    private func desktopHostBundleFingerprint(at bundleURL: URL) -> String? {
        var hasher = SHA256()
        for name in Self.desktopHostRequiredFiles {
            let fileURL = bundleURL.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            hasher.update(data: Data(name.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: data)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func isInstalledWebServerPackage(profileDir: URL, version: String) -> Bool {
        let manifestURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("@deepseek-ai", isDirectory: true)
            .appendingPathComponent("dsh-host-webserver", isDirectory: true)
            .appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return package["name"] as? String == "@deepseek-ai/dsh-host-webserver"
            && package["version"] as? String == version
    }

    private func desktopHostOwnershipError(_ detail: String, operation: String = "清理 web Profile 桥接依赖") -> NSError {
        NSError(
            domain: "DshPluginManager",
            code: -24,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "拒绝自动\(operation)：\(detail)。为保护用户同名依赖，请手动处理"
            ]
        )
    }

    private func normalizedFileDependencyPath(_ spec: String) -> String? {
        guard spec.hasPrefix("file:") else { return nil }
        let path = String(spec.dropFirst("file:".count))
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func isPath(_ candidate: URL, inside directory: URL) -> Bool {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let path = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    private func manifestFingerprint(at manifestURL: URL) -> String? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Adopt a pre-marker bridge install established by an older shell.
    /// Returns true when the ownership proof was recorded immediately.
    /// Adoption requires the installed bits to be byte-identical to the
    /// current bundled bridge plus manifest declarations that already point
    /// at a file: bridge and the runtime webserver; anything else stays
    /// fail-closed so user-owned same-name entries are never touched.
    /// A partial install (host present, webserver missing) returns false so
    /// the pnpm add below completes it and records the proof post-install.
    private func adoptDesktopHostOwnershipProof(
        profileDir: URL,
        packageRoot: [String: Any]?,
        sourceBundle: String
    ) throws -> Bool {
        let operation = "安装桌面桥接依赖"
        let sourceURL = URL(fileURLWithPath: sourceBundle, isDirectory: true)
        let installedHostURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(Self.desktopHostPluginName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: installedHostURL.path),
              isPath(installedHostURL, inside: profileDir),
              isInstalledDesktopHostBundle(profileDir: profileDir, sourceBundle: sourceBundle) else {
            if let reason = staleAppBridgeRejectionReason(
                profileDir: profileDir, packageRoot: packageRoot, sourceBundle: sourceBundle) {
                throw desktopHostOwnershipError(reason, operation: operation)
            }
            // Stale but provably App-placed: repoint the declaration and
            // let the pnpm refresh below replace the bits. The proof is
            // recorded post-install once the tree verifies end to end.
            _ = repairDesktopHostDependency(sourceBundle, profileDirectory: profileDir)
            return false
        }
        let packageURL = profileDir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = root["dependencies"] as? [String: Any],
              let hostSpec = dependencies[Self.desktopHostPluginName] as? String,
              normalizedFileDependencyPath(hostSpec) != nil,
              let webServerSpec = dependencies["@deepseek-ai/dsh-host-webserver"] as? String,
              !webServerSpec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let dsh = root["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String],
              bundles.contains(Self.desktopHostPluginName) else {
            throw desktopHostOwnershipError("缺少、损坏或不匹配的持久所有权证明", operation: operation)
        }
        // App upgrades move the file: target; align the declaration (and the
        // lockfile importer) before recording the proof. Bit-equality above
        // already proved the installed directory is ours.
        _ = repairDesktopHostDependency(sourceBundle, profileDirectory: profileDir)
        if (try? writeDesktopHostOwnershipProof(profileDir: profileDir, sourceBundle: sourceBundle)) != nil {
            return true
        }
        return false
    }

    /// A bridge installed by a previous App whose bundled bits have since
    /// changed. Returns nil when the installed directory is still provably
    /// App-placed (byte-identical to the bundle the manifest spec points at,
    /// that spec lives inside an App bundle's Resources tree, and the
    /// referenced bundle validates); otherwise returns a specific reason so
    /// the failure stays actionable instead of collapsing into the generic
    /// missing-proof message.
    private func staleAppBridgeRejectionReason(
        profileDir: URL,
        packageRoot: [String: Any]?,
        sourceBundle: String
    ) -> String? {
        let sourcePath = URL(fileURLWithPath: sourceBundle, isDirectory: true).standardizedFileURL.path
        guard let root = packageRoot else {
            return "Profile manifest 不可读"
        }
        guard let dependencies = root["dependencies"] as? [String: Any],
              let hostSpec = dependencies[Self.desktopHostPluginName] as? String,
              let oldPath = normalizedFileDependencyPath(hostSpec) else {
            return "桥接声明不是 App 安装的 file: 依赖"
        }
        if oldPath == sourcePath {
            return "已安装桥接与当前内置桥接指纹不同（可能已损坏或被手动修改）"
        }
        guard (try? validateDesktopHostBundle(oldPath)) != nil else {
            return "旧桥接来源校验失败"
        }
        guard isAppBundledBridgeSource(oldPath) else {
            return "旧桥接来源不在 App 包内"
        }
        guard let dsh = root["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String],
              bundles.contains(Self.desktopHostPluginName) else {
            return "Profile manifest 缺少内置桥接 Bundle 记录"
        }
        guard let webServerSpec = dependencies["@deepseek-ai/dsh-host-webserver"] as? String,
              !webServerSpec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Profile manifest 缺少 WebServer 依赖声明"
        }
        let oldURL = URL(fileURLWithPath: oldPath, isDirectory: true)
        let installedHostURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(Self.desktopHostPluginName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: installedHostURL.path),
              isPath(installedHostURL, inside: profileDir) else {
            return "已安装桥接路径缺失或越界"
        }
        guard let installedFingerprint = desktopHostBundleFingerprint(at: installedHostURL),
              installedFingerprint == desktopHostBundleFingerprint(at: oldURL) else {
            return "已安装文件与旧桥接来源不一致（可能被手动修改过）"
        }
        return nil
    }

    /// The manifest file: spec must resolve inside an App bundle's Resources
    /// tree (e.g. `.../DSH.app/Contents/Resources/...`). User directories
    /// never qualify, so a matching stale install cannot be user-owned code.
    private func isAppBundledBridgeSource(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let range = standardized.range(of: ".app/Contents/", options: .caseInsensitive) else {
            return false
        }
        return standardized[range.upperBound...].hasPrefix("Resources/")
    }

    /// Validate the persistent bridge ownership proof before any destructive
    /// operation. The proof binds the selected Profile, the exact bundled
    /// source, both direct dependency specifiers, and installed fingerprints.
    /// Missing or stale proof always fails closed; package names are never
    /// treated as ownership evidence.
    private func verifyDesktopHostOwnershipProof(
        profileDir: URL,
        packageRoot: [String: Any]?,
        operation: String = "清理 web Profile 桥接依赖"
    ) throws {
        let fileManager = FileManager.default
        let markerURL = profileDir.appendingPathComponent(Self.desktopHostOwnershipMarkerName)
        guard let markerData = try? Data(contentsOf: markerURL),
              let marker = try? JSONSerialization.jsonObject(with: markerData) as? [String: Any],
              marker["schema"] as? Int == 1,
              let recordedProfile = marker["profileDirectory"] as? String,
              recordedProfile == profileDir.standardizedFileURL.path,
              let sourcePath = marker["sourceBundle"] as? String,
              let sourceFingerprint = marker["sourceFingerprint"] as? String,
              let installedFingerprint = marker["installedFingerprint"] as? String,
              let recordedDependencies = marker["dependencies"] as? [String: String],
              recordedDependencies.count == 2,
              let recordedHostSpec = recordedDependencies[Self.desktopHostPluginName],
              let recordedWebServerSpec = recordedDependencies["@deepseek-ai/dsh-host-webserver"] else {
            throw desktopHostOwnershipError("缺少、损坏或不匹配的持久所有权证明", operation: operation)
        }

        guard let currentSourcePath = NodeRuntime.shared.resolveDesktopHostBundlePath(),
              URL(fileURLWithPath: sourcePath).standardizedFileURL.path
                == URL(fileURLWithPath: currentSourcePath).standardizedFileURL.path else {
            throw desktopHostOwnershipError("内置桥接来源已变化", operation: operation)
        }
        let sourceURL = URL(fileURLWithPath: sourcePath, isDirectory: true)
        guard desktopHostBundleFingerprint(at: sourceURL) == sourceFingerprint else {
            throw desktopHostOwnershipError("内置桥接来源指纹不匹配", operation: operation)
        }

        guard let root = packageRoot,
              let dependencies = root["dependencies"] as? [String: Any],
              let currentHostSpec = dependencies[Self.desktopHostPluginName] as? String,
              let currentWebServerSpec = dependencies["@deepseek-ai/dsh-host-webserver"] as? String else {
            throw desktopHostOwnershipError("Profile manifest 缺少可验证的桥接依赖", operation: operation)
        }
        guard currentHostSpec == recordedHostSpec,
              currentWebServerSpec == recordedWebServerSpec,
              normalizedFileDependencyPath(recordedHostSpec)
                == sourceURL.standardizedFileURL.path else {
            throw desktopHostOwnershipError("Profile manifest 中的桥接依赖归属不匹配", operation: operation)
        }

        guard let dsh = root["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String],
              bundles.contains(Self.desktopHostPluginName) else {
            throw desktopHostOwnershipError("Profile manifest 缺少内置桥接 Bundle 记录", operation: operation)
        }

        let installedHostURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(Self.desktopHostPluginName, isDirectory: true)
        if fileManager.fileExists(atPath: installedHostURL.path) {
            guard isPath(installedHostURL, inside: profileDir),
                  let manifestURL = packageManifestURL(name: Self.desktopHostPluginName, profileDir: profileDir),
                  let data = try? Data(contentsOf: manifestURL),
                  let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  package["name"] as? String == Self.desktopHostPluginName,
                  desktopHostBundleFingerprint(at: installedHostURL) == installedFingerprint else {
                throw desktopHostOwnershipError("已安装桥接 Bundle 指纹或路径不匹配", operation: operation)
            }
        }

        let webServerName = "@deepseek-ai/dsh-host-webserver"
        let webServerURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("@deepseek-ai", isDirectory: true)
            .appendingPathComponent("dsh-host-webserver", isDirectory: true)
        if fileManager.fileExists(atPath: webServerURL.path) {
            guard isPath(webServerURL, inside: profileDir),
                  let manifestURL = packageManifestURL(name: webServerName, profileDir: profileDir),
                  let data = try? Data(contentsOf: manifestURL),
                  let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  package["name"] as? String == webServerName,
                  manifestFingerprint(at: manifestURL)
                    == marker["webServerManifestFingerprint"] as? String else {
                throw desktopHostOwnershipError("已安装 WebServer 依赖指纹或路径不匹配", operation: operation)
            }
        }
    }

    /// Record ownership only after all bridge postconditions have passed.
    /// This marker is deliberately local to the selected Profile and is
    /// removed only after a verified cleanup succeeds.
    private func writeDesktopHostOwnershipProof(profileDir: URL, sourceBundle: String) throws {
        let packageURL = profileDir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = root["dependencies"] as? [String: Any],
              let hostSpec = dependencies[Self.desktopHostPluginName] as? String,
              let webServerSpec = dependencies["@deepseek-ai/dsh-host-webserver"] as? String,
              let dsh = root["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String],
              bundles.contains(Self.desktopHostPluginName) else {
            throw desktopHostOwnershipError("安装后无法验证 Profile 桥接依赖", operation: "安装桌面桥接依赖")
        }

        let sourceURL = URL(fileURLWithPath: sourceBundle, isDirectory: true)
        guard let sourceFingerprint = desktopHostBundleFingerprint(at: sourceURL),
              normalizedFileDependencyPath(hostSpec) == sourceURL.standardizedFileURL.path else {
            throw desktopHostOwnershipError("安装后桥接来源指纹或依赖路径不匹配", operation: "安装桌面桥接依赖")
        }

        let installedHostURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(Self.desktopHostPluginName, isDirectory: true)
        let webServerManifestURL = profileDir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("@deepseek-ai", isDirectory: true)
            .appendingPathComponent("dsh-host-webserver", isDirectory: true)
            .appendingPathComponent("package.json")
        guard isPath(installedHostURL, inside: profileDir),
              let installedFingerprint = desktopHostBundleFingerprint(at: installedHostURL),
              installedFingerprint == sourceFingerprint,
              let webServerManifestFingerprint = manifestFingerprint(at: webServerManifestURL) else {
            throw desktopHostOwnershipError("安装后无法验证桥接依赖物化路径", operation: "安装桌面桥接依赖")
        }

        let proof: [String: Any] = [
            "schema": 1,
            "profileDirectory": profileDir.standardizedFileURL.path,
            "sourceBundle": sourceURL.standardizedFileURL.path,
            "sourceFingerprint": sourceFingerprint,
            "installedFingerprint": installedFingerprint,
            "webServerManifestFingerprint": webServerManifestFingerprint,
            "dependencies": [
                Self.desktopHostPluginName: hostSpec,
                "@deepseek-ai/dsh-host-webserver": webServerSpec
            ]
        ]
        let markerURL = profileDir.appendingPathComponent(Self.desktopHostOwnershipMarkerName)
        let markerData = try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
        try markerData.write(to: markerURL, options: .atomic)
    }

    private func profileContainsBundle(_ name: String, profileDir: URL? = nil) -> Bool {
        let packageURL = (profileDir ?? Self.activeProfileDirectory).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dsh = root["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String] else {
            return false
        }
        return bundles.contains(name)
    }

    private func registryArguments(_ registry: String) -> [String] {
        ["--registry", registry]
    }
}
