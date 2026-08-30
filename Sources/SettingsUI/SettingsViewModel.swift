import Foundation
import AppKit
import SwiftUI
import Combine

public extension Notification.Name {
    static let dshSettingsPanelDidChange = Notification.Name("dsh.settingsPanelDidChange")
}

private enum DshRuntimeUpdateFailure: LocalizedError {
    case candidateInstall(version: String, detail: String)
    case runtimeStartup(version: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .candidateInstall(let version, let detail):
            return "candidate Runtime \(version) 安装失败，当前仍使用原版本：\(detail)"
        case .runtimeStartup(let version, let detail):
            return "新 Runtime \(version) 启动或健康检查失败，已尝试恢复旧版本：\(detail)"
        }
    }
}

@MainActor
public final class SettingsViewModel: ObservableObject {
    public static let shared = SettingsViewModel()
    private static let selectedPanelDefaultsKey = "dsh.settings.selectedPanel"

    @Published public var availableVersions: [DshVersionItem] = []
    @Published public var installedVersions: [String] = []
    @Published public var selectedVersion: String? = nil
    @Published public var selectedCategoryIndex: Int = 0
    @Published public var latestVersion: String? = nil
    @Published public var nextVersion: String? = nil
    @Published public var autoFollowLatest: Bool = false
    @Published public var runtimeChannel: DshRuntimeChannel = .latest
    @Published public var npmRegistry: String = DshVersionManager.defaultRegistry
    @Published public var dshPort: Int = 3080
    @Published public var browserAccessEnabled: Bool = false
    @Published public var networkExposure: DshNetworkExposure = .loopback
    @Published public var isUpdatingBrowserAccess: Bool = false
    @Published public var isUpdatingNetworkExposure: Bool = false
    @Published public private(set) var lanURL: URL?
    @Published public var isLoadingLANURL: Bool = false
    @Published public var isOpeningBrowser: Bool = false
    @Published public var uiTheme: String = "default"
    @Published public private(set) var externalTheme: String?
    @Published public var translateCommands: Bool = true

    @Published public var installedPlugins: [DshPluginItem] = []
    @Published public var outdatedPluginsMap: [String: String] = [:]

    @Published public var isInstallingVersion: Bool = false
    @Published public var isUpdatingRuntime: Bool = false
    @Published public var installingVersionName: String? = nil
    @Published public var installProgressPhase: String = ""
    @Published public var installProgressDetail: String? = nil

    @Published public var isLoadingCatalog: Bool = false
    @Published public var isRefreshingPlugins: Bool = false
    @Published public var isCheckingPluginUpdates: Bool = false
    @Published public var isOperatingPlugin: Bool = false
    @Published public var operatingPluginName: String? = nil
    @Published public var pluginStatusMessage: String? = nil
    @Published public var alertMessage: String? = nil

    private var isFollowingLatest = false
    private var catalogRequestGeneration = 0
    private var pluginStatusDismissTask: Task<Void, Never>?
    private var pluginStatusGeneration = 0

    private var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

    private init() {
        if let savedPanel = UserDefaults.standard.object(forKey: Self.selectedPanelDefaultsKey) as? Int,
           SettingsPanel(rawValue: savedPanel) != nil {
            self.selectedCategoryIndex = savedPanel
        }
        loadFromState()
    }

    public func rememberSelectedPanel(_ panel: SettingsPanel) {
        selectedCategoryIndex = panel.rawValue
        UserDefaults.standard.set(panel.rawValue, forKey: Self.selectedPanelDefaultsKey)
        NotificationCenter.default.post(name: .dshSettingsPanelDidChange, object: panel)
    }

    public func loadFromState() {
        let state = DshStateManager.shared.current
        self.selectedVersion = DshVersionManager.shared.ensureSelection()
        self.runtimeChannel = state.runtimeState.channel
        self.autoFollowLatest = self.runtimeChannel == .latest
            && state.runtimeState.updatePolicy == .automaticStable
        self.npmRegistry = state.npmRegistry ?? DshVersionManager.defaultRegistry
        self.dshPort = state.dshPort ?? 3080
        self.browserAccessEnabled = state.browserAccessEnabled
        self.networkExposure = state.networkExposure
        if state.networkExposure != .lan { self.lanURL = nil }
        self.uiTheme = state.uiTheme
        self.externalTheme = DshPluginManager.shared.detectExternalTheme()
        self.translateCommands = state.translateCommands
        self.installedVersions = DshVersionManager.shared.listInstalledVersions()
        self.installedPlugins = DshPluginManager.shared.listPlugins(outdatedMap: outdatedPluginsMap)

        if let diagnostic = DshStateManager.shared.current.runtimeState.lastDiagnostic {
            self.alertMessage = diagnostic
            DshStateManager.shared.update { $0.runtimeState.lastDiagnostic = nil }
        }
    }

    /// Refresh the profile-based theme state after plugin changes or when the
    /// general settings page becomes visible.
    public func refreshExternalTheme() {
        let detected = DshPluginManager.shared.detectExternalTheme()
        guard externalTheme != detected else { return }
        externalTheme = detected
        MainWindowController.shared.syncUiTheme()
    }

    /// The bridge can report the active theme, but the package manifest is the
    /// stable source used by Electron for settings availability. Re-read it so
    /// a stale bridge snapshot cannot keep the native control locked.
    public func refreshExternalThemeFromBridge() {
        refreshExternalTheme()
    }

    public func refreshCatalog() async {
        let registry = DshVersionManager.normalizedRegistry(npmRegistry)
        catalogRequestGeneration &+= 1
        let requestGeneration = catalogRequestGeneration
        isLoadingCatalog = true
        let startedAt = Date()
        defer {
            if requestGeneration == catalogRequestGeneration {
                isLoadingCatalog = false
            }
        }
        do {
            let res = try await DshVersionManager.shared.fetchCatalog(registry: registry)
            guard requestGeneration == catalogRequestGeneration,
                  DshVersionManager.normalizedRegistry(npmRegistry) == registry else { return }
            self.latestVersion = res.latest
            self.nextVersion = res.next
            self.availableVersions = res.versions
            self.installedVersions = DshVersionManager.shared.listInstalledVersions()
        } catch {
            if requestGeneration == catalogRequestGeneration,
               DshVersionManager.normalizedRegistry(npmRegistry) == registry {
                self.alertMessage = error.localizedDescription
            }
        }
        await holdRefreshAnimation(since: startedAt)
    }

    public func refreshPlugins() {
        self.installedPlugins = DshPluginManager.shared.listPlugins(outdatedMap: outdatedPluginsMap)
        refreshExternalTheme()
    }

    public func refreshPluginList() async {
        guard !isRefreshingPlugins else { return }
        isRefreshingPlugins = true
        let startedAt = Date()
        defer { isRefreshingPlugins = false }
        refreshPlugins()
        await holdRefreshAnimation(since: startedAt)
    }

    public func checkPluginUpdates() async {
        guard !isCheckingPluginUpdates else { return }
        isCheckingPluginUpdates = true
        let startedAt = Date()
        defer { isCheckingPluginUpdates = false }
        do {
            let map = try await DshPluginManager.shared.checkOutdatedPlugins()
            self.outdatedPluginsMap = map
            self.installedPlugins = DshPluginManager.shared.listPlugins(outdatedMap: map)
        } catch {
            self.alertMessage = "检测插件更新失败：\(error.localizedDescription)"
        }
        await holdRefreshAnimation(since: startedAt)
    }

    public func updatePlugin(name: String) {
        guard !isOperatingPlugin else { return }
        isOperatingPlugin = true
        clearPluginStatus()
        operatingPluginName = "正在更新 \(name)…"
        Task {
            do {
                try await MainWindowController.shared.withRuntimeOperation {
                    try await DshPluginManager.shared.updatePlugin(name: name)
                    self.outdatedPluginsMap.removeValue(forKey: name)
                    self.refreshPlugins()
                    try await self.restartDshServiceDuringOperationAndWait()
                }
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.showPluginStatus("插件 \(name) 更新成功，服务已重启")
            } catch {
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.alertMessage = error.localizedDescription
            }
        }
    }

    public func updateAllPlugins() {
        guard !isOperatingPlugin else { return }
        isOperatingPlugin = true
        clearPluginStatus()
        let count = installedPlugins.filter(\.hasUpdate).count
        operatingPluginName = "正在更新插件（0/\(count)）…"
        Task {
            do {
                try await MainWindowController.shared.withRuntimeOperation {
                    try await DshPluginManager.shared.updateAllPlugins()
                    self.outdatedPluginsMap.removeAll()
                    self.refreshPlugins()
                    try await self.restartDshServiceDuringOperationAndWait()
                }
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.showPluginStatus("全部插件已更新至最新版本，服务已重启")
            } catch {
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.alertMessage = error.localizedDescription
            }
        }
    }

    /// Start a one-way update to the selected npm `latest` version. The
    /// settings UI deliberately has no arbitrary install/switch/downgrade
    /// action anymore.
    public func updateToLatest() {
        updateToChannel(.latest)
    }

    public func updateToSelectedChannel() {
        updateToChannel(runtimeChannel)
    }

    private func updateToChannel(_ channel: DshRuntimeChannel) {
        let targetVersion = channel == .next ? nextVersion : latestVersion
        guard let targetVersion,
              let item = availableVersions.first(where: { $0.version == targetVersion }) else {
            alertMessage = "尚未获取到可用的 npm 更新。"
            return
        }
        Task { [self] in await runRuntimeUpdate(item) }
    }

    /// Update to a catalog version only when it is strictly newer than the
    /// active runtime. This remains separate from the UI so future channels
    /// can reuse the same transaction without restoring arbitrary switching.
    public func updateToVersion(_ version: String) {
        let selectedTarget = runtimeChannel == .next ? nextVersion : latestVersion
        guard version == selectedTarget,
              let item = availableVersions.first(where: { $0.version == version }) else {
            alertMessage = "只能更新到当前选定通道的 npm tag 版本。"
            return
        }
        Task { [self] in await runRuntimeUpdate(item) }
    }

    /// Match startup auto-follow behavior while using the same persisted
    /// transaction as a manual update.
    public func followLatestIfEnabled() async {
        let state = DshStateManager.shared.current
        guard autoFollowLatest,
              state.runtimeState.channel == .latest,
              state.runtimeState.pending == nil,
              !isFollowingLatest,
              let latest = latestVersion,
              let item = availableVersions.first(where: { $0.version == latest }),
              !(state.runtimeState.dismissedVersion == latest
                  && state.runtimeState.dismissedAppVersion == currentAppVersion),
              let current = state.selectedVersion,
              DshVersionManager.shared.isVersionInstalled(current),
              DshVersionManager.shared.isVersionNewer(latest, than: current) else { return }

        isFollowingLatest = true
        defer { isFollowingLatest = false }
        await runRuntimeUpdate(item, isAutomatic: true)
    }

    /// If the app was terminated during an update, restore the last known
    /// active runtime before the next service launch. A confirmed transaction
    /// is simply finalized; all earlier phases are treated as unconfirmed.
    public func recoverPendingRuntimeUpdate() async {
        let state = DshStateManager.shared.current
        let installedVersions = Set(DshVersionManager.shared.listInstalledVersions())
        guard let action = DshRuntimeRecoveryPlanner.plan(
            state: state,
            installedVersions: installedVersions
        ) else { return }

        switch action {
        case .finalizeConfirmed(let active):
            DshStateManager.shared.update { state in
                state.runtimeState.pending = nil
                // Keep confirmed until the next healthy start can count
                // toward previous/Profile cleanup.
                state.runtimeState.phase = .confirmed
                state.runtimeState.active = active
                state.runtimeState.healthyStartCount = 1
            }

        case .rollback(let active, _):
            let message = "检测到上次 Runtime 更新在\(recoveryPhaseDescription(state.runtimeState.phase))中断，将恢复到 \(active.version)。"
            DshStateManager.shared.update { state in
                state.selectedVersion = active.version
                state.runtimeState.active = active
                state.runtimeState = DshRuntimeTransaction.recordRollbackFailure(
                    state.runtimeState,
                    diagnostic: message
                )
            }

            // Keep rollingBack/previous/pending until the previous Runtime
            // actually passes the normal startup health gate. MainWindowController
            // owns the single restore operation immediately before that start;
            // doing it here as well would restore the 4 GB Profile twice.
            self.alertMessage = "\(message) 已准备恢复，正在验证旧 Runtime。"

        case .reset(let candidate):
            let message = "检测到上次 Runtime 更新在\(recoveryPhaseDescription(state.runtimeState.phase))中断，且没有可用的回滚 Runtime，请重新安装。"
            let snapshotID = state.runtimeState.webProfileSnapshotID
            if let snapshotID {
                do {
                    try await DshPluginManager.shared.restoreWebProfileSnapshot(snapshotID) { progress in
                        Task { @MainActor in
                            self.installProgressPhase = progress.phase
                            self.installProgressDetail = progress.detail
                        }
                    }
                } catch {
                    let diagnostic = "\(message) 但 web Profile 恢复失败，事务仍保留待下次启动重试：\(error.localizedDescription)"
                    DshStateManager.shared.update { state in
                        state.runtimeState = DshRuntimeTransaction.recordRollbackFailure(
                            state.runtimeState,
                            diagnostic: diagnostic
                        )
                    }
                    self.alertMessage = diagnostic
                    return
                }
            }
            DshStateManager.shared.update { state in
                state.selectedVersion = nil
                state.runtimeState.active = nil
                state.runtimeState.pending = nil
                state.runtimeState.previous = nil
                state.runtimeState.phase = .idle
                state.runtimeState.webProfileSnapshotID = nil
                state.runtimeState.healthyStartCount = 0
                state.runtimeState.lastDiagnostic = message
            }
            var finalMessage = message
            do {
                try DshVersionManager.shared.discardInstalledVersion(candidate.version)
            } catch {
                finalMessage += " Candidate \(candidate.version) 清理失败：\(error.localizedDescription)"
                DshStateManager.shared.update { $0.runtimeState.lastDiagnostic = finalMessage }
            }
            if let snapshotID {
                do {
                    try await DshPluginManager.shared.deleteWebProfileSnapshot(snapshotID)
                } catch {
                    finalMessage += " web Profile 快照清理失败：\(error.localizedDescription)"
                    DshStateManager.shared.update { state in
                        state.runtimeState.webProfileSnapshotID = snapshotID
                        state.runtimeState.lastDiagnostic = finalMessage
                    }
                }
            }
            self.alertMessage = finalMessage
        }
    }

    private func recoveryPhaseDescription(_ phase: DshRuntimeTransactionPhase) -> String {
        switch phase {
        case .staging:
            return " candidate 安装阶段"
        case .switching, .verifying:
            return "新 Runtime 启动/健康验证阶段"
        case .rollingBack:
            return "回滚阶段"
        case .confirmed:
            return "确认阶段"
        case .idle:
            return "未知阶段"
        }
    }

    private func runtimeTransactionMatches(
        _ state: DshStateConfig,
        phase: DshRuntimeTransactionPhase,
        selectedVersion: String?,
        activeVersion: String?,
        previousVersion: String?,
        pendingVersion: String?,
        snapshotID: String?
    ) -> Bool {
        state.selectedVersion == selectedVersion
            && state.runtimeState.phase == phase
            && state.runtimeState.active?.version == activeVersion
            && state.runtimeState.previous?.version == previousVersion
            && state.runtimeState.pending?.version == pendingVersion
            && state.runtimeState.webProfileSnapshotID == snapshotID
    }

    /// Count a successful app/service start after an update. Keep the old
    /// runtime until the new one has survived two starts, then remove only
    /// the exact recorded previous directory.
    public func recordHealthyRuntimeStart() async {
        let state = DshStateManager.shared.current
        guard state.runtimeState.phase == .confirmed,
              let previous = state.runtimeState.previous else { return }

        let expectedSelectedVersion = state.selectedVersion
        let expectedActiveVersion = state.runtimeState.active?.version
        let expectedPreviousVersion = previous.version
        let expectedPendingVersion = state.runtimeState.pending?.version
        let expectedSnapshotID = state.runtimeState.webProfileSnapshotID
        let nextCount = state.runtimeState.healthyStartCount + 1
        guard nextCount >= 2 else {
            DshStateManager.shared.update { state in
                guard self.runtimeTransactionMatches(
                    state,
                    phase: .confirmed,
                    selectedVersion: expectedSelectedVersion,
                    activeVersion: expectedActiveVersion,
                    previousVersion: expectedPreviousVersion,
                    pendingVersion: expectedPendingVersion,
                    snapshotID: expectedSnapshotID
                ), state.runtimeState.healthyStartCount == nextCount - 1 else { return }
                state.runtimeState.healthyStartCount = nextCount
            }
            return
        }

        let snapshotID = expectedSnapshotID
        var snapshotCleanupError: Error?
        if let snapshotID {
            do {
                try await DshPluginManager.shared.deleteWebProfileSnapshot(snapshotID)
            } catch {
                snapshotCleanupError = error
            }
        }

        let stateAfterSnapshotCleanup = DshStateManager.shared.current
        guard runtimeTransactionMatches(
            stateAfterSnapshotCleanup,
            phase: .confirmed,
            selectedVersion: expectedSelectedVersion,
            activeVersion: expectedActiveVersion,
            previousVersion: expectedPreviousVersion,
            pendingVersion: expectedPendingVersion,
            snapshotID: expectedSnapshotID
        ), stateAfterSnapshotCleanup.runtimeState.healthyStartCount == nextCount - 1 else { return }

        do {
            try DshVersionManager.shared.discardInstalledVersion(previous.version)
            var didCommit = false
            DshStateManager.shared.update { state in
                guard self.runtimeTransactionMatches(
                    state,
                    phase: .confirmed,
                    selectedVersion: expectedSelectedVersion,
                    activeVersion: expectedActiveVersion,
                    previousVersion: expectedPreviousVersion,
                    pendingVersion: expectedPendingVersion,
                    snapshotID: expectedSnapshotID
                ), state.runtimeState.healthyStartCount == nextCount - 1 else { return }
                didCommit = true
                state.runtimeState.previous = nil
                state.runtimeState.healthyStartCount = 0
                state.runtimeState.phase = .idle
                state.runtimeState.webProfileSnapshotID = snapshotCleanupError == nil ? nil : snapshotID
                state.runtimeState.lastDiagnostic = snapshotCleanupError.map {
                    "旧 Runtime 已清理，但 web Profile 快照清理失败：\($0.localizedDescription)"
                }
            }
            guard didCommit else { return }
        } catch {
            DshStateManager.shared.update { state in
                guard self.runtimeTransactionMatches(
                    state,
                    phase: .confirmed,
                    selectedVersion: expectedSelectedVersion,
                    activeVersion: expectedActiveVersion,
                    previousVersion: expectedPreviousVersion,
                    pendingVersion: expectedPendingVersion,
                    snapshotID: expectedSnapshotID
                ) else { return }
                state.runtimeState.healthyStartCount = nextCount
            }
            self.alertMessage = "新 Runtime 已连续启动，但旧 Runtime 清理失败：\(error.localizedDescription)"
        }
    }

    /// Retry a snapshot deletion that previously failed after the Runtime
    /// transaction itself had already settled. Keep the ID in state until the
    /// delete really succeeds so startup cleanup never turns a multi-GB
    /// snapshot into an untracked leak.
    public func retryRetainedWebProfileSnapshotCleanup() async {
        let state = DshStateManager.shared.current
        guard state.runtimeState.pending == nil,
              state.runtimeState.phase == .idle,
              let snapshotID = state.runtimeState.webProfileSnapshotID else { return }

        do {
            try await DshPluginManager.shared.deleteWebProfileSnapshot(snapshotID)
            DshStateManager.shared.update { state in
                guard state.runtimeState.pending == nil,
                      state.runtimeState.webProfileSnapshotID == snapshotID else { return }
                state.runtimeState.webProfileSnapshotID = nil
                state.runtimeState.lastDiagnostic = nil
            }
        } catch {
            alertMessage = "web Profile 快照清理仍失败，将在下次启动继续重试：\(error.localizedDescription)"
        }
    }

    /// Finish a rollback that was left pending because the previous process
    /// could not be started during the original update attempt. The next app
    /// launch restores the Profile before starting the previous Runtime; once
    /// that start is healthy, this method can safely settle the transaction.
    public func finalizeRecoveredRuntimeAfterSuccessfulStart() async {
        let state = DshStateManager.shared.current
        guard state.runtimeState.phase == .rollingBack,
              let active = state.runtimeState.previous,
              let candidate = state.runtimeState.pending,
              state.selectedVersion == active.version else { return }

        let expectedSelectedVersion = state.selectedVersion
        let expectedActiveVersion = state.runtimeState.active?.version
        let expectedPreviousVersion = active.version
        let expectedPendingVersion = candidate.version
        let snapshotID = state.runtimeState.webProfileSnapshotID
        var cleanupErrors: [String] = []
        do {
            try DshVersionManager.shared.discardInstalledVersion(candidate.version)
        } catch {
            cleanupErrors.append("candidate 清理失败：\(error.localizedDescription)")
        }

        var retainedSnapshotID: String?
        if let snapshotID {
            do {
                try await DshPluginManager.shared.deleteWebProfileSnapshot(snapshotID)
            } catch {
                retainedSnapshotID = snapshotID
                cleanupErrors.append("web Profile 快照清理失败：\(error.localizedDescription)")
            }
        }

        let stateBeforeCommit = DshStateManager.shared.current
        guard runtimeTransactionMatches(
            stateBeforeCommit,
            phase: .rollingBack,
            selectedVersion: expectedSelectedVersion,
            activeVersion: expectedActiveVersion,
            previousVersion: expectedPreviousVersion,
            pendingVersion: expectedPendingVersion,
            snapshotID: snapshotID
        ) else { return }

        let diagnostic = cleanupErrors.isEmpty ? nil : cleanupErrors.joined(separator: "；")
        var didCommit = false
        DshStateManager.shared.update { state in
            guard self.runtimeTransactionMatches(
                state,
                phase: .rollingBack,
                selectedVersion: expectedSelectedVersion,
                activeVersion: expectedActiveVersion,
                previousVersion: expectedPreviousVersion,
                pendingVersion: expectedPendingVersion,
                snapshotID: snapshotID
            ) else { return }
            didCommit = true
            state.runtimeState = DshRuntimeTransaction.finishRollback(
                state.runtimeState,
                active: active,
                retainedWebProfileSnapshotID: retainedSnapshotID
            )
            state.runtimeState.lastDiagnostic = diagnostic
        }
        guard didCommit else { return }
        if let diagnostic {
            alertMessage = "已恢复到 \(active.version)，但\(diagnostic)"
        }
    }

    private func runRuntimeUpdate(_ item: DshVersionItem, isAutomatic: Bool = false) async {
        guard !isUpdatingRuntime else { return }
        guard DshStateManager.shared.current.runtimeState.pending == nil else {
            alertMessage = "上一次 Runtime 更新尚未完成恢复，请重启 DSH 后再重试。"
            return
        }
        guard let currentVersion = DshStateManager.shared.current.selectedVersion,
              DshVersionManager.shared.isVersionInstalled(currentVersion) else {
            alertMessage = "当前没有可用于升级的 DSH Runtime。"
            return
        }
        guard DshVersionManager.shared.isVersionNewer(item.version, than: currentVersion) else {
            alertMessage = "当前已经是该 Registry 中不低于目标版本的 Runtime。"
            return
        }

        if isAutomatic {
            let state = DshStateManager.shared.current
            guard !(state.runtimeState.dismissedVersion == item.version
                && state.runtimeState.dismissedAppVersion == currentAppVersion) else { return }
        } else {
            // The update button is the explicit user retry path for a
            // previously suppressed candidate.
            DshStateManager.shared.update { state in
                state.runtimeState.dismissedVersion = nil
                state.runtimeState.dismissedAppVersion = nil
            }
        }

        isUpdatingRuntime = true
        isInstallingVersion = true
        installingVersionName = item.version
        installProgressPhase = "准备更新 DSH \(item.version)..."
        installProgressDetail = nil

        do {
            try await performRuntimeUpdate(item, currentVersion: currentVersion)
            loadFromState()
            await refreshCatalog()
        } catch {
            // performRuntimeUpdate includes the active/candidate versions and
            // whether rollback or cleanup also failed. Keep that diagnostic
            // intact instead of prefixing it with a duplicate failure label.
            DshStateManager.shared.update { state in
                state.runtimeState.dismissedVersion = item.version
                state.runtimeState.dismissedAppVersion = currentAppVersion
            }
            alertMessage = error.localizedDescription
        }

        isUpdatingRuntime = false
        isInstallingVersion = false
        installingVersionName = nil
    }

    private func performRuntimeUpdate(_ item: DshVersionItem, currentVersion: String) async throws {
        try await MainWindowController.shared.withRuntimeOperation {
            try await self.performRuntimeUpdateDuringOperation(item, currentVersion: currentVersion)
        }
    }

    private func performRuntimeUpdateDuringOperation(_ item: DshVersionItem, currentVersion: String) async throws {
        let registry = DshVersionManager.normalizedRegistry(npmRegistry)
        let state = DshStateManager.shared.current
        guard let integrity = item.integrity else {
            throw NSError(
                domain: "DshRuntimeUpdate",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "npm 版本目录缺少 DSH integrity，已拒绝更新"]
            )
        }
        let active = state.runtimeState.active ?? NpmRuntimeDescriptor(
            version: currentVersion,
            registry: registry,
            integrity: nil
        )
        let candidate = NpmRuntimeDescriptor(
            version: item.version,
            registry: registry,
            integrity: integrity
        )

        let transaction = DshRuntimeTransaction.begin(
            active: active,
            candidate: candidate,
            updatePolicy: state.runtimeState.updatePolicy,
            channel: state.runtimeState.channel
        )
        DshStateManager.shared.update { state in
            state.runtimeState = transaction
        }

        var candidateActivated = false
        do {
            do {
                try await DshVersionManager.shared.installCandidate(
                    version: item.version,
                    registry: registry,
                    expectedIntegrity: integrity
                ) { progress in
                    Task { @MainActor in
                        self.installProgressPhase = progress.phase
                        self.installProgressDetail = progress.detail
                    }
                }
            } catch {
                throw DshRuntimeUpdateFailure.candidateInstall(
                    version: item.version,
                    detail: error.localizedDescription
                )
            }

            DshStateManager.shared.update { state in
                state.selectedVersion = item.version
                state.runtimeState = DshRuntimeTransaction.activateCandidate(state.runtimeState)
            }
            candidateActivated = true
            DshStateManager.shared.update {
                $0.runtimeState = DshRuntimeTransaction.beginVerification($0.runtimeState)
            }
            do {
                try await restartDshServiceDuringOperationAndWait()
            } catch {
                throw DshRuntimeUpdateFailure.runtimeStartup(
                    version: item.version,
                    detail: error.localizedDescription
                )
            }

            DshStateManager.shared.update { state in
                state.runtimeState = DshRuntimeTransaction.confirm(state.runtimeState)
            }
        } catch {
            let failureDescription = error.localizedDescription
            DshStateManager.shared.update { state in
                state.selectedVersion = currentVersion
                state.runtimeState = DshRuntimeTransaction.beginRollback(state.runtimeState)
            }
            var rollbackError: Error?
            if candidateActivated {
                // Do not let pnpm or a running candidate keep files open while
                // the pre-transaction Profile snapshot is being restored.
                DshService.shared.stop()
                do {
                    try await restartDshServiceDuringOperationAndWait()
                } catch {
                    rollbackError = error
                }
            }
            if let rollbackError {
                let diagnostic = "Runtime 回滚失败：\(rollbackError.localizedDescription)"
                DshStateManager.shared.update { state in
                    state.runtimeState = DshRuntimeTransaction.recordRollbackFailure(
                        state.runtimeState,
                        diagnostic: diagnostic
                    )
                    state.runtimeState.dismissedVersion = item.version
                    state.runtimeState.dismissedAppVersion = currentAppVersion
                }
                throw NSError(
                    domain: "DshRuntimeUpdate",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "更新到 \(item.version) 失败：\(failureDescription)；自动恢复 \(active.version) 也失败：\(rollbackError.localizedDescription)"]
                )
            }

            var cleanupErrors: [String] = []
            do {
                try DshVersionManager.shared.discardInstalledVersion(item.version)
            } catch {
                cleanupErrors.append("candidate 清理失败：\(error.localizedDescription)")
            }
            let snapshotID = DshStateManager.shared.current.runtimeState.webProfileSnapshotID
            var retainedSnapshotID: String?
            if let snapshotID {
                do {
                    try await DshPluginManager.shared.deleteWebProfileSnapshot(snapshotID)
                } catch {
                    retainedSnapshotID = snapshotID
                    cleanupErrors.append("web Profile 快照清理失败：\(error.localizedDescription)")
                }
            }
            let cleanupDiagnostic = cleanupErrors.isEmpty ? nil : cleanupErrors.joined(separator: "；")
            DshStateManager.shared.update { state in
                state.runtimeState = DshRuntimeTransaction.finishRollback(
                    state.runtimeState,
                    active: active,
                    retainedWebProfileSnapshotID: retainedSnapshotID
                )
                state.runtimeState.dismissedVersion = item.version
                state.runtimeState.dismissedAppVersion = currentAppVersion
                state.runtimeState.lastDiagnostic = cleanupDiagnostic
            }
            if let cleanupDiagnostic {
                throw NSError(
                    domain: "DshRuntimeUpdate",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "更新到 \(item.version) 失败，已恢复 \(active.version)，但\(cleanupDiagnostic)"]
                )
            }
            throw NSError(
                domain: "DshRuntimeUpdate",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "更新到 \(item.version) 失败，已自动恢复 \(active.version)：\(failureDescription)"]
            )
        }
    }

    public func addPlugin(spec: String) {
        guard !isOperatingPlugin, !spec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isOperatingPlugin = true
        clearPluginStatus()
        operatingPluginName = "正在安装插件 \(spec)…"
        Task {
            do {
                try await MainWindowController.shared.withRuntimeOperation {
                    try await DshPluginManager.shared.addPlugin(spec: spec)
                    self.refreshPlugins()
                    try await self.restartDshServiceDuringOperationAndWait()
                }
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.showPluginStatus("插件 \(spec) 安装成功，服务已重启")
            } catch {
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                self.alertMessage = message.isEmpty ? "安装插件 \(spec) 失败" : message
            }
        }
    }

    public func removePlugin(name: String) {
        guard !isOperatingPlugin else { return }
        isOperatingPlugin = true
        clearPluginStatus()
        operatingPluginName = "正在卸载插件 \(name)…"
        Task {
            do {
                try await MainWindowController.shared.withRuntimeOperation {
                    try await DshPluginManager.shared.removePlugin(name: name)
                    self.outdatedPluginsMap.removeValue(forKey: name)
                    self.refreshPlugins()
                    try await self.restartDshServiceDuringOperationAndWait()
                }
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.showPluginStatus("插件 \(name) 已卸载，服务已重启")
            } catch {
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.alertMessage = error.localizedDescription
            }
        }
    }

    public func saveGeneralSettings() {
        let persistedExposure = browserAccessEnabled ? networkExposure : .loopback
        if networkExposure != persistedExposure {
            networkExposure = persistedExposure
        }
        if runtimeChannel == .next, autoFollowLatest {
            autoFollowLatest = false
        }
        let normalizedRegistry = DshVersionManager.normalizedRegistry(npmRegistry)
        let previousRegistry = DshVersionManager.normalizedRegistry(
            DshStateManager.shared.current.npmRegistry
        )
        if normalizedRegistry != previousRegistry {
            catalogRequestGeneration &+= 1
            availableVersions = []
            latestVersion = nil
            nextVersion = nil
        }
        npmRegistry = normalizedRegistry
        DshStateManager.shared.update { state in
            state.dshPort = dshPort
            state.npmRegistry = normalizedRegistry
            state.uiTheme = uiTheme
            state.translateCommands = translateCommands
            state.autoFollowLatest = autoFollowLatest
            state.runtimeState.updatePolicy = autoFollowLatest ? .automaticStable : .notify
            state.runtimeState.channel = runtimeChannel
            state.networkExposure = persistedExposure
        }
        MainWindowController.shared.syncUiTheme()
        MainWindowController.shared.syncTranslateCommands()
    }

    /// Change the live Node policy and persist the setting in the order
    /// required by the browser-access contract. A failed policy update rolls
    /// both the UI and disk state back to the previous value.
    public func setBrowserAccessEnabled(_ enabled: Bool) {
        guard !isUpdatingBrowserAccess, enabled != browserAccessEnabled else { return }

        let previous = browserAccessEnabled
        browserAccessEnabled = enabled
        isUpdatingBrowserAccess = true
        Task { [self] in
            do {
                if enabled {
                    DshStateManager.shared.update { $0.browserAccessEnabled = true }
                    try await DshService.shared.setBrowserAccessEnabled(true)
                } else {
                    try await DshService.shared.setBrowserAccessEnabled(false)
                    DshStateManager.shared.update {
                        $0.browserAccessEnabled = false
                        $0.networkExposure = .loopback
                    }
                    self.networkExposure = .loopback
                    self.lanURL = nil
                }
            } catch {
                DshStateManager.shared.update { $0.browserAccessEnabled = previous }
                self.browserAccessEnabled = previous
                self.alertMessage = "更新浏览器访问设置失败：\(error.localizedDescription)"
            }
            self.isUpdatingBrowserAccess = false
        }
    }

    /// Toggle the separate LAN HTTP ingress. It is available only while the
    /// ordinary browser gate is enabled; the live policy is acknowledged
    /// before the state file is changed.
    public func setNetworkExposure(_ enabled: Bool) {
        let target: DshNetworkExposure = enabled ? .lan : .loopback
        guard !isUpdatingNetworkExposure,
              target != networkExposure else { return }
        guard browserAccessEnabled else {
            alertMessage = "请先开启浏览器访问。"
            return
        }

        let previous = networkExposure
        networkExposure = target
        isUpdatingNetworkExposure = true
        Task { [self] in
            do {
                try await DshService.shared.setNetworkExposure(target)
                DshStateManager.shared.update { $0.networkExposure = target }
                if target == .loopback { self.lanURL = nil }
            } catch {
                self.networkExposure = previous
                self.alertMessage = "更新局域网访问设置失败：\(error.localizedDescription)"
            }
            self.isUpdatingNetworkExposure = false
        }
    }

    public func refreshLANURL() {
        guard browserAccessEnabled,
              networkExposure == .lan,
              !isLoadingLANURL else { return }
        isLoadingLANURL = true
        Task { [self] in
            do {
                self.lanURL = try await MainWindowController.shared.fetchLANURL()
            } catch {
                self.alertMessage = "获取局域网地址失败：\(error.localizedDescription)"
            }
            self.isLoadingLANURL = false
        }
    }

    public func copyLANURL() {
        guard !isLoadingLANURL else { return }
        isLoadingLANURL = true
        Task { [self] in
            do {
                let url = try await MainWindowController.shared.fetchLANURL()
                self.lanURL = url
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(url.absoluteString, forType: .string)
                self.showPluginStatus("局域网访问地址已复制（10 分钟内有效）")
            } catch {
                self.alertMessage = "获取局域网地址失败：\(error.localizedDescription)"
            }
            self.isLoadingLANURL = false
        }
    }

    public func openBrowser() {
        guard browserAccessEnabled, !isOpeningBrowser else { return }
        isOpeningBrowser = true
        Task { [self] in
            do {
                let url = try await MainWindowController.shared.fetchAuthenticatedBrowserURL()
                guard NSWorkspace.shared.open(url) else {
                    throw MainWindowController.BrowserURLError.openFailed
                }
            } catch {
                self.alertMessage = "打开浏览器失败：\(error.localizedDescription)"
            }
            self.isOpeningBrowser = false
        }
    }

    public func restartDshService() {
        Task {
            MainWindowController.shared.startAndLoadDsh()
        }
    }

    private func restartDshServiceAndWait() async throws {
        _ = try await MainWindowController.shared.restartDshService()
    }

    private func restartDshServiceDuringOperationAndWait() async throws {
        _ = try await MainWindowController.shared.restartDshServiceDuringOperation()
    }

    private func clearPluginStatus() {
        pluginStatusGeneration &+= 1
        pluginStatusDismissTask?.cancel()
        pluginStatusDismissTask = nil
        pluginStatusMessage = nil
    }

    private func showPluginStatus(_ message: String) {
        pluginStatusGeneration &+= 1
        let generation = pluginStatusGeneration
        pluginStatusDismissTask?.cancel()
        pluginStatusMessage = message
        pluginStatusDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.pluginStatusGeneration == generation else { return }
            self.pluginStatusMessage = nil
            self.pluginStatusDismissTask = nil
        }
    }

    private func holdRefreshAnimation(since startedAt: Date) async {
        let minimumDuration = 0.9
        let remaining = minimumDuration - Date().timeIntervalSince(startedAt)
        guard remaining > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }
}
