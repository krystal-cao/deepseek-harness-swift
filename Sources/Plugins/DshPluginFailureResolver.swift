import Foundation

/// The resolver's conclusion is deliberately weaker than a command.  It
/// explains which Profile package is associated with the evidence, while the
/// removal preview below remains an explicit, non-executable plan.
public enum DshPluginFailureResolution: String, Codable, CaseIterable, Sendable {
    case located = "已定位"
    case suspected = "疑似相关"
    case unknown = "无法确定"
}

public enum DshPluginFailureEvidenceSource: String, Codable, Sendable {
    case structuredDiagnostic = "结构化异常"
    case diagnosticEvidence = "诊断证据"
    case modulePath = "模块路径"
    case inspection = "只读检查"
    case bundleRelation = "Bundle 关系"
    case dependencyRelation = "依赖关系"
    case safetyRule = "安全规则"
}

public struct DshPluginFailureEvidence: Codable, Equatable, Sendable {
    public let source: DshPluginFailureEvidenceSource
    public let confidence: DshDiagnosticConfidence
    public let summary: String
    public let relatedPath: String?

    public init(
        source: DshPluginFailureEvidenceSource,
        confidence: DshDiagnosticConfidence,
        summary: String,
        relatedPath: String? = nil
    ) {
        self.source = source
        self.confidence = confidence
        self.summary = summary
        self.relatedPath = relatedPath
    }
}

/// A relation is supplied by a trusted package/inspector boundary.  A
/// dependency with multiple roots is never treated as belonging to one root,
/// even if a module path happens to name that dependency.
public struct DshPluginDependencyRelation: Codable, Equatable, Sendable {
    public let dependencyName: String
    public let ownerPluginNames: [String]
    public let isShared: Bool

    public init(
        dependencyName: String,
        ownerPluginNames: [String],
        isShared: Bool = false
    ) {
        self.dependencyName = dependencyName
        self.ownerPluginNames = Array(Set(ownerPluginNames)).sorted()
        self.isShared = isShared || Set(ownerPluginNames).count > 1
    }
}

/// All fields are snapshots. The resolver never reads or writes the Profile,
/// executes pnpm, or mutates patch/config files.
public struct DshPluginFailureResolverInput: Sendable {
    public let diagnostics: [DshDiagnosticRecord]
    public let inspection: DshPluginInspectionResult?
    public let modulePaths: [String]
    public let dependencyRelations: [DshPluginDependencyRelation]
    public let managedPluginNames: Set<String>

    public init(
        diagnostics: [DshDiagnosticRecord] = [],
        inspection: DshPluginInspectionResult? = nil,
        modulePaths: [String] = [],
        dependencyRelations: [DshPluginDependencyRelation] = [],
        managedPluginNames: Set<String> = [
            "dsh-desktop-host",
            "@deepseek-ai/dsh-host-webserver"
        ]
    ) {
        self.diagnostics = diagnostics
        self.inspection = inspection
        self.modulePaths = modulePaths
        self.dependencyRelations = dependencyRelations
        self.managedPluginNames = managedPluginNames
    }
}

/// Resolver output remains a preview only. isExecutable is permanently false
/// here; the recovery UI may create an executable intent only after its own
/// fresh token/launch/generation/Profile checks, and the MainWindow
/// coordinator must still stop the service and enter the P01 transaction.
public struct DshPluginRemovalPlanPreview: Codable, Equatable, Sendable {
    /// Opaque identity of this read-only plan.  A coordinator must echo this
    /// token when it re-validates a plan; it is never a substitute for the
    /// current launch/generation checks.
    public let token: UUID
    public let pluginName: String?
    public let allowed: Bool
    public let requiresExplicitConfirmation: Bool
    public let affectedDependencies: [String]
    public let reason: String

    public init(
        token: UUID = UUID(),
        pluginName: String?,
        allowed: Bool,
        requiresExplicitConfirmation: Bool = true,
        affectedDependencies: [String] = [],
        reason: String
    ) {
        self.token = token
        self.pluginName = pluginName
        self.allowed = allowed
        self.requiresExplicitConfirmation = requiresExplicitConfirmation
        self.affectedDependencies = affectedDependencies.sorted()
        self.reason = reason
    }

    /// This resolver has no mutation authority. Keeping the property explicit
    /// prevents callers from mistaking an allowed preview for a command.
    public var isExecutable: Bool { false }
}

public struct DshPluginFailureCandidate: Codable, Equatable, Sendable {
    public let pluginName: String?
    public let resolution: DshPluginFailureResolution
    public let evidence: [DshPluginFailureEvidence]
    public let removalPlan: DshPluginRemovalPlanPreview

    public init(
        pluginName: String?,
        resolution: DshPluginFailureResolution,
        evidence: [DshPluginFailureEvidence],
        removalPlan: DshPluginRemovalPlanPreview
    ) {
        self.pluginName = pluginName
        self.resolution = resolution
        self.evidence = evidence
        self.removalPlan = removalPlan
    }
}

public struct DshPluginFailureAnalysis: Codable, Equatable, Sendable {
    public let candidates: [DshPluginFailureCandidate]
    public let hasAmbiguity: Bool
    public let summary: String

    public init(candidates: [DshPluginFailureCandidate], hasAmbiguity: Bool, summary: String) {
        self.candidates = candidates
        self.hasAmbiguity = hasAmbiguity
        self.summary = summary
    }

    public var locatedCandidates: [DshPluginFailureCandidate] {
        candidates.filter { $0.resolution == .located }
    }

    public var suspectedCandidates: [DshPluginFailureCandidate] {
        candidates.filter { $0.resolution == .suspected }
    }
}

public struct DshPluginFailureResolver: Sendable {
    private static let standardManagedPluginNames: Set<String> = [
        "dsh-desktop-host",
        "@deepseek-ai/dsh-host-webserver",
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app"
    ]

    public init() {}

    public func analyze(_ input: DshPluginFailureResolverInput) -> DshPluginFailureAnalysis {
        var observations: [String: Observation] = [:]
        let inspectedItems = input.inspection?.items ?? []
        let inspectedNames = Set(inspectedItems.map(\.name))
        let managedNames = input.managedPluginNames
            .union(Self.standardManagedPluginNames)
            .union(inspectedItems.filter { $0.kind == .runtimeCore }.map(\.name))

        func observe(
            _ name: String,
            source: DshPluginFailureEvidenceSource,
            confidence: DshDiagnosticConfidence,
            summary: String,
            path: String? = nil,
            explicit: Bool = false
        ) {
            guard Self.isPlausiblePackageName(name) else { return }
            var value = observations[name] ?? Observation()
            value.evidence.append(DshPluginFailureEvidence(
                source: source,
                confidence: confidence,
                summary: summary,
                relatedPath: path
            ))
            value.explicit = value.explicit || explicit
            observations[name] = value
        }

        for record in input.diagnostics {
            let diagnosticRelevant = record.code == .pluginConfigurationInvalid
                || record.code == .pluginPackageMissing
            for evidence in record.evidence {
                for path in Self.modulePaths(in: evidence.summary) {
                    if let pathName = Self.packageName(fromModulePath: path) {
                        observe(
                            pathName,
                            source: .modulePath,
                            confidence: .suspected,
                            summary: "诊断证据包含模块路径，尚未证明因果关系",
                            path: path
                        )
                    }
                }
                guard let name = evidence.pluginName else { continue }
                let exactName = inspectedNames.contains(name) || Self.isPlausiblePackageName(name)
                guard exactName else { continue }
                let confidence = evidence.confidence
                observe(
                    name,
                    source: diagnosticRelevant ? .structuredDiagnostic : .diagnosticEvidence,
                    confidence: confidence,
                    summary: evidence.summary,
                    explicit: confidence == .confirmed && diagnosticRelevant
                )
            }

            let diagnosticText = [record.summary, record.technicalDetail]
                .compactMap { $0 }
                .joined(separator: " ")
            let paths = Self.modulePaths(in: diagnosticText)
            for path in paths {
                if let name = Self.packageName(fromModulePath: path) {
                    observe(
                        name,
                        source: .modulePath,
                        confidence: .suspected,
                        summary: "结构化异常文本包含模块路径，尚未证明因果关系",
                        path: path
                    )
                }
            }
        }

        for path in input.modulePaths {
            guard let name = Self.packageName(fromModulePath: path) else { continue }
            observe(
                name,
                source: .modulePath,
                confidence: .suspected,
                summary: "模块路径指向该包，但路径本身不是因果证明",
                path: path
            )
        }

        for item in inspectedItems {
            guard Self.isProblematic(item.status) else { continue }
            observe(
                item.name,
                source: .inspection,
                confidence: item.confidence == .confirmed ? .suspected : .unknown,
                summary: "只读检查：\(item.status.rawValue)\(item.detail.map { "：\($0)" } ?? "")"
            )
        }

        // A failed module can be a dependency shared by multiple roots. Add
        // relation evidence to every owner, then mark all such owners
        // ambiguous; no single root is safe to remove.
        var sharedDependencyNames = Set<String>()
        var sharedOwnerNames = Set<String>()
        for relation in input.dependencyRelations {
            guard observations[relation.dependencyName] != nil else { continue }
            let shared = relation.isShared || relation.ownerPluginNames.count != 1
            if shared {
                sharedDependencyNames.insert(relation.dependencyName)
                sharedOwnerNames.formUnion(relation.ownerPluginNames)
            }
            for owner in relation.ownerPluginNames {
                observe(
                    owner,
                    source: .dependencyRelation,
                    confidence: shared ? .unknown : .suspected,
                    summary: shared
                        ? "该依赖由多个插件共同使用，无法唯一归属：\(relation.dependencyName)"
                        : "模块依赖关系指向该插件：\(relation.dependencyName)"
                )
            }
        }

        // A Bundle relation helps explain why a candidate is in the runtime,
        // but it does not establish that the Bundle caused the failure.
        if let inspection = input.inspection {
            let composed = Set(inspection.bundleOrder)
            for name in observations.keys where composed.contains(name) {
                observe(
                    name,
                    source: .bundleRelation,
                    confidence: .suspected,
                    summary: "该包出现在 Profile 的 Bundle 组合顺序中"
                )
            }
        }

        let unresolvedPatch = input.inspection?.items.contains {
            $0.status == .unavailable || $0.status == .uncertain
        } == true || input.inspection?.issues.contains {
            $0.code == "patchInspectionUnavailable"
                || $0.code == "patchReferenceMissing"
        } == true || !(input.inspection?.uncertainties.isEmpty ?? true)

        let namesBeforeSimilarity = Set(observations.keys)
        var similarNames = Set<String>()
        for name in namesBeforeSimilarity {
            let peers = inspectedNames.filter { peer in
                peer != name && Self.packageNamesAreSimilar(name, peer)
            }
            if !peers.isEmpty {
                similarNames.insert(name)
                for peer in peers where observations[peer] != nil {
                    similarNames.insert(peer)
                }
            }
        }

        var ambiguity = unresolvedPatch || !sharedDependencyNames.isEmpty || !similarNames.isEmpty
        var candidates: [DshPluginFailureCandidate] = []
        for name in observations.keys.sorted() {
            guard var observation = observations[name] else { continue }
            // A package named only as the right-hand side of a dependency
            // edge is not itself a removable root. Report its owner roots;
            // retaining this guard prevents a shared transitive dependency
            // from becoming a misleading third removal target.
            let isDependencyOnly = input.dependencyRelations.contains {
                $0.dependencyName == name
            } && !inspectedNames.contains(name) && !observation.explicit
            if isDependencyOnly { continue }
            let isManaged = managedNames.contains(name)
                || inspectedItems.first(where: { $0.name == name })?.kind == .runtimeCore
            let exactInspection = inspectedItems.first(where: { $0.name == name })
            let isInstalledProfileRoot = Self.isInstalledProfileRoot(
                exactInspection,
                dependencyRelations: input.dependencyRelations
            )
            let explicit = observation.explicit
            let resolution: DshPluginFailureResolution
            if isManaged {
                resolution = explicit ? .located : .suspected
                observation.evidence.append(DshPluginFailureEvidence(
                    source: .safetyRule,
                    confidence: .confirmed,
                    summary: "受管理核心组件禁止移除"
                ))
            } else if unresolvedPatch && !explicit {
                resolution = .unknown
            } else if explicit && !sharedOwnerNames.contains(name) && !similarNames.contains(name) {
                resolution = .located
            } else if !observation.evidence.isEmpty {
                resolution = .suspected
            } else {
                resolution = .unknown
            }

            let relatedDependencies = input.dependencyRelations
                .filter { $0.ownerPluginNames.contains(name) }
                .map(\.dependencyName)
            let plan: DshPluginRemovalPlanPreview
            if isManaged {
                plan = DshPluginRemovalPlanPreview(
                    pluginName: name,
                    allowed: false,
                    affectedDependencies: relatedDependencies,
                    reason: "受管理核心组件不能由用户移除。"
                )
            } else if unresolvedPatch || sharedOwnerNames.contains(name) || similarNames.contains(name) {
                plan = DshPluginRemovalPlanPreview(
                    pluginName: name,
                    allowed: false,
                    affectedDependencies: relatedDependencies,
                    reason: "证据存在歧义或 patch 无法解析，暂不生成可执行移除计划。"
                )
            } else if resolution == .located {
                if isInstalledProfileRoot {
                    plan = DshPluginRemovalPlanPreview(
                        pluginName: name,
                        allowed: true,
                        affectedDependencies: relatedDependencies,
                        reason: "Inspector 已确认 \(name) 是 Profile 中已安装的根插件；可在明确确认后预览移除，本结果不执行修改。"
                    )
                } else {
                    plan = DshPluginRemovalPlanPreview(
                        pluginName: name,
                        allowed: false,
                        affectedDependencies: relatedDependencies,
                        reason: "诊断证据虽点名 \(name)，但 Inspector 未确认其为 Profile 中已安装的根插件或 Bundle ownership。"
                    )
                }
            } else {
                plan = DshPluginRemovalPlanPreview(
                    pluginName: name,
                    allowed: false,
                    affectedDependencies: relatedDependencies,
                    reason: "尚未唯一定位到可移除的插件。"
                )
            }
            candidates.append(DshPluginFailureCandidate(
                pluginName: name,
                resolution: resolution,
                evidence: observation.evidence,
                removalPlan: plan
            ))
        }

        if candidates.isEmpty {
            ambiguity = true
            candidates = [DshPluginFailureCandidate(
                pluginName: nil,
                resolution: .unknown,
                evidence: [],
                removalPlan: DshPluginRemovalPlanPreview(
                    pluginName: nil,
                    allowed: false,
                    requiresExplicitConfirmation: false,
                    reason: "没有足够的结构化证据唯一定位插件，不生成移除目标。"
                )
            )]
        }

        let summary: String
        if let located = candidates.first(where: { $0.resolution == .located }) {
            summary = "已定位插件：\(located.pluginName ?? "未知")；移除仅可作为显式预览。"
        } else if candidates.contains(where: { $0.resolution == .suspected }) {
            summary = "发现疑似相关插件，但证据不足以安全确定唯一移除目标。"
        } else {
            summary = "无法确定故障插件；未生成可执行移除目标。"
        }
        return DshPluginFailureAnalysis(
            candidates: candidates,
            hasAmbiguity: ambiguity,
            summary: summary
        )
    }

    private struct Observation {
        var evidence: [DshPluginFailureEvidence] = []
        var explicit = false
    }

    private static func isProblematic(_ status: DshPluginInspectionStatus) -> Bool {
        switch status {
        case .healthy, .disabled:
            return false
        case .missingPackage, .notComposed, .duplicateBundle,
             .patchReferenceMissing, .unavailable, .uncertain:
            return true
        }
    }

    /// The resolver can only authorize a root that the inspector found in the
    /// user Profile and classified as materialized. Runtime-host and
    /// unresolved entries, missing/uncertain/duplicate Bundle states, and
    /// transitive dependency names are never removal roots.
    private static func isInstalledProfileRoot(
        _ item: DshPluginInspectionItem?,
        dependencyRelations: [DshPluginDependencyRelation]
    ) -> Bool {
        guard let item,
              item.source == .profile,
              item.kind == .library || item.kind == .bundle,
              item.status == .healthy || item.status == .disabled else {
            return false
        }
        return !dependencyRelations.contains { $0.dependencyName == item.name }
    }

    private static func isPlausiblePackageName(_ value: String) -> Bool {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !name.contains(where: { $0 == "/" && !name.hasPrefix("@") }),
              !name.contains("."),
              !name.contains("package"),
              !name.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return false
        }
        if name.hasPrefix("@") {
            let parts = name.split(separator: "/")
            return parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
        }
        return !name.hasPrefix("/") && !name.hasPrefix("-")
    }

    private static func packageName(fromModulePath path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard let marker = components.lastIndex(of: "node_modules") else { return nil }
        let start = components.index(after: marker)
        guard start < components.endIndex else { return nil }
        if components[start].hasPrefix("@") {
            guard components.index(start, offsetBy: 1, limitedBy: components.endIndex) != components.endIndex else {
                return nil
            }
            let end = components.index(start, offsetBy: 2)
            guard end <= components.endIndex else { return nil }
            return components[start..<end].joined(separator: "/")
        }
        return String(components[start])
    }

    private static func modulePaths(in text: String) -> [String] {
        let pattern = #"(?:^|[\s\"'])([^\s\"']*node_modules[/\\][^\s\"']+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: ",.;:)]}"))
        }
    }

    private static func packageNamesAreSimilar(_ lhs: String, _ rhs: String) -> Bool {
        let left = packageStem(lhs)
        let right = packageStem(rhs)
        guard left.count >= 3, right.count >= 3 else { return false }
        return left == right || left.hasPrefix(right) || right.hasPrefix(left)
    }

    private static func packageStem(_ name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? name
        return last
            .replacingOccurrences(of: #"[-_.](plugin|bundle|desktop|web|core|host)$"#, with: "", options: .regularExpression)
    }
}
