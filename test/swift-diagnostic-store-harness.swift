import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct DiagnosticStoreHarness {
    static func main() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("dsh-diagnostic-harness-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = root.appendingPathComponent("diagnostics.json")
        defer { try? fileManager.removeItem(at: root) }

        let launchID = UUID(uuidString: "0A6E8A8A-23A7-4EC2-8D6E-18B0A42A8D01")!
        let generationID = UUID(uuidString: "DDF3E39A-7F24-45F8-87CF-0CE6517F2B8B")!
        let staleGenerationID = UUID(uuidString: "7D0E8453-7F01-48BC-AFD7-0BE1D0AF32D6")!
        let otherLaunchID = UUID(uuidString: "AB4BAA9D-9A6A-4DD4-8AB4-B7C24D693C1A")!
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let store = DshDiagnosticStore(
            storageURL: archiveURL,
            maximumRecords: 3,
            maximumLogBytes: 64,
            now: { timestamp },
            redactor: DshSecretRedactor(secrets: ["fixture-secret"])
        )

        store.beginLaunch(DshDiagnosticLaunchContext(
            launchID: launchID,
            generationID: generationID,
            runtimeVersion: "0.1.2-alpha.5",
            profile: "desktop",
            startedAt: timestamp
        ))
        require(store.currentPhase == .preparing, "beginLaunch should enter preparing")
        require(store.setPhase(.dependencyCheck, launchID: launchID, generationID: generationID), "current phase should be accepted")

        require(store.appendLog(
            "Authorization: Bearer fixture-secret\n\u{4E2D}\u{6587}\u{4E2D}\u{6587}\u{4E2D}\u{6587}",
            launchID: launchID,
            generationID: generationID
        ), "current output should be accepted")
        let currentLog = store.diagnosticOutput(for: launchID)
        require(!currentLog.contains("fixture-secret"), "logs must redact known secrets")
        require(currentLog.contains(DshSecretRedactor.replacement), "logs should retain a redaction marker")
        require(Data(currentLog.utf8).count <= 64, "log buffer must remain bounded")

        let suspectedEvidence = DshDiagnosticEvidence(
            source: .pluginInspector,
            confidence: .suspected,
            summary: "plugin manifest references a missing package",
            pluginName: "fixture-plugin",
            generationID: generationID
        )
        let first = store.record(
            launchID: launchID,
            generationID: generationID,
            phase: .dependencyCheck,
            code: .pluginPackageMissing,
            summary: "插件包缺失",
            technicalDetail: "fixture-secret",
            retryability: .retryable,
            source: .pluginInspector,
            evidence: [suspectedEvidence]
        )
        require(first?.occurrenceCount == 1, "first failure should have one occurrence")
        require(first?.technicalDetail == DshSecretRedactor.replacement, "record detail must be redacted")

        let repeated = store.record(
            launchID: launchID,
            generationID: generationID,
            phase: .dependencyCheck,
            code: .pluginPackageMissing,
            summary: "插件包缺失",
            technicalDetail: "fixture-secret",
            retryability: .retryable,
            source: .pluginInspector,
            evidence: [suspectedEvidence]
        )
        require(repeated?.id == first?.id, "same failure should be deduplicated")
        require(repeated?.occurrenceCount == 2, "dedup should retain occurrence count")
        require(store.records(for: launchID).count == 1, "dedup should keep one record")

        let staleRecord = store.record(
            launchID: launchID,
            generationID: staleGenerationID,
            phase: .startingService,
            code: .processExited,
            summary: "stale process",
            retryability: .retryable,
            source: .processOutput
        )
        require(staleRecord == nil, "stale generation must be rejected")
        require(!store.appendLog("stale output", launchID: otherLaunchID, generationID: generationID), "stale launch output must be rejected")
        require(store.record(
            launchID: launchID,
            generationID: generationID,
            phase: .startingService,
            code: .processExited,
            summary: "current process",
            retryability: .retryable,
            source: .processOutput
        ) != nil, "current generation should remain accepted")

        store.beginLaunch(DshDiagnosticLaunchContext(
            launchID: otherLaunchID,
            generationID: staleGenerationID,
            runtimeVersion: "0.1.2-alpha.5",
            profile: "desktop",
            startedAt: timestamp
        ))
        require(store.diagnosticOutput(for: otherLaunchID).isEmpty, "new launch must not inherit old output")
        require(store.record(
            launchID: launchID,
            generationID: generationID,
            phase: .ready,
            code: .unknown,
            summary: "old launch",
            retryability: .unknown,
            source: .native
        ) == nil, "old launch records must be rejected after a new launch")

        let current = store.record(
            launchID: otherLaunchID,
            generationID: staleGenerationID,
            phase: .authentication,
            code: .authenticationFailed,
            summary: "认证失败",
            technicalDetail: "Authorization: Bearer fixture-secret",
            retryability: .retryable,
            source: .healthCheck,
            evidence: [DshDiagnosticEvidence(
                source: .healthCheck,
                confidence: .unknown,
                summary: "无法唯一判断是认证还是插件",
                generationID: staleGenerationID
            )]
        )
        require(current != nil, "new launch record should be accepted")

        let reloaded = DshDiagnosticStore(
            storageURL: archiveURL,
            maximumRecords: 3,
            maximumLogBytes: 64,
            now: { timestamp },
            redactor: DshSecretRedactor(secrets: ["fixture-secret"])
        )
        let persisted = reloaded.records(for: otherLaunchID)
        require(persisted.count == 1, "records should persist in a bounded archive")
        require(!persisted[0].technicalDetail!.contains("fixture-secret"), "persisted detail must stay redacted")

        require(store.endLaunch(launchID: otherLaunchID), "active launch should end by ID")
        require(store.snapshot(for: otherLaunchID) == nil, "ended launch should have no active snapshot")
        require(!store.setPhase(.ready, launchID: otherLaunchID, generationID: staleGenerationID), "ended launch must reject late events")

        let bindStore = DshDiagnosticStore(
            maximumLogBytes: 256,
            now: { timestamp },
            redactor: DshSecretRedactor(secrets: ["context-secret"])
        )
        let bindLaunchID = UUID(uuidString: "515AD7E7-8A02-47E1-9A6E-D6E92ED73133")!
        let firstGeneration = UUID(uuidString: "A9F63A6B-25B8-4C8C-A3A4-4AD0FDD80DC9")!
        let secondGeneration = UUID(uuidString: "B28A54B2-66DB-4867-8A6F-4FA3B5BA5BA1")!
        bindStore.beginLaunch(DshDiagnosticLaunchContext(
            launchID: bindLaunchID,
            runtimeVersion: "context-secret-runtime",
            profile: "context-secret-profile",
            startedAt: timestamp
        ))
        require(bindStore.appendLog("preparing before process generation", launchID: bindLaunchID), "preparing output should be retained")
        require(bindStore.bindGeneration(firstGeneration, launchID: bindLaunchID), "generation should bind to current launch")
        require(bindStore.bindGeneration(firstGeneration, launchID: bindLaunchID), "same generation should bind idempotently")
        require(!bindStore.bindGeneration(secondGeneration, launchID: bindLaunchID), "a bound launch must reject rebinding to another generation")
        require(bindStore.currentContext?.runtimeVersion?.contains("context-secret") == false, "context runtime metadata must be redacted")
        require(bindStore.currentContext?.profile?.contains("context-secret") == false, "context profile metadata must be redacted")
        require(!bindStore.diagnosticOutput(for: bindLaunchID).isEmpty, "binding generation must not clear preparing output")
        require(!bindStore.appendLog("old generation", launchID: bindLaunchID, generationID: secondGeneration), "different generation should be rejected")
        require(bindStore.appendLog("bound generation", launchID: bindLaunchID, generationID: firstGeneration), "bound generation should be accepted")

        let long = String(repeating: "界", count: 5_000)
        let longEvidence = DshDiagnosticEvidence(
            source: .pluginInspector,
            confidence: .unknown,
            summary: long,
            pluginName: long,
            generationID: firstGeneration
        )
        let longRecord = bindStore.record(
            launchID: bindLaunchID,
            generationID: firstGeneration,
            phase: .dependencyCheck,
            code: .unknown,
            summary: long,
            technicalDetail: "context-secret-\(long)",
            retryability: .unknown,
            source: .pluginInspector,
            evidence: [longEvidence]
        )!
        require(Data(longRecord.summary.utf8).count <= DshDiagnosticStore.defaultMaximumFieldBytes, "long summary must be bounded")
        require(Data(longRecord.evidence[0].summary.utf8).count <= DshDiagnosticStore.defaultMaximumFieldBytes, "long evidence must be bounded")
        require(longRecord.technicalDetail?.contains("context-secret") == false, "long detail must be redacted")
        require(String(data: Data(longRecord.summary.utf8), encoding: .utf8) != nil, "bounded summary must remain valid UTF8")

        let concurrentStore = DshDiagnosticStore(
            storageURL: root.appendingPathComponent("concurrent.json"),
            maximumRecords: 32,
            maximumArchiveBytes: 16 * 1024 * 1024,
            now: { timestamp }
        )
        let concurrentLaunchID = UUID(uuidString: "DBEE3E41-0567-4D2A-A7D5-68C4BC3DC4E1")!
        concurrentStore.beginLaunch(DshDiagnosticLaunchContext(launchID: concurrentLaunchID, startedAt: timestamp))
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            _ = concurrentStore.record(
                launchID: concurrentLaunchID,
                phase: .startingService,
                code: .unknown,
                summary: "concurrent-\(index)",
                retryability: .unknown,
                source: .native
            )
        }
        let concurrentReload = DshDiagnosticStore(
            storageURL: root.appendingPathComponent("concurrent.json"),
            maximumRecords: 32,
            maximumArchiveBytes: 16 * 1024 * 1024,
            now: { timestamp }
        )
        require(concurrentReload.lastLoadError == nil, "concurrent archive must remain valid")
        require(concurrentReload.records(for: concurrentLaunchID).count == 12, "concurrent persistence must retain all records")

        let boundedArchiveURL = root.appendingPathComponent("bounded.json")
        let boundedArchiveStore = DshDiagnosticStore(
            storageURL: boundedArchiveURL,
            maximumRecords: 4,
            maximumFieldBytes: 8 * 1024,
            maximumArchiveBytes: 1_200,
            now: { timestamp }
        )
        let boundedLaunchID = UUID(uuidString: "37B4AA5D-5AA2-4CC4-8F81-89F0E2E375A0")!
        boundedArchiveStore.beginLaunch(DshDiagnosticLaunchContext(
            launchID: boundedLaunchID,
            generationID: firstGeneration,
            runtimeVersion: String(repeating: "runtime-", count: 200),
            profile: String(repeating: "profile-", count: 200),
            startedAt: timestamp
        ))
        for index in 0..<3 {
            _ = boundedArchiveStore.record(
                launchID: boundedLaunchID,
                generationID: firstGeneration,
                phase: .dependencyCheck,
                code: .unknown,
                summary: "record-\(index)-" + String(repeating: "界", count: 2_000),
                technicalDetail: String(repeating: "detail-", count: 2_000),
                retryability: .unknown,
                source: .native,
                evidence: [DshDiagnosticEvidence(
                    source: .native,
                    confidence: .unknown,
                    summary: String(repeating: "evidence-", count: 500),
                    pluginName: "bounded-plugin",
                    generationID: firstGeneration
                )]
            )
        }
        let boundedSize = try! FileManager.default.attributesOfItem(atPath: boundedArchiveURL.path)[.size] as! NSNumber
        require(boundedSize.intValue <= 1_200, "encoded archive must respect the byte limit")
        let boundedReload = DshDiagnosticStore(
            storageURL: boundedArchiveURL,
            maximumRecords: 4,
            maximumFieldBytes: 8 * 1024,
            maximumArchiveBytes: 1_200,
            now: { timestamp }
        )
        require(boundedReload.lastLoadError == nil, "a bounded archive must remain readable")
        require(!boundedReload.records(for: boundedLaunchID).isEmpty, "bounded archive should retain the newest record when possible")

        let malformedURL = root.appendingPathComponent("malformed.json")
        try! Data("{malformed".utf8).write(to: malformedURL, options: .atomic)
        let malformedStore = DshDiagnosticStore(storageURL: malformedURL, now: { timestamp })
        require(malformedStore.lastLoadError != nil, "malformed archive should expose a load error")
        require(malformedStore.records().isEmpty, "malformed archive should not create records")

        let oversizedURL = root.appendingPathComponent("oversized.json")
        try! Data(repeating: 0x78, count: 257).write(to: oversizedURL, options: .atomic)
        let oversizedStore = DshDiagnosticStore(
            storageURL: oversizedURL,
            maximumArchiveBytes: 256,
            now: { timestamp }
        )
        require(oversizedStore.lastLoadError?.contains("大小") == true, "oversized archive should be rejected before decoding")

        print("swift diagnostic store harness passed")
    }
}
