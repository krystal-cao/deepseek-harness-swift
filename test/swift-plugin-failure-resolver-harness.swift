import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func inspection(
    _ items: [DshPluginInspectionItem],
    bundleOrder: [String] = [],
    issues: [DshPluginInspectionIssue] = [],
    uncertainties: [String] = []
) -> DshPluginInspectionResult {
    DshPluginInspectionResult(
        profileDirectory: "/tmp/dsh-failure-profile",
        runtimeHostRoot: "/tmp/dsh-runtime",
        runtimeRootVerified: true,
        items: items,
        bundleOrder: bundleOrder,
        disabledBundleNames: [],
        issues: issues,
        uncertainties: uncertainties,
        scannedFileCount: 4,
        isComplete: issues.isEmpty && uncertainties.isEmpty
    )
}

private func item(
    _ name: String,
    kind: DshPluginInspectionKind = .library,
    source: DshPluginInspectionSource = .profile,
    status: DshPluginInspectionStatus = .healthy,
    confidence: DshPluginInspectionConfidence = .confirmed
) -> DshPluginInspectionItem {
    DshPluginInspectionItem(
        name: name,
        kind: kind,
        source: source,
        status: status,
        confidence: confidence,
        detail: nil
    )
}

private func record(
    code: DshDiagnosticCode,
    pluginName: String? = nil,
    confidence: DshDiagnosticConfidence = .confirmed,
    detail: String? = nil
) -> DshDiagnosticRecord {
    DshDiagnosticRecord(
        launchID: UUID(),
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        phase: .dependencyCheck,
        code: code,
        summary: "插件启动异常",
        technicalDetail: detail,
        retryability: .retryable,
        source: .pluginInspector,
        evidence: pluginName.map { name in
            [
            DshDiagnosticEvidence(
                source: .pluginInspector,
                confidence: confidence,
                summary: "结构化插件证据",
                pluginName: name
            )
            ]
        } ?? []
    )
}

@main
struct PluginFailureResolverHarness {
    static func main() {
        let resolver = DshPluginFailureResolver()

        let located = resolver.analyze(DshPluginFailureResolverInput(
            diagnostics: [record(code: .pluginConfigurationInvalid, pluginName: "alpha-plugin")],
            inspection: inspection([item("alpha-plugin"), item("healthy-plugin")]),
            modulePaths: ["/tmp/profile/node_modules/alpha-plugin/index.js"]
        ))
        require(located.locatedCandidates.count == 1, "explicit structured evidence should locate one plugin")
        require(located.locatedCandidates[0].pluginName == "alpha-plugin", "located plugin name")
        require(located.locatedCandidates[0].removalPlan.allowed, "located user plugin should have a preview")
        require(!located.locatedCandidates[0].removalPlan.isExecutable, "preview must never be executable")

        let diagnosticOnly = resolver.analyze(DshPluginFailureResolverInput(
            diagnostics: [record(code: .pluginConfigurationInvalid, pluginName: "diagnostic-only")]
        ))
        require(diagnosticOnly.candidates.first?.resolution == .located,
                "explicit diagnostics can still be reported as located")
        require(diagnosticOnly.candidates.first?.removalPlan.allowed == false,
                "diagnostic-only package must never be an allowed removal root")
        require(diagnosticOnly.candidates.first?.removalPlan.reason.contains("Inspector") == true,
                "absence of Inspector root proof should be explained")

        let shared = resolver.analyze(DshPluginFailureResolverInput(
            inspection: inspection([item("alpha-plugin"), item("beta-plugin")]),
            modulePaths: ["/tmp/profile/node_modules/shared-dependency/lib.js"],
            dependencyRelations: [DshPluginDependencyRelation(
                dependencyName: "shared-dependency",
                ownerPluginNames: ["alpha-plugin", "beta-plugin"],
                isShared: true
            )]
        ))
        require(shared.hasAmbiguity, "shared dependency must be ambiguous")
        require(shared.suspectedCandidates.count == 2, "both shared roots should be reported")
        require(shared.suspectedCandidates.allSatisfy { !$0.removalPlan.allowed }, "shared roots cannot be removed")

        let similar = resolver.analyze(DshPluginFailureResolverInput(
            diagnostics: [record(code: .pluginConfigurationInvalid, pluginName: "foo")],
            inspection: inspection([item("foo"), item("foo-extra")]),
            modulePaths: ["/tmp/profile/node_modules/foo/index.js"]
        ))
        require(similar.hasAmbiguity, "similar package names must be ambiguous")
        require(similar.candidates.first?.resolution == .suspected, "similar package must not be located")
        require(similar.candidates.first?.removalPlan.allowed == false, "similar package cannot have removal plan")

        let unresolvedPatch = resolver.analyze(DshPluginFailureResolverInput(
            inspection: inspection(
                [item("mystery-bundle", kind: .bundle, status: .unavailable, confidence: .unknown)],
                issues: [DshPluginInspectionIssue(
                    code: "patchInspectionUnavailable",
                    severity: .error,
                    detail: "无法解析 patch"
                )]
            )
        ))
        require(unresolvedPatch.candidates.first?.resolution == .unknown, "unresolved patch must remain unknown")
        require(unresolvedPatch.candidates.first?.removalPlan.allowed == false, "unresolved patch cannot be removed")

        let managed = resolver.analyze(DshPluginFailureResolverInput(
            diagnostics: [record(code: .pluginConfigurationInvalid, pluginName: "dsh-desktop-host")],
            inspection: inspection([item("dsh-desktop-host", kind: .runtimeCore)])
        ))
        require(managed.locatedCandidates.count == 1, "managed core can be located")
        require(managed.locatedCandidates[0].removalPlan.allowed == false, "managed core cannot be removed")
        require(managed.locatedCandidates[0].removalPlan.reason.contains("受管理"), "managed reason")

        for core in ["@deepseek-ai/dsh-host-webserver", "@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"] {
            let coreAnalysis = resolver.analyze(DshPluginFailureResolverInput(
                diagnostics: [record(code: .pluginConfigurationInvalid, pluginName: core)],
                inspection: inspection([item(core, kind: .bundle)])
            ))
            require(coreAnalysis.locatedCandidates.count == 1,
                    "standard core \(core) should retain its evidence status")
            require(coreAnalysis.locatedCandidates[0].removalPlan.allowed == false,
                    "standard core \(core) must not be removable")
            require(coreAnalysis.locatedCandidates[0].removalPlan.reason.contains("受管理"),
                    "standard core \(core) should explain its managed guard")
        }

        let runtimeHost = resolver.analyze(DshPluginFailureResolverInput(
            diagnostics: [record(code: .pluginConfigurationInvalid, pluginName: "runtime-bundle")],
            inspection: inspection([item("runtime-bundle", kind: .bundle, source: .runtimeHost)])
        ))
        require(runtimeHost.candidates.first?.removalPlan.allowed == false,
                "runtime-host Bundle ownership is not a user Profile root")

        let unknown = resolver.analyze(DshPluginFailureResolverInput(
            diagnostics: [record(code: .unknown, detail: "generic launch failure")]
        ))
        require(unknown.candidates.count == 1 && unknown.candidates[0].pluginName == nil, "generic failure has no guessed target")
        require(!unknown.candidates[0].removalPlan.isExecutable, "unknown result has no action")

        print("swift plugin failure resolver harness passed")
    }
}
