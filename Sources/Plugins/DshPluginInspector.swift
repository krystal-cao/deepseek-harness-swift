import Foundation

public enum DshPluginInspectionKind: String, Codable, Sendable {
    case library, bundle, runtimeCore, unknown
}

public enum DshPluginInspectionSource: String, Codable, Sendable {
    case profile, runtimeHost, unresolved
}

public enum DshPluginInspectionStatus: String, Codable, Sendable {
    case healthy, missingPackage, notComposed, disabled, duplicateBundle
    case patchReferenceMissing, unavailable, uncertain
}

public enum DshPluginInspectionConfidence: String, Codable, Sendable {
    case confirmed, suspected, unknown
}

public struct DshPluginInspectionItem: Codable, Equatable, Sendable {
    public let name: String
    public let requestedSpec: String?
    public let kind: DshPluginInspectionKind
    public let source: DshPluginInspectionSource
    public let status: DshPluginInspectionStatus
    public let confidence: DshPluginInspectionConfidence
    public let detail: String?
    public init(name: String, requestedSpec: String? = nil, kind: DshPluginInspectionKind,
                source: DshPluginInspectionSource, status: DshPluginInspectionStatus,
                confidence: DshPluginInspectionConfidence, detail: String? = nil) {
        self.name = name; self.requestedSpec = requestedSpec; self.kind = kind
        self.source = source; self.status = status; self.confidence = confidence
        self.detail = detail
    }
}

public enum DshPluginInspectionIssueSeverity: String, Codable, Sendable { case warning, error }

public struct DshPluginInspectionIssue: Codable, Equatable, Sendable {
    public let code: String
    public let severity: DshPluginInspectionIssueSeverity
    public let file: String?
    public let line: Int?
    public let detail: String
    public init(code: String, severity: DshPluginInspectionIssueSeverity, file: String? = nil,
                line: Int? = nil, detail: String) {
        self.code = code; self.severity = severity; self.file = file; self.line = line
        self.detail = detail
    }
}

public struct DshPluginInspectorRuntimeDescriptor: Sendable {
    public let root: URL
    public let nodeBinary: URL?
    public let integrityVerified: Bool
    public init(root: URL, nodeBinary: URL? = nil, integrityVerified: Bool) {
        self.root = root.standardizedFileURL
        self.nodeBinary = nodeBinary?.standardizedFileURL
        self.integrityVerified = integrityVerified
    }
    public static func verified(root: URL, nodeBinary: URL? = nil) -> Self {
        Self(root: root, nodeBinary: nodeBinary, integrityVerified: true)
    }
}

public struct DshPluginInspectionResult: Codable, Equatable, Sendable {
    public let profileDirectory: String
    public let runtimeHostRoot: String
    public let runtimeRootVerified: Bool
    public let items: [DshPluginInspectionItem]
    public let bundleOrder: [String]
    public let disabledBundleNames: [String]
    public let issues: [DshPluginInspectionIssue]
    public let uncertainties: [String]
    public let scannedFileCount: Int
    public let isComplete: Bool
    public var hasProblems: Bool {
        items.contains { $0.status != .healthy && $0.status != .disabled }
            || issues.contains { $0.severity == .error }
    }
    public init(profileDirectory: String, runtimeHostRoot: String, runtimeRootVerified: Bool = false,
                items: [DshPluginInspectionItem], bundleOrder: [String],
                disabledBundleNames: [String], issues: [DshPluginInspectionIssue],
                uncertainties: [String], scannedFileCount: Int, isComplete: Bool) {
        self.profileDirectory = profileDirectory; self.runtimeHostRoot = runtimeHostRoot
        self.runtimeRootVerified = runtimeRootVerified; self.items = items
        self.bundleOrder = bundleOrder; self.disabledBundleNames = disabledBundleNames
        self.issues = issues; self.uncertainties = uncertainties
        self.scannedFileCount = scannedFileCount; self.isComplete = isComplete
    }
}

public struct DshPluginInspector: Sendable {
    public let profileDirectory: URL
    public let runtimeHostRoot: URL
    public let runtimeNodeBinary: URL?
    public let runtimeRootVerified: Bool

    public init(profileDirectory: URL, runtimeHostRoot: URL, nodeBinary: URL? = nil,
                runtimeRootVerified: Bool = false) {
        self.profileDirectory = profileDirectory.standardizedFileURL
        self.runtimeHostRoot = runtimeHostRoot.standardizedFileURL
        self.runtimeNodeBinary = nodeBinary?.standardizedFileURL
        self.runtimeRootVerified = runtimeRootVerified
    }
    public init(profileDirectory: URL, runtime: DshPluginInspectorRuntimeDescriptor) {
        self.init(profileDirectory: profileDirectory, runtimeHostRoot: runtime.root,
                  nodeBinary: runtime.nodeBinary, runtimeRootVerified: runtime.integrityVerified)
    }
    public func inspectAsync() async -> DshPluginInspectionResult {
        await Task.detached(priority: .utility) { self.inspect() }.value
    }

    public func inspect() -> DshPluginInspectionResult {
        var state = InspectionState()
        let rootManifestURL = profileDirectory.appendingPathComponent("package.json")
        state.scannedFileCount += 1
        guard let root = readManifest(rootManifestURL, state: &state,
                                       missing: "profileManifestMissing",
                                       invalid: "profileManifestInvalid") else {
            return state.result(profile: profileDirectory, runtime: runtimeHostRoot,
                                verified: runtimeRootVerified)
        }
        readBundleOrder(root, at: rootManifestURL, state: &state)
        let direct = dependencyMap(root, at: rootManifestURL, state: &state)
        let directNames = Set(direct.keys)
        var records: [String: PackageRecord] = [:]
        for name in directNames.sorted() {
            records[name] = resolve(name: name, spec: direct[name] ?? "*",
                                     parent: profileDirectory, state: &state,
                                     missing: "materializedManifestMissing",
                                     invalid: "materializedManifestInvalid")
        }

        var indirect = Set<String>()
        var queue = directNames.sorted()
        var walked = Set<String>()
        while !queue.isEmpty {
            let owner = queue.removeFirst()
            guard walked.insert(owner).inserted, let record = records[owner],
                  let manifest = record.manifest, let manifestURL = record.manifestURL else { continue }
            for (name, spec) in dependencyMap(manifest, at: manifestURL, state: &state)
                where !directNames.contains(name) {
                indirect.insert(name)
                if records[name] == nil {
                    records[name] = resolve(name: name, spec: spec,
                                             parent: manifestURL.deletingLastPathComponent(),
                                             state: &state, missing: "indirectManifestMissing",
                                             invalid: "indirectManifestInvalid")
                }
                queue.append(name)
            }
        }

        for installed in discoverInstalled(state: &state) where records[installed.name] == nil {
            records[installed.name] = installed
        }
        if let order = state.bundleOrder {
            for name in order where records[name] == nil {
                let record = resolve(
                    name: name, spec: "*", parent: profileDirectory, state: &state,
                    missing: "materializedManifestMissing",
                    invalid: "materializedManifestInvalid",
                    reportMissing: false
                )
                records[name] = record
                if record.manifest == nil {
                    state.issues.append(DshPluginInspectionIssue(
                        code: "bundlePackageMissing", severity: .error,
                        file: rootManifestURL.lastPathComponent,
                        detail: "Bundle 顺序引用的包 \(name) 缺少 manifest"))
                }
            }
        }
        inspectPatches(records, state: &state)
        resolvePatchOnlyReferences(&records, state: &state)
        for record in records.values where indirect.contains(record.name) && classify(record) == .bundle {
            state.uncertainties.append("Bundle \(record.name) 仅通过间接依赖可达，无法唯一归属")
        }
        var items = records.values.map {
            makeItem($0, direct: directNames.contains($0.name),
                     indirect: indirect.contains($0.name), state: state)
        }
        for name in state.patchReferences where records[name] == nil {
            state.issues.append(DshPluginInspectionIssue(
                code: "patchReferenceMissing", severity: .error, file: state.patchFiles.first,
                detail: "Cordis patch 引用了未解析的包 \(name)"))
            items.append(DshPluginInspectionItem(name: name, kind: .unknown, source: .unresolved,
                                                 status: .patchReferenceMissing,
                                                 confidence: .confirmed, detail: "patch 引用不存在的包"))
        }
        return DshPluginInspectionResult(
            profileDirectory: profileDirectory.path, runtimeHostRoot: runtimeHostRoot.path,
            runtimeRootVerified: runtimeRootVerified, items: items.sorted { $0.name < $1.name },
            bundleOrder: state.bundleOrder ?? [],
            disabledBundleNames: Array(Set(state.patchEntries.filter(\.disabled).compactMap(\.name)
                .filter { $0 == packageRoot($0) })).sorted(), issues: state.issues,
            uncertainties: state.uncertainties, scannedFileCount: state.scannedFileCount,
            isComplete: !state.issues.contains { $0.severity == .error })
    }

    private func makeItem(_ record: PackageRecord, direct: Bool, indirect: Bool,
                          state: InspectionState) -> DshPluginInspectionItem {
        guard record.manifest != nil else {
            return DshPluginInspectionItem(
                name: record.name, requestedSpec: record.requestedSpec, kind: .unknown,
                source: record.unreadable ? record.source : .unresolved,
                status: record.unreadable ? .unavailable : .missingPackage,
                confidence: record.unreadable ? .unknown : .confirmed,
                detail: record.unreadable ? "manifest 无法读取或不是合法 JSON" : "依赖声明存在但包 manifest 缺失")
        }
        let kind = classify(record)
        guard kind != .unknown else {
            return DshPluginInspectionItem(name: record.name, requestedSpec: record.requestedSpec,
                                           kind: .unknown, source: record.source,
                                           status: .unavailable, confidence: .unknown,
                                           detail: "包的 dsh 元数据结构未知")
        }
        // A direct runtime host can be disabled by a parsed patch even though
        // its manifest is an ordinary library. Indirect targets stay unknown.
        guard kind == .bundle else {
            if direct, !state.patchInspectionUnavailable, isDisabled(record.name, state: state) {
                return DshPluginInspectionItem(name: record.name, requestedSpec: record.requestedSpec,
                                               kind: kind, source: record.source, status: .disabled,
                                               confidence: .confirmed, detail: "Cordis patch 明确禁用该目标")
            }
            return DshPluginInspectionItem(name: record.name, requestedSpec: record.requestedSpec,
                                           kind: kind, source: record.source, status: .healthy,
                                           confidence: .confirmed,
                                           detail: kind == .runtimeCore ? "manifest 明确标记为 Runtime core" : nil)
        }
        // A patch-only reference that resolves inside the verified Runtime
        // tree is a Runtime-internal composition detail, not a Profile
        // inconsistency. pnpm keeps each managed package's siblings in its
        // own virtual-store directory, so these names are usually absent
        // from the top-level node_modules yet fully loadable at runtime.
        if !direct, record.source == .runtimeHost,
           state.runtimeSatisfiedBundles.contains(record.name) {
            return DshPluginInspectionItem(name: record.name, requestedSpec: record.requestedSpec,
                                           kind: kind, source: record.source, status: .healthy,
                                           confidence: .confirmed,
                                           detail: "Runtime 内部 patch 引用已在已校验 Runtime 树中解析")
        }
        if !direct {
            // Runtime-provided Bundles explicitly composed via the Profile's
            // own dsh.profile.bundles carry the same composition evidence as
            // a direct dependency: the Profile opted in and the package
            // resolves from the verified Runtime tree. Only Profile-side
            // unattributed Bundles stay uncertain.
            if record.source != .runtimeHost {
                return DshPluginInspectionItem(name: record.name, requestedSpec: record.requestedSpec,
                                               kind: kind, source: record.source, status: .uncertain,
                                               confidence: .unknown,
                                               detail: indirect ? "Bundle 仅通过间接依赖可达，无法唯一归属"
                                                                : "Bundle 没有 Profile 依赖归属证据")
            }
        }
        // A patch is part of the package's runtime semantics. If it exists but
        // cannot be inspected, do not infer either enabled or disabled state.
        if state.patchInspectionUnavailable {
            return DshPluginInspectionItem(name: record.name, requestedSpec: record.requestedSpec,
                                           kind: kind, source: record.source, status: .unavailable,
                                           confidence: .unknown,
                                           detail: "Cordis patch 无法解析，不能确认 Bundle 状态")
        }
        if isDisabled(record.name, state: state) {
            return DshPluginInspectionItem(name: record.name, requestedSpec: record.requestedSpec,
                                           kind: kind, source: record.source, status: .disabled,
                                           confidence: .confirmed, detail: "Cordis patch 明确禁用该目标")
        }
        guard state.bundleOrder != nil else {
            return DshPluginInspectionItem(name: record.name, requestedSpec: record.requestedSpec,
                                           kind: kind, source: record.source, status: .unavailable,
                                           confidence: .unknown,
                                           detail: "缺少 dsh.profile.bundles，不能确认 Bundle 是否已组合")
        }
        guard state.activeNames.contains(record.name) else {
            return DshPluginInspectionItem(name: record.name, requestedSpec: record.requestedSpec,
                                           kind: kind, source: record.source, status: .notComposed,
                                           confidence: .confirmed,
                                           detail: "已物化 Bundle 未出现在 dsh.profile.bundles 中")
        }
        if state.duplicateNames.contains(record.name) {
            return DshPluginInspectionItem(name: record.name, requestedSpec: record.requestedSpec,
                                           kind: kind, source: record.source, status: .duplicateBundle,
                                           confidence: .unknown, detail: "dsh.profile.bundles 中重复出现")
        }
        return DshPluginInspectionItem(name: record.name, requestedSpec: record.requestedSpec,
                                       kind: kind, source: record.source, status: .healthy,
                                       confidence: .confirmed)
    }

    private func classify(_ record: PackageRecord) -> DshPluginInspectionKind {
        if record.source == .runtimeHost, let dsh = record.manifest?["dsh"] as? [String: Any],
           dsh["runtimeCore"] as? Bool == true {
            return .runtimeCore
        }
        guard let raw = record.manifest?["dsh"] else { return .library }
        guard let dsh = raw as? [String: Any] else { return .unknown }
        guard let bundle = dsh["bundle"] else { return .library }
        return bundle is [String: Any] ? .bundle : .unknown
    }

    private func isDisabled(_ name: String, state: InspectionState) -> Bool {
        let values = state.patchEntries.filter { $0.name == name }
        guard !values.isEmpty else { return false }
        return values.allSatisfy(\.disabled)
    }

    private func readBundleOrder(_ manifest: [String: Any], at url: URL,
                                 state: inout InspectionState) {
        guard let dsh = manifest["dsh"] as? [String: Any],
              let profile = dsh["profile"] as? [String: Any],
              let raw = profile["bundles"] else {
            state.issues.append(DshPluginInspectionIssue(
                code: "bundleOrderUnavailable", severity: .error, file: url.lastPathComponent,
                detail: "Profile 缺少 dsh.profile.bundles"))
            return
        }
        guard let values = raw as? [Any] else {
            state.issues.append(DshPluginInspectionIssue(
                code: "bundleOrderInvalid", severity: .error, file: url.lastPathComponent,
                detail: "dsh.profile.bundles 不是数组"))
            return
        }
        var names: [String] = [], seen = Set<String>()
        for value in values {
            guard let name = value as? String, safeName(name) else {
                state.issues.append(DshPluginInspectionIssue(
                    code: "bundleOrderInvalid", severity: .error, file: url.lastPathComponent,
                    detail: "dsh.profile.bundles 含有无效包名"))
                continue
            }
            names.append(name)
            if !seen.insert(name).inserted {
                state.duplicateNames.insert(name)
                state.issues.append(DshPluginInspectionIssue(
                    code: "duplicateBundle", severity: .error, file: url.lastPathComponent,
                    detail: "Bundle 顺序中重复出现：\(name)"))
            }
        }
        state.bundleOrder = names; state.activeNames.formUnion(names)
    }

    private func dependencyMap(_ manifest: [String: Any], at url: URL,
                               state: inout InspectionState) -> [String: String] {
        guard let raw = manifest["dependencies"] else { return [:] }
        guard let values = raw as? [String: Any] else {
            state.issues.append(DshPluginInspectionIssue(
                code: "dependenciesInvalid", severity: .error, file: url.lastPathComponent,
                detail: "dependencies 不是对象"))
            return [:]
        }
        var result: [String: String] = [:]
        for (name, value) in values {
            guard let spec = value as? String, safeName(name) else {
                state.issues.append(DshPluginInspectionIssue(
                    code: "dependencyInvalid", severity: .error, file: url.lastPathComponent,
                    detail: "依赖名称或版本声明无效：\(name)"))
                continue
            }
            result[name] = spec
        }
        return result
    }

    private func resolve(name: String, spec: String, parent: URL,
                         state: inout InspectionState, missing: String,
                         invalid: String, reportMissing: Bool = true) -> PackageRecord {
        guard let resolved = resolveURL(name: name, spec: spec, parent: parent, state: &state) else {
            if reportMissing {
                state.issues.append(DshPluginInspectionIssue(
                    code: "packageMissing", severity: .error, file: "package.json",
                    detail: "声明的包 \(name) 缺少可读 manifest"))
            }
            return PackageRecord(name: name, requestedSpec: spec, manifest: nil,
                                 source: .unresolved, manifestURL: nil, unreadable: false)
        }
        guard let data = try? Data(contentsOf: resolved.url) else {
            state.issues.append(DshPluginInspectionIssue(
                code: missing, severity: .error, file: resolved.url.lastPathComponent,
                detail: "无法读取 JSON manifest；检查结果不确定"))
            return PackageRecord(name: name, requestedSpec: spec, manifest: nil,
                                 source: resolved.source, manifestURL: resolved.url, unreadable: true)
        }
        state.scannedFileCount += 1
        do {
            guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "DshPluginInspector", code: 1)
            }
            return PackageRecord(name: name, requestedSpec: spec, manifest: manifest,
                                 source: resolved.source, manifestURL: resolved.url, unreadable: false)
        } catch {
            state.issues.append(DshPluginInspectionIssue(
                code: invalid, severity: .error, file: resolved.url.lastPathComponent,
                detail: "JSON manifest 损坏，无法完成检查"))
            return PackageRecord(name: name, requestedSpec: spec, manifest: nil,
                                 source: resolved.source, manifestURL: resolved.url, unreadable: true)
        }
    }

    private func resolveURL(name: String, spec: String, parent: URL, state: inout InspectionState)
        -> ResolvedManifest? {
        var candidates: [(URL, DshPluginInspectionSource)] = []
        if spec.hasPrefix("file:") || spec.hasPrefix("link:") {
            let root = URL(fileURLWithPath: String(spec.dropFirst(5)), relativeTo: parent)
                .standardizedFileURL
            let url = root.appendingPathComponent("package.json")
            if within(profileDirectory, url) { candidates.append((url, .profile)) }
        }
        var cursor = parent.standardizedFileURL
        while within(profileDirectory, cursor) {
            if let url = packageURL(cursor, name) { candidates.append((url, .profile)) }
            if cursor.path == profileDirectory.path { break }
            cursor = cursor.deletingLastPathComponent()
        }
        if let url = packageURL(runtimeHostRoot, name) { candidates.append((url, .runtimeHost)) }
        // pnpm keeps dependencies of @deepseek-ai/dsh beside the package in
        // its verified virtual-store node_modules directory instead of
        // hoisting every Runtime Bundle to the version root. Follow only the
        // canonical managed dsh package link and keep the resolved dependency
        // root inside the already verified Runtime tree.
        let dshPackage = runtimeHostRoot
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("@deepseek-ai", isDirectory: true)
            .appendingPathComponent("dsh", isDirectory: true)
        let resolvedDshPackage = dshPackage.resolvingSymlinksInPath()
        let runtimeDependencyRoot = resolvedDshPackage
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if within(runtimeHostRoot, resolvedDshPackage),
           within(runtimeHostRoot, runtimeDependencyRoot),
           let url = packageURL(runtimeDependencyRoot, name) {
            candidates.append((url, .runtimeHost))
        }
        for (url, source) in candidates where FileManager.default.fileExists(atPath: url.path) {
            state.scannedFileCount += 1
            return ResolvedManifest(url: url, source: source)
        }
        return nil
    }

    private func packageURL(_ root: URL, _ name: String) -> URL? {
        guard let parts = packageParts(name) else { return nil }
        return parts.reduce(root.appendingPathComponent("node_modules", isDirectory: true)) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.appendingPathComponent("package.json")
    }

    /// Resolve patch-only references that the initial dependency walk could
    /// not place. The managed Runtime is a pnpm virtual store: each package's
    /// siblings live beside that package's real location, not beside the
    /// top-level `@deepseek-ai/dsh` link, so a single virtual-store hop
    /// misses most Runtime-internal patch targets. This pass follows the
    /// real location of every already-resolved package and falls back to a
    /// bounded `.pnpm` scan. It is strictly additive: names that still do
    /// not resolve keep the existing `patchReferenceMissing` error.
    private func resolvePatchOnlyReferences(_ records: inout [String: PackageRecord],
                                            state: inout InspectionState) {
        let missing = state.patchReferences.filter { records[$0] == nil }.sorted()
        guard !missing.isEmpty else { return }
        let roots = virtualStoreRoots(from: records)
        for name in missing {
            guard let record = resolvePatchReference(name: name, storeRoots: roots, state: &state) else {
                continue
            }
            records[name] = record
            if record.source == .runtimeHost {
                state.runtimeSatisfiedBundles.insert(name)
            }
        }
    }

    /// Candidate pnpm store roots derived from the real (symlink-resolved)
    /// location of every already-resolved package manifest.
    private func virtualStoreRoots(from records: [String: PackageRecord]) -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()
        for record in records.values {
            guard let manifestURL = record.manifestURL,
                  let root = storeRoot(for: manifestURL),
                  seen.insert(root.path).inserted else { continue }
            roots.append(root)
        }
        return roots.sorted { $0.path < $1.path }
    }

    /// Map `.../<store>/node_modules[/@scope]/<pkg>/package.json` to
    /// `.../<store>`. Returns nil unless the store stays inside the Profile
    /// or the managed Runtime tree.
    private func storeRoot(for manifestURL: URL) -> URL? {
        let real = manifestURL.resolvingSymlinksInPath().standardizedFileURL
        var components = real.pathComponents
        guard components.last == "package.json" else { return nil }
        components.removeLast()
        guard let pkg = components.popLast(), !pkg.isEmpty else { return nil }
        if pkg.hasPrefix("@") {
            // manifestURL points at the scope directory itself only when the
            // package name was malformed; real manifests always have one
            // more component. Bail out rather than guessing.
            return nil
        }
        if let scope = components.last, scope.hasPrefix("@") {
            components.removeLast()
        }
        guard components.last == "node_modules" else { return nil }
        components.removeLast()
        var root = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst() {
            root.appendPathComponent(component, isDirectory: true)
        }
        let standardized = root.standardizedFileURL
        guard within(profileDirectory, standardized) || within(runtimeHostRoot, standardized) else {
            return nil
        }
        return standardized
    }

    private func resolvePatchReference(name: String, storeRoots: [URL],
                                       state: inout InspectionState) -> PackageRecord? {
        for root in storeRoots {
            let source: DshPluginInspectionSource =
                within(profileDirectory, root) ? .profile : .runtimeHost
            if let record = readSiblingPackage(name: name, storeRoot: root,
                                               source: source, state: &state) {
                return record
            }
        }
        // Bounded fallback for Runtime-internal references whose referrer was
        // itself reachable only through another store (e.g. web-app siblings
        // while only the base store was collected). Profile stores win over
        // Runtime stores so user-installed copies keep precedence.
        let fallbacks: [(URL, DshPluginInspectionSource)] = [
            (profileDirectory.appendingPathComponent("node_modules/.pnpm", isDirectory: true), .profile),
            (runtimeHostRoot.appendingPathComponent("node_modules/.pnpm", isDirectory: true), .runtimeHost),
        ]
        for (storeDir, source) in fallbacks {
            if let record = searchVirtualStore(name: name, storeDir: storeDir,
                                               source: source, state: &state) {
                return record
            }
        }
        return nil
    }

    private func readSiblingPackage(name: String, storeRoot: URL,
                                    source: DshPluginInspectionSource,
                                    state: inout InspectionState) -> PackageRecord? {
        guard let url = packageURL(storeRoot, name),
              (within(profileDirectory, url) || within(runtimeHostRoot, url)),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return readResolvedManifest(name: name, url: url, source: source, state: &state)
    }

    private func searchVirtualStore(name: String, storeDir: URL,
                                    source: DshPluginInspectionSource,
                                    state: inout InspectionState) -> PackageRecord? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]),
              children.count <= 5000 else { return nil }
        for child in children.sorted(by: { $0.path < $1.path }) {
            guard let url = packageURL(child, name),
                  within(storeDir, url),
                  FileManager.default.fileExists(atPath: url.path),
                  let record = readResolvedManifest(name: name, url: url,
                                                    source: source, state: &state) else { continue }
            return record
        }
        return nil
    }

    private func readResolvedManifest(name: String, url: URL,
                                      source: DshPluginInspectionSource,
                                      state: inout InspectionState) -> PackageRecord? {
        state.scannedFileCount += 1
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["name"] as? String == name else { return nil }
        return PackageRecord(name: name, requestedSpec: nil, manifest: manifest,
                             source: source, manifestURL: url, unreadable: false)
    }

    private func discoverInstalled(state: inout InspectionState) -> [PackageRecord] {
        let root = profileDirectory.appendingPathComponent("node_modules", isDirectory: true)
        guard let top = try? FileManager.default.contentsOfDirectory(at: root,
                                                                      includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        var dirs: [URL] = []
        for item in top {
            if item.lastPathComponent.hasPrefix("@"),
               let scoped = try? FileManager.default.contentsOfDirectory(at: item,
                                                                          includingPropertiesForKeys: nil,
                                                                          options: [.skipsHiddenFiles]) {
                dirs.append(contentsOf: scoped)
            } else { dirs.append(item) }
        }
        var result: [PackageRecord] = []
        for dir in dirs {
            let url = dir.appendingPathComponent("package.json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            state.scannedFileCount += 1
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = manifest["name"] as? String, safeName(name) else {
                state.issues.append(DshPluginInspectionIssue(
                    code: "installedManifestInvalid", severity: .error,
                    file: url.lastPathComponent, detail: "已安装包 manifest 损坏或缺少合法 name"))
                continue
            }
            result.append(PackageRecord(name: name, requestedSpec: nil, manifest: manifest,
                                        source: .profile, manifestURL: url, unreadable: false))
        }
        return result
    }

    private func inspectPatches(_ records: [String: PackageRecord], state: inout InspectionState) {
        var paths: [URL] = []
        let profilePatch = profileDirectory.appendingPathComponent("cordis.patch.yml")
        if FileManager.default.fileExists(atPath: profilePatch.path) { paths.append(profilePatch) }
        for record in records.values {
            guard let manifest = record.manifest,
                  let dsh = manifest["dsh"] as? [String: Any],
                  let bundle = dsh["bundle"] as? [String: Any],
                  bundle["patch"] != nil else { continue }
            guard let patch = bundle["patch"] as? String, let manifestURL = record.manifestURL else {
                state.patchInspectionUnavailable = true
                state.issues.append(DshPluginInspectionIssue(
                    code: "patchInspectionUnavailable", severity: .error,
                    detail: "Bundle patch 字段不可读，不能完成检查"))
                continue
            }
            let root = manifestURL.deletingLastPathComponent()
            let url = URL(fileURLWithPath: patch, relativeTo: root).standardizedFileURL
            guard within(root, url), FileManager.default.fileExists(atPath: url.path) else {
                state.patchInspectionUnavailable = true
                state.issues.append(DshPluginInspectionIssue(
                    code: "patchMissing", severity: .error, file: url.lastPathComponent,
                    detail: "无法读取 Cordis patch，不能把它当成空配置"))
                continue
            }
            paths.append(url)
        }
        guard !paths.isEmpty else { return }
        state.patchFiles = paths.map(\.lastPathComponent)

        for url in paths {
            switch readPatch(url) {
            case .unavailable(let detail):
                state.patchInspectionUnavailable = true
                state.issues.append(DshPluginInspectionIssue(
                    code: "patchInspectionUnavailable", severity: .error,
                    file: url.lastPathComponent, detail: detail))
            case .invalid(let line, let detail):
                state.patchInspectionUnavailable = true
                state.issues.append(DshPluginInspectionIssue(
                    code: "patchInvalid", severity: .error,
                    file: url.lastPathComponent, line: line, detail: detail))
            case .value(let value):
                collectPatchEntries(value, file: url.path, state: &state)
            }
        }
        recordPatchOverrides(state: &state)
    }

    private func readPatch(_ url: URL) -> PatchReadResult {
        guard runtimeRootVerified, let node = runtimeNodeBinary,
              FileManager.default.isExecutableFile(atPath: node.path) else {
            return .unavailable("未提供已通过完整性校验的 managed Runtime Node/parser")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return .unavailable("无法读取 Cordis patch，不能把它当成空配置")
        }

        // The helper imports js-yaml only from the verified managed Runtime
        // root.  It never resolves modules from the Profile or current cwd.
        let helper = #"""
        const fs = require('node:fs');
        const path = require('node:path');
        const rawRoot = path.resolve(process.argv[1]);
        // Resolve the managed root the same way the candidate package roots
        // are resolved below. Swift and POSIX can spell symlinked ancestors
        // differently (e.g. /tmp vs /private/tmp); comparing real paths on
        // both sides keeps the containment check correct.
        let root = rawRoot;
        try { root = fs.realpathSync(rawRoot); } catch (_) {}
        const input = path.resolve(process.argv[2]);
        const inside = (candidate) => candidate === root || candidate.startsWith(root + path.sep);
        const packageCandidates = [
          path.join(root, 'node_modules', 'js-yaml'),
          ...(() => {
            const pnpm = path.join(root, 'node_modules', '.pnpm');
            try { return fs.readdirSync(pnpm, { withFileTypes: true })
              .filter((entry) => entry.isDirectory())
              .map((entry) => path.join(pnpm, entry.name, 'node_modules', 'js-yaml')); }
            catch (_) { return []; }
          })()
        ];
        let parser;
        for (const packageRoot of packageCandidates) {
          const packageFile = path.join(packageRoot, 'package.json');
          const entry = path.join(packageRoot, 'index.js');
          if (!fs.existsSync(packageFile) || !fs.existsSync(entry)) continue;
          let realRoot;
          try { realRoot = fs.realpathSync(packageRoot); } catch (_) { continue; }
          if (!inside(realRoot)) continue;
          try {
            parser = require(path.join(realRoot, 'index.js'));
            break;
          } catch (_) {}
        }
        if (!parser) {
          process.stdout.write(JSON.stringify({ kind: 'unavailable', detail: 'managed Runtime 中没有 js-yaml' }));
          process.exit(3);
        }
        const opaque = (value) => ({ __dshOpaque: true, value });
        const opaqueTags = [
          'tag:yaml.org,2002:js',
          'tag:yaml.org,2002:js/function', 'tag:yaml.org,2002:js/regexp',
          'tag:yaml.org,2002:js/undefined', 'tag:yaml.org,2002:js/instance'
        ];
        const tags = opaqueTags.flatMap((tag) => ['scalar', 'sequence', 'mapping']
          .map((kind) => new parser.Type(tag, { kind, resolve: () => true, construct: opaque })));
        const schema = parser.DEFAULT_SCHEMA.extend(tags);
        try {
          const value = parser.load(fs.readFileSync(input, 'utf8'), { schema, json: false });
          process.stdout.write(JSON.stringify({ kind: 'value', value }));
        } catch (error) {
          const mark = error && error.mark;
          process.stdout.write(JSON.stringify({
            kind: 'invalid', line: mark && Number.isInteger(mark.line) ? mark.line + 1 : null,
            detail: String(error && error.message || error)
          }));
          process.exit(2);
        }
        """#
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = node
        process.arguments = ["--input-type=commonjs", "--eval", helper,
                             runtimeHostRoot.path, url.path]
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .unavailable("无法启动 managed Runtime YAML helper")
        }
        let responseData = output.fileHandleForReading.readDataToEndOfFile()
        guard let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let kind = object["kind"] as? String else {
            let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            return .unavailable(stderr?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                                ? "YAML helper 无有效结果：\(stderr!)"
                                : "YAML helper 无有效结果")
        }
        switch kind {
        case "value":
            return .value(object["value"] ?? NSNull())
        case "invalid":
            let line = (object["line"] as? NSNumber)?.intValue
            return .invalid(line: line, detail: object["detail"] as? String ?? "YAML 无法解析")
        default:
            return .unavailable(object["detail"] as? String ?? "YAML helper 不可用")
        }
    }

    private func collectPatchEntries(_ value: Any, file: String, state: inout InspectionState) {
        guard let values = value as? [Any] else {
            state.issues.append(DshPluginInspectionIssue(
                code: "patchInvalid", severity: .error, file: file,
                detail: "Cordis patch 根值必须是数组"))
            state.patchInspectionUnavailable = true
            return
        }
        collectPatchSequence(values, file: file, state: &state)
    }

    private func collectPatchSequence(_ values: [Any], file: String,
                                      state: inout InspectionState) {
        for value in values {
            guard let map = value as? [String: Any] else {
                state.issues.append(DshPluginInspectionIssue(
                    code: "patchInvalid", severity: .error, file: file,
                    detail: "Cordis patch 条目必须是对象"))
                state.patchInspectionUnavailable = true
                continue
            }
            let id = map["id"] as? String
            let name = map["name"] as? String
            if id != nil || name != nil {
                guard id.map({ !$0.isEmpty }) ?? true,
                      name.map(safePatchName) ?? true else {
                    state.issues.append(DshPluginInspectionIssue(
                        code: "patchInvalid", severity: .error, file: file,
                        detail: "Cordis patch 条目的 id/name 无效"))
                    state.patchInspectionUnavailable = true
                    continue
                }
                let disabled: Bool
                if let raw = map["disabled"] {
                    if let bool = raw as? Bool {
                        disabled = bool
                    } else if let opaque = raw as? [String: Any],
                              opaque["__dshOpaque"] as? Bool == true {
                        // !!js is part of Cordis' patch contract. The helper
                        // deliberately parses it as inert data; accepting the
                        // expression does not execute it or claim that the
                        // target is statically disabled.
                        disabled = false
                    } else {
                        state.issues.append(DshPluginInspectionIssue(
                            code: "patchInvalid", severity: .error, file: file,
                            detail: "Cordis patch 的 disabled 必须是布尔值"))
                        state.patchInspectionUnavailable = true
                        continue
                    }
                } else {
                    disabled = false
                }
                let entry = CordisPatchEntry(id: id, name: name, disabled: disabled, file: file)
                state.patchEntries.append(entry)
                if let name { state.patchReferences.insert(packageRoot(name)) }
            }
            // `config` and other nested mappings are opaque to ownership
            // checks.  Only the documented insert sequence contains entries.
            if let insert = map["insert"] as? [Any] {
                collectPatchSequence(insert, file: file, state: &state)
            } else if let insert = map["insert"] as? [String: Any] {
                collectPatchSequence([insert], file: file, state: &state)
            }
        }
    }

    private func recordPatchOverrides(state: inout InspectionState) {
        // Cordis composes patches in order: each Bundle's patch, then the
        // Profile patch, then overlays. The same id in different files is
        // normal layering (a later Bundle intentionally refines an earlier
        // row); only duplicates inside one file are ambiguous authoring.
        var groups: [PatchFileIdentity: [CordisPatchEntry]] = [:]
        for entry in state.patchEntries {
            groups[PatchFileIdentity(entry), default: []].append(entry)
        }
        for (identity, entries) in groups where entries.count > 1 {
            guard let id = identity.id else { continue }
            state.issues.append(DshPluginInspectionIssue(
                code: "patchOverride", severity: .warning,
                detail: "Cordis patch 按顺序覆盖同一 id：\(id)"))
            state.uncertainties.append("patch id \(id) 在多个条目中出现，最终值由顺序决定")
        }
    }

    private func readManifest(_ url: URL, state: inout InspectionState,
                              missing: String, invalid: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else {
            state.issues.append(DshPluginInspectionIssue(
                code: missing, severity: .error, file: url.lastPathComponent,
                detail: FileManager.default.fileExists(atPath: url.path)
                    ? "无法读取 JSON manifest；检查结果不确定" : "JSON manifest 不存在"))
            return nil
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "DshPluginInspector", code: 1)
            }
            return object
        } catch {
            state.issues.append(DshPluginInspectionIssue(
                code: invalid, severity: .error, file: url.lastPathComponent,
                detail: "JSON manifest 损坏，无法完成检查"))
            return nil
        }
    }

    private func packageParts(_ name: String) -> [String]? {
        let p = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (p.count == 1 || p.count == 2),
              !p.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        if p.count == 2 && !p[0].hasPrefix("@") { return nil }
        return p
    }
    private func safeName(_ name: String) -> Bool { packageParts(name) != nil }
    private func packageRoot(_ name: String) -> String {
        let p = name.split(separator: "/", omittingEmptySubsequences: true)
        guard p.count > 1, p[0].hasPrefix("@") else { return String(p.first ?? "") }
        return "\(p[0])/\(p[1])"
    }
    private func safePatchName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 1, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return false
        }
        if parts[0].hasPrefix("@") {
            guard parts.count >= 2, !parts[1].isEmpty else { return false }
        } else if parts.count == 1 {
            return true
        }
        return safeName(packageRoot(name))
    }
    private func within(_ root: URL, _ candidate: URL) -> Bool {
        let r = root.standardizedFileURL.path, c = candidate.standardizedFileURL.path
        return c == r || c.hasPrefix(r + "/")
    }
}

private struct PackageRecord {
    let name: String
    let requestedSpec: String?
    let manifest: [String: Any]?
    let source: DshPluginInspectionSource
    let manifestURL: URL?
    let unreadable: Bool
}
private struct ResolvedManifest {
    let url: URL
    let source: DshPluginInspectionSource
}
private struct CordisPatchEntry {
    let id: String?
    let name: String?
    let disabled: Bool
    let file: String?
}
private struct PatchFileIdentity: Hashable {
    let file: String?
    let id: String?
    let name: String?
    init(_ value: CordisPatchEntry) {
        self.file = value.file
        if let id = value.id, !id.isEmpty {
            self.id = id
            self.name = nil
        } else {
            self.id = nil
            self.name = value.name
        }
    }
}
private enum PatchReadResult {
    case value(Any)
    case invalid(line: Int?, detail: String)
    case unavailable(String)
}
private struct InspectionState {
    var patchEntries: [CordisPatchEntry] = []
    var patchReferences = Set<String>()
    var runtimeSatisfiedBundles = Set<String>()
    var activeNames = Set<String>()
    var bundleOrder: [String]?
    var patchInspectionUnavailable = false
    var patchFiles: [String] = []
    var duplicateNames = Set<String>()
    var issues: [DshPluginInspectionIssue] = []
    var uncertainties: [String] = []
    var scannedFileCount = 0
    func result(profile: URL, runtime: URL, verified: Bool) -> DshPluginInspectionResult {
        DshPluginInspectionResult(profileDirectory: profile.path, runtimeHostRoot: runtime.path,
                                  runtimeRootVerified: verified, items: [],
                                  bundleOrder: bundleOrder ?? [],
                                  disabledBundleNames: Array(Set(patchEntries.filter(\.disabled).compactMap(\.name))),
                                  issues: issues, uncertainties: uncertainties,
                                  scannedFileCount: scannedFileCount,
                                  isComplete: !issues.contains { $0.severity == .error })
    }
}
