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
    private static let webProfileSnapshotDirectoryName = "dsh-runtime-profile-snapshots"
    private static let missingProfileMarkerName = ".profile-was-missing"

    public static func profileDirectory(for profile: DshAppProfile) -> URL {
        let dshHome = ProcessInfo.processInfo.environment["DSH_HOME"] ?? (NSHomeDirectory() as NSString).appendingPathComponent(".dsh")
        return URL(fileURLWithPath: dshHome)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(profile.rawValue, isDirectory: true)
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
        onProgress: @escaping @Sendable (DshProfileSnapshotProgress) -> Void
    ) throws -> String {
        let id = UUID().uuidString
        let snapshotURL = try webProfileSnapshotURL(for: id)
        let profileURL = profileDirectory(for: profile)
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
        onProgress: @escaping @Sendable (DshProfileSnapshotProgress) -> Void
    ) throws {
        let snapshotURL = try webProfileSnapshotURL(for: id)
        let profileURL = profileDirectory(for: profile)
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
        onProgress: @escaping @Sendable (DshProfileSnapshotProgress) -> Void = { _ in }
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            try Self.createWebProfileSnapshotSynchronously(profile: profile, onProgress: onProgress)
        }.value
    }

    /// Restore a previously persisted Profile snapshot. Replacement is
    /// recoverable: the current Profile is moved aside until the snapshot
    /// copy succeeds, so a failed copy does not silently destroy both states.
    public func restoreWebProfileSnapshot(
        _ id: String,
        profile: DshAppProfile = .web,
        onProgress: @escaping @Sendable (DshProfileSnapshotProgress) -> Void = { _ in }
    ) async throws {
        try await Task.detached(priority: .utility) {
            try Self.restoreWebProfileSnapshotSynchronously(id, profile: profile, onProgress: onProgress)
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
        let profileDir = Self.activeProfileDirectory
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
        let packageURL = Self.activeProfileDirectory.appendingPathComponent("package.json")
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
        guard let pnpm = NodeRuntime.shared.resolvePnpmBinary(),
              let node = NodeRuntime.shared.resolveNodeBinary() else {
            throw NSError(domain: "DshPluginManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少 Node 或 pnpm"])
        }

        if let hostBundle = NodeRuntime.shared.resolveDesktopHostBundlePath() {
            _ = repairDesktopHostDependency(hostBundle)
        }

        let profileDir = Self.activeProfileDirectory
        guard FileManager.default.fileExists(atPath: profileDir.appendingPathComponent("package.json").path) else {
            return [:]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        proc.arguments = ["outdated", "--json"] + registryArguments()

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        try proc.run()
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
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
    public func addPlugin(spec: String) async throws {
        if let packageName = packageName(from: spec),
           Self.internalPluginDependencyNames.contains(packageName) {
            throw NSError(
                domain: "DshPluginManager",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: "不能直接安装 DSH 内部依赖 \(packageName)"]
            )
        }
        try await validateRegistryPackageIfNeeded(spec: spec)

        guard let pnpm = NodeRuntime.shared.resolvePnpmBinary(),
              let node = NodeRuntime.shared.resolveNodeBinary() else {
            throw NSError(domain: "DshPluginManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少 Node 或 pnpm"])
        }

        if let hostBundle = NodeRuntime.shared.resolveDesktopHostBundlePath() {
            _ = repairDesktopHostDependency(hostBundle)
        }

        let profileDir = Self.activeProfileDirectory
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        proc.arguments = ["add", spec] + registryArguments() + ["--reporter=append-only"]

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        proc.environment = env

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "DshPluginManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "安装插件 \(spec) 失败（退出码 \(proc.terminationStatus)）"])
        }
        if let packageName = packageName(from: spec) {
            try updateProfileBundle(packageName, removing: false)
        }
    }

    /// Update a specific plugin to its latest version.
    public func updatePlugin(name: String) async throws {
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
            _ = repairDesktopHostDependency(hostBundle)
        }

        let profileDir = Self.activeProfileDirectory
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        proc.arguments = ["update", name, "--latest"] + registryArguments() + ["--reporter=append-only"]

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let detail = processOutput(stdout: stdout, stderr: stderr)
            throw NSError(domain: "DshPluginManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "更新插件 \(name) 失败（退出码 \(proc.terminationStatus)）\(detail)"])
        }
    }

    /// Update all installed plugins to their latest versions.
    public func updateAllPlugins() async throws {
        guard let pnpm = NodeRuntime.shared.resolvePnpmBinary(),
              let node = NodeRuntime.shared.resolveNodeBinary() else {
            throw NSError(domain: "DshPluginManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少 Node 或 pnpm"])
        }

        if let hostBundle = NodeRuntime.shared.resolveDesktopHostBundlePath() {
            _ = repairDesktopHostDependency(hostBundle)
        }

        let profileDir = Self.activeProfileDirectory
        let pluginNames = listPlugins()
            .filter { !$0.isManaged && !$0.isLocal }
            .map(\.name)
        guard !pluginNames.isEmpty else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        proc.arguments = ["update"] + pluginNames + ["--latest"] + registryArguments() + ["--reporter=append-only"]

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        proc.environment = env

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "DshPluginManager", code: -4, userInfo: [NSLocalizedDescriptionKey: "批量更新插件失败"])
        }
    }

    /// Remove a plugin by name.
    public func removePlugin(name: String) async throws {
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

        if let hostBundle = NodeRuntime.shared.resolveDesktopHostBundlePath() {
            _ = repairDesktopHostDependency(hostBundle)
        }

        let profileDir = Self.activeProfileDirectory
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        // pnpm 11's `remove` command does not accept `--registry`. Removal
        // only operates on the existing lockfile, so keep the registry in
        // the environment for any incidental resolution instead of passing
        // it as an unsupported command-specific option.
        proc.arguments = ["remove", name, "--reporter=append-only"]

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        env["npm_config_registry"] = DshVersionManager.normalizedRegistry(
            DshStateManager.shared.current.npmRegistry
        )
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let detail = processOutput(stdout: stdout, stderr: stderr)
            throw NSError(
                domain: "DshPluginManager",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "卸载插件 \(name) 失败（退出码 \(proc.terminationStatus)）\(detail)"]
            )
        }
        try updateProfileBundle(name, removing: true)
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
    public func removeDesktopHostArtifacts(from profile: DshAppProfile) async throws {
        guard profile == .web else { return }
        let profileDir = Self.profileDirectory(for: profile)
        let packageURL = profileDir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let dependencies = root["dependencies"] as? [String: String] ?? [:]
        let dependenciesToRemove = [
            Self.desktopHostPluginName,
            "@deepseek-ai/dsh-host-webserver"
        ].filter { dependencies[$0] != nil }

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
            env["npm_config_registry"] = DshVersionManager.normalizedRegistry(
                DshStateManager.shared.current.npmRegistry
            )
            proc.environment = env

            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr

            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                let detail = processOutput(stdout: stdout, stderr: stderr)
                throw NSError(
                    domain: "DshPluginManager",
                    code: -18,
                    userInfo: [NSLocalizedDescriptionKey: "清理 web Profile 桥接依赖失败（退出码 \(proc.terminationStatus)）\(detail)"]
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
        let fileManager = FileManager.default
        let stalePaths = [
            profileDir.appendingPathComponent("node_modules/dsh-desktop-host", isDirectory: true),
            profileDir.appendingPathComponent("node_modules/@deepseek-ai/dsh-host-webserver", isDirectory: true)
        ]
        for path in stalePaths where fileManager.fileExists(atPath: path.path) {
            try fileManager.removeItem(at: path)
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
    private func validateRegistryPackageIfNeeded(spec: String) async throws {
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

        let registry = DshVersionManager.normalizedRegistry(DshStateManager.shared.current.npmRegistry)
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
    private func repairDesktopHostDependency(_ hostBundle: String) -> Bool {
        let profileDir = Self.activeProfileDirectory
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

    private func processOutput(stdout: Pipe, stderr: Pipe) -> String {
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let detail = [out, err]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
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

    /// Create the canonical selected-profile manifest before pnpm is invoked.
    ///
    /// DSH normally creates this file during its first boot. That ordering is
    /// unsafe for the desktop shell because the first boot would use the
    /// upstream, unprotected WebServer before the managed host can be added.
    /// The shape mirrors DSH's standard profile initializer and preserves
    /// any existing user dependencies and bundle order.
    public func bootstrapWebProfileManifestIfMissing() throws {
        let selectedProfile = DshStateManager.shared.current.appProfile
        let profileDir = Self.activeProfileDirectory
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let packageURL = profileDir.appendingPathComponent("package.json")

        if !FileManager.default.fileExists(atPath: packageURL.path) {
            let root: [String: Any] = [
                "name": "dsh-profile-\(selectedProfile.rawValue)",
                "private": true,
                "dependencies": [String: String](),
                "dsh": [
                    "profile": ["bundles": Self.standardProfileBundles]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: packageURL, options: .atomic)
            return
        }

        guard let data = try? Data(contentsOf: packageURL),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "DshPluginManager",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "无法读取 \(selectedProfile.rawValue) Profile manifest"]
            )
        }

        var changed = false
        if root["name"] == nil {
            root["name"] = "dsh-profile-\(selectedProfile.rawValue)"
            changed = true
        }
        if root["private"] == nil {
            root["private"] = true
            changed = true
        }
        if root["dependencies"] == nil {
            root["dependencies"] = [String: String]()
            changed = true
        } else if root["dependencies"] as? [String: Any] == nil {
            throw NSError(
                domain: "DshPluginManager",
                code: -17,
                userInfo: [NSLocalizedDescriptionKey: "\(selectedProfile.rawValue) Profile manifest 的 dependencies 格式无效"]
            )
        }

        var dsh = root["dsh"] as? [String: Any] ?? [:]
        var profile = dsh["profile"] as? [String: Any] ?? [:]
        if let bundles = profile["bundles"] as? [String], !bundles.isEmpty {
            if !changed { return }
        } else {
            profile["bundles"] = Self.standardProfileBundles
            changed = true
        }
        dsh["profile"] = profile
        root["dsh"] = dsh

        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: packageURL, options: .atomic)
    }

    /// Repair the profile manifest created by an older Swift shell.
    ///
    /// The old first-launch path ran `pnpm add` before DSH had initialized the
    /// web profile. pnpm then created a package.json containing only
    /// `dependencies`, which made DSH boot an empty profile forever. Keep the
    /// user's installed plugin dependencies and restore only the missing DSH
    /// profile section so the normal DSH initializer can continue.
    public func repairWebProfileManifestIfNeeded() {
        let packageURL = Self.activeProfileDirectory.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        var dsh = root["dsh"] as? [String: Any] ?? [:]
        var profile = dsh["profile"] as? [String: Any] ?? [:]
        if let bundles = profile["bundles"] as? [String], !bundles.isEmpty {
            return
        }

        profile["bundles"] = Self.standardProfileBundles
        dsh["profile"] = profile
        root["dsh"] = dsh

        guard let updated = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? updated.write(to: packageURL, options: .atomic)
    }

    /// Whether the web profile has already been initialized enough for pnpm
    /// to add a local bridge bundle without recreating a partial manifest.
    /// A completely new profile is intentionally left for the first DSH boot
    /// so DSH can write its canonical package metadata first.
    public func hasInitializedWebProfileManifest() -> Bool {
        let packageURL = Self.activeProfileDirectory.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dsh = root["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String] else {
            return false
        }
        return !bundles.isEmpty
    }

    /// Ensure the built-in desktop host bridge plugin is installed and valid
    /// in the selected profile. Failure is thrown so callers cannot start a bare
    /// WebServer as a fallback.
    public func ensureDesktopHostPlugin(registry: String? = nil) async throws -> Bool {
        guard let hostBundle = NodeRuntime.shared.resolveDesktopHostBundlePath() else {
            throw NSError(domain: "DshPluginManager", code: -12, userInfo: [NSLocalizedDescriptionKey: "找不到内置 dsh-desktop-host Bundle"])
        }
        guard let dshVersion = currentDshVersion() else {
            throw NSError(domain: "DshPluginManager", code: -18, userInfo: [NSLocalizedDescriptionKey: "无法确定当前 DSH 版本，拒绝启动未验证的桌面 Host"])
        }
        guard let pnpm = NodeRuntime.shared.resolvePnpmBinary(),
              let node = NodeRuntime.shared.resolveNodeBinary() else {
            throw NSError(domain: "DshPluginManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少 Node 或 pnpm"])
        }
        try validateDesktopHostBundle(hostBundle)
        try bootstrapWebProfileManifestIfMissing()

        let profileDir = Self.activeProfileDirectory
        let hostSpec = "file:\(hostBundle)"
        let installedHostIsCurrent = isInstalledDesktopHostBundle(
            profileDir: profileDir,
            sourceBundle: hostBundle
        )
        let dependencyWasRepaired = repairDesktopHostDependency(hostBundle)
        let hostBundleNeedsRefresh = !installedHostIsCurrent || dependencyWasRepaired

        if !installedHostIsCurrent {
            try removeInstalledDesktopHostBundle(profileDir: profileDir, sourceBundle: hostBundle)
        }

        let plugins = listPlugins()
        if let existing = plugins.first(where: { $0.name == Self.desktopHostPluginName }) {
            if existing.version == hostSpec && !hostBundleNeedsRefresh {
                if profileContainsBundle(Self.desktopHostPluginName),
                   isInstalledDesktopHostBundle(profileDir: profileDir, sourceBundle: hostBundle),
                   isInstalledWebServerPackage(profileDir: profileDir, version: dshVersion) {
                        return false // Already installed and mounted.
                }
                try updateProfileBundle(Self.desktopHostPluginName, removing: false)
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
                "--registry", DshVersionManager.normalizedRegistry(registry ?? DshStateManager.shared.current.npmRegistry),
                "--reporter=append-only"
            ]

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        proc.environment = env

        guard (try? proc.run()) != nil else {
            throw NSError(domain: "DshPluginManager", code: -13, userInfo: [NSLocalizedDescriptionKey: "无法启动 pnpm 安装内置桥接插件"])
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(
                domain: "DshPluginManager",
                code: -14,
                userInfo: [NSLocalizedDescriptionKey: "安装内置桥接插件失败（退出码 \(proc.terminationStatus)）\(processOutput(stdout: stdout, stderr: stderr))"]
            )
        }

        try updateProfileBundle(Self.desktopHostPluginName, removing: false)
        guard profileContainsBundle(Self.desktopHostPluginName),
              isInstalledDesktopHostBundle(profileDir: profileDir, sourceBundle: hostBundle) else {
            throw NSError(domain: "DshPluginManager", code: -15, userInfo: [NSLocalizedDescriptionKey: "内置桥接插件安装后未正确挂载"])
        }
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
    public func repairProfileDependenciesIfNeeded(registry: String? = nil) async throws -> Bool {
        guard DshStateManager.shared.current.appProfile == .desktop else {
            // The web Profile is intentionally shared with the terminal CLI.
            // Never repair or reinstall that user-owned dependency tree during
            // an app launch.
            return false
        }
        let profileDir = Self.activeProfileDirectory
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
            "--registry", DshVersionManager.normalizedRegistry(registry ?? DshStateManager.shared.current.npmRegistry),
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

        guard (try? proc.run()) != nil else {
            throw NSError(
                domain: "DshPluginManager",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "无法启动 Desktop Profile 依赖修复"]
            )
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let detail = processOutput(stdout: stdout, stderr: stderr)
            throw NSError(
                domain: "DshPluginManager",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "Desktop Profile 依赖修复失败（退出码 \(proc.terminationStatus)）。如果需要手动修复，请执行：dsh plugin --profile desktop install --config.minimum-release-age=0\(detail)"]
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

    private func profileContainsBundle(_ name: String) -> Bool {
        let packageURL = Self.activeProfileDirectory.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dsh = root["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String] else {
            return false
        }
        return bundles.contains(name)
    }

    private func registryArguments() -> [String] {
        ["--registry", DshVersionManager.normalizedRegistry(DshStateManager.shared.current.npmRegistry)]
    }
}
