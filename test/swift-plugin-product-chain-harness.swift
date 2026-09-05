import Foundation

private enum HarnessError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class ProductFixture: @unchecked Sendable {
    let fileManager = FileManager.default
    let dshHome: URL
    let fixtureRoot: URL
    let desktop: URL
    let web: URL
    let operationStore: URL
    let globalConfig: URL
    let fakeLog: URL
    let baselineManifest: Data
    let baselineA: Data
    let baselineB: Data

    init() throws {
        guard let home = ProcessInfo.processInfo.environment["DSH_HOME"], !home.isEmpty,
              let fixture = ProcessInfo.processInfo.environment["DSH_PLUGIN_FIXTURE_ROOT"], !fixture.isEmpty,
              let global = ProcessInfo.processInfo.environment["DSH_FAKE_PNPM_GLOBAL_CONFIG"], !global.isEmpty,
              let log = ProcessInfo.processInfo.environment["DSH_FAKE_PNPM_LOG"], !log.isEmpty else {
            throw HarnessError.failed("isolated product-chain environment is incomplete")
        }
        dshHome = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
        fixtureRoot = URL(fileURLWithPath: fixture, isDirectory: true).standardizedFileURL
        desktop = DshPluginManager.profileDirectory(for: .desktop)
        web = DshPluginManager.profileDirectory(for: .web)
        operationStore = DshStateManager.appSupportDirectory.appendingPathComponent("dsh-plugin-operation.json")
        globalConfig = URL(fileURLWithPath: global, isDirectory: false).standardizedFileURL
        fakeLog = URL(fileURLWithPath: log, isDirectory: false).standardizedFileURL
        baselineManifest = Data(#"""
{
  "name": "dsh-profile-desktop",
  "private": true,
  "dependencies": {
    "plugin-a": "1.0.0",
    "plugin-b": "1.0.0"
  },
  "dsh": {
    "profile": {
      "bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]
    }
  }
}
"""#.utf8)
        baselineA = Data(#"""
{
  "name": "plugin-a",
  "version": "1.0.0",
  "description": "baseline plugin a"
}
"""#.utf8)
        baselineB = Data(#"""
{
  "name": "plugin-b",
  "version": "1.0.0",
  "description": "baseline plugin b"
}
"""#.utf8)
    }

    func reset() throws {
        try? fileManager.removeItem(at: desktop)
        try? fileManager.removeItem(at: web)
        try? fileManager.removeItem(at: operationStore)
        try? fileManager.removeItem(at: DshStateManager.appSupportDirectory.appendingPathComponent("dsh-plugin-operation-snapshots", isDirectory: true))
        try? fileManager.removeItem(at: fakeLog)
        try fileManager.createDirectory(at: desktop, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: web, withIntermediateDirectories: true)
        try baselineManifest.write(to: desktop.appendingPathComponent("package.json"), options: .atomic)
        try fileManager.createDirectory(at: desktop.appendingPathComponent("node_modules/plugin-a", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: desktop.appendingPathComponent("node_modules/plugin-b", isDirectory: true), withIntermediateDirectories: true)
        try baselineA.write(to: desktop.appendingPathComponent("node_modules/plugin-a/package.json"), options: .atomic)
        try baselineB.write(to: desktop.appendingPathComponent("node_modules/plugin-b/package.json"), options: .atomic)
        try Data("terminal-web-profile-sentinel\n".utf8).write(to: web.appendingPathComponent("sentinel"), options: .atomic)
        try Data("pnpm-user-config-sentinel\n".utf8).write(to: globalConfig, options: .atomic)
    }

    func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: desktop.appendingPathComponent(relativePath))
    }

    func manifest() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data("package.json"))
        guard let value = object as? [String: Any] else {
            throw HarnessError.failed("profile package.json is not an object")
        }
        return value
    }

    func dependencies() throws -> [String: String] {
        guard let dependencies = try manifest()["dependencies"] as? [String: String] else {
            throw HarnessError.failed("profile dependencies are missing")
        }
        return dependencies
    }

    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw HarnessError.failed(message) }
    }

    func requireData(_ expected: Data, at relativePath: String, _ message: String) throws {
        let actual = try data(relativePath)
        try require(actual == expected, message)
    }

    func requireUnchangedOutsideDesktop(_ webBefore: Data, _ configBefore: Data) throws {
        let webAfter = try Data(contentsOf: web.appendingPathComponent("sentinel"))
        let configAfter = try Data(contentsOf: globalConfig)
        try require(webAfter == webBefore,
                    "operation must not touch the shared web Profile")
        try require(configAfter == configBefore,
                    "operation must not mutate global pnpm configuration")
    }

    func pluginCPath() -> URL {
        fixtureRoot.appendingPathComponent("plugin-c", isDirectory: true)
    }

    func writeOperationState(_ state: DshPluginOperationState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try fileManager.createDirectory(at: operationStore.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: operationStore, options: .atomic)
    }
}

private func runCommitted(
    _ fixture: ProductFixture,
    action: DshPluginOperationAction,
    targetPackage: String? = nil,
    targetPackages: [String] = [],
    mutation: @escaping @Sendable (DshPluginOperationRequest) async throws -> Void
) async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: fixture.operationStore)
    let request = DshPluginOperationRequest(
        action: action,
        profile: .desktop,
        profileDirectory: fixture.desktop,
        targetPackage: targetPackage,
        targetPackages: targetPackages
    )
    let result = try await coordinator.perform(
        request,
        hooks: DshPluginOperationHooks(mutate: mutation)
    )
    try fixture.require(result.phase == .committed, "(action.rawValue) must commit")
    try await coordinator.finalizeCommittedOperation(operationID: result.operationID)
    try fixture.require(coordinator.persistedStatus == .absent,
                        "(action.rawValue) finalization must clear its durable record")
}

private func runProductChain() async throws {
    let fixture = try ProductFixture()
    try fixture.reset()
    let manager = DshPluginManager.shared
    let webBefore = try Data(contentsOf: fixture.web.appendingPathComponent("sentinel"))
    let configBefore = try Data(contentsOf: fixture.globalConfig)

    try await runCommitted(
        fixture,
        action: .install,
        targetPackage: "plugin-c",
        mutation: { request in
            try await manager.addPlugin(
                spec: "file:\(fixture.pluginCPath().path)",
                profileDirectory: request.profileDirectory,
                profile: .desktop,
                registry: "http://127.0.0.1:9"
            )
        }
    )
    let afterInstall = try fixture.dependencies()
    try fixture.require(afterInstall["plugin-c"]?.hasPrefix("file:") == true,
                        "real addPlugin path must add the fixture dependency")
    try fixture.require(FileManager.default.fileExists(atPath: fixture.desktop.appendingPathComponent("node_modules/plugin-c/package.json").path),
                        "real addPlugin path must materialize the installed manifest")

    try await runCommitted(
        fixture,
        action: .update,
        targetPackage: "plugin-a",
        mutation: { request in
            try await manager.updatePlugin(
                name: "plugin-a",
                profileDirectory: request.profileDirectory,
                profile: .desktop,
                registry: "http://127.0.0.1:9"
            )
        }
    )
    let updatedDependencies = try fixture.dependencies()
    try fixture.require(updatedDependencies["plugin-a"] == "2.0.0",
                        "real updatePlugin path must update the dependency")
    let updatedA = try String(contentsOf: fixture.desktop.appendingPathComponent("node_modules/plugin-a/package.json"), encoding: .utf8)
    try fixture.require(updatedA.contains("\"version\": \"2.0.0\""),
                        "real updatePlugin path must update the installed manifest")

    try await runCommitted(
        fixture,
        action: .updateAll,
        targetPackages: ["plugin-a", "plugin-b"],
        mutation: { request in
            try await manager.updateAllPlugins(
                profileDirectory: request.profileDirectory,
                profile: .desktop,
                registry: "http://127.0.0.1:9"
            )
        }
    )
    let afterUpdateAll = try fixture.dependencies()
    try fixture.require(afterUpdateAll["plugin-a"] == "2.0.0" && afterUpdateAll["plugin-b"] == "2.0.0",
                        "real updateAllPlugins path must update every user plugin")

    try await runCommitted(
        fixture,
        action: .remove,
        targetPackage: "plugin-c",
        mutation: { request in
            try await manager.removePlugin(
                name: "plugin-c",
                profileDirectory: request.profileDirectory,
                profile: .desktop,
                registry: "http://127.0.0.1:9"
            )
        }
    )
    let afterRemove = try fixture.dependencies()
    try fixture.require(afterRemove["plugin-c"] == nil,
                        "real removePlugin path must remove the dependency")
    try fixture.require(!FileManager.default.fileExists(atPath: fixture.desktop.appendingPathComponent("node_modules/plugin-c").path),
                        "real removePlugin path must remove the installed manifest")
    let remainingDependencies = try fixture.dependencies()
    try fixture.require(remainingDependencies["plugin-a"] == "2.0.0",
                        "removePlugin must leave unrelated dependencies intact")
    try fixture.requireUnchangedOutsideDesktop(webBefore, configBefore)
    print("plugin product-chain success passed")
}

private func runBatchFailure() async throws {
    let fixture = try ProductFixture()
    try fixture.reset()
    let manager = DshPluginManager.shared
    let webBefore = try Data(contentsOf: fixture.web.appendingPathComponent("sentinel"))
    let configBefore = try Data(contentsOf: fixture.globalConfig)
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: fixture.operationStore)
    let request = DshPluginOperationRequest(
        action: .updateAll,
        profile: .desktop,
        profileDirectory: fixture.desktop,
        targetPackages: ["plugin-a", "plugin-b"]
    )
    let restoredChecks = Counter()
    do {
        _ = try await coordinator.perform(
            request,
            hooks: DshPluginOperationHooks(
                mutate: { request in
                    try await manager.updateAllPlugins(
                        profileDirectory: request.profileDirectory,
                        profile: .desktop,
                        registry: "http://127.0.0.1:9"
                    )
                },
                verifyRestored: { _ in restoredChecks.increment() }
            )
        )
        throw HarnessError.failed("batch update unexpectedly succeeded")
    } catch let error as HarnessError {
        throw error
    } catch {
        // The fake pnpm intentionally mutates both package manifests before
        // failing. The coordinator must restore the exact pre-command tree.
    }
    try fixture.require(restoredChecks.value == 1, "batch failure must run the restored health gate")
    try fixture.require(coordinator.persistedStatus == .absent,
                        "successful batch rollback must clear its durable record")
    try fixture.requireData(fixture.baselineManifest, at: "package.json",
                            "batch rollback must restore package.json")
    try fixture.requireData(fixture.baselineA, at: "node_modules/plugin-a/package.json",
                            "batch rollback must restore plugin-a")
    try fixture.requireData(fixture.baselineB, at: "node_modules/plugin-b/package.json",
                            "batch rollback must restore plugin-b")
    try fixture.require(!FileManager.default.fileExists(atPath: fixture.desktop.appendingPathComponent("pnpm-workspace.yaml").path),
                        "batch rollback must remove workspace setup introduced by the mutation path")
    try fixture.requireUnchangedOutsideDesktop(webBefore, configBefore)
    print("plugin product-chain batch-failure passed")
}

private func runHealthFailure() async throws {
    let fixture = try ProductFixture()
    try fixture.reset()
    let manager = DshPluginManager.shared
    let webBefore = try Data(contentsOf: fixture.web.appendingPathComponent("sentinel"))
    let configBefore = try Data(contentsOf: fixture.globalConfig)
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: fixture.operationStore)
    let request = DshPluginOperationRequest(
        action: .update,
        profile: .desktop,
        profileDirectory: fixture.desktop,
        targetPackage: "plugin-a"
    )
    let restoredChecks = Counter()
    do {
        _ = try await coordinator.perform(
            request,
            hooks: DshPluginOperationHooks(
                mutate: { request in
                    try await manager.updatePlugin(
                        name: "plugin-a",
                        profileDirectory: request.profileDirectory,
                        profile: .desktop,
                        registry: "http://127.0.0.1:9"
                    )
                },
                verify: { _ in
                    throw NSError(domain: "fixture", code: 88, userInfo: [
                        NSLocalizedDescriptionKey: "healthy restart rejected the changed plugin tree"
                    ])
                },
                verifyRestored: { _ in restoredChecks.increment() }
            )
        )
        throw HarnessError.failed("health failure fixture unexpectedly succeeded")
    } catch let error as HarnessError {
        throw error
    } catch {
        // The command succeeded and the verification hook rejected the new
        // tree. This is the P01/P02 boundary where rollback is mandatory.
    }
    try fixture.require(restoredChecks.value == 1,
                        "health failure must run the restored health gate")
    try fixture.require(coordinator.persistedStatus == .absent,
                        "health failure rollback must clear its durable record")
    try fixture.requireData(fixture.baselineManifest, at: "package.json",
                            "health failure must restore package.json")
    try fixture.requireData(fixture.baselineA, at: "node_modules/plugin-a/package.json",
                            "health failure must restore the changed package")
    try fixture.require(!FileManager.default.fileExists(atPath: fixture.desktop.appendingPathComponent("pnpm-workspace.yaml").path),
                        "health failure rollback must remove workspace setup")
    try fixture.requireUnchangedOutsideDesktop(webBefore, configBefore)
    print("plugin product-chain health-failure passed")
}

private func runSafetyGates() async throws {
    let fixture = try ProductFixture()
    try fixture.reset()
    let manager = DshPluginManager.shared
    let webBefore = try Data(contentsOf: fixture.web.appendingPathComponent("sentinel"))
    let configBefore = try Data(contentsOf: fixture.globalConfig)
    let operationID = UUID().uuidString
    let snapshot = try await manager.createPluginOperationSnapshot(
        operationID: operationID,
        profile: .desktop,
        profileDirectory: fixture.desktop
    )
    let pending = DshPluginOperationState(
        operationID: operationID,
        profile: .desktop,
        targetPackage: "plugin-a",
        action: .update,
        snapshot: snapshot,
        phase: .recoveryRequired,
        lastError: "恢复仍需人工确认"
    )
    try fixture.writeOperationState(pending)
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: fixture.operationStore)
    let mutationCalls = Counter()
    let request = DshPluginOperationRequest(
        action: .update,
        profile: .desktop,
        profileDirectory: fixture.desktop,
        targetPackage: "plugin-a"
    )
    do {
        _ = try await coordinator.perform(
            request,
            hooks: DshPluginOperationHooks(mutate: { _ in mutationCalls.increment() })
        )
        throw HarnessError.failed("recoveryRequired gate unexpectedly allowed mutation")
    } catch let error as HarnessError {
        throw error
    } catch let error as DshPluginOperationError {
        guard case .operationAlreadyPending(operationID) = error else {
            throw HarnessError.failed("recoveryRequired gate returned unexpected error: \(error)")
        }
    }
    try fixture.require(mutationCalls.value == 0,
                        "recoveryRequired gate must disable mutation before hooks")
    try fixture.require(coordinator.hasPersistedOperationRecord,
                        "recoveryRequired gate must retain its durable record")

    // A corrupt owner record is a second fail-closed state. It must not be
    // collapsed into an absent record merely to make the UI retry available.
    try Data("{ corrupt plugin operation".utf8).write(to: fixture.operationStore, options: .atomic)
    let corruptCoordinator = DshPluginOperationCoordinator(operationStoreURL: fixture.operationStore)
    try fixture.require(corruptCoordinator.persistedStatus.isCorrupt,
                        "corrupt operation record must stay visible to the gate")
    do {
        _ = try await corruptCoordinator.perform(
            request,
            hooks: DshPluginOperationHooks(mutate: { _ in mutationCalls.increment() })
        )
        throw HarnessError.failed("corrupt operation gate unexpectedly allowed mutation")
    } catch let error as HarnessError {
        throw error
    } catch let error as DshPluginOperationError {
        guard case .recoveryRequired("插件事务记录损坏") = error else {
            throw HarnessError.failed("corrupt operation gate returned unexpected error: \(error)")
        }
    }
    try fixture.require(mutationCalls.value == 0,
                        "corrupt operation gate must disable mutation before hooks")
    try fixture.requireUnchangedOutsideDesktop(webBefore, configBefore)
    try? await manager.deletePluginOperationSnapshot(snapshot)
    print("plugin product-chain safety-gates passed")
}

private func runMinimumReleaseAgeFailure() async throws {
    let fixture = try ProductFixture()
    try fixture.reset()
    let manager = DshPluginManager.shared
    let webBefore = try Data(contentsOf: fixture.web.appendingPathComponent("sentinel"))
    let configBefore = try Data(contentsOf: fixture.globalConfig)
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: fixture.operationStore)
    let request = DshPluginOperationRequest(
        action: .install,
        profile: .desktop,
        profileDirectory: fixture.desktop,
        targetPackage: "plugin-c"
    )
    do {
        _ = try await coordinator.perform(
            request,
            hooks: DshPluginOperationHooks(mutate: { request in
                try await manager.addPlugin(
                    spec: "file:\(fixture.pluginCPath().path)",
                    ignoringMinimumReleaseAge: false,
                    profileDirectory: request.profileDirectory,
                    profile: .desktop,
                    registry: "http://127.0.0.1:9"
                )
            })
        )
        throw HarnessError.failed("minimum-release-age fixture unexpectedly succeeded")
    } catch let error as HarnessError {
        throw error
    } catch {
        try fixture.require(DshPluginManager.isMinimumReleaseAgeViolation(error),
                            "minimum-release-age failure must remain identifiable to the UI")
    }
    try fixture.require(coordinator.persistedStatus == .absent,
                        "minimum-release-age rollback must clear its durable record")
    try fixture.requireData(fixture.baselineManifest, at: "package.json",
                            "minimum-release-age failure must not modify the Profile")
    try fixture.require(!FileManager.default.fileExists(atPath: fixture.desktop.appendingPathComponent("node_modules/plugin-c").path),
                        "minimum-release-age failure must not leave a partial install")
    try fixture.requireUnchangedOutsideDesktop(webBefore, configBefore)
    let log = try String(contentsOf: fixture.fakeLog, encoding: .utf8)
    try fixture.require(!log.contains("--config.minimum-release-age=0"),
                        "normal install must not silently opt out of release-age policy")
    print("plugin product-chain minimum-release-age passed")
}

private func runMinimumReleaseAgeUpdateFailure(
    action: DshPluginOperationAction,
    scenarioName overrideScenarioName: String? = nil
) async throws {
    let fixture = try ProductFixture()
    try fixture.reset()
    let manager = DshPluginManager.shared
    let webBefore = try Data(contentsOf: fixture.web.appendingPathComponent("sentinel"))
    let configBefore = try Data(contentsOf: fixture.globalConfig)
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: fixture.operationStore)
    let targetPackages = action == .updateAll ? ["plugin-a", "plugin-b"] : []
    let request = DshPluginOperationRequest(
        action: action,
        profile: .desktop,
        profileDirectory: fixture.desktop,
        targetPackage: action == .update ? "plugin-a" : nil,
        targetPackages: targetPackages
    )
    do {
        _ = try await coordinator.perform(
            request,
            hooks: DshPluginOperationHooks(mutate: { request in
                switch action {
                case .update:
                    try await manager.updatePlugin(
                        name: "plugin-a",
                        ignoringMinimumReleaseAge: false,
                        profileDirectory: request.profileDirectory,
                        profile: .desktop,
                        registry: "http://127.0.0.1:9"
                    )
                case .updateAll:
                    try await manager.updateAllPlugins(
                        ignoringMinimumReleaseAge: false,
                        profileDirectory: request.profileDirectory,
                        profile: .desktop,
                        registry: "http://127.0.0.1:9"
                    )
                default:
                    throw HarnessError.failed("unexpected minimum-release-age update action")
                }
            })
        )
        throw HarnessError.failed("minimum-release-age \(action.rawValue) fixture unexpectedly succeeded")
    } catch let error as HarnessError {
        throw error
    } catch {
        try fixture.require(DshPluginManager.isMinimumReleaseAgeViolation(error),
                            "minimum-release-age \(action.rawValue) failure must remain identifiable to the UI")
    }
    try fixture.require(coordinator.persistedStatus == .absent,
                        "minimum-release-age \(action.rawValue) rollback must clear its durable record")
    try fixture.requireData(fixture.baselineManifest, at: "package.json",
                            "minimum-release-age \(action.rawValue) failure must not modify the Profile")
    try fixture.requireData(fixture.baselineA, at: "node_modules/plugin-a/package.json",
                            "minimum-release-age \(action.rawValue) failure must preserve plugin-a")
    try fixture.requireData(fixture.baselineB, at: "node_modules/plugin-b/package.json",
                            "minimum-release-age \(action.rawValue) failure must preserve plugin-b")
    try fixture.require(!FileManager.default.fileExists(atPath: fixture.desktop.appendingPathComponent("pnpm-workspace.yaml").path),
                        "minimum-release-age \(action.rawValue) rollback must remove workspace setup")
    try fixture.requireUnchangedOutsideDesktop(webBefore, configBefore)
    let log = try String(contentsOf: fixture.fakeLog, encoding: .utf8)
    let updateLogLines = log.split(separator: "\n").filter { $0.contains("\"update\"") }
    try fixture.require(!updateLogLines.contains { $0.contains("--config.minimum-release-age=0") },
                        "normal \(action.rawValue) must not silently opt out of release-age policy")
    let scenarioName = overrideScenarioName
        ?? (action == .update ? "update-minimum-release-age" : "update-all-minimum-release-age")
    print("plugin product-chain \(scenarioName) passed")
}

private func runUpdatePreflight(
    expected: DshPluginUpdatePreflightResult = .minimumReleaseAgeViolation,
    scenarioName: String = "update-preflight"
) async throws {
    let fixture = try ProductFixture()
    try fixture.reset()
    let manager = DshPluginManager.shared
    let webBefore = try Data(contentsOf: fixture.web.appendingPathComponent("sentinel"))
    let configBefore = try Data(contentsOf: fixture.globalConfig)

    let single = try await manager.preflightPluginUpdate(
        name: "plugin-a",
        profileDirectory: fixture.desktop,
        profile: .desktop,
        registry: "http://127.0.0.1:9"
    )
    try fixture.require(single == expected,
                        "single-plugin preflight returned an unexpected decision")

    let batch = try await manager.preflightAllPluginUpdates(
        profileDirectory: fixture.desktop,
        profile: .desktop,
        registry: "http://127.0.0.1:9"
    )
    try fixture.require(batch == expected,
                        "batch preflight returned an unexpected decision")

    // The resolver uses a disposable copy. The real Profile, shared Web
    // Profile and global pnpm config must remain byte-for-byte unchanged.
    try fixture.requireData(fixture.baselineManifest, at: "package.json",
                            "preflight must not modify package.json")
    try fixture.requireData(fixture.baselineA, at: "node_modules/plugin-a/package.json",
                            "preflight must not modify plugin-a")
    try fixture.requireData(fixture.baselineB, at: "node_modules/plugin-b/package.json",
                            "preflight must not modify plugin-b")
    try fixture.require(!FileManager.default.fileExists(
        atPath: fixture.desktop.appendingPathComponent("pnpm-workspace.yaml").path
    ), "preflight must not create the real workspace config")
    try fixture.requireUnchangedOutsideDesktop(webBefore, configBefore)

    let log = try String(contentsOf: fixture.fakeLog, encoding: .utf8)
    let updateLines = log.split(separator: "\n").filter { $0.contains("\"update\"") }
    try fixture.require(updateLines.count == 2,
                        "single and batch preflight must each invoke pnpm once")
    for line in updateLines {
        try fixture.require(line.contains("--lockfile-only"),
                            "preflight must use lockfile-only mode")
        try fixture.require(line.contains("--ignore-scripts"),
                            "preflight must disable lifecycle scripts")
        try fixture.require(!line.contains("--config.minimum-release-age=0"),
                            "preflight must retain the configured release-age policy")
    }
    print("plugin product-chain \(scenarioName) passed")
}

private func runUpdatePreflightConfirm() async throws {
    let fixture = try ProductFixture()
    try fixture.reset()
    let manager = DshPluginManager.shared
    let preflight = try await manager.preflightAllPluginUpdates(
        profileDirectory: fixture.desktop,
        profile: .desktop,
        registry: "http://127.0.0.1:9"
    )
    try fixture.require(preflight == .minimumReleaseAgeViolation,
                        "confirmation fixture must require a release-age override")

    // Confirmation is the only point at which the formal mutation receives
    // the one-shot override. There must be no second lockfile-only resolver.
    try await manager.updateAllPlugins(
        ignoringMinimumReleaseAge: true,
        profileDirectory: fixture.desktop,
        profile: .desktop,
        registry: "http://127.0.0.1:9"
    )
    let confirmedDependencies = try fixture.dependencies()
    try fixture.require(confirmedDependencies["plugin-a"] == "2.0.0",
                        "confirmed update must mutate plugin-a once")
    try fixture.require(confirmedDependencies["plugin-b"] == "2.0.0",
                        "confirmed update must mutate plugin-b once")

    let log = try String(contentsOf: fixture.fakeLog, encoding: .utf8)
    let updateLines = log.split(separator: "\n").filter { $0.contains("\"update\"") }
    try fixture.require(updateLines.count == 2,
                        "preflight plus confirmation must invoke update exactly twice")
    try fixture.require(updateLines[0].contains("--lockfile-only") &&
                        !updateLines[0].contains("--config.minimum-release-age=0"),
                        "preflight must be the only lockfile-only invocation")
    try fixture.require(!updateLines[1].contains("--lockfile-only") &&
                        updateLines[1].contains("--config.minimum-release-age=0"),
                        "confirmation must be the only override invocation")
    print("plugin product-chain update-preflight-confirm passed")
}

private func runUpdatePreflightSymlink() async throws {
    let fixture = try ProductFixture()
    try fixture.reset()
    let manager = DshPluginManager.shared
    let packageURL = fixture.desktop.appendingPathComponent("package.json")
    let externalPackageURL = fixture.dshHome.appendingPathComponent("external-package.json")
    try FileManager.default.createDirectory(at: fixture.dshHome, withIntermediateDirectories: true)
    try fixture.baselineManifest.write(to: externalPackageURL, options: .atomic)
    try FileManager.default.removeItem(at: packageURL)
    try FileManager.default.createSymbolicLink(
        at: packageURL,
        withDestinationURL: externalPackageURL
    )

    let result = try await manager.preflightPluginUpdate(
        name: "plugin-a",
        profileDirectory: fixture.desktop,
        profile: .desktop,
        registry: "http://127.0.0.1:9"
    )
    try fixture.require(result == .inconclusive,
                        "symlinked Profile input must conservatively skip preflight")
    let externalAfter = try Data(contentsOf: externalPackageURL)
    try fixture.require(externalAfter == fixture.baselineManifest,
                        "preflight must not modify a symlink target")
    let target = try FileManager.default.destinationOfSymbolicLink(atPath: packageURL.path)
    try fixture.require(URL(fileURLWithPath: target).standardizedFileURL.path == externalPackageURL.path,
                        "preflight must preserve the Profile symlink")
    try fixture.require(!FileManager.default.fileExists(atPath: fixture.fakeLog.path),
                        "symlink rejection must happen before pnpm starts")
    print("plugin product-chain update-preflight-symlink passed")
}

@main
struct PluginProductChainHarness {
    static func main() async throws {
        let scenario = CommandLine.arguments.dropFirst().first ?? "product-chain"
        switch scenario {
        case "product-chain": try await runProductChain()
        case "batch-failure": try await runBatchFailure()
        case "health-failure": try await runHealthFailure()
        case "safety-gates": try await runSafetyGates()
        case "minimum-release-age": try await runMinimumReleaseAgeFailure()
        case "update-minimum-release-age": try await runMinimumReleaseAgeUpdateFailure(action: .update)
        case "update-all-minimum-release-age": try await runMinimumReleaseAgeUpdateFailure(action: .updateAll)
        case "update-preflight": try await runUpdatePreflight()
        case "update-preflight-confirm": try await runUpdatePreflightConfirm()
        case "update-preflight-symlink": try await runUpdatePreflightSymlink()
        case "silent-update-preflight":
            try await runUpdatePreflight(scenarioName: "silent-update-preflight")
        case "silent-no-keyword-preflight":
            try await runUpdatePreflight(scenarioName: "silent-no-keyword-preflight")
        case "silent-update-minimum-release-age":
            try await runMinimumReleaseAgeUpdateFailure(
                action: .update,
                scenarioName: "silent-update-minimum-release-age"
            )
        default: throw HarnessError.failed("unknown scenario \(scenario)")
        }
    }
}
