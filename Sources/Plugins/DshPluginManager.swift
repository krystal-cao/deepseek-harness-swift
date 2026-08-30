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

public final class DshPluginManager {
    public static let shared = DshPluginManager()

    public static let desktopHostPluginName = "dsh-desktop-host"
    private static let desktopHostRequiredFiles = [
        "package.json",
        "index.js",
        "client.js",
        "webserver.js",
        "browser-url-route.js",
        "lan-url-route.js",
        "lan-http-ingress.js",
        "control.js",
        "access-state.js",
        "cordis.patch.yml",
    ]
    private static let standardWebProfileBundles = [
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app"
    ]

    public static var webProfileDirectory: URL {
        let dshHome = ProcessInfo.processInfo.environment["DSH_HOME"] ?? (NSHomeDirectory() as NSString).appendingPathComponent(".dsh")
        return URL(fileURLWithPath: dshHome).appendingPathComponent("profiles/web", isDirectory: true)
    }

    private init() {}

    /// List all installed plugins in the web profile.
    public func listPlugins(outdatedMap: [String: String] = [:]) -> [DshPluginItem] {
        let profileDir = Self.webProfileDirectory
        let pkgUrl = profileDir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: pkgUrl),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deps = json["dependencies"] as? [String: String] else {
            return []
        }

        var list: [DshPluginItem] = []
        for (name, spec) in deps {
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
        let packageURL = Self.webProfileDirectory.appendingPathComponent("package.json")
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

        let profileDir = Self.webProfileDirectory
        guard FileManager.default.fileExists(atPath: profileDir.appendingPathComponent("package.json").path) else {
            return [:]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        proc.arguments = ["outdated", "--json"]

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
            if let infoDict = info as? [String: Any],
               let latestVer = infoDict["latest"] as? String {
                outdated[pkgName] = latestVer
            }
        }
        return outdated
    }

    /// Add a plugin by name or npm specifier.
    public func addPlugin(spec: String) async throws {
        try await validateRegistryPackageIfNeeded(spec: spec)

        guard let pnpm = NodeRuntime.shared.resolvePnpmBinary(),
              let node = NodeRuntime.shared.resolveNodeBinary() else {
            throw NSError(domain: "DshPluginManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "缺少 Node 或 pnpm"])
        }

        if let hostBundle = NodeRuntime.shared.resolveDesktopHostBundlePath() {
            _ = repairDesktopHostDependency(hostBundle)
        }

        let profileDir = Self.webProfileDirectory
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        proc.arguments = ["add", spec, "--reporter=append-only"]

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

        let profileDir = Self.webProfileDirectory
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        proc.arguments = ["update", name, "--latest", "--reporter=append-only"]

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

        let profileDir = Self.webProfileDirectory
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        proc.arguments = ["update", "--latest", "--reporter=append-only"]

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

        let profileDir = Self.webProfileDirectory
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pnpm)
        proc.currentDirectoryURL = profileDir
        proc.arguments = ["remove", name, "--reporter=append-only"]

        var env = NodeRuntime.shared.buildEnvironment()
        env["DSH_NODE_BIN"] = node
        proc.environment = env

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "DshPluginManager", code: -6, userInfo: [NSLocalizedDescriptionKey: "卸载插件 \(name) 失败"])
        }
        try updateProfileBundle(name, removing: true)
    }

    private func updateProfileBundle(_ name: String, removing: Bool) throws {
        let packageURL = Self.webProfileDirectory.appendingPathComponent("package.json")
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

        let registry = DshStateManager.shared.current.npmRegistry ?? DshVersionManager.defaultRegistry
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
        let profileDir = Self.webProfileDirectory
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

    /// Create the canonical web profile manifest before pnpm is invoked.
    ///
    /// DSH normally creates this file during its first boot. That ordering is
    /// unsafe for the desktop shell because the first boot would use the
    /// upstream, unprotected WebServer before the managed host can be added.
    /// The shape mirrors DSH's standard web profile initializer and preserves
    /// any existing user dependencies and bundle order.
    public func bootstrapWebProfileManifestIfMissing() throws {
        let profileDir = Self.webProfileDirectory
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let packageURL = profileDir.appendingPathComponent("package.json")

        if !FileManager.default.fileExists(atPath: packageURL.path) {
            let root: [String: Any] = [
                "name": "dsh-profile-web",
                "private": true,
                "dependencies": [String: String](),
                "dsh": [
                    "profile": ["bundles": Self.standardWebProfileBundles]
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
                userInfo: [NSLocalizedDescriptionKey: "无法读取 web Profile manifest"]
            )
        }

        var changed = false
        if root["name"] == nil {
            root["name"] = "dsh-profile-web"
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
                userInfo: [NSLocalizedDescriptionKey: "web Profile manifest 的 dependencies 格式无效"]
            )
        }

        var dsh = root["dsh"] as? [String: Any] ?? [:]
        var profile = dsh["profile"] as? [String: Any] ?? [:]
        if let bundles = profile["bundles"] as? [String], !bundles.isEmpty {
            if !changed { return }
        } else {
            profile["bundles"] = Self.standardWebProfileBundles
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
        let packageURL = Self.webProfileDirectory.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        var dsh = root["dsh"] as? [String: Any] ?? [:]
        var profile = dsh["profile"] as? [String: Any] ?? [:]
        if let bundles = profile["bundles"] as? [String], !bundles.isEmpty {
            return
        }

        profile["bundles"] = Self.standardWebProfileBundles
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
        let packageURL = Self.webProfileDirectory.appendingPathComponent("package.json")
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
    /// in the web profile. Failure is thrown so callers cannot start a bare
    /// WebServer as a fallback.
    public func ensureDesktopHostPlugin() async throws -> Bool {
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

        let profileDir = Self.webProfileDirectory
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
        let packageURL = Self.webProfileDirectory.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dsh = root["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let bundles = profile["bundles"] as? [String] else {
            return false
        }
        return bundles.contains(name)
    }
}
