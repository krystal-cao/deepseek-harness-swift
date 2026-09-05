import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private let fileManager = FileManager.default

private func testHome() -> URL {
    guard let raw = ProcessInfo.processInfo.environment["DSH_HOME"], !raw.isEmpty else {
        fputs("FAIL: DSH_HOME is required\n", stderr)
        exit(2)
    }
    return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
}

private func profileURL() -> URL {
    DshPluginManager.profileDirectory(for: .desktop)
}

private func operationStoreURL() -> URL {
    DshStateManager.appSupportDirectory.appendingPathComponent(
        "dsh-plugin-operation.json"
    )
}

private func snapshotDirectoryURL(
    _ reference: DshPluginOperationSnapshotReference
) -> URL {
    DshStateManager.appSupportDirectory
        .appendingPathComponent("dsh-plugin-operation-snapshots", isDirectory: true)
        .appendingPathComponent(reference.operationID, isDirectory: true)
        .appendingPathComponent(reference.snapshotID, isDirectory: true)
}

private func resetFixture() throws {
    // The caller supplies a fresh temporary DSH_HOME and app-support root.
    // Only paths below those explicit roots are touched here.
    try? fileManager.removeItem(at: profileURL())
    try? fileManager.removeItem(at: operationStoreURL())
    try? fileManager.removeItem(
        at: DshStateManager.appSupportDirectory.appendingPathComponent(
            "dsh-plugin-operation-snapshots", isDirectory: true
        )
    )
    try fileManager.createDirectory(at: profileURL(), withIntermediateDirectories: true)
    try Data(#"{"dependencies":{"plugin":"1.0.0","plugin-a":"1.0.0","plugin-b":"1.0.0"}}"#.utf8)
        .write(to: profileURL().appendingPathComponent("package.json"), options: .atomic)
    try Data("baseline".utf8)
        .write(to: profileURL().appendingPathComponent("marker"), options: .atomic)
    try Data("batch-a-baseline".utf8)
        .write(to: profileURL().appendingPathComponent("batch-a"), options: .atomic)
    try Data("batch-b-baseline".utf8)
        .write(to: profileURL().appendingPathComponent("batch-b"), options: .atomic)
}

private func writeOperationState(_ state: DshPluginOperationState) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try fileManager.createDirectory(
        at: operationStoreURL().deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try encoder.encode(state).write(to: operationStoreURL(), options: .atomic)
}

private func readOperationState() throws -> DshPluginOperationState {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
        DshPluginOperationState.self,
        from: Data(contentsOf: operationStoreURL())
    )
}

private func persistFixtureOperation(
    phase: DshPluginOperationPhase,
    mutationDigest: String? = nil,
    action: DshPluginOperationAction = .update
) async throws -> DshPluginOperationState {
    let operationID = UUID().uuidString
    let snapshot = try await DshPluginManager.shared.createPluginOperationSnapshot(
        operationID: operationID,
        profile: .desktop,
        profileDirectory: profileURL()
    )
    let state = DshPluginOperationState(
        operationID: operationID,
        profile: .desktop,
        targetPackage: action == .updateAll ? nil : "plugin",
        targetPackages: action == .updateAll ? ["plugin-a", "plugin-b"] : [],
        action: action,
        snapshot: snapshot,
        phase: phase,
        mutationDigest: mutationDigest
    )
    try writeOperationState(state)
    return state
}

private func marker(_ value: String) throws {
    try Data(value.utf8)
        .write(to: profileURL().appendingPathComponent("marker"), options: .atomic)
}

private func requireContents(_ expected: String, at url: URL, _ message: String) throws {
    let actual = try String(contentsOf: url, encoding: .utf8)
    require(actual == expected, message)
}

private func expectOperationError(
    _ expected: DshPluginOperationError,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        require(false, "expected error \(expected), operation succeeded")
    } catch let error as DshPluginOperationError {
        require(error == expected, "expected \(expected), got \(error)")
    } catch {
        require(false, "expected \(expected), got \(error)")
    }
}

private func waitForHook(_ counter: Counter, _ message: String) async throws {
    for _ in 0..<100 {
        if counter.value > 0 { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    require(false, message)
}

private func expectCancelled(_ task: Task<DshPluginOperationResult, Error>) async {
    do {
        _ = try await task.value
        require(false, "cancelled plugin operation unexpectedly succeeded")
    } catch is CancellationError {
        return
    } catch {
        require(false, "cancelled plugin operation returned (error)")
    }
}

private func setupPrepared() async throws {
    try resetFixture()
    let state = try await persistFixtureOperation(phase: .prepared)
    require(state.phase == .prepared, "prepared setup must persist prepared")
}

private func recoverPrepared() async throws {
    let state = try readOperationState()
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let result = try await coordinator.recoverPendingOperation()
    require(result?.operationID == state.operationID, "prepared recovery must resume the same operation")
    require(result?.phase == .prepared && result?.wasRestored == true, "prepared recovery result")
    require(coordinator.pendingOperation == nil, "prepared recovery must clear the record")
    require(!fileManager.fileExists(atPath: snapshotDirectoryURL(state.snapshot).path), "prepared recovery must remove snapshot")
    try requireContents("baseline", at: profileURL().appendingPathComponent("marker"), "prepared recovery must preserve baseline")
}

private func setupMutatingWithoutDigest() async throws {
    try resetFixture()
    try marker("mutating-before-interruption")
    let state = try await persistFixtureOperation(phase: .mutating)
    require(state.mutationDigest == nil, "mutating interruption fixture must omit digest")
}

private func recoverMutatingWithoutDigest() async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    await expectOperationError(.operationInterruptedDuringMutation) {
        _ = try await coordinator.recoverPendingOperation()
    }
    require(coordinator.pendingOperation?.phase == .recoveryRequired, "missing mutation digest must require recovery")
    try requireContents("mutating-before-interruption", at: profileURL().appendingPathComponent("marker"), "missing digest must not overwrite current tree")
}

private func setupVerifying() async throws {
    try resetFixture()
    let manager = DshPluginManager.shared
    let operationID = UUID().uuidString
    let snapshot = try await manager.createPluginOperationSnapshot(
        operationID: operationID,
        profile: .desktop,
        profileDirectory: profileURL()
    )
    try marker("mutated")
    let digest = try await manager.pluginProfileDigest(at: profileURL())
    let state = DshPluginOperationState(
        operationID: operationID,
        profile: .desktop,
        targetPackage: "plugin",
        action: .update,
        snapshot: snapshot,
        phase: .verifying,
        mutationDigest: digest
    )
    try writeOperationState(state)
}

private func recoverVerifyingCommit() async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let result = try await coordinator.recoverPendingOperation(
        hooks: DshPluginOperationHooks(
            mutate: { _ in },
            verify: { _ in }
        )
    )
    require(result?.phase == .committed, "verifying restart should commit after successful verification")
    require(coordinator.pendingOperation?.phase == .committed, "committed record must remain durable")
    try requireContents("mutated", at: profileURL().appendingPathComponent("marker"), "successful verifying recovery must keep mutation")
}

private func recoverVerifyingRestore() async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let result = try await coordinator.recoverPendingOperation(
        hooks: DshPluginOperationHooks(
            mutate: { _ in },
            verify: { _ in
                throw NSError(domain: "fixture", code: 91, userInfo: [
                    NSLocalizedDescriptionKey: "verification failed"
                ])
            }
        )
    )
    require(result?.phase == .restoring && result?.wasRestored == true, "failed verifying restart must restore")
    require(coordinator.pendingOperation == nil, "successful restore must clear verifying record")
    try requireContents("baseline", at: profileURL().appendingPathComponent("marker"), "failed verifying restart must restore baseline")
}

private func setupRestoring() async throws {
    try resetFixture()
    let manager = DshPluginManager.shared
    let operationID = UUID().uuidString
    let snapshot = try await manager.createPluginOperationSnapshot(
        operationID: operationID,
        profile: .desktop,
        profileDirectory: profileURL()
    )
    try marker("mutated-before-restoring-interruption")
    let digest = try await manager.pluginProfileDigest(at: profileURL())
    let state = DshPluginOperationState(
        operationID: operationID,
        profile: .desktop,
        targetPackage: "plugin",
        action: .update,
        snapshot: snapshot,
        phase: .restoring,
        mutationDigest: digest
    )
    try writeOperationState(state)
}

private func recoverRestoringIdempotently() async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let first = try await coordinator.recoverPendingOperation()
    require(first?.wasRestored == true, "restoring restart must continue restoration")
    try requireContents("baseline", at: profileURL().appendingPathComponent("marker"), "restoring restart must restore baseline")
    require(coordinator.pendingOperation == nil, "restoring restart must clear after completion")
    let second = try await coordinator.recoverPendingOperation()
    require(second == nil, "restoring recovery must be idempotent")
}

/// Simulate the narrow force-quit window after restoration and snapshot
/// deletion but before the durable operation record is removed. Recovery must
/// use the baseline digest and the persisted owner reference to finish
/// cleanup, instead of attempting a second restore or getting stuck forever.
private func setupRestoringAfterSnapshotDeletion() async throws {
    try resetFixture()
    let manager = DshPluginManager.shared
    let operationID = UUID().uuidString
    let snapshot = try await manager.createPluginOperationSnapshot(
        operationID: operationID,
        profile: .desktop,
        profileDirectory: profileURL()
    )
    try marker("mutated-before-cleanup-interruption")
    let mutationDigest = try await manager.pluginProfileDigest(at: profileURL())
    let state = DshPluginOperationState(
        operationID: operationID,
        profile: .desktop,
        targetPackage: "plugin",
        action: .update,
        snapshot: snapshot,
        phase: .restoring,
        mutationDigest: mutationDigest
    )
    try writeOperationState(state)
    try await manager.restorePluginOperationSnapshot(
        snapshot,
        expectedCurrentDigest: mutationDigest
    )
    try await manager.deletePluginOperationSnapshot(snapshot)
    require(fileManager.fileExists(atPath: operationStoreURL().path),
            "cleanup interruption fixture must retain the operation record")
    require(!fileManager.fileExists(atPath: snapshotDirectoryURL(snapshot).path),
            "cleanup interruption fixture must remove the snapshot")
}

private func recoverRestoringAfterSnapshotDeletion() async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    guard case .loaded(let state) = coordinator.persistedStatus else {
        require(false, "cleanup interruption must expose a loaded persisted status")
        return
    }
    let result = try await coordinator.recoverPendingOperation()
    require(result?.operationID == state.operationID,
            "cleanup recovery must resume the same operation")
    require(result?.wasRestored == true,
            "cleanup recovery must report the already-restored baseline")
    require(coordinator.persistedStatus == .absent,
            "cleanup recovery must clear the durable record")
    try requireContents("baseline", at: profileURL().appendingPathComponent("marker"),
                        "cleanup recovery must keep the restored baseline")
    let second = try await coordinator.recoverPendingOperation()
    require(second == nil, "cleanup recovery must remain idempotent")
}

private func runCommittedRetention() async throws {
    try resetFixture()
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let request = DshPluginOperationRequest(
        action: .update,
        profile: .desktop,
        profileDirectory: profileURL(),
        targetPackage: "plugin"
    )
    let result = try await coordinator.perform(
        request,
        hooks: DshPluginOperationHooks(
            mutate: { request in
                try Data("committed".utf8).write(
                    to: request.profileDirectory.appendingPathComponent("marker"),
                    options: .atomic
                )
            }
        )
    )
    require(result.phase == .committed, "successful operation must commit")
    guard let pending = coordinator.pendingOperation else {
        require(false, "committed record must remain until health confirmation")
        return
    }
    require(pending.phase == .committed, "committed record must remain until health confirmation")
    require(coordinator.persistedStatus == .loaded(pending),
            "committed operation must expose an explicit loaded status")
    require(fileManager.fileExists(atPath: operationStoreURL().path), "committed record must be durable")
    try await coordinator.finalizeCommittedOperation(operationID: result.operationID)
    require(coordinator.pendingOperation == nil, "finalize must clear committed record")
    require(coordinator.persistedStatus == .absent, "finalize must expose an absent status")
    require(!fileManager.fileExists(atPath: operationStoreURL().path), "finalize must remove durable record")
}

private func runCancelledBeforeRecord() async throws {
    try resetFixture()
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let entered = Counter()
    let request = DshPluginOperationRequest(
        action: .update,
        profile: .desktop,
        profileDirectory: profileURL(),
        targetPackage: "plugin"
    )
    let task = Task {
        try await coordinator.perform(
            request,
            hooks: DshPluginOperationHooks(
                prepareForMutation: {
                    entered.increment()
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                },
                mutate: { _ in }
            )
        )
    }
    try await waitForHook(entered, "prepare hook did not start")
    task.cancel()
    await expectCancelled(task)
    require(coordinator.pendingOperation == nil, "pre-record cancellation must not leave an operation")
    require(!coordinator.hasPersistedOperationRecord, "pre-record cancellation must not persist an owner record")
    let snapshotRoot = DshStateManager.appSupportDirectory
        .appendingPathComponent("dsh-plugin-operation-snapshots", isDirectory: true)
    let entries = try? fileManager.contentsOfDirectory(atPath: snapshotRoot.path)
    require(entries?.isEmpty ?? true, "pre-record cancellation must not leave snapshot directories")
}

private func runCancelledDuringMutation(restoreFails: Bool = false) async throws {
    try resetFixture()
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let entered = Counter()
    let restoredChecks = Counter()
    let request = DshPluginOperationRequest(
        action: .update,
        profile: .desktop,
        profileDirectory: profileURL(),
        targetPackage: "plugin"
    )
    let task = Task {
        try await coordinator.perform(
            request,
            hooks: DshPluginOperationHooks(
                mutate: { request in
                    entered.increment()
                    try Data("mutated-before-cancel".utf8).write(
                        to: request.profileDirectory.appendingPathComponent("marker"),
                        options: .atomic
                    )
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                },
                verifyRestored: { _ in
                    restoredChecks.increment()
                    if restoreFails {
                        throw NSError(domain: "fixture", code: 94, userInfo: [
                            NSLocalizedDescriptionKey: "restored health rejected"
                        ])
                    }
                }
            )
        )
    }
    try await waitForHook(entered, "mutation hook did not start")
    task.cancel()
    if restoreFails {
        do {
            _ = try await task.value
            require(false, "cancellation with failed restoration unexpectedly succeeded")
        } catch let error as DshPluginOperationError {
            guard case .recoveryRequired = error else {
                require(false, "failed restoration must report recoveryRequired, got (error)")
                return
            }
        } catch {
            require(false, "failed restoration returned unexpected error (error)")
        }
        require(coordinator.pendingOperation?.phase == .recoveryRequired,
                "failed cancellation recovery must retain recoveryRequired")
        require(restoredChecks.value == 1, "failed cancellation recovery must run restored health once")
        try requireContents("baseline", at: profileURL().appendingPathComponent("marker"),
                            "failed cancellation recovery must still restore the baseline")
    } else {
        await expectCancelled(task)
        require(coordinator.pendingOperation == nil,
                "mutation cancellation with successful recovery must clear the record")
        require(restoredChecks.value == 1,
                "mutation cancellation must re-check restored health")
        try requireContents("baseline", at: profileURL().appendingPathComponent("marker"),
                            "mutation cancellation must restore the baseline")
    }
}

private func runCancelledDuringVerify() async throws {
    try resetFixture()
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let entered = Counter()
    let restoredChecks = Counter()
    let request = DshPluginOperationRequest(
        action: .update,
        profile: .desktop,
        profileDirectory: profileURL(),
        targetPackage: "plugin"
    )
    let task = Task {
        try await coordinator.perform(
            request,
            hooks: DshPluginOperationHooks(
                mutate: { request in
                    try Data("mutated-before-verify-cancel".utf8).write(
                        to: request.profileDirectory.appendingPathComponent("marker"),
                        options: .atomic
                    )
                },
                verify: { _ in
                    entered.increment()
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                },
                verifyRestored: { _ in restoredChecks.increment() }
            )
        )
    }
    try await waitForHook(entered, "verify hook did not start")
    task.cancel()
    await expectCancelled(task)
    require(coordinator.pendingOperation == nil,
            "verify cancellation with successful recovery must clear the record")
    require(restoredChecks.value == 1, "verify cancellation must re-check restored health")
    try requireContents("baseline", at: profileURL().appendingPathComponent("marker"),
                        "verify cancellation must restore the baseline")
}

private func runSnapshotCapacityContract() throws {
    let required = Int64(4 * 1024 * 1024)
    let safety = DshPluginManager.pluginSnapshotSafetyBytes
    do {
        try DshPluginManager.validatePluginSnapshotCapacity(
            requiredBytes: required,
            availableBytes: safety + required - 1
        )
        require(false, "insufficient snapshot capacity unexpectedly passed")
    } catch let error as DshPluginOperationError {
        guard case .snapshotCapacityInsufficient(
            let requiredBytes,
            let availableBytes
        ) = error else {
            require(false, "insufficient snapshot capacity returned (error)")
            return
        }
        require(requiredBytes == safety + required, "capacity error must report required bytes including safety")
        require(availableBytes == safety + required - 1, "capacity error must report available bytes")
    }
    try DshPluginManager.validatePluginSnapshotCapacity(
        requiredBytes: required,
        availableBytes: safety + required
    )
}

private func runOwnedSnapshotDeleteGuard() async throws {
    try resetFixture()
    let manager = DshPluginManager.shared
    let operationID = UUID().uuidString
    let snapshot = try await manager.createPluginOperationSnapshot(
        operationID: operationID,
        profile: .desktop,
        profileDirectory: profileURL()
    )
    let foreign = DshPluginOperationSnapshotReference(
        snapshotID: snapshot.snapshotID,
        operationID: snapshot.operationID,
        profile: snapshot.profile,
        profileDirectory: profileURL(),
        baselineDigest: snapshot.baselineDigest,
        createdAt: snapshot.createdAt,
        ownerID: "foreign-owner",
        profileWasMissing: snapshot.profileWasMissing
    )
    await expectOperationError(.desktopProfileRequired) {
        try await manager.deletePluginOperationSnapshot(foreign)
    }
    require(fileManager.fileExists(atPath: snapshotDirectoryURL(snapshot).path),
            "foreign delete request must leave the owned snapshot intact")
    try await manager.deletePluginOperationSnapshot(snapshot)
    require(!fileManager.fileExists(atPath: snapshotDirectoryURL(snapshot).path),
            "matching owner delete request must remove exactly its snapshot")
}

private func runBatchFailure() async throws {
    try resetFixture()
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    let restoredChecks = Counter()
    let request = DshPluginOperationRequest(
        action: .updateAll,
        profile: .desktop,
        profileDirectory: profileURL(),
        targetPackages: ["plugin-a", "plugin-b"]
    )
    var operationError: Error?
    do {
        _ = try await coordinator.perform(
            request,
            hooks: DshPluginOperationHooks(
                mutate: { request in
                    try Data("batch-a-mutated".utf8).write(
                        to: request.profileDirectory.appendingPathComponent("batch-a"),
                        options: .atomic
                    )
                    try Data("batch-b-mutated".utf8).write(
                        to: request.profileDirectory.appendingPathComponent("batch-b"),
                        options: .atomic
                    )
                    try Data("partial-package-update".utf8).write(
                        to: request.profileDirectory.appendingPathComponent("package.json"),
                        options: .atomic
                    )
                    throw NSError(domain: "fixture", code: 73, userInfo: [
                        NSLocalizedDescriptionKey: "batch command failed halfway"
                    ])
                },
                verifyRestored: { _ in restoredChecks.value += 1 }
            )
        )
    } catch {
        operationError = error
    }
    require(operationError != nil, "batch mutation failure must throw")
    require(restoredChecks.value == 1, "batch failure must re-check restored health")
    require(coordinator.pendingOperation == nil, "batch rollback must clear record")
    try requireContents("baseline", at: profileURL().appendingPathComponent("marker"), "batch rollback must preserve marker")
    try requireContents("batch-a-baseline", at: profileURL().appendingPathComponent("batch-a"), "batch rollback must restore first package")
    try requireContents("batch-b-baseline", at: profileURL().appendingPathComponent("batch-b"), "batch rollback must restore second package")
    let restoredManifest = try String(contentsOf: profileURL().appendingPathComponent("package.json"), encoding: .utf8)
    require(restoredManifest.contains("plugin-a"), "batch rollback must restore package manifest")
}

private func runCorruptRecord() async throws {
    try resetFixture()
    try Data("{ this is not a plugin operation record".utf8)
        .write(to: operationStoreURL(), options: .atomic)
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    require(coordinator.persistedStatus.isCorrupt,
            "malformed operation record must expose corrupt persisted status")
    let preparationChecks = Counter()
    let request = DshPluginOperationRequest(
        action: .update,
        profile: .desktop,
        profileDirectory: profileURL(),
        targetPackage: "plugin"
    )
    await expectOperationError(.recoveryRequired("插件事务记录损坏")) {
        _ = try await coordinator.perform(
            request,
            hooks: DshPluginOperationHooks(
                prepareForMutation: { preparationChecks.value += 1 },
                mutate: { _ in }
            )
        )
    }
    require(preparationChecks.value == 0, "corrupt record must fail closed before preparation")
    await expectOperationError(.recoveryRequired("插件事务记录损坏")) {
        _ = try await coordinator.recoverPendingOperation()
    }
    require(fileManager.fileExists(atPath: operationStoreURL().path), "corrupt record must remain for explicit recovery")
}

private func runStructurallyInvalidRecord() async throws {
    try resetFixture()
    _ = try await persistFixtureOperation(phase: .restoring)
    var object = try JSONSerialization.jsonObject(
        with: Data(contentsOf: operationStoreURL())
    ) as! [String: Any]
    object["operationID"] = UUID().uuidString
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        .write(to: operationStoreURL(), options: .atomic)

    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    require(coordinator.persistedStatus == .corrupt("插件事务记录损坏"),
            "inconsistent operation IDs must be classified as corrupt")
    await expectOperationError(.recoveryRequired("插件事务记录损坏")) {
        _ = try await coordinator.recoverPendingOperation()
    }
    require(fileManager.fileExists(atPath: operationStoreURL().path),
            "structurally corrupt operation record must remain for explicit recovery")
}

private func setupRestorationGuard(_ kind: String) async throws {
    try resetFixture()
    let state = try await persistFixtureOperation(phase: .restoring)
    try marker("mutated-guard")
    let digest = try await DshPluginManager.shared.pluginProfileDigest(at: profileURL())
    let corrected = DshPluginOperationState(
        operationID: state.operationID,
        profile: state.profile,
        targetPackage: state.targetPackage,
        targetPackages: state.targetPackages,
        action: state.action,
        snapshot: state.snapshot,
        startedAt: state.startedAt,
        phase: .restoring,
        mutationDigest: digest
    )
    try writeOperationState(corrected)
    let snapshotURL = snapshotDirectoryURL(state.snapshot)
    if kind == "missing" {
        try fileManager.removeItem(at: snapshotURL)
    } else {
        let metadataURL = snapshotURL.appendingPathComponent("snapshot.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as! [String: Any]
        object["ownerID"] = "not-dsh-desktop-owner"
        let metadata = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try metadata.write(to: metadataURL, options: .atomic)
    }
}

private func recoverRestorationGuard(_ kind: String) async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    do {
        _ = try await coordinator.recoverPendingOperation()
        require(false, "\(kind) snapshot guard must fail")
    } catch {
        require(coordinator.pendingOperation != nil, "\(kind) snapshot guard must retain operation record")
        require(coordinator.pendingOperation?.phase == .recoveryRequired, "\(kind) snapshot guard must enter recoveryRequired")
    }
    try requireContents("mutated-guard", at: profileURL().appendingPathComponent("marker"), "\(kind) snapshot guard must not overwrite current tree")
}

private func setupExternalModification() async throws {
    try await setupVerifying()
    try marker("external-concurrent-change")
}

private func recoverExternalModification() async throws {
    let coordinator = DshPluginOperationCoordinator(operationStoreURL: operationStoreURL())
    await expectOperationError(.externalModification) {
        _ = try await coordinator.recoverPendingOperation()
    }
    require(coordinator.pendingOperation?.phase == .recoveryRequired, "external change must require recovery")
    try requireContents("external-concurrent-change", at: profileURL().appendingPathComponent("marker"), "external change must never be overwritten")
}

@main
struct PluginOperationHarness {
    static func main() async throws {
        _ = testHome()
        let scenario = CommandLine.arguments.dropFirst().first ?? "committed"
        switch scenario {
        case "prepared-setup": try await setupPrepared()
        case "prepared-recover": try await recoverPrepared()
        case "mutating-no-digest-setup": try await setupMutatingWithoutDigest()
        case "mutating-no-digest-recover": try await recoverMutatingWithoutDigest()
        case "verifying-setup": try await setupVerifying()
        case "verifying-commit-recover": try await recoverVerifyingCommit()
        case "verifying-restore-recover": try await recoverVerifyingRestore()
        case "restoring-setup": try await setupRestoring()
        case "restoring-recover": try await recoverRestoringIdempotently()
        case "restoring-cleanup-setup": try await setupRestoringAfterSnapshotDeletion()
        case "restoring-cleanup-recover": try await recoverRestoringAfterSnapshotDeletion()
        case "committed": try await runCommittedRetention()
        case "cancel-before-record": try await runCancelledBeforeRecord()
        case "cancel-during-mutation": try await runCancelledDuringMutation()
        case "cancel-during-mutation-recovery-failure": try await runCancelledDuringMutation(restoreFails: true)
        case "cancel-during-verify": try await runCancelledDuringVerify()
        case "capacity-contract": try runSnapshotCapacityContract()
        case "owned-snapshot-delete-guard": try await runOwnedSnapshotDeleteGuard()
        case "batch-failure": try await runBatchFailure()
        case "corrupt-record": try await runCorruptRecord()
        case "structurally-invalid-record": try await runStructurallyInvalidRecord()
        case "missing-snapshot-setup": try await setupRestorationGuard("missing")
        case "missing-snapshot-recover": try await recoverRestorationGuard("missing")
        case "ownership-mismatch-setup": try await setupRestorationGuard("ownership")
        case "ownership-mismatch-recover": try await recoverRestorationGuard("ownership")
        case "external-setup": try await setupExternalModification()
        case "external-recover": try await recoverExternalModification()
        default:
            fputs("FAIL: unknown scenario \(scenario)\n", stderr)
            exit(2)
        }
        print("plugin operation scenario \(scenario) passed")
    }
}
