import Foundation

func requireRecovery(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct RecoveryHarness {
    @MainActor
    static func main() {
        let launchID = UUID(uuidString: "0B4A2F20-A6B5-4FA0-9D56-5A5C6E5C3E8A")!
        let oldLaunchID = UUID(uuidString: "BA945EC2-1AA5-4394-BB9A-A8BB90FE2F2B")!
        let generationID = UUID(uuidString: "99C8D7E1-6C9F-4B6D-8E03-AD3D6D0F4FC5")!
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let token = String(repeating: "a", count: 43)

        let record = DshDiagnosticRecord(
            launchID: launchID,
            generationID: generationID,
            runtimeVersion: "1.0",
            profile: "desktop",
            timestamp: timestamp,
            phase: .startingService,
            code: .processExited,
            summary: "服务进程已退出",
            technicalDetail: "Authorization: Bearer \(token)",
            retryability: .retryable,
            source: .processOutput,
            evidence: [DshDiagnosticEvidence(
                source: .processOutput,
                confidence: .suspected,
                summary: "进程输出需要进一步检查",
                pluginName: "fixture-plugin",
                generationID: generationID
            )]
        )
        let snapshot = DshDiagnosticSnapshot(
            context: DshDiagnosticLaunchContext(
                launchID: launchID,
                generationID: generationID,
                runtimeVersion: "1.0",
                profile: "desktop",
                startedAt: timestamp
            ),
            phase: .startingService,
            records: [record],
            log: "Authorization: Bearer \(token)",
            generatedAt: timestamp
        )

        var retryCount = 0
        var settingsCount = 0
        var safeModeCount = 0
        var firstRetryRequest: DshRecoveryActionRequest?
        var secondRetryRequest: DshRecoveryActionRequest?
        var safeModeRequest: DshRecoveryActionRequest?
        var removalRequest: DshRecoveryPluginRemovalRequest?
        let actions = DshRecoveryActions(
            retry: { request in
                retryCount += 1
                if firstRetryRequest == nil {
                    firstRetryRequest = request
                } else {
                    secondRetryRequest = request
                }
            },
            openSettings: { _ in settingsCount += 1 },
            startSafeMode: { request in
                safeModeCount += 1
                safeModeRequest = request
            },
            removePluginAndRetry: { request in
                removalRequest = request
            }
        )
        let viewModel = DshRecoveryViewModel(
            launchID: launchID,
            snapshot: snapshot,
            actions: actions,
            redactor: DshSecretRedactor(secrets: [token]),
            originalProfilePath: "/tmp/dsh/profiles/desktop"
        )

        requireRecovery(viewModel.phase == .startingService, "matching snapshot should expose its phase")
        requireRecovery(viewModel.failureSummary == "服务进程已退出", "matching snapshot should expose its failure summary")
        requireRecovery(viewModel.redactedDetails.contains(DshSecretRedactor.replacement), "details should retain a redaction marker")
        requireRecovery(!viewModel.redactedDetails.contains(token), "details must not expose credentials")
        requireRecovery(!viewModel.isSafeModeAvailable, "safe mode should be unavailable by default")

        let longRecord = DshDiagnosticRecord(
            launchID: launchID,
            generationID: generationID,
            timestamp: timestamp,
            phase: .loadingInterface,
            code: .pageLoadFailed,
            summary: String(repeating: "界", count: 30_000),
            technicalDetail: String(repeating: "界", count: 30_000),
            retryability: .retryable,
            source: .webKit
        )
        let longSnapshot = DshDiagnosticSnapshot(
            context: snapshot.context,
            phase: .loadingInterface,
            records: [longRecord],
            log: String(repeating: "界", count: 30_000),
            generatedAt: timestamp.addingTimeInterval(1)
        )
        let boundedViewModel = DshRecoveryViewModel(
            launchID: launchID,
            snapshot: longSnapshot,
            maximumDetailBytes: 64
        )
        let boundedDetailsData = Data(boundedViewModel.redactedDetails.utf8)
        requireRecovery(!boundedViewModel.redactedDetails.isEmpty, "long UTF8 details should remain visible after bounding")
        requireRecovery(boundedDetailsData.count <= 64, "long UTF8 details should respect the byte bound")
        requireRecovery(String(data: boundedDetailsData, encoding: .utf8) != nil, "bounded UTF8 details must remain valid")

        let staleSnapshot = DshDiagnosticSnapshot(
            context: DshDiagnosticLaunchContext(launchID: oldLaunchID, startedAt: timestamp),
            phase: .ready,
            records: [],
            log: "stale",
            generatedAt: timestamp.addingTimeInterval(100)
        )
        requireRecovery(!viewModel.apply(staleSnapshot, for: oldLaunchID), "old launch snapshot must be discarded")
        requireRecovery(viewModel.phase == .startingService, "discarding old launch must preserve visible state")

        let olderSameLaunch = DshDiagnosticSnapshot(
            context: snapshot.context,
            phase: .preparing,
            records: [],
            log: "older",
            generatedAt: timestamp.addingTimeInterval(-1)
        )
        requireRecovery(!viewModel.apply(olderSameLaunch, for: launchID), "older same-launch snapshot must be discarded")
        requireRecovery(viewModel.phase == .startingService, "older event must not revert the phase")

        requireRecovery(!viewModel.requestSafeMode(), "unavailable safe mode must not dispatch")
        requireRecovery(safeModeCount == 0, "unavailable safe mode must not invoke its callback")
        requireRecovery(viewModel.actionMessage == "安全模式尚未接入。", "unavailable safe mode should explain why")

        requireRecovery(viewModel.requestRetry(), "first retry request should be accepted")
        requireRecovery(retryCount == 1, "retry callback should be invoked once")
        requireRecovery(!viewModel.requestRetry(), "duplicate retry should be rejected while in flight")
        requireRecovery(!viewModel.requestOpenSettings(), "other actions should be blocked while a request is in flight")
        requireRecovery(retryCount == 1 && settingsCount == 0, "in-flight guard should prevent duplicate callbacks")
        let oldRequest = DshRecoveryActionRequest(launchID: oldLaunchID, action: .retry)
        requireRecovery(!viewModel.finishAction(oldRequest), "old launch completion must not clear an action")
        requireRecovery(viewModel.isActionInFlight, "old completion must leave the request in flight")
        requireRecovery(viewModel.finishAction(firstRetryRequest!), "current launch completion should clear an action")
        requireRecovery(!viewModel.isActionInFlight, "completed action should no longer be in flight")
        requireRecovery(firstRetryRequest!.sequence > 0, "action request should carry a non-zero completion sequence")
        requireRecovery(!viewModel.finishAction(firstRetryRequest!.completionToken), "a completed request token must not finish again")

        requireRecovery(viewModel.requestRetry(), "retry should be available after completion")
        requireRecovery(retryCount == 2, "second retry should dispatch once")
        requireRecovery(secondRetryRequest!.sequence > firstRetryRequest!.sequence, "action sequences should increase")
        requireRecovery(!viewModel.finishAction(firstRetryRequest!.completionToken), "a stale completion token must not finish a later request")
        requireRecovery(!viewModel.finishAction(firstRetryRequest!), "a previous request token must not finish a new request")
        requireRecovery(viewModel.finishAction(secondRetryRequest!, message: "重试仍未完成"), "second retry should be finishable")
        requireRecovery(viewModel.actionMessage == "重试仍未完成", "completion message should be exposed")

        let locatedSnapshot = DshDiagnosticSnapshot(
            context: snapshot.context,
            phase: .dependencyCheck,
            records: [DshDiagnosticRecord(
                launchID: launchID,
                generationID: generationID,
                timestamp: timestamp.addingTimeInterval(2),
                phase: .dependencyCheck,
                code: .pluginConfigurationInvalid,
                summary: "插件配置失败",
                retryability: .retryable,
                source: .pluginInspector,
                evidence: [DshDiagnosticEvidence(
                    source: .pluginInspector,
                    confidence: .confirmed,
                    summary: "唯一根插件配置无效",
                    pluginName: "fixture-plugin",
                    generationID: generationID
                )]
            )],
            log: "",
            generatedAt: timestamp.addingTimeInterval(2)
        )
        requireRecovery(viewModel.apply(locatedSnapshot, for: launchID), "newer plugin snapshot should be accepted")
        viewModel.setPluginInspection(DshPluginInspectionResult(
            profileDirectory: "/tmp/dsh/profiles/desktop",
            runtimeHostRoot: "/tmp/dsh/runtime",
            runtimeRootVerified: true,
            items: [DshPluginInspectionItem(
                name: "fixture-plugin",
                kind: .library,
                source: .profile,
                status: .healthy,
                confidence: .confirmed
            )],
            bundleOrder: [],
            disabledBundleNames: [],
            issues: [],
            uncertainties: [],
            scannedFileCount: 1,
            isComplete: true
        ))
        requireRecovery(viewModel.pluginFailureAnalysis?.locatedCandidates.count == 1,
                        "unique structured plugin evidence should be located")
        requireRecovery(viewModel.canRequestPluginRemoval,
                        "exact installed desktop root should expose removal intent")
        requireRecovery(viewModel.requestRemovePluginAndRetry(),
                        "removal intent should dispatch once")
        requireRecovery(removalRequest?.pluginName == "fixture-plugin",
                        "removal intent should carry the resolved root")
        requireRecovery(removalRequest?.isExecutable == true,
                        "only a fully validated intent is executable")
        requireRecovery(viewModel.isFreshPluginRemovalRequest(removalRequest!),
                        "fresh removal intent should retain token and generation identity")
        let stalePathRequest = DshRecoveryPluginRemovalRequest(
            id: removalRequest!.id,
            launchID: removalRequest!.launchID,
            planToken: removalRequest!.planToken,
            pluginName: removalRequest!.pluginName,
            generationID: removalRequest!.generationID,
            originalProfile: removalRequest!.originalProfile,
            originalProfilePath: "/tmp/dsh/profiles/web"
        )
        requireRecovery(!viewModel.isFreshPluginRemovalRequest(stalePathRequest),
                        "a web Profile path must invalidate the removal intent")
        requireRecovery(viewModel.finishPluginRemoval(removalRequest!),
                        "coordinator should be able to settle removal intent")

        viewModel.setSafeModeAvailability(true)
        requireRecovery(viewModel.requestSafeMode(), "available safe mode should be accepted")
        requireRecovery(safeModeCount == 1, "safe mode callback should be invoked once")
        requireRecovery(!viewModel.requestSafeMode(), "duplicate safe mode should be rejected while in flight")
        requireRecovery(viewModel.finishAction(safeModeRequest!), "safe mode completion should clear its request")

        requireRecovery(viewModel.requestOpenSettings(), "settings action should be accepted when idle")
        requireRecovery(settingsCount == 1, "settings callback should be invoked once")
        requireRecovery(viewModel.finishAction(viewModel.actionRequest!), "settings action should be finishable")

        print("swift recovery harness passed")
    }
}
