import Foundation

/// Thread-safe, bounded storage for one active launch's diagnostic stream and
/// a small history of normalized failures. The store accepts events only from
/// the active launch context; a generation mismatch is rejected when the
/// event explicitly carries a generation.
public final class DshDiagnosticStore: @unchecked Sendable {
    public static let defaultMaximumRecords = 64
    public static let defaultMaximumLogBytes = 256 * 1024
    public static let defaultMaximumFieldBytes = 16 * 1024
    public static let defaultMaximumArchiveBytes = 16 * 1024 * 1024

    private struct Archive: Codable {
        let schemaVersion: Int
        let records: [DshDiagnosticRecord]
    }

    private let lock = NSLock()
    private let storageURL: URL?
    private let maximumRecords: Int
    private let maximumLogBytes: Int
    private let maximumFieldBytes: Int
    private let maximumArchiveBytes: Int
    private let now: @Sendable () -> Date
    private let redactor: DshSecretRedactor

    private var context: DshDiagnosticLaunchContext?
    private var phase: DshLaunchPhase?
    private var recordsValue: [DshDiagnosticRecord]
    private var logChunks: [Data]
    private var logByteCount = 0
    private var persistenceErrorValue: String?
    private var loadErrorValue: String?

    public var lastPersistenceError: String? {
        lock.lock()
        defer { lock.unlock() }
        return persistenceErrorValue
    }

    /// A malformed or oversized diagnostic archive is observable to the
    /// caller, but is intentionally not treated as a transaction failure.
    public var lastLoadError: String? {
        lock.lock()
        defer { lock.unlock() }
        return loadErrorValue
    }

    public init(
        storageURL: URL? = nil,
        maximumRecords: Int = DshDiagnosticStore.defaultMaximumRecords,
        maximumLogBytes: Int = DshDiagnosticStore.defaultMaximumLogBytes,
        maximumFieldBytes: Int = DshDiagnosticStore.defaultMaximumFieldBytes,
        maximumArchiveBytes: Int = DshDiagnosticStore.defaultMaximumArchiveBytes,
        now: @escaping @Sendable () -> Date = { Date() },
        redactor: DshSecretRedactor = DshSecretRedactor()
    ) {
        self.storageURL = storageURL
        self.maximumRecords = max(1, maximumRecords)
        self.maximumLogBytes = max(1, maximumLogBytes)
        self.maximumFieldBytes = max(64, maximumFieldBytes)
        self.maximumArchiveBytes = max(1, maximumArchiveBytes)
        self.now = now
        self.redactor = redactor
        self.context = nil
        self.phase = nil
        self.recordsValue = []
        self.logChunks = []
        self.persistenceErrorValue = nil
        self.loadErrorValue = nil
        loadArchive()
    }

    /// Begin a new launch and discard the previous active stream. Historical
    /// records remain available, but events carrying an older launch ID will
    /// be refused by every mutating API.
    public func beginLaunch(_ context: DshDiagnosticLaunchContext) {
        lock.lock()
        self.context = sanitizedContext(context)
        self.phase = .preparing
        logChunks.removeAll(keepingCapacity: true)
        logByteCount = 0
        lock.unlock()
        persist()
    }

    /// End only the named launch. This does not erase its historical records.
    public func endLaunch(launchID: UUID) -> Bool {
        lock.lock()
        guard context?.launchID == launchID else {
            lock.unlock()
            return false
        }
        context = nil
        phase = nil
        logChunks.removeAll(keepingCapacity: false)
        logByteCount = 0
        lock.unlock()
        persist()
        return true
    }

    /// Bind the process generation after launch preparation has started. This
    /// keeps preparation diagnostics while making later process/control events
    /// reject the old generation.
    @discardableResult
    public func bindGeneration(
        _ generationID: UUID,
        launchID: UUID
    ) -> Bool {
        lock.lock()
        guard let current = context, current.launchID == launchID else {
            lock.unlock()
            return false
        }
        guard current.generationID == nil || current.generationID == generationID else {
            lock.unlock()
            return false
        }
        if current.generationID == generationID {
            // Binding the same generation again is harmless and must not
            // reopen acceptance for an older process generation.
            lock.unlock()
            return true
        }
        context = DshDiagnosticLaunchContext(
            launchID: current.launchID,
            generationID: generationID,
            runtimeVersion: current.runtimeVersion,
            profile: current.profile,
            startedAt: current.startedAt
        )
        lock.unlock()
        persist()
        return true
    }

    @discardableResult
    public func setPhase(
        _ phase: DshLaunchPhase,
        launchID: UUID,
        generationID: UUID? = nil
    ) -> Bool {
        lock.lock()
        guard acceptsLocked(launchID: launchID, generationID: generationID) else {
            lock.unlock()
            return false
        }
        self.phase = phase
        lock.unlock()
        return true
    }

    /// Append one output line or text fragment. Redaction happens before the
    /// bytes enter the bounded buffer and before persistence.
    @discardableResult
    public func appendLog(
        _ text: String,
        launchID: UUID,
        generationID: UUID? = nil,
        source: DshDiagnosticSource = .processOutput
    ) -> Bool {
        lock.lock()
        guard acceptsLocked(launchID: launchID, generationID: generationID) else {
            lock.unlock()
            return false
        }
        let redacted = redactor.redact(text)
        let normalized = normalizedLogChunk(redacted)
        let data = Data(normalized.utf8)
        appendLogDataLocked(data)
        lock.unlock()
        _ = source // Kept in the API so callers can preserve event provenance.
        return true
    }

    /// Record one failure. A nil result means that the event belonged to a
    /// stale launch or generation and was intentionally ignored.
    @discardableResult
    public func record(
        launchID: UUID,
        generationID: UUID? = nil,
        phase: DshLaunchPhase,
        code: DshDiagnosticCode,
        summary: String,
        technicalDetail: String? = nil,
        retryability: DshDiagnosticRetryability,
        source: DshDiagnosticSource,
        evidence: [DshDiagnosticEvidence] = []
    ) -> DshDiagnosticRecord? {
        lock.lock()
        guard let context,
              acceptsLocked(launchID: launchID, generationID: generationID) else {
            lock.unlock()
            return nil
        }

        let eventGeneration = generationID ?? context.generationID
        let timestamp = now()
        let normalizedSummary = boundedRedacted(summary)
        let normalizedDetail = technicalDetail.map(boundedRedacted)
        guard evidence.allSatisfy({
            $0.generationID == nil || $0.generationID == eventGeneration
        }) else {
            lock.unlock()
            return nil
        }
        let normalizedEvidence = normalizeEvidence(evidence)
        let candidate = DshDiagnosticRecord(
            launchID: launchID,
            generationID: eventGeneration,
            runtimeVersion: context.runtimeVersion.map(boundedRedacted),
            profile: context.profile.map(boundedRedacted),
            timestamp: timestamp,
            phase: phase,
            code: code,
            summary: normalizedSummary,
            technicalDetail: normalizedDetail,
            retryability: retryability,
            source: source,
            evidence: normalizedEvidence
        )

        let result: DshDiagnosticRecord
        if let index = recordsValue.firstIndex(where: {
            $0.launchID == candidate.launchID
                && $0.generationID == candidate.generationID
                && $0.phase == candidate.phase
                && $0.code == candidate.code
                && $0.summary == candidate.summary
        }) {
            var merged = recordsValue[index]
            merged.lastSeenAt = timestamp
            merged.occurrenceCount += 1
            merged.evidence = mergeEvidence(merged.evidence, normalizedEvidence)
            recordsValue[index] = merged
            result = merged
        } else {
            recordsValue.append(candidate)
            if recordsValue.count > maximumRecords {
                recordsValue.removeFirst(recordsValue.count - maximumRecords)
            }
            result = candidate
        }
        self.phase = phase
        lock.unlock()
        persist()
        return result
    }

    public func records(for launchID: UUID? = nil) -> [DshDiagnosticRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let launchID else { return recordsValue }
        return recordsValue.filter { $0.launchID == launchID }
    }

    public func diagnosticOutput(for launchID: UUID? = nil) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let launchID, context?.launchID != launchID { return "" }
        return String(data: logChunks.reduce(into: Data()) { $0.append($1) }, encoding: .utf8) ?? ""
    }

    public func snapshot(for launchID: UUID) -> DshDiagnosticSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard context?.launchID == launchID else { return nil }
        let log = String(data: logChunks.reduce(into: Data()) { $0.append($1) }, encoding: .utf8) ?? ""
        return DshDiagnosticSnapshot(
            context: context,
            phase: phase,
            records: recordsValue.filter { $0.launchID == launchID },
            log: log,
            generatedAt: now()
        )
    }

    public var currentContext: DshDiagnosticLaunchContext? {
        lock.lock()
        defer { lock.unlock() }
        return context
    }

    public var currentPhase: DshLaunchPhase? {
        lock.lock()
        defer { lock.unlock() }
        return phase
    }

    private func acceptsLocked(launchID: UUID, generationID: UUID?) -> Bool {
        guard let context, context.launchID == launchID else { return false }
        guard let expected = context.generationID, let generationID else { return true }
        return expected == generationID
    }

    private func normalizeEvidence(_ values: [DshDiagnosticEvidence]) -> [DshDiagnosticEvidence] {
        var result: [DshDiagnosticEvidence] = []
        for value in values.prefix(16) {
            let normalized = DshDiagnosticEvidence(
                source: value.source,
                confidence: value.confidence,
                summary: boundedRedacted(value.summary),
                pluginName: value.pluginName.map(boundedRedacted),
                generationID: value.generationID
            )
            if !result.contains(normalized) { result.append(normalized) }
        }
        return result
    }

    private func sanitizedContext(_ value: DshDiagnosticLaunchContext) -> DshDiagnosticLaunchContext {
        DshDiagnosticLaunchContext(
            launchID: value.launchID,
            generationID: value.generationID,
            runtimeVersion: value.runtimeVersion.map(boundedRedacted),
            profile: value.profile.map(boundedRedacted),
            startedAt: value.startedAt
        )
    }

    private func sanitizedRecord(_ value: DshDiagnosticRecord) -> DshDiagnosticRecord {
        DshDiagnosticRecord(
            id: value.id,
            launchID: value.launchID,
            generationID: value.generationID,
            runtimeVersion: value.runtimeVersion.map(boundedRedacted),
            profile: value.profile.map(boundedRedacted),
            timestamp: value.timestamp,
            lastSeenAt: value.lastSeenAt,
            phase: value.phase,
            code: value.code,
            summary: boundedRedacted(value.summary),
            technicalDetail: value.technicalDetail.map(boundedRedacted),
            retryability: value.retryability,
            source: value.source,
            evidence: normalizeEvidence(value.evidence),
            occurrenceCount: min(max(1, value.occurrenceCount), 1_000_000)
        )
    }

    private func mergeEvidence(
        _ existing: [DshDiagnosticEvidence],
        _ additions: [DshDiagnosticEvidence]
    ) -> [DshDiagnosticEvidence] {
        var merged = existing
        for value in additions where !merged.contains(value) {
            guard merged.count < 16 else { break }
            merged.append(value)
        }
        return merged
    }

    private func boundedRedacted(_ value: String) -> String {
        let redacted = redactor.redact(value)
        return Self.utf8Truncated(redacted, maxBytes: maximumFieldBytes)
    }

    private func normalizedLogChunk(_ value: String) -> String {
        value.hasSuffix("\n") ? value : value + "\n"
    }

    private func appendLogDataLocked(_ data: Data) {
        guard !data.isEmpty else { return }
        let bounded = Self.utf8Suffix(data, maxBytes: maximumLogBytes)
        logChunks.append(bounded)
        logByteCount += bounded.count
        while logByteCount > maximumLogBytes, !logChunks.isEmpty {
            let removed = logChunks.removeFirst()
            logByteCount -= removed.count
        }
    }

    private func persist() {
        guard let storageURL else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            // Keep the lock through encoding and the atomic replacement. This
            // serializes writers and makes every write observe the latest
            // records, so an older snapshot cannot land after a newer one.
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try boundedArchiveDataLocked()
            try data.write(to: storageURL, options: .atomic)
            persistenceErrorValue = nil
        } catch {
            persistenceErrorValue = sanitizedStorageError(error)
        }
    }

    /// Encode the latest records while respecting the on-disk byte limit. The
    /// limit applies to encoded bytes, rather than to the in-memory field
    /// limits, so an archive can never be written in a form that its next
    /// reader would reject. Old records are discarded first; if one record is
    /// still too large, its human text/evidence is progressively shortened.
    private func boundedArchiveDataLocked() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var candidates = recordsValue
        while true {
            let data = try encoder.encode(Archive(schemaVersion: 1, records: candidates))
            if data.count <= maximumArchiveBytes {
                return data
            }
            guard candidates.count > 1 else { break }
            candidates.removeFirst()
        }

        if let record = candidates.first {
            // Keep the newest record where possible. The first pass preserves
            // all fields, then progressively budgets free text and evidence.
            var budget = maximumFieldBytes
            while true {
                let shortened = archiveRecord(record, fieldBytes: budget, compactMetadata: false)
                let data = try encoder.encode(Archive(schemaVersion: 1, records: [shortened]))
                if data.count <= maximumArchiveBytes {
                    return data
                }
                if budget == 0 { break }
                budget = budget <= 64 ? 0 : budget / 2
            }

            // Very small limits may require dropping optional metadata as
            // well. This keeps a useful stable code/phase record when it can
            // fit, while still allowing the empty archive fallback below.
            let compact = archiveRecord(record, fieldBytes: 0, compactMetadata: true)
            let compactData = try encoder.encode(Archive(schemaVersion: 1, records: [compact]))
            if compactData.count <= maximumArchiveBytes {
                return compactData
            }
        }

        let emptyData = try encoder.encode(Archive(schemaVersion: 1, records: []))
        guard emptyData.count <= maximumArchiveBytes else {
            throw NSError(
                domain: "DshDiagnosticStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "诊断归档大小上限过小，无法写入有效归档"]
            )
        }
        return emptyData
    }

    private func archiveRecord(
        _ value: DshDiagnosticRecord,
        fieldBytes: Int,
        compactMetadata: Bool
    ) -> DshDiagnosticRecord {
        let bounded = { (text: String) in
            Self.utf8Truncated(text, maxBytes: fieldBytes)
        }
        let evidence = compactMetadata
            ? []
            : value.evidence.map { item in
                DshDiagnosticEvidence(
                    source: item.source,
                    confidence: item.confidence,
                    summary: bounded(item.summary),
                    pluginName: item.pluginName.map(bounded),
                    generationID: item.generationID
                )
            }
        return DshDiagnosticRecord(
            id: value.id,
            launchID: value.launchID,
            generationID: compactMetadata ? nil : value.generationID,
            runtimeVersion: compactMetadata ? nil : value.runtimeVersion.map(bounded),
            profile: compactMetadata ? nil : value.profile.map(bounded),
            timestamp: value.timestamp,
            lastSeenAt: value.lastSeenAt,
            phase: value.phase,
            code: value.code,
            summary: bounded(value.summary),
            technicalDetail: compactMetadata ? nil : value.technicalDetail.map(bounded),
            retryability: value.retryability,
            source: value.source,
            evidence: evidence,
            occurrenceCount: value.occurrenceCount
        )
    }

    private func loadArchive() {
        guard let storageURL else { return }
        guard let values = try? storageURL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize else {
            // A missing file is the normal first-launch state. Other metadata
            // failures are observable but do not block diagnostics in memory.
            if FileManager.default.fileExists(atPath: storageURL.path) {
                setLoadError("无法读取诊断归档大小")
            }
            return
        }
        guard fileSize <= maximumArchiveBytes else {
            setLoadError("诊断归档超过大小上限")
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: storageURL, options: [.mappedIfSafe])
        } catch {
            setLoadError(sanitizedStorageError(error))
            return
        }
        let archive: Archive
        do {
            archive = try JSONDecoder().decode(Archive.self, from: data)
        } catch {
            setLoadError(sanitizedStorageError(error))
            return
        }
        guard archive.schemaVersion == 1 else {
            setLoadError("不支持的诊断归档版本")
            return
        }
        lock.lock()
        recordsValue = archive.records
            .suffix(maximumRecords)
            .map(sanitizedRecord)
        lock.unlock()
    }

    private func setLoadError(_ message: String) {
        lock.lock()
        loadErrorValue = Self.utf8Truncated(redactor.redact(message), maxBytes: maximumFieldBytes)
        lock.unlock()
    }

    private func sanitizedStorageError(_ error: Error) -> String {
        var message = redactor.redact(error.localizedDescription)
        if let storagePath = storageURL?.path, !storagePath.isEmpty {
            message = message.replacingOccurrences(of: storagePath, with: "[PATH]")
        }
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if !homePath.isEmpty {
            message = message.replacingOccurrences(of: homePath, with: "~")
        }
        return Self.utf8Truncated(message, maxBytes: maximumFieldBytes)
    }

    private static func utf8Truncated(_ value: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let data = Data(value.utf8)
        guard data.count > maxBytes else { return value }
        return String(data: utf8Suffix(data, maxBytes: maxBytes), encoding: .utf8) ?? ""
    }

    private static func utf8Suffix(_ data: Data, maxBytes: Int) -> Data {
        guard data.count > maxBytes else { return data }
        let start = data.count - maxBytes
        for offset in 0..<min(4, maxBytes) {
            let candidate = Data(data.dropFirst(start + offset))
            if String(data: candidate, encoding: .utf8) != nil { return candidate }
        }
        return Data(data.suffix(maxBytes))
    }
}
