import Foundation

@main
struct DshDiagnosticExportProductHarness {
    @MainActor
    static func main() throws {
        let launchID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let generationID = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
        let context = DshDiagnosticLaunchContext(
            launchID: launchID,
            generationID: generationID,
            runtimeVersion: "0.1.2-alpha.5",
            profile: "desktop",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let shortJSONSamples = #"{"token":"abc"} {"cookie":"sid=abc"} {"authorization":"Bearer abc"}"#
        let ordinaryError = "Error: authorization is invalid; token is invalid; retry later"
        require(
            DshSecretRedactor().redactDiagnostic(ordinaryError) == ordinaryError,
            "ordinary error text remains readable"
        )
        let snapshot = DshDiagnosticSnapshot(
            context: context,
            phase: .connectionValidation,
            records: [DshDiagnosticRecord(
                launchID: launchID,
                generationID: generationID,
                timestamp: Date(timeIntervalSince1970: 101),
                phase: .connectionValidation,
                code: .connectionFailed,
                summary: "DSH 连接验证失败 \(homePath)/project",
                technicalDetail: "authorization: secret-token Cookie: cookie-value\n\(shortJSONSamples)\npath=\(homePath)/diagnostics",
                retryability: .retryable,
                source: .healthCheck,
                evidence: [DshDiagnosticEvidence(
                    source: .healthCheck,
                    confidence: .suspected,
                    summary: "Runtime 连接未完成",
                    pluginName: "sample-plugin",
                    generationID: generationID
                )]
            )],
            log: "authorization: secret-token\nCookie: cookie-value\n\(shortJSONSamples)\npath=\(homePath)/diagnostics\n",
            generatedAt: Date(timeIntervalSince1970: 102)
        )

        var copiedSummary: String?
        var savedPlan: DshDiagnosticExportPlan?
        let actions = DshRecoveryActions(
            copyDiagnosticSummary: { copiedSummary = $0 },
            saveDiagnosticExport: { savedPlan = $0 }
        )
        let exporter = DshDiagnosticExporter(
            redactor: DshSecretRedactor(secrets: ["secret-token", "cookie-value"])
        )
        let viewModel = DshRecoveryViewModel(
            launchID: launchID,
            snapshot: snapshot,
            actions: actions,
            diagnosticExporter: exporter,
            diagnosticMetadata: DshDiagnosticExportMetadata(
                appVersion: "1.0.0",
                buildNumber: "7",
                runtimeVersion: "0.1.2-alpha.5",
                systemArchitecture: "arm64",
                operatingSystem: nil,
                plugins: [DshDiagnosticExportPlugin(name: "sample-plugin", version: "2.0.0")]
            )
        )

        require(viewModel.diagnosticPreview?.contains("sample-plugin") == true, "preview keeps plugin metadata")
        require(viewModel.diagnosticPreview?.contains("secret-token") == false, "preview redacts authorization")
        require(viewModel.diagnosticPreview?.contains("cookie-value") == false, "preview redacts Cookie")
        requireNoSensitiveValues(viewModel.diagnosticPreview ?? "", homePath: homePath, label: "preview redacts short JSON values")
        requireNoSensitiveValues(viewModel.redactedDetails, homePath: homePath, label: "details redact short JSON values and home path")
        require(viewModel.diagnosticSummary.contains("阶段：验证连接"), "summary keeps error phase")
        require(viewModel.diagnosticSummary.contains("authorization") == false, "summary excludes process details")

        require(viewModel.requestCopyDiagnosticSummary(), "copy action should be accepted")
        require(copiedSummary?.contains("DSH 诊断摘要") == true, "copy action receives summary")
        require(copiedSummary?.contains("secret-token") == false, "copied summary is safe")
        requireNoSensitiveValues(copiedSummary ?? "", homePath: homePath, label: "copied summary redacts home path")

        require(viewModel.requestSaveDiagnosticExport(), "save action should be accepted")
        guard let savedPlan else {
            require(false, "save action should provide a plan")
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-diagnostic-export-product-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("diagnostic.json")
        try savedPlan.writeAtomically(to: destination)
        require(FileManager.default.fileExists(atPath: destination.path), "save plan writes JSON")
        let savedJSON = String(data: savedPlan.data, encoding: .utf8) ?? ""
        requireNoSensitiveValues(savedJSON, homePath: homePath, label: "saved JSON redacts short JSON values and home path")

        let failedDestination = root.appendingPathComponent("missing/diagnostic.json")
        do {
            try savedPlan.writeAtomically(to: failedDestination)
            require(false, "missing destination must fail")
        } catch {
            require(viewModel.snapshot != nil, "save failure keeps in-memory snapshot")
            require(viewModel.diagnosticPreview != nil, "save failure keeps in-memory preview")
        }

        // Exercise the exporter and recovery display with the default
        // redactor, without injecting any of the short fixture values as
        // runtime secrets. This catches regressions where only registered
        // secrets are removed.
        let defaultExporter = DshDiagnosticExporter()
        let directPreview = try defaultExporter.preview(snapshot: snapshot)
        requireNoSensitiveValues(directPreview.json, homePath: homePath, label: "default exporter preview")
        var defaultCopiedSummary: String?
        var defaultSavedPlan: DshDiagnosticExportPlan?
        let defaultViewModel = DshRecoveryViewModel(
            launchID: launchID,
            snapshot: snapshot,
            actions: DshRecoveryActions(
                copyDiagnosticSummary: { defaultCopiedSummary = $0 },
                saveDiagnosticExport: { defaultSavedPlan = $0 }
            ),
            diagnosticExporter: defaultExporter
        )
        requireNoSensitiveValues(defaultViewModel.redactedDetails, homePath: homePath, label: "default details")
        require(defaultViewModel.requestCopyDiagnosticSummary(), "default copy action should be accepted")
        requireNoSensitiveValues(defaultCopiedSummary ?? "", homePath: homePath, label: "default copied summary")
        require(defaultViewModel.requestSaveDiagnosticExport(), "default save action should be accepted")
        requireNoSensitiveValues(
            String(data: defaultSavedPlan?.data ?? Data(), encoding: .utf8) ?? "",
            homePath: homePath,
            label: "default saved JSON"
        )

        print("swift diagnostic export product harness passed")
    }

    @MainActor
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("diagnostic export assertion failed: \(message)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func requireNoSensitiveValues(_ value: String, homePath: String, label: String) {
        for sample in ["\"abc\"", "sid=abc", "Bearer abc", homePath] {
            require(!value.contains(sample), "\(label): \(sample) leaked")
        }
    }
}
