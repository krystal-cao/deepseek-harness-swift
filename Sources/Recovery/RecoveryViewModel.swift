import Combine
import Foundation

/// The actions a recovery coordinator may perform for the native recovery
/// surface. The view model does not discover services, inspect global state,
/// or invoke Node; a coordinator supplies these closures when it wires the
/// component into the application.
public struct DshRecoveryActionRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let launchID: UUID
    public let action: DshRecoveryAction
    /// Monotonic per-view-model sequence used by bridges that cannot safely
    /// retain a UUID object. The UUID remains the opaque request identity;
    /// both values must match before a completion can settle an action.
    public let sequence: UInt64

    public init(
        id: UUID = UUID(),
        launchID: UUID,
        action: DshRecoveryAction,
        sequence: UInt64 = 0
    ) {
        self.id = id
        self.launchID = launchID
        self.action = action
        self.sequence = sequence
    }

    public var completionToken: DshRecoveryActionCompletionToken {
        DshRecoveryActionCompletionToken(
            launchID: launchID,
            action: action,
            sequence: sequence
        )
    }
}

/// A small value suitable for an asynchronous completion callback. A token
/// from a previous request can never complete a later request of the same
/// action because the sequence is part of the identity check.
public struct DshRecoveryActionCompletionToken: Equatable, Sendable {
    public let launchID: UUID
    public let action: DshRecoveryAction
    public let sequence: UInt64

    public init(launchID: UUID, action: DshRecoveryAction, sequence: UInt64) {
        self.launchID = launchID
        self.action = action
        self.sequence = sequence
    }
}

/// A recovery removal request carries every identity the coordinator must
/// re-check before it can leave the read-only recovery surface.  The plan
/// token alone is intentionally insufficient: launch, generation and Profile
/// identity are all part of the request.
public struct DshRecoveryPluginRemovalRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let launchID: UUID
    public let planToken: UUID
    public let pluginName: String
    public let generationID: UUID
    public let originalProfile: String
    public let originalProfilePath: String

    public init(
        id: UUID = UUID(),
        launchID: UUID,
        planToken: UUID,
        pluginName: String,
        generationID: UUID,
        originalProfile: String,
        originalProfilePath: String = ""
    ) {
        self.id = id
        self.launchID = launchID
        self.planToken = planToken
        self.pluginName = pluginName
        self.generationID = generationID
        self.originalProfile = originalProfile
        self.originalProfilePath = originalProfilePath
    }

    /// This is an executable intent, not resolver authority.  The MainWindow
    /// coordinator still revalidates every field before entering P01.
    public var isExecutable: Bool { true }
}

public struct DshRecoveryActions {
    public var retry: (DshRecoveryActionRequest) -> Void
    public var openSettings: (DshRecoveryActionRequest) -> Void
    public var startSafeMode: (DshRecoveryActionRequest) -> Void
    public var removePluginAndRetry: (DshRecoveryPluginRemovalRequest) -> Void
    public var copyDiagnosticSummary: (String) -> Void
    public var saveDiagnosticExport: (DshDiagnosticExportPlan) -> Void

    public init(
        retry: @escaping (DshRecoveryActionRequest) -> Void = { _ in },
        openSettings: @escaping (DshRecoveryActionRequest) -> Void = { _ in },
        startSafeMode: @escaping (DshRecoveryActionRequest) -> Void = { _ in },
        removePluginAndRetry: @escaping (DshRecoveryPluginRemovalRequest) -> Void = { _ in },
        copyDiagnosticSummary: @escaping (String) -> Void = { _ in },
        saveDiagnosticExport: @escaping (DshDiagnosticExportPlan) -> Void = { _ in }
    ) {
        self.retry = retry
        self.openSettings = openSettings
        self.startSafeMode = startSafeMode
        self.removePluginAndRetry = removePluginAndRetry
        self.copyDiagnosticSummary = copyDiagnosticSummary
        self.saveDiagnosticExport = saveDiagnosticExport
    }
}

public enum DshRecoveryAction: String, CaseIterable, Sendable {
    case retry
    case openSettings
    case safeMode
}

/// Main-actor state for the reusable recovery UI. A launch ID is fixed for
/// the lifetime of this object; snapshots from another launch or from an
/// older generated event are ignored instead of reverting visible state.
@MainActor
public final class DshRecoveryViewModel: ObservableObject {
    public let launchID: UUID

    @Published public private(set) var snapshot: DshDiagnosticSnapshot?
    @Published public private(set) var actionInFlight: DshRecoveryAction?
    @Published public private(set) var actionRequest: DshRecoveryActionRequest?
    @Published public private(set) var actionMessage: String?
    @Published public private(set) var diagnosticPreview: String?
    @Published public private(set) var diagnosticPreviewByteCount = 0
    @Published public private(set) var isSafeModeAvailable = false
    @Published public private(set) var safeModeAvailabilityDescription = "安全模式尚未接入。"
    @Published public private(set) var pluginFailureAnalysis: DshPluginFailureAnalysis?
    @Published public private(set) var pluginRemovalInFlight = false
    @Published public private(set) var pluginRemovalRequest: DshRecoveryPluginRemovalRequest?

    private let actions: DshRecoveryActions
    private let redactor: DshSecretRedactor
    private let maximumDetailBytes: Int
    private let diagnosticExporter: DshDiagnosticExporter
    private let diagnosticMetadata: DshDiagnosticExportMetadata
    private let pluginResolver: DshPluginFailureResolver
    private var pluginInspection: DshPluginInspectionResult?
    private let originalProfilePath: String?
    private var latestSnapshotDate: Date?
    private var nextActionSequence: UInt64 = 0

    public init(
        launchID: UUID,
        snapshot: DshDiagnosticSnapshot? = nil,
        actions: DshRecoveryActions = DshRecoveryActions(),
        redactor: DshSecretRedactor = DshSecretRedactor(),
        maximumDetailBytes: Int = 64 * 1024,
        diagnosticExporter: DshDiagnosticExporter = DshDiagnosticExporter(),
        diagnosticMetadata: DshDiagnosticExportMetadata = DshDiagnosticExportMetadata(),
        pluginInspection: DshPluginInspectionResult? = nil,
        pluginResolver: DshPluginFailureResolver = DshPluginFailureResolver(),
        originalProfilePath: String? = nil
    ) {
        self.launchID = launchID
        self.actions = actions
        self.redactor = redactor
        self.maximumDetailBytes = max(64, maximumDetailBytes)
        self.diagnosticExporter = diagnosticExporter
        self.diagnosticMetadata = diagnosticMetadata
        self.pluginInspection = pluginInspection
        self.pluginResolver = pluginResolver
        self.originalProfilePath = originalProfilePath
        self.snapshot = nil
        self.actionInFlight = nil
        self.actionRequest = nil
        self.actionMessage = nil
        self.diagnosticPreview = nil
        self.diagnosticPreviewByteCount = 0
        self.pluginFailureAnalysis = nil
        self.pluginRemovalInFlight = false
        self.pluginRemovalRequest = nil

        if let snapshot {
            _ = apply(snapshot, for: launchID)
        }
    }

    public var phase: DshLaunchPhase? {
        snapshot?.phase
    }

    public var phaseTitle: String {
        phase?.displayName ?? "启动状态未知"
    }

    public var latestFailure: DshDiagnosticRecord? {
        snapshot?.records.last
    }

    public var failureSummary: String {
        latestFailure?.summary ?? "启动尚未完成。"
    }

    public var failureCodeTitle: String? {
        latestFailure.map { $0.code.rawValue }
    }

    /// Text shown only after the user expands the details disclosure. The
    /// input snapshot is sanitized again at this boundary as defense in
    /// depth; the diagnostic store remains the source of bounded history.
    public var redactedDetails: String {
        guard let snapshot else { return "暂无技术详情。" }

        var lines: [String] = []
        if let record = snapshot.records.last {
            lines.append("阶段：\(record.phase.displayName)")
            lines.append("错误码：\(record.code.rawValue)")
            lines.append("来源：\(record.source.rawValue)")
            lines.append("判断：\(record.evidence.map { $0.confidence.rawValue }.first ?? "unknown")")
            if let technicalDetail = record.technicalDetail, !technicalDetail.isEmpty {
                lines.append("详情：\(technicalDetail)")
            }
            for evidence in record.evidence.prefix(8) {
                let plugin = evidence.pluginName.map { " (\($0))" } ?? ""
                lines.append("证据：\(evidence.confidence.rawValue)\(plugin) \(evidence.summary)")
            }
        }
        if !snapshot.log.isEmpty {
            lines.append("输出：\n\(snapshot.log)")
        }

        guard !lines.isEmpty else { return "暂无技术详情。" }
        return boundedRedacted(lines.joined(separator: "\n"))
    }

    public var isActionInFlight: Bool {
        actionInFlight != nil
    }

    public var hasDiagnosticSnapshot: Bool {
        snapshot != nil
    }

    /// A compact, safe-to-share summary. It intentionally excludes process
    /// output, chat content, credentials and environment variables.
    public var diagnosticSummary: String {
        guard let snapshot else { return "DSH 诊断摘要\n暂无可用诊断。" }
        var lines = ["DSH 诊断摘要"]
        if let context = snapshot.context {
            if let runtimeVersion = context.runtimeVersion {
                lines.append("Runtime：\(runtimeVersion)")
            }
            if let profile = context.profile {
                lines.append("Profile：\(profile)")
            }
        }
        if let phase = snapshot.phase {
            lines.append("阶段：\(phase.displayName)")
        }
        if let record = snapshot.records.last {
            lines.append("错误码：\(record.code.rawValue)")
            lines.append("摘要：\(record.summary)")
        }
        return boundedRedacted(lines.joined(separator: "\n"))
    }

    /// Build an in-memory JSON preview. No file or network side effect occurs.
    /// The current sanitized snapshot remains intact if rendering fails.
    @discardableResult
    public func refreshDiagnosticPreview() -> Bool {
        guard let snapshot else {
            diagnosticPreview = nil
            diagnosticPreviewByteCount = 0
            return false
        }
        do {
            let preview = try diagnosticExporter.preview(
                snapshot: snapshot,
                metadata: diagnosticMetadata
            )
            diagnosticPreview = preview.json
            diagnosticPreviewByteCount = preview.byteCount
            return true
        } catch {
            actionMessage = "无法生成诊断预览：\(boundedRedacted(error.localizedDescription))"
            return false
        }
    }

    @discardableResult
    public func requestCopyDiagnosticSummary() -> Bool {
        guard snapshot != nil else {
            actionMessage = "暂无可复制的诊断。"
            return false
        }
        actions.copyDiagnosticSummary(diagnosticSummary)
        actionMessage = "诊断摘要已复制。"
        return true
    }

    /// Create a user-approved export plan and pass it to the native save
    /// panel. A failed plan never clears the in-memory snapshot or preview.
    @discardableResult
    public func requestSaveDiagnosticExport() -> Bool {
        guard let snapshot else {
            actionMessage = "暂无可保存的诊断。"
            return false
        }
        do {
            let plan = try diagnosticExporter.makePlan(
                snapshot: snapshot,
                metadata: diagnosticMetadata
            )
            actions.saveDiagnosticExport(plan)
            actionMessage = "请选择诊断 JSON 的保存位置。"
            return true
        } catch {
            actionMessage = "无法准备诊断导出：\(boundedRedacted(error.localizedDescription))"
            return false
        }
    }

    /// Apply a snapshot only when both the caller's identity and the
    /// snapshot's context identify this view model's launch. Generated dates
    /// also prevent an older same-launch event from reverting the screen.
    @discardableResult
    public func apply(_ incoming: DshDiagnosticSnapshot, for eventLaunchID: UUID) -> Bool {
        guard eventLaunchID == launchID,
              incoming.context?.launchID == launchID else {
            return false
        }
        if let latestSnapshotDate,
           incoming.generatedAt < latestSnapshotDate {
            return false
        }

        let normalized = sanitize(incoming)
        snapshot = normalized
        latestSnapshotDate = incoming.generatedAt
        pluginFailureAnalysis = makePluginFailureAnalysis(for: normalized)
        _ = refreshDiagnosticPreview()
        return true
    }

    /// The resolver is read-only.  The optional inspector result is accepted
    /// only when it describes the same logical Profile; a stale inspection is
    /// discarded instead of becoming evidence for a different launch.
    public func setPluginInspection(_ inspection: DshPluginInspectionResult?) {
        pluginInspection = inspection
        if let snapshot {
            pluginFailureAnalysis = makePluginFailureAnalysis(for: snapshot)
        }
    }

    public var canRequestPluginRemoval: Bool {
        guard !pluginRemovalInFlight,
              actionInFlight == nil,
              let snapshot,
              snapshot.context?.profile == "desktop",
              let originalProfilePath,
              Self.isDesktopProfilePath(originalProfilePath),
              let generationID = snapshot.context?.generationID,
              snapshot.records.last?.generationID == generationID,
              let analysis = pluginFailureAnalysis,
              !analysis.hasAmbiguity,
              analysis.locatedCandidates.count == 1,
              let candidate = analysis.locatedCandidates.first,
              let name = candidate.pluginName,
              !name.isEmpty,
              candidate.removalPlan.allowed,
              candidate.removalPlan.requiresExplicitConfirmation else {
            return false
        }
        return candidate.removalPlan.pluginName == name
    }

    /// Validate a previously issued intent against the currently displayed
    /// evidence before handing it to the MainWindow coordinator.
    public func isFreshPluginRemovalRequest(
        _ request: DshRecoveryPluginRemovalRequest
    ) -> Bool {
        guard request.launchID == launchID,
              pluginRemovalRequest == request,
              let snapshot,
              snapshot.context?.profile == request.originalProfile,
              request.originalProfilePath == originalProfilePath,
              Self.isDesktopProfilePath(request.originalProfilePath),
              snapshot.context?.generationID == request.generationID,
              snapshot.records.last?.generationID == request.generationID,
              let candidate = pluginFailureAnalysis?.locatedCandidates.first,
              pluginFailureAnalysis?.locatedCandidates.count == 1 else {
            return false
        }
        return candidate.pluginName == request.pluginName
            && candidate.removalPlan.token == request.planToken
    }

    public func pluginRemovalPlan(
        for request: DshRecoveryPluginRemovalRequest
    ) -> DshPluginRemovalPlanPreview? {
        guard isFreshPluginRemovalRequest(request),
              let candidate = pluginFailureAnalysis?.locatedCandidates.first,
              candidate.removalPlan.allowed,
              candidate.removalPlan.requiresExplicitConfirmation else {
            return nil
        }
        return candidate.removalPlan
    }

    /// Dispatch a removal intent only when the resolver produced one unique
    /// non-managed plan for the original desktop Profile.  This method never
    /// mutates the Profile; the MainWindow coordinator owns the final fresh
    /// launch/generation check and P01 transaction.
    @discardableResult
    public func requestRemovePluginAndRetry() -> Bool {
        guard canRequestPluginRemoval,
              let snapshot,
              let generationID = snapshot.context?.generationID,
              let candidate = pluginFailureAnalysis?.locatedCandidates.first,
              let name = candidate.pluginName else {
            actionMessage = "证据不足，未生成可执行的插件移除目标。"
            return false
        }
        let request = DshRecoveryPluginRemovalRequest(
            launchID: launchID,
            planToken: candidate.removalPlan.token,
            pluginName: name,
            generationID: generationID,
            originalProfile: snapshot.context?.profile ?? "",
            originalProfilePath: originalProfilePath ?? ""
        )
        pluginRemovalRequest = request
        pluginRemovalInFlight = true
        actionMessage = "正在验证插件移除计划…"
        actions.removePluginAndRetry(request)
        return true
    }

    @discardableResult
    public func finishPluginRemoval(
        _ request: DshRecoveryPluginRemovalRequest,
        message: String? = nil
    ) -> Bool {
        guard pluginRemovalInFlight, pluginRemovalRequest == request,
              request.launchID == launchID else { return false }
        pluginRemovalInFlight = false
        pluginRemovalRequest = nil
        actionMessage = message.map(boundedRedacted)
        return true
    }

    private func makePluginFailureAnalysis(
        for snapshot: DshDiagnosticSnapshot
    ) -> DshPluginFailureAnalysis {
        let inspection: DshPluginInspectionResult?
        if let candidate = pluginInspection,
           let profile = snapshot.context?.profile,
           profile == "desktop" {
            // The inspection API stores the absolute Profile directory.  A
            // desktop-only screen may still receive a stale result, so only
            // use it when its path names the desktop Profile.
            let normalizedPath = candidate.profileDirectory
                .replacingOccurrences(of: "\\\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            inspection = normalizedPath.hasSuffix("/profiles/desktop")
                ? candidate
                : nil
        } else {
            inspection = nil
        }
        return pluginResolver.analyze(DshPluginFailureResolverInput(
            diagnostics: snapshot.records,
            inspection: inspection
        ))
    }

    private static func isDesktopProfilePath(_ path: String) -> Bool {
        let normalized = path
            .replacingOccurrences(of: "\\\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized.hasSuffix("/profiles/desktop")
    }

    /// Safe mode is deliberately an explicit capability from the future
    /// coordinator. Until F05 supplies it, the default state stays disabled
    /// and exposes a reason to the user.
    public func setSafeModeAvailability(_ available: Bool, reason: String? = nil) {
        isSafeModeAvailable = available
        if available {
            safeModeAvailabilityDescription = "安全模式可用。"
        } else {
            safeModeAvailabilityDescription = boundedRedacted(reason ?? "安全模式尚未接入。")
        }
    }

    @discardableResult
    public func requestRetry() -> Bool {
        beginAction(.retry)
    }

    @discardableResult
    public func requestOpenSettings() -> Bool {
        beginAction(.openSettings)
    }

    @discardableResult
    public func requestSafeMode() -> Bool {
        beginAction(.safeMode)
    }

    /// A coordinator calls this after its explicit action has completed. The
    /// request token must be the exact token delivered to its callback, so a
    /// late completion from an earlier same-launch request cannot clear a new
    /// request of the same kind.
    @discardableResult
    public func finishAction(
        _ request: DshRecoveryActionRequest,
        message: String? = nil
    ) -> Bool {
        guard request.launchID == launchID,
              actionRequest == request else {
            return false
        }
        actionInFlight = nil
        actionRequest = nil
        actionMessage = message.map(boundedRedacted)
        return true
    }

    /// Completion entry point for native/bridge code that stores only the
    /// explicit token. The request overload above remains available to
    /// callers that retain the complete request value.
    @discardableResult
    public func finishAction(
        _ token: DshRecoveryActionCompletionToken,
        message: String? = nil
    ) -> Bool {
        guard let request = actionRequest,
              request.completionToken == token else {
            return false
        }
        return finishAction(
            DshRecoveryActionRequest(
                id: request.id,
                launchID: request.launchID,
                action: request.action,
                sequence: request.sequence
            ),
            message: message
        )
    }

    private func beginAction(_ action: DshRecoveryAction) -> Bool {
        guard actionInFlight == nil else { return false }
        guard action != .safeMode || isSafeModeAvailable else {
            actionMessage = safeModeAvailabilityDescription
            return false
        }

        actionMessage = nil
        nextActionSequence = nextActionSequence == UInt64.max
            ? 1
            : nextActionSequence + 1
        let request = DshRecoveryActionRequest(
            launchID: launchID,
            action: action,
            sequence: nextActionSequence
        )
        actionInFlight = action
        actionRequest = request
        switch action {
        case .retry:
            actions.retry(request)
        case .openSettings:
            actions.openSettings(request)
        case .safeMode:
            actions.startSafeMode(request)
        }
        return true
    }

    private func sanitize(_ incoming: DshDiagnosticSnapshot) -> DshDiagnosticSnapshot {
        let context = incoming.context.map { value in
            DshDiagnosticLaunchContext(
                launchID: value.launchID,
                generationID: value.generationID,
                runtimeVersion: value.runtimeVersion.map(boundedRedacted),
                profile: value.profile.map(boundedRedacted),
                startedAt: value.startedAt
            )
        }
        let records = incoming.records.map { value in
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
                evidence: value.evidence.prefix(8).map { evidence in
                    DshDiagnosticEvidence(
                        source: evidence.source,
                        confidence: evidence.confidence,
                        summary: boundedRedacted(evidence.summary),
                        pluginName: evidence.pluginName.map(boundedRedacted),
                        generationID: evidence.generationID
                    )
                },
                occurrenceCount: value.occurrenceCount
            )
        }
        return DshDiagnosticSnapshot(
            context: context,
            phase: incoming.phase,
            records: records,
            log: boundedRedacted(incoming.log),
            generatedAt: incoming.generatedAt
        )
    }

    private func boundedRedacted(_ value: String) -> String {
        // Keep preview, copy, save, and expanded details on the same
        // diagnostic boundary. In particular this covers short quoted JSON
        // fields and user-home paths that the protocol matcher cannot infer.
        let redacted = redactor.redactDiagnostic(value)
        let data = Data(redacted.utf8)
        guard data.count > maximumDetailBytes else { return redacted }
        var start = data.count - maximumDetailBytes
        // `redacted` came from a Swift String and is valid UTF-8 already. Move
        // at most three bytes over a continuation byte so the suffix starts at
        // a scalar boundary while never exceeding the byte cap.
        while start < data.count && (data[start] & 0xC0) == 0x80 {
            start += 1
        }
        return String(data: data.subdata(in: start..<data.count), encoding: .utf8) ?? ""
    }
}
