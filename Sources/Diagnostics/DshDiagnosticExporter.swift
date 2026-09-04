import Foundation

/// Optional application metadata supplied by the native coordinator. These
/// are the only application and Runtime fields that enter an export.
public struct DshDiagnosticExportMetadata: Equatable, Sendable {
    public let appVersion: String?
    public let buildNumber: String?
    public let runtimeVersion: String?
    public let systemArchitecture: String?
    public let operatingSystem: String?
    public let plugins: [DshDiagnosticExportPlugin]

    public init(
        appVersion: String? = nil,
        buildNumber: String? = nil,
        runtimeVersion: String? = nil,
        systemArchitecture: String? = DshDiagnosticExportMetadata.defaultArchitecture,
        operatingSystem: String? = ProcessInfo.processInfo.operatingSystemVersionString,
        plugins: [DshDiagnosticExportPlugin] = []
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.runtimeVersion = runtimeVersion
        self.systemArchitecture = systemArchitecture
        self.operatingSystem = operatingSystem
        self.plugins = plugins
    }

    public static var defaultArchitecture: String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "x86_64"
#else
        return "unknown"
#endif
    }
}

public struct DshDiagnosticExportPlugin: Codable, Equatable, Sendable {
    public let name: String
    public let version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

/// Limits apply after redaction and before JSON encoding. This prevents a
/// large or malformed process log from turning a preview into an unbounded
/// memory or disk operation.
public struct DshDiagnosticExportLimits: Equatable, Sendable {
    public let maximumRecords: Int
    public let maximumPlugins: Int
    public let maximumLogBytes: Int
    public let maximumFieldBytes: Int
    public let maximumPreviewBytes: Int

    public init(
        maximumRecords: Int = 64,
        maximumPlugins: Int = 64,
        maximumLogBytes: Int = 128 * 1024,
        maximumFieldBytes: Int = 8 * 1024,
        maximumPreviewBytes: Int = 512 * 1024
    ) {
        self.maximumRecords = max(1, maximumRecords)
        self.maximumPlugins = max(0, maximumPlugins)
        self.maximumLogBytes = max(0, maximumLogBytes)
        self.maximumFieldBytes = max(64, maximumFieldBytes)
        self.maximumPreviewBytes = max(1024, maximumPreviewBytes)
    }
}

public enum DshDiagnosticExportError: Error, LocalizedError, Equatable, Sendable {
    case unableToEncode
    case previewTooLarge
    case invalidDestination
    case destinationDirectoryMissing

    public var errorDescription: String? {
        switch self {
        case .unableToEncode: return "无法生成诊断导出预览。"
        case .previewTooLarge: return "诊断预览超过大小上限。"
        case .invalidDestination: return "诊断导出位置无效。"
        case .destinationDirectoryMissing: return "诊断导出位置的目录不存在。"
        }
    }
}

/// An in-memory preview. Creating or inspecting this value never creates a
/// file and has no network side effect.
public struct DshDiagnosticExportPreview: Sendable {
    public let schemaVersion: Int
    public let json: String
    public let byteCount: Int
    public let redactionsApplied: Bool

    public init(schemaVersion: Int, json: String, byteCount: Int, redactionsApplied: Bool) {
        self.schemaVersion = schemaVersion
        self.json = json
        self.byteCount = byteCount
        self.redactionsApplied = redactionsApplied
    }
}

/// A user-approved export that is ready to be written. The data remains in
/// memory until `writeAtomically(to:)` is explicitly called by the save flow.
public struct DshDiagnosticExportPlan: Sendable {
    public let schemaVersion: Int
    public let suggestedFilename: String
    public let data: Data

    public init(schemaVersion: Int, suggestedFilename: String, data: Data) {
        self.schemaVersion = schemaVersion
        self.suggestedFilename = suggestedFilename
        self.data = data
    }

    /// Write a selected destination using Foundation's atomic replacement.
    /// The parent directory must already exist, as it does for a save-panel
    /// destination; no directory tree is created from untrusted input.
    public func writeAtomically(to destination: URL) throws {
        guard destination.isFileURL, !destination.path.isEmpty else {
            throw DshDiagnosticExportError.invalidDestination
        }
        let directory = destination.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw DshDiagnosticExportError.destinationDirectoryMissing
        }
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw error
        }
    }
}

/// Builds a small, versioned, redacted diagnostic document. This type is
/// intentionally independent from AppKit so preview and boundary tests can
/// execute as a Swift behavior harness.
public struct DshDiagnosticExporter: Sendable {
    public static let schemaVersion = 1

    private let limits: DshDiagnosticExportLimits
    private let redactor: DshSecretRedactor
    private let pathPrefixes: [String]

    public init(
        limits: DshDiagnosticExportLimits = DshDiagnosticExportLimits(),
        redactor: DshSecretRedactor = DshSecretRedactor(),
        pathPrefixes: [String] = []
    ) {
        self.limits = limits
        self.redactor = redactor
        self.pathPrefixes = pathPrefixes.filter { !$0.isEmpty }
    }

    public func preview(
        snapshot: DshDiagnosticSnapshot,
        metadata: DshDiagnosticExportMetadata = DshDiagnosticExportMetadata()
    ) throws -> DshDiagnosticExportPreview {
        let rendered = try render(snapshot: snapshot, metadata: metadata)
        return DshDiagnosticExportPreview(
            schemaVersion: Self.schemaVersion,
            json: rendered.json,
            byteCount: rendered.data.count,
            redactionsApplied: rendered.redactionsApplied
        )
    }

    public func makePlan(
        snapshot: DshDiagnosticSnapshot,
        metadata: DshDiagnosticExportMetadata = DshDiagnosticExportMetadata(),
        suggestedFilename: String? = nil
    ) throws -> DshDiagnosticExportPlan {
        let rendered = try render(snapshot: snapshot, metadata: metadata)
        return DshDiagnosticExportPlan(
            schemaVersion: Self.schemaVersion,
            suggestedFilename: suggestedFilename ?? Self.defaultFilename(at: snapshot.generatedAt),
            data: rendered.data
        )
    }

    public static func defaultFilename(at date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        return "dsh-diagnostic-\(stamp).json"
    }

    private struct Rendered {
        let json: String
        let data: Data
        let redactionsApplied: Bool
    }

    private struct ExportDocument: Codable {
        let schemaVersion: Int
        let generatedAt: String
        let appVersion: String?
        let buildNumber: String?
        let runtimeVersion: String?
        let systemArchitecture: String?
        let operatingSystem: String?
        let launchID: String?
        let generationID: String?
        let profile: String?
        let startedAt: String?
        let phase: String?
        let plugins: [ExportPlugin]
        let records: [ExportRecord]
        let log: String
        let redactionsApplied: Bool
    }

    private struct ExportPlugin: Codable {
        let name: String
        let version: String?
    }

    private struct ExportEvidence: Codable {
        let source: String
        let confidence: String
        let summary: String
        let pluginName: String?
    }

    private struct ExportRecord: Codable {
        let id: String
        let launchID: String
        let generationID: String?
        let timestamp: String
        let lastSeenAt: String
        let phase: String
        let code: String
        let summary: String
        let technicalDetail: String?
        let retryability: String
        let source: String
        let evidence: [ExportEvidence]
        let occurrenceCount: Int
    }

    private func render(
        snapshot: DshDiagnosticSnapshot,
        metadata: DshDiagnosticExportMetadata
    ) throws -> Rendered {
        let context = snapshot.context
        let appVersion = bounded(metadata.appVersion)
        let buildNumber = bounded(metadata.buildNumber)
        let runtimeVersion = bounded(metadata.runtimeVersion ?? context?.runtimeVersion)
        let systemArchitecture = bounded(metadata.systemArchitecture)
        let operatingSystem = bounded(metadata.operatingSystem)
        let launchID = context?.launchID.uuidString
        let generationID = context?.generationID?.uuidString
        let profile = bounded(context?.profile)
        let startedAt = context.map { iso8601($0.startedAt) }
        let generatedAt = iso8601(snapshot.generatedAt)

        var recordValues = snapshot.records
            .suffix(limits.maximumRecords)
            .map { exportRecord($0) }
        var pluginValues = metadata.plugins
            .prefix(limits.maximumPlugins)
            .map { ExportPlugin(name: bounded($0.name) ?? "", version: bounded($0.version)) }
        var log = boundedLog(snapshot.log)
        var fieldLimit = limits.maximumFieldBytes

        while true {
            let document = ExportDocument(
                schemaVersion: Self.schemaVersion,
                generatedAt: generatedAt,
                appVersion: appVersion,
                buildNumber: buildNumber,
                runtimeVersion: runtimeVersion,
                systemArchitecture: systemArchitecture,
                operatingSystem: operatingSystem,
                launchID: launchID,
                generationID: generationID,
                profile: profile,
                startedAt: startedAt,
                phase: snapshot.phase?.rawValue,
                plugins: pluginValues,
                records: recordValues,
                log: log,
                redactionsApplied: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(document) else {
                throw DshDiagnosticExportError.unableToEncode
            }
            if data.count <= limits.maximumPreviewBytes {
                let json = String(data: data, encoding: .utf8) ?? "{}"
                return Rendered(json: json, data: data, redactionsApplied: true)
            }

            // Trim the least useful bulk first while retaining structured
            // failure codes and phases. Every retry re-encodes valid JSON.
            if !log.isEmpty {
                let next = max(0, Data(log.utf8).count / 2)
                log = utf8Suffix(log, maxBytes: next)
                continue
            }
            if recordValues.count > 1 {
                recordValues.removeFirst()
                continue
            }
            if !pluginValues.isEmpty {
                pluginValues.removeLast()
                continue
            }
            if fieldLimit > 64 {
                fieldLimit = max(64, fieldLimit / 2)
                recordValues = recordValues.map { boundedRecord($0, maxBytes: fieldLimit) }
                log = utf8Suffix(log, maxBytes: fieldLimit)
                continue
            }
            throw DshDiagnosticExportError.previewTooLarge
        }
    }

    private func exportRecord(_ value: DshDiagnosticRecord) -> ExportRecord {
        ExportRecord(
            id: value.id.uuidString,
            launchID: value.launchID.uuidString,
            generationID: value.generationID?.uuidString,
            timestamp: iso8601(value.timestamp),
            lastSeenAt: iso8601(value.lastSeenAt),
            phase: value.phase.rawValue,
            code: value.code.rawValue,
            summary: bounded(value.summary) ?? "",
            technicalDetail: bounded(value.technicalDetail),
            retryability: value.retryability.rawValue,
            source: value.source.rawValue,
            evidence: value.evidence.prefix(16).map {
                ExportEvidence(
                    source: $0.source.rawValue,
                    confidence: $0.confidence.rawValue,
                    summary: bounded($0.summary) ?? "",
                    pluginName: bounded($0.pluginName)
                )
            },
            occurrenceCount: min(max(1, value.occurrenceCount), 1_000_000)
        )
    }

    private func boundedRecord(_ value: ExportRecord, maxBytes: Int) -> ExportRecord {
        func cap(_ value: String) -> String { utf8Prefix(value, maxBytes: maxBytes) }
        return ExportRecord(
            id: value.id,
            launchID: value.launchID,
            generationID: value.generationID,
            timestamp: value.timestamp,
            lastSeenAt: value.lastSeenAt,
            phase: value.phase,
            code: value.code,
            summary: cap(value.summary),
            technicalDetail: value.technicalDetail.map(cap),
            retryability: value.retryability,
            source: value.source,
            evidence: value.evidence.map {
                ExportEvidence(
                    source: $0.source,
                    confidence: $0.confidence,
                    summary: cap($0.summary),
                    pluginName: $0.pluginName.map(cap)
                )
            },
            occurrenceCount: value.occurrenceCount
        )
    }

    private func bounded(_ value: String?) -> String? {
        value.map { utf8Prefix(redact($0), maxBytes: limits.maximumFieldBytes) }
    }

    private func boundedLog(_ value: String) -> String {
        utf8Suffix(redact(value), maxBytes: limits.maximumLogBytes)
    }

    private func redact(_ value: String) -> String {
        var output = redactor.redact(value)
        output = redactSensitiveAssignments(output)
        let prefixes = pathPrefixes + [FileManager.default.homeDirectoryForCurrentUser.path]
        for prefix in prefixes where !prefix.isEmpty {
            output = output.replacingOccurrences(of: prefix, with: "[USER_HOME]")
        }
        output = replaceGenericUserPaths(output, root: "/Users/")
        output = replaceGenericUserPaths(output, root: "/home/")
        return output
    }

    /// Cover short fixture credentials as well as the longer protocol-shaped
    /// values handled by DshSecretRedactor.
    private func redactSensitiveAssignments(_ value: String) -> String {
        let keys = ["token", "cookie", "authorization", "password", "api_key", "apikey", "secret"]
        var output = value
        for key in keys {
            var searchStart = output.startIndex
            while let range = output.range(of: key, options: [.caseInsensitive], range: searchStart..<output.endIndex) {
                let afterKey = range.upperBound
                var cursor = afterKey
                while cursor < output.endIndex, output[cursor].isWhitespace { cursor = output.index(after: cursor) }
                guard cursor < output.endIndex, output[cursor] == ":" || output[cursor] == "=" else {
                    searchStart = afterKey
                    continue
                }
                cursor = output.index(after: cursor)
                while cursor < output.endIndex, output[cursor].isWhitespace { cursor = output.index(after: cursor) }
                let valueStart = cursor
                while cursor < output.endIndex {
                    let character = output[cursor]
                    if character.isWhitespace || ",;&\r\n\"'".contains(character) { break }
                    cursor = output.index(after: cursor)
                }
                guard valueStart < cursor else {
                    searchStart = afterKey
                    continue
                }
                output.replaceSubrange(valueStart..<cursor, with: DshSecretRedactor.replacement)
                searchStart = output.index(valueStart, offsetBy: DshSecretRedactor.replacement.count)
            }
        }
        return output
    }

    private func replaceGenericUserPaths(_ value: String, root: String) -> String {
        var output = value
        var searchStart = output.startIndex
        while let rootRange = output.range(of: root, range: searchStart..<output.endIndex) {
            let usernameStart = rootRange.upperBound
            guard let usernameEnd = output[usernameStart...].firstIndex(of: "/") else {
                guard usernameStart < output.endIndex else { break }
                output.replaceSubrange(rootRange.lowerBound..<output.endIndex, with: "[USER_HOME]")
                break
            }
            var pathEnd = usernameEnd
            while pathEnd < output.endIndex {
                let character = output[pathEnd]
                if character.isWhitespace || "\"'<>[]{}(),;".contains(character) { break }
                pathEnd = output.index(after: pathEnd)
            }
            let suffix = String(output[usernameEnd..<pathEnd])
            output.replaceSubrange(rootRange.lowerBound..<pathEnd, with: "[USER_HOME]" + suffix)
            searchStart = output.index(rootRange.lowerBound, offsetBy: "[USER_HOME]".count + suffix.count)
        }
        return output
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func utf8Prefix(_ value: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let data = Data(value.utf8)
        guard data.count > maxBytes else { return value }
        for end in stride(from: maxBytes, through: max(0, maxBytes - 4), by: -1) {
            if let result = String(data: data.prefix(end), encoding: .utf8) { return result }
        }
        return ""
    }

    private func utf8Suffix(_ value: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let data = Data(value.utf8)
        guard data.count > maxBytes else { return value }
        let start = max(0, data.count - maxBytes)
        for offset in 0..<min(4, data.count - start + 1) {
            if let result = String(data: data.dropFirst(start + offset), encoding: .utf8) { return result }
        }
        return ""
    }
}
