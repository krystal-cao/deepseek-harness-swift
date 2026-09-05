import Foundation

/// FIFO gate for the whole plugin transaction.  It is intentionally separate
/// from the service's startup gate; product wiring can acquire the wider
/// MainWindow operation gate around this coordinator without making P01
/// depend on AppKit.
private final class DshPluginTransactionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            var resume = false
            lock.lock()
            if held {
                waiters.append(continuation)
            } else {
                held = true
                resume = true
            }
            lock.unlock()
            if resume {
                continuation.resume()
            }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>?
        lock.lock()
        if waiters.isEmpty {
            held = false
            next = nil
        } else {
            next = waiters.removeFirst()
        }
        lock.unlock()
        next?.resume()
    }
}

/// The plugin record is intentionally a separate file from the Runtime state
/// file.  A malformed record is an unresolved recovery condition, never an
/// implicit empty state.
private final class DshPluginOperationStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    /// Distinguish an absent operation from a malformed persisted record.
    /// `load()` intentionally maps malformed JSON to a recovery error, while
    /// this probe is used by startup to decide whether that error belongs to
    /// P01 or should retain the original M1 launch-failure path.
    func hasPersistedRecord() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    func status() -> DshPluginOperationPersistedStatus {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .absent
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return .loaded(try decoder.decode(DshPluginOperationState.self, from: Data(contentsOf: fileURL)))
        } catch {
            return .corrupt("插件事务记录损坏")
        }
    }

    func load() throws -> DshPluginOperationState? {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(DshPluginOperationState.self, from: Data(contentsOf: fileURL))
        } catch {
            throw DshPluginOperationError.recoveryRequired("插件事务记录损坏")
        }
    }

    func write(_ state: DshPluginOperationState) throws {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// P01's side-effect-free orchestration boundary.  The coordinator owns the
/// durable phase machine and Profile snapshot; callers provide service stop,
/// pnpm mutation and ordinary startup health verification through hooks.
/// This deliberately leaves UI/P02 wiring to a later task.
public final class DshPluginOperationCoordinator: @unchecked Sendable {
    public static let shared = DshPluginOperationCoordinator()

    private static let gate = DshPluginTransactionGate()
    private let stateManager: DshStateManager
    private let pluginManager: DshPluginManager
    private let operationStore: DshPluginOperationStore

    public init(
        stateManager: DshStateManager = .shared,
        pluginManager: DshPluginManager = .shared,
        operationStoreURL: URL? = nil
    ) {
        self.stateManager = stateManager
        self.pluginManager = pluginManager
        self.operationStore = DshPluginOperationStore(
            fileURL: operationStoreURL
                ?? DshStateManager.appSupportDirectory.appendingPathComponent(
                    "dsh-plugin-operation.json"
                )
        )
    }

    /// The active record is read-only and intentionally returned as a value.
    public var pendingOperation: DshPluginOperationState? {
        try? operationStore.load()
    }

    /// Explicit durable-record probe for startup and mutation gates.  The
    /// legacy `pendingOperation` optional remains available for existing UI,
    /// but must not collapse a corrupt record into the absent state.
    public var persistedStatus: DshPluginOperationPersistedStatus {
        operationStore.status()
    }

    /// True when the durable P01 owner file exists, including when its
    /// contents are corrupt and therefore cannot be decoded as a state value.
    public var hasPersistedOperationRecord: Bool {
        operationStore.hasPersistedRecord()
    }

    /// Execute one desktop plugin operation.  The record is persisted as
    /// `prepared` before `mutating`, and as `verifying` before the health hook
    /// is called.  A successful operation returns `committed`; its snapshot
    /// remains owned until `finalizeCommittedOperation` is called after the
    /// caller's extra healthy launch check.
    @discardableResult
    public func perform(
        _ request: DshPluginOperationRequest,
        hooks: DshPluginOperationHooks
    ) async throws -> DshPluginOperationResult {
        try validate(request)
        await Self.gate.acquire()
        defer { Self.gate.release() }

        // Cancellation while waiting for the transaction gate must not
        // create a prepared record.  The gate is non-throwing by design, so
        // check immediately after acquiring it and before any side effect.
        try Task.checkCancellation()

        guard noOtherRecoveryIsPending() else {
            throw DshPluginOperationError.runtimeOrProfileRecoveryPending
        }
        try requireNoPersistedOperation()

        let operationID = UUID().uuidString
        // Stop the service and establish the port/health precondition before
        // taking the baseline.  If preparation or snapshot creation fails,
        // no operation record has been written and therefore no false durable
        // recovery obligation is created.
        try await hooks.prepareForMutation()
        try Task.checkCancellation()
        try requireNoPersistedOperation()
        let snapshot: DshPluginOperationSnapshotReference
        snapshot = try await pluginManager.createPluginOperationSnapshot(
            operationID: operationID,
            profile: request.profile,
            profileDirectory: request.profileDirectory
        )
        // Snapshot creation runs in an uncancelled worker so it can finish
        // atomically.  Cancellation is checked inside the persistence cleanup
        // scope below so a completed-but-unpersisted snapshot cannot leak.
        var operation = DshPluginOperationState(
            operationID: operationID,
            profile: request.profile,
            targetPackage: request.targetPackage,
            targetPackages: request.targetPackages,
            action: request.action,
            snapshot: snapshot
        )
        do {
            try Task.checkCancellation()
            try persist(operation, replacing: nil)
        } catch {
            // The snapshot is transaction-local, but there is no durable
            // owner record when this write fails.  Remove it before surfacing
            // the error so a later launch cannot mistake an orphan for work
            // that must be recovered.
            try? await pluginManager.deletePluginOperationSnapshot(snapshot)
            throw error
        }

        do {
            try Task.checkCancellation()
            try await ensureProfileDigest(operation.snapshot.baselineDigest, at: request.profileDirectory)
            try Task.checkCancellation()
            operation = try advance(operation, to: .mutating)
            try persist(operation, replacing: operation.operationID)

            try Task.checkCancellation()
            try await hooks.mutate(request)
            // A cancellable mutation hook may return after doing part of its
            // work.  Treat cancellation as a mutation failure and roll back.
            try Task.checkCancellation()
            let mutationDigest = try await pluginManager.pluginProfileDigest(at: request.profileDirectory)
            try Task.checkCancellation()
            operation = try advance(
                operation,
                to: .verifying,
                mutationDigest: mutationDigest
            )
            try persist(operation, replacing: operation.operationID)

            try Task.checkCancellation()
            try await hooks.verify(request)
            try Task.checkCancellation()
            operation = try advance(operation, to: .committed)
            try persist(operation, replacing: operation.operationID)
            return DshPluginOperationResult(operationID: operation.operationID, phase: .committed)
        } catch {
            // The task remains cancelled while its error is being handled.
            // Run rollback in a detached worker so cancellation cannot abort
            // the digest/restore/health sequence halfway through.  If that
            // recovery itself fails, the worker persists recoveryRequired.
            try await Task.detached(priority: .utility) { [self] in
                try await failAndRecover(
                    operation,
                    request: request,
                    originalError: error,
                    verifyRestored: hooks.verifyRestored
                )
            }.value
            throw error
        }
    }

    /// Resume a persisted record after a normal process interruption.  A
    /// record that was still `mutating` has no proof of who changed the tree,
    /// so it is retained as `recoveryRequired` rather than overwritten.
    @discardableResult
    public func recoverPendingOperation(
        hooks: DshPluginOperationHooks? = nil
    ) async throws -> DshPluginOperationResult? {
        await Self.gate.acquire()
        defer { Self.gate.release() }
        var operation: DshPluginOperationState
        switch operationStore.status() {
        case .absent:
            return nil
        case .corrupt(let detail):
            throw DshPluginOperationError.recoveryRequired(detail)
        case .loaded(let loaded):
            operation = loaded
        }
        guard operation.profile == .desktop,
              operation.profile == operation.snapshot.profile else {
            throw DshPluginOperationError.desktopProfileRequired
        }

        let profileURL = URL(fileURLWithPath: operation.snapshot.profileDirectory, isDirectory: true)
        switch operation.phase {
        case .prepared:
            guard try await pluginManager.pluginProfileDigest(at: profileURL) == operation.snapshot.baselineDigest else {
                operation = try markRecoveryRequired(operation, error: DshPluginOperationError.externalModification)
                throw DshPluginOperationError.externalModification
            }
            do {
                try await deleteAndClear(operation)
                return DshPluginOperationResult(
                    operationID: operation.operationID,
                    phase: .prepared,
                    wasRestored: true
                )
            } catch {
                let recoveryError = (error as? DshPluginOperationError) ??
                    DshPluginOperationError.recoveryRequired(Self.redacted(error.localizedDescription))
                _ = try markRecoveryRequired(operation, error: recoveryError)
                throw recoveryError
            }

        case .mutating:
            guard let mutationDigest = operation.mutationDigest else {
                operation = try markRecoveryRequired(operation, error: DshPluginOperationError.operationInterruptedDuringMutation)
                throw DshPluginOperationError.operationInterruptedDuringMutation
            }
            return try await recoverVerifyingOrRestoring(
                operation,
                profileURL: profileURL,
                mutationDigest: mutationDigest,
                hooks: hooks
            )

        case .verifying:
            guard let mutationDigest = operation.mutationDigest else {
                operation = try markRecoveryRequired(operation, error: DshPluginOperationError.operationInterruptedDuringMutation)
                throw DshPluginOperationError.operationInterruptedDuringMutation
            }
            return try await recoverVerifyingOrRestoring(
                operation,
                profileURL: profileURL,
                mutationDigest: mutationDigest,
                hooks: hooks
            )

        case .restoring, .recoveryRequired:
            // Restoration can be interrupted after the Profile has already
            // been put back but before the snapshot/owner record cleanup.
            // A baseline digest plus a missing (or still app-owned) snapshot
            // is sufficient proof to finish that cleanup idempotently.
            if try await pluginManager.pluginProfileDigest(at: profileURL) == operation.snapshot.baselineDigest {
                do {
                    let snapshotExists = try await pluginManager.hasOwnedPluginOperationSnapshot(operation.snapshot)
                    // A recoveryRequired record may represent a failed
                    // restored-health check. Keep it until the snapshot is
                    // gone; only the snapshot-deleted + baseline case is an
                    // unambiguous post-cleanup retry.
                    if operation.phase == .restoring || !snapshotExists {
                        _ = try await finishRestoredCleanupIfSafe(operation)
                        return DshPluginOperationResult(
                            operationID: operation.operationID,
                            phase: .restoring,
                            wasRestored: true
                        )
                    }
                } catch {
                    let recoveryError = (error as? DshPluginOperationError) ??
                        DshPluginOperationError.recoveryRequired(Self.redacted(error.localizedDescription))
                    _ = try markRecoveryRequired(operation, error: recoveryError)
                    throw recoveryError
                }
            }
            guard let mutationDigest = operation.mutationDigest else {
                let error = DshPluginOperationError.recoveryRequired("缺少可验证的变更指纹")
                operation = try markRecoveryRequired(operation, error: error)
                throw error
            }
            guard try await pluginManager.pluginProfileDigest(at: profileURL) == mutationDigest else {
                let error = DshPluginOperationError.externalModification
                operation = try markRecoveryRequired(operation, error: error)
                throw error
            }
            do {
                operation = try await restore(
                    operation,
                    expectedCurrentDigest: mutationDigest,
                    verifyRestored: hooks?.verifyRestored
                )
                return DshPluginOperationResult(
                    operationID: operation.operationID,
                    phase: .restoring,
                    wasRestored: true
                )
            } catch {
                // A restoring record must never be left looking retryable
                // after the snapshot is missing, foreign, or otherwise
                // unusable. Keep the owner record for the next launch. If
                // the record itself changed, markRecoveryRequired throws its
                // persistenceConflict and preserves the fail-closed result.
                let recoveryError = (error as? DshPluginOperationError) ??
                    DshPluginOperationError.recoveryRequired(Self.redacted(error.localizedDescription))
                _ = try markRecoveryRequired(operation, error: recoveryError)
                throw recoveryError
            }

        case .committed:
            return DshPluginOperationResult(operationID: operation.operationID, phase: .committed)
        }

    }

    /// Delete the retained post-commit snapshot only after the caller has
    /// completed its ordinary startup health window.
    public func finalizeCommittedOperation(operationID: String) async throws {
        await Self.gate.acquire()
        defer { Self.gate.release() }
        let operation: DshPluginOperationState
        switch operationStore.status() {
        case .absent:
            return
        case .corrupt(let detail):
            throw DshPluginOperationError.recoveryRequired(detail)
        case .loaded(let loaded):
            operation = loaded
        }
        guard operation.operationID == operationID,
              operation.phase == .committed else {
            throw DshPluginOperationError.operationAlreadyPending(operation.operationID)
        }
        try await pluginManager.deletePluginOperationSnapshot(operation.snapshot)
        try clear(operation)
    }

    private func recoverVerifyingOrRestoring(
        _ original: DshPluginOperationState,
        profileURL: URL,
        mutationDigest: String,
        hooks: DshPluginOperationHooks?
    ) async throws -> DshPluginOperationResult {
        guard try await pluginManager.pluginProfileDigest(at: profileURL) == mutationDigest else {
            let error = DshPluginOperationError.externalModification
            _ = try markRecoveryRequired(original, error: error)
            throw error
        }

        if original.phase == .mutating || original.phase == .verifying,
           let hooks {
            var verifying = original
            if original.phase == .mutating {
                verifying = try advance(
                    original,
                    to: .verifying,
                    mutationDigest: mutationDigest
                )
                try persist(verifying, replacing: original.operationID)
            }
            do {
                try await hooks.verify(DshPluginOperationRequest(
                    action: verifying.action,
                    profile: verifying.profile,
                    profileDirectory: profileURL,
                    targetPackage: verifying.targetPackage,
                    targetPackages: verifying.targetPackages
                ))
                var committed = try advance(verifying, to: .committed)
                committed.lastError = nil
                try persist(committed, replacing: original.operationID)
                return DshPluginOperationResult(
                    operationID: committed.operationID,
                    phase: .committed
                )
            } catch {
                // Continue to restoration below; the persisted state records
                // the exact last observed mutation tree first.
            }
        }
        do {
            let restored = try await restore(
                original,
                expectedCurrentDigest: mutationDigest,
                verifyRestored: hooks?.verifyRestored
            )
            return DshPluginOperationResult(
                operationID: restored.operationID,
                phase: .restoring,
                wasRestored: true
            )
        } catch {
            // Startup recovery must leave a durable, explicit recovery
            // obligation regardless of whether restore, health verification,
            // snapshot deletion, or record cleanup failed.
            let recoveryError = (error as? DshPluginOperationError) ??
                DshPluginOperationError.recoveryRequired(Self.redacted(error.localizedDescription))
            _ = try markRecoveryRequired(original, error: recoveryError)
            throw recoveryError
        }
    }

    private func failAndRecover(
        _ original: DshPluginOperationState,
        request: DshPluginOperationRequest,
        originalError: Error,
        verifyRestored: @escaping @Sendable (DshPluginOperationRequest) async throws -> Void
    ) async throws {
        let safeError = Self.redacted(originalError.localizedDescription)
        var operation = original
        let currentDigest = try? await pluginManager.pluginProfileDigest(at: request.profileDirectory)

        // Failure before package mutation is safe to discard only if the
        // Profile remained byte-for-byte at the snapshot point.
        if original.phase == .prepared {
            guard currentDigest == original.snapshot.baselineDigest else {
                operation = try markRecoveryRequired(operation, error: DshPluginOperationError.externalModification)
                throw DshPluginOperationError.externalModification
            }
            do {
                try await deleteAndClear(operation)
                return
            } catch {
                let recoveryError = (error as? DshPluginOperationError) ??
                    DshPluginOperationError.recoveryRequired(Self.redacted(error.localizedDescription))
                _ = try markRecoveryRequired(operation, error: recoveryError)
                throw recoveryError
            }
        }

        guard let currentDigest else {
            operation = try markRecoveryRequired(operation, error: DshPluginOperationError.recoveryRequired("无法读取当前 Profile"))
            throw DshPluginOperationError.recoveryRequired(safeError)
        }
        do {
            operation = try advance(
                operation,
                to: .restoring,
                mutationDigest: currentDigest,
                lastError: safeError
            )
            try persist(operation, replacing: operation.operationID)
            _ = try await restore(
                operation,
                expectedCurrentDigest: currentDigest,
                verifyRestored: verifyRestored
            )
        } catch {
            let recoveryError = (error as? DshPluginOperationError) ??
                DshPluginOperationError.recoveryRequired(Self.redacted(error.localizedDescription))
            _ = try markRecoveryRequired(operation, error: recoveryError)
            throw recoveryError
        }
    }

    private func restore(
        _ operation: DshPluginOperationState,
        expectedCurrentDigest: String,
        verifyRestored: (@Sendable (DshPluginOperationRequest) async throws -> Void)? = nil
    ) async throws -> DshPluginOperationState {
        var restoring = operation
        if restoring.phase != .restoring {
            restoring = try advance(
                restoring,
                to: .restoring,
                mutationDigest: expectedCurrentDigest
            )
        }
        try persist(restoring, replacing: restoring.operationID)
        try await pluginManager.restorePluginOperationSnapshot(
            restoring.snapshot,
            expectedCurrentDigest: expectedCurrentDigest
        )
        if let verifyRestored {
            try await verifyRestored(makeRequest(from: restoring))
        }
        // Keep the durable restoring marker until every cleanup side effect
        // is complete. If the process exits after snapshot deletion but
        // before record deletion, the next launch can prove the baseline and
        // finish this protocol without attempting a second restore.
        try await pluginManager.deletePluginOperationSnapshot(restoring.snapshot)
        try clear(restoring)
        return restoring
    }

    private func makeRequest(from operation: DshPluginOperationState) -> DshPluginOperationRequest {
        DshPluginOperationRequest(
            action: operation.action,
            profile: operation.profile,
            profileDirectory: URL(fileURLWithPath: operation.snapshot.profileDirectory, isDirectory: true),
            targetPackage: operation.targetPackage,
            targetPackages: operation.targetPackages
        )
    }

    private func deleteAndClear(_ operation: DshPluginOperationState) async throws {
        do {
            try await pluginManager.deletePluginOperationSnapshot(operation.snapshot)
            try clear(operation)
        } catch {
            // A prepared record has not mutated the Profile. It is safe to
            // retain the record for an idempotent cleanup retry, but it must
            // never be silently discarded after a partial cleanup failure.
            throw error
        }
    }

    /// Complete cleanup after a successful restoration. The operation owner
    /// in the durable record is validated even when the snapshot directory
    /// has already disappeared; if a directory remains, the manager verifies
    /// its metadata before allowing deletion.
    private func finishRestoredCleanupIfSafe(_ operation: DshPluginOperationState) async throws -> Bool {
        guard operation.operationID == operation.snapshot.operationID,
              operation.profile == .desktop,
              operation.snapshot.profile == .desktop,
              operation.snapshot.ownerID == DshPluginOperationSnapshotReference.owner else {
            let error = DshPluginOperationError.recoveryRequired("插件事务快照所有权记录无效")
            _ = try markRecoveryRequired(operation, error: error)
            throw error
        }
        let snapshotExists = try await pluginManager.hasOwnedPluginOperationSnapshot(operation.snapshot)
        if snapshotExists {
            try await pluginManager.deletePluginOperationSnapshot(operation.snapshot)
        }
        try clear(operation)
        return true
    }

    @discardableResult
    private func markRecoveryRequired(
        _ operation: DshPluginOperationState,
        error: Error
    ) throws -> DshPluginOperationState {
        var next = operation
        next.phase = .recoveryRequired
        next.lastError = Self.redacted(error.localizedDescription)
        try persist(next, replacing: operation.operationID)
        return next
    }

    private func advance(
        _ operation: DshPluginOperationState,
        to phase: DshPluginOperationPhase,
        mutationDigest: String? = nil,
        lastError: String? = nil
    ) throws -> DshPluginOperationState {
        try DshPluginOperationTransition.advance(
            operation,
            to: phase,
            mutationDigest: mutationDigest,
            lastError: lastError
        )
    }

    private func persist(
        _ operation: DshPluginOperationState,
        replacing operationID: String?
    ) throws {
        if let operationID {
            let existingID = try operationStore.load()?.operationID
            guard existingID == operationID else {
                throw DshPluginOperationError.persistenceConflict(
                    expected: operationID,
                    actual: existingID
                )
            }
        } else {
            let existingID = try operationStore.load()?.operationID
            guard existingID == nil else {
                throw DshPluginOperationError.persistenceConflict(
                    expected: "无活动事务",
                    actual: existingID
                )
            }
        }
        try operationStore.write(operation)
    }

    private func clear(_ operation: DshPluginOperationState) throws {
        let existingID = try operationStore.load()?.operationID
        guard existingID == operation.operationID else {
            throw DshPluginOperationError.persistenceConflict(
                expected: operation.operationID,
                actual: existingID
            )
        }
        try operationStore.clear()
    }

    private func noOtherRecoveryIsPending() -> Bool {
        let state = stateManager.current
        return state.runtimeState.pending == nil && state.pendingProfileSwitch == nil
    }

    private func ensureProfileDigest(_ expected: String, at directory: URL) async throws {
        guard try await pluginManager.pluginProfileDigest(at: directory) == expected else {
            throw DshPluginOperationError.staleProfileChanged
        }
    }

    private func requireNoPersistedOperation() throws {
        switch operationStore.status() {
        case .absent:
            return
        case .loaded(let pending):
            throw DshPluginOperationError.operationAlreadyPending(pending.operationID)
        case .corrupt(let detail):
            throw DshPluginOperationError.recoveryRequired(detail)
        }
    }

    private func validate(_ request: DshPluginOperationRequest) throws {
        guard request.profile == .desktop else {
            throw DshPluginOperationError.desktopProfileRequired
        }
        let path = request.profileDirectory.standardizedFileURL.path
        guard path.hasPrefix("/"), path != "/", !path.isEmpty else {
            throw DshPluginOperationError.unsafeProfileDirectory
        }
        if FileManager.default.fileExists(atPath: path),
           request.profileDirectory.resolvingSymlinksInPath().path != path {
            throw DshPluginOperationError.unsafeProfileDirectory
        }
        switch request.action {
        case .updateAll:
            break
        case .install, .update, .remove:
            guard let package = request.targetPackage,
                  !package.isEmpty,
                  !package.contains(where: { $0.isNewline || $0 == "\0" }) else {
                throw DshPluginOperationError.unsafeProfileDirectory
            }
        }
    }

    private static func redacted(_ value: String) -> String {
        var text = value
        let replacements: [(String, String)] = [
            (#"(?i)(authorization\s*:\s*bearer\s+)[^\s\r\n]+"#, "$1[REDACTED]"),
            (#"(?i)(cookie\s*:\s*)[^\r\n]+"#, "$1[REDACTED]"),
            (#"(?i)([?&](?:token|access_token|refresh_token|api_key)=)[^&\s]+"#, "$1[REDACTED]")
        ]
        for (pattern, replacement) in replacements {
            text = text.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        text = text.replacingOccurrences(of: home, with: "~")
        if text.count > 8 * 1024 {
            text = String(text.prefix(8 * 1024)) + "…"
        }
        return text
    }
}
