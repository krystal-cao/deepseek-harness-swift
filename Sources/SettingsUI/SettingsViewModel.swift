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

private enum DshSettingsUIMessage {
    static let maximumLength = 600

    static func safe(_ text: String) -> String {
        let redacted = DshSecretRedactor().redact(text)
        guard redacted.count > maximumLength else { return redacted }
        return String(redacted.prefix(maximumLength)) + "…"
    }

    static func safe(_ error: Error) -> String {
        safe(error.localizedDescription)
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
    @Published public var alphaVersion: String? = nil
    @Published public var autoFollowLatest: Bool = false
    @Published public var runtimeChannel: DshRuntimeChannel = .latest
    @Published public var npmRegistry: String = DshVersionManager.defaultRegistry
    @Published public var appProfile: DshAppProfile = .desktop
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
    @Published public private(set) var pluginInspectionResult: DshPluginInspectionResult?
    @Published public private(set) var isInspectingPlugins = false
    @Published public private(set) var pluginInspectionMessage: String?

    @Published public var isInstallingVersion: Bool = false
    @Published public var isUpdatingRuntime: Bool = false
    /// A failed Runtime rollback remains blocked until startup recovery has
    /// verified the previous Runtime. Keeping this published prevents the
    /// Profile picker from becoming active when the update task has already
    /// returned an error.
    @Published public private(set) var isRuntimeRecoveryPending: Bool = false
    @Published public var installingVersionName: String? = nil
    @Published public var installProgressPhase: String = ""
    @Published public var installProgressDetail: String? = nil

    @Published public var isLoadingCatalog: Bool = false
    @Published public var isRefreshingPlugins: Bool = false
    @Published public var isCheckingPluginUpdates: Bool = false
    @Published public var isOperatingPlugin: Bool = false
    @Published public var isSwitchingProfile: Bool = false
    @Published public var operatingPluginName: String? = nil
    @Published public private(set) var pendingPluginInstallSpec: String? = nil
    @Published public private(set) var pendingPluginUpdate: DshPendingPluginUpdate? = nil
    @Published public var pluginStatusMessage: String? = nil
    @Published public var alertMessage: String? = nil

    /// Mutating the selected Profile or Runtime is suspended while a recovery
    /// transaction is unresolved or the service is serving an isolated
    /// recovery Profile. Read-only inspection remains available in those
    /// states so the user can still understand the failure.
    public var pluginMutationsAllowed: Bool {
        let state = DshStateManager.shared.current
        guard state.runtimeState.phase == .idle,
              state.runtimeState.previous == nil,
              state.runtimeState.pending == nil,
              state.runtimeState.transactionID == nil,
              state.runtimeState.webProfileSnapshotID == nil,
              state.pendingProfileSwitch == nil,
              !MainWindowController.shared.hasUnresolvedRecovery else { return false }
        return MainWindowController.shared.currentLaunchContext?.purpose != .recovery
    }

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
        let hasPendingRuntimeRecovery = state.runtimeState.pending != nil
        let transactionProfile = state.runtimeState.profile
        let effectiveProfile = hasPendingRuntimeRecovery ? transactionProfile : state.appProfile
        if hasPendingRuntimeRecovery, state.appProfile != transactionProfile {
            // This can only be encountered when an older build persisted a
            // profile switch while rollback was pending. Repair it before any
            // service launch so the retained snapshot is restored only to its
            // owning Profile.
            DshStateManager.shared.update { state in
                guard state.runtimeState.pending != nil,
                      state.runtimeState.profile == transactionProfile else { return }
                state.appProfile = transactionProfile
            }
            self.alertMessage = "检测到未完成的 Runtime 回滚，已切回 \(transactionProfile.rawValue) Profile 以保护 Profile 数据。"
        }
        self.selectedVersion = DshVersionManager.shared.ensureSelection()
        self.appProfile = effectiveProfile
        self.isRuntimeRecoveryPending = hasPendingRuntimeRecovery
        self.runtimeChannel = state.runtimeState.channel
        self.autoFollowLatest = self.appProfile == .desktop
            && self.runtimeChannel == .latest
            && state.runtimeState.updatePolicy == .automaticStable
        self.npmRegistry = state.npmRegistry ?? DshVersionManager.defaultRegistry
        self.dshPort = state.dshPort ?? 3080
        self.browserAccessEnabled = state.browserAccessEnabled
        self.networkExposure = state.networkExposure
        if state.networkExposure != .lan { self.lanURL = nil }
        self.uiTheme = state.uiTheme
        let settingsProfileDirectory = DshLaunchContext.profileDirectory(for: effectiveProfile)
        self.externalTheme = DshPluginManager.shared.detectExternalTheme(at: settingsProfileDirectory)
        self.translateCommands = state.translateCommands
        self.installedVersions = DshVersionManager.shared.listInstalledVersions()
        self.installedPlugins = DshPluginManager.shared.listPlugins(
            at: settingsProfileDirectory,
            outdatedMap: outdatedPluginsMap
        )

        if let diagnostic = DshStateManager.shared.current.runtimeState.lastDiagnostic {
            self.alertMessage = diagnostic
            DshStateManager.shared.update { $0.runtimeState.lastDiagnostic = nil }
        }
    }

    private func syncRuntimeRecoveryState() {
        isRuntimeRecoveryPending = DshStateManager.shared.current.runtimeState.pending != nil
    }

    /// Recover a Profile switch that was interrupted by force-quitting the
    /// app, a crash, or a failed in-process restore. The persisted
    /// `appProfile` is the target while a switch is in flight, so startup must
    /// always return to the Profile that was healthy before the transaction.
    /// Cleanup is limited to the web bridge artifacts owned by this app; user
    /// plugins and shared credentials are never removed.
    public func recoverPendingProfileSwitch() async {
        let state = DshStateManager.shared.current
        guard let transaction = state.pendingProfileSwitch else { return }
        let capturedRegistry = DshVersionManager.normalizedRegistry(state.npmRegistry)

        // When leaving web, the desktop target is already healthy once the
        // transaction reaches finalizing; only the source cleanup remains.
        // Before that point, keep the original web Profile intact so it can
        // still be restored safely.
        let targetWasHealthy = transaction.phase == .finalizing
            && state.appProfile == transaction.to
        let restoreProfile = targetWasHealthy ? transaction.to : transaction.from
        let requiresWebCleanup = transaction.to == .web
            || (transaction.from == .web && transaction.to == .desktop && targetWasHealthy)

        // Make the safe Profile durable before touching the shared web tree.
        // If cleanup is interrupted, the next launch still starts the known
        // healthy Profile and retries only the app-owned cleanup.
        DshStateManager.shared.update { state in
            guard state.pendingProfileSwitch == transaction else { return }
            state.appProfile = restoreProfile
        }
        self.appProfile = restoreProfile
        self.isSwitchingProfile = false

        var cleanupError: Error?
        if requiresWebCleanup {
            do {
                try await DshPluginManager.shared.removeDesktopHostArtifacts(
                    from: .web,
                    registry: capturedRegistry
                )
            } catch {
                cleanupError = error
            }
        }

        if cleanupError == nil {
            DshStateManager.shared.update { state in
                guard state.pendingProfileSwitch == transaction else { return }
                state.pendingProfileSwitch = nil
            }
        }

        // Refresh all published settings after the durable state transition;
        // this also keeps the Profile picker and plugin list consistent before
        // MainWindowController starts the service.
        loadFromState()
        if let cleanupError {
            alertMessage = "检测到未完成的 Profile 切换，已恢复 \(restoreProfile.rawValue)，但 web 桥接清理失败，将在下次启动重试：\(DshSettingsUIMessage.safe(cleanupError))"
        } else {
            alertMessage = "检测到未完成的 Profile 切换，已恢复 \(restoreProfile.rawValue)。"
        }
    }

    public func retryPendingProfileSwitchCleanup(for context: DshLaunchContext) async {
        let state = DshStateManager.shared.current
        guard context.isFresh(in: state),
              context.purpose == .profileSwitch || context.purpose == .profileRollback,
              let contextTransactionID = context.transactionID,
              let transaction = state.pendingProfileSwitch,
              transaction.transactionID == contextTransactionID,
              context.profile == state.appProfile,
              context.originalProfile == transaction.from else { return }
        if context.purpose == .profileRollback {
            guard context.profile == transaction.from,
                  state.appProfile == transaction.from else { return }
            do {
                // A failed switch may have partially materialized the target
                // Profile. Clean only that target, then clear its transaction;
                // the source Profile is the one that just passed health checks.
                try await DshPluginManager.shared.removeDesktopHostArtifacts(
                    from: transaction.to,
                    profileDirectory: DshLaunchContext.profileDirectory(for: transaction.to),
                    registry: context.runtimeDescriptor.registry
                )
                DshStateManager.shared.update { state in
                    guard state.pendingProfileSwitch == transaction,
                          state.appProfile == transaction.from else { return }
                    state.pendingProfileSwitch = nil
                }
            } catch {
                alertMessage = "目标 \(transaction.to.rawValue) Profile 清理仍失败，将在下次启动重试：\(DshSettingsUIMessage.safe(error))"
            }
            return
        }
        let targetWasHealthy = transaction.phase == .finalizing
            && state.appProfile == transaction.to
        let desktopSourceFailure = transaction.from == .desktop
            && transaction.to == .web
            && state.appProfile == .desktop
        guard targetWasHealthy || desktopSourceFailure else { return }

        do {
            try await DshPluginManager.shared.removeDesktopHostArtifacts(
                from: .web,
                registry: context.runtimeDescriptor.registry
            )
            DshStateManager.shared.update { state in
                guard state.pendingProfileSwitch == transaction else { return }
                state.pendingProfileSwitch = nil
            }
        } catch {
            alertMessage = "web 桥接清理仍失败，将在下次启动重试：\(DshSettingsUIMessage.safe(error))"
        }
    }

    /// Refresh the profile-based theme state after plugin changes or when the
    /// general settings page becomes visible.
    public func refreshExternalTheme() {
        let directory = DshLaunchContext.profileDirectory(for: appProfile)
        refreshExternalTheme(at: directory)
    }

    public func refreshExternalTheme(for context: DshLaunchContext) {
        refreshExternalTheme(at: context.profileDirectory)
    }

    private func refreshExternalTheme(at directory: URL) {
        let detected = DshPluginManager.shared.detectExternalTheme(at: directory)
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
            self.alphaVersion = res.alpha
            self.availableVersions = res.versions
            self.installedVersions = DshVersionManager.shared.listInstalledVersions()
        } catch {
            if requestGeneration == catalogRequestGeneration,
               DshVersionManager.normalizedRegistry(npmRegistry) == registry {
                self.alertMessage = DshSettingsUIMessage.safe(error)
            }
        }
        await holdRefreshAnimation(since: startedAt)
    }

    public func refreshPlugins() {
        let directory = DshLaunchContext.profileDirectory(for: appProfile)
        refreshPlugins(at: directory)
    }

    public func refreshPlugins(for context: DshLaunchContext) {
        refreshPlugins(at: context.profileDirectory)
    }

    private func refreshPlugins(at directory: URL) {
        self.installedPlugins = DshPluginManager.shared.listPlugins(
            at: directory,
            outdatedMap: outdatedPluginsMap
        )
        refreshExternalTheme(at: directory)
    }

    public func refreshPluginList() async {
        guard !isRefreshingPlugins else { return }
        isRefreshingPlugins = true
        let startedAt = Date()
        defer { isRefreshingPlugins = false }
        refreshPlugins()
        await holdRefreshAnimation(since: startedAt)
    }

    /// Run the F03 dependency inspection against one captured launch context.
    /// The operation is read-only and publishes only if the state still points
    /// at that same Profile and Runtime when the detached scan returns.
    public func inspectPlugins() async {
        guard !isInspectingPlugins else { return }
        isInspectingPlugins = true
        pluginInspectionMessage = nil
        defer { isInspectingPlugins = false }

        do {
            let inspected = try await MainWindowController.shared.withRuntimeOperation {
                guard let context = DshLaunchContext.makeStartup(from: DshStateManager.shared.current) else {
                    throw DshLaunchContextError.invalidProfileName
                }
                let runtimeEntry = DshVersionManager.shared.resolveEntry(for: context.runtimeDescriptor)
                let runtimeRoot = runtimeEntry.map { entry in
                    URL(fileURLWithPath: entry)
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                } ?? DshStateManager.versionsDirectory
                let nodeBinary = NodeRuntime.shared.resolveNodeBinary().map(URL.init(fileURLWithPath:))
                let result = await DshPluginInspector(
                    profileDirectory: context.profileDirectory,
                    runtime: DshPluginInspectorRuntimeDescriptor(
                        root: runtimeRoot,
                        nodeBinary: nodeBinary,
                        integrityVerified: runtimeEntry != nil
                    )
                ).inspectAsync()
                return (context, result)
            }
            guard inspected.0.isFresh(in: DshStateManager.shared.current) else { return }
            pluginInspectionResult = inspected.1
            let message = Self.pluginInspectionMessage(for: inspected.1)
            pluginInspectionMessage = message
            // A passing check is transient feedback; dismiss it after a few
            // seconds so it does not linger. Problem reports stay until the
            // next inspection because they require user action.
            if message == Self.pluginInspectionPassedMessage {
                let shown = message
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if !isInspectingPlugins, pluginInspectionMessage == shown {
                        pluginInspectionMessage = nil
                    }
                }
            }
        } catch {
            pluginInspectionResult = nil
            pluginInspectionMessage = "无法完成插件一致性检查：\(DshSettingsUIMessage.safe(error))"
        }
    }

    public static let pluginInspectionPassedMessage = "插件依赖一致性检查通过。"

    public static func pluginInspectionMessage(for result: DshPluginInspectionResult) -> String? {
        if result.items.contains(where: { $0.status == .missingPackage }) {
            return "发现包缺失；为保护现有 Profile，启动准备已阻止写入，请修复后重试。"
        }
        if result.items.contains(where: { $0.status == .notComposed }) {
            return "发现已安装但未组合的 Bundle；为保护现有 Profile，启动准备已阻止写入。"
        }
        if result.items.contains(where: { $0.status == .duplicateBundle }) {
            return "发现重复 Bundle 引用；归属无法唯一确认，未自动修改。"
        }
        if result.items.contains(where: { $0.status == .unavailable || $0.status == .uncertain })
            || result.issues.contains(where: { $0.code == "patchInspectionUnavailable" }) {
            return "部分插件配置无法确认；启动准备已阻止写入，请查看详情后重试。"
        }
        if result.hasProblems {
            return "发现插件配置引用失效，请查看详情后重试。"
        }
        return pluginInspectionPassedMessage
    }

    public func checkPluginUpdates() async {
        guard !isCheckingPluginUpdates else { return }
        isCheckingPluginUpdates = true
        let startedAt = Date()
        defer { isCheckingPluginUpdates = false }
        do {
            try await MainWindowController.shared.withRuntimeOperation {
                guard let context = DshLaunchContext.makeStartup(from: DshStateManager.shared.current) else {
                    throw DshLaunchContextError.invalidProfileName
                }
                let map = try await DshPluginManager.shared.checkOutdatedPlugins(
                    at: context.profileDirectory,
                    profile: context.profile,
                    registry: context.runtimeDescriptor.registry
                )
                self.outdatedPluginsMap = map
                self.installedPlugins = DshPluginManager.shared.listPlugins(
                    at: context.profileDirectory,
                    outdatedMap: map
                )
            }
        } catch {
            self.alertMessage = "检测插件更新失败：\(DshSettingsUIMessage.safe(error))"
        }
        await holdRefreshAnimation(since: startedAt)
    }

    public func updatePlugin(name: String) {
        guard pluginMutationsAllowed else { return }
        startPluginUpdate(name: name, ignoringMinimumReleaseAge: false)
    }

    public func updateAllPlugins() {
        guard pluginMutationsAllowed else { return }
        startPluginUpdateAll(ignoringMinimumReleaseAge: false)
    }

    public func confirmPendingPluginUpdate() {
        guard let request = pendingPluginUpdate else { return }
        guard pluginMutationsAllowed else {
            alertMessage = "插件更新仍在等待恢复完成；请求已保留，请完成恢复后重试。"
            return
        }
        guard !isOperatingPlugin, !isSwitchingProfile else {
            alertMessage = "当前已有插件操作排队，请稍后重试。"
            return
        }
        let queued: Bool
        switch request {
        case .plugin(let name):
            queued = startPluginUpdate(name: name, ignoringMinimumReleaseAge: true)
        case .all:
            queued = startPluginUpdateAll(ignoringMinimumReleaseAge: true)
        }
        if queued {
            pendingPluginUpdate = nil
        }
    }

    public func cancelPendingPluginUpdate() {
        pendingPluginUpdate = nil
    }

    public var pendingPluginUpdateMessage: String? {
        guard let request = pendingPluginUpdate else { return nil }
        switch request {
        case .plugin(let name):
            return "更新插件 \(name) 时，npm 检测到依赖版本发布时间过近。继续更新将仅对本次操作使用 --config.minimum-release-age=0，不会修改全局 pnpm 配置。"
        case .all:
            return "批量更新插件时，npm 检测到依赖版本发布时间过近。继续更新将仅对本次操作使用 --config.minimum-release-age=0，不会修改全局 pnpm 配置。"
        }
    }

    @discardableResult
    private func startPluginUpdate(name: String, ignoringMinimumReleaseAge: Bool) -> Bool {
        guard pluginMutationsAllowed else {
            alertMessage = "插件更新暂不可用；请求已保留，请完成恢复后重试。"
            return false
        }
        guard !isOperatingPlugin, !isSwitchingProfile else {
            alertMessage = "当前已有插件操作排队，请稍后重试。"
            return false
        }
        isOperatingPlugin = true
        clearPluginStatus()
        operatingPluginName = DshSettingsUIMessage.safe("正在更新 \(name)…")
        Task {
            do {
                try await MainWindowController.shared.withRuntimeOperation {
                    guard let context = DshLaunchContext.makeStartup(from: DshStateManager.shared.current) else {
                        throw DshLaunchContextError.invalidProfileName
                    }
                    try await DshPluginManager.shared.updatePlugin(
                        name: name,
                        ignoringMinimumReleaseAge: ignoringMinimumReleaseAge,
                        profileDirectory: context.profileDirectory,
                        profile: context.profile,
                        registry: context.runtimeDescriptor.registry
                    )
                    self.outdatedPluginsMap.removeValue(forKey: name)
                    self.refreshPlugins(for: context)
                    _ = try await MainWindowController.shared.restartDshServiceDuringOperation(context: context)
                    self.refreshPlugins(for: context)
                }
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.showPluginStatus("插件 \(name) 更新成功，服务已重启")
            } catch {
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                if !ignoringMinimumReleaseAge,
                   DshPluginManager.isMinimumReleaseAgeViolation(error) {
                    self.pendingPluginUpdate = .plugin(name)
                    return
                }
                self.alertMessage = DshSettingsUIMessage.safe(error)
            }
        }
        return true
    }

    @discardableResult
    private func startPluginUpdateAll(ignoringMinimumReleaseAge: Bool) -> Bool {
        guard pluginMutationsAllowed else {
            alertMessage = "插件更新暂不可用；请求已保留，请完成恢复后重试。"
            return false
        }
        guard !isOperatingPlugin, !isSwitchingProfile else {
            alertMessage = "当前已有插件操作排队，请稍后重试。"
            return false
        }
        isOperatingPlugin = true
        clearPluginStatus()
        let count = installedPlugins.filter(\.hasUpdate).count
        operatingPluginName = DshSettingsUIMessage.safe(count > 0
            ? "正在更新插件（共 \(count) 个）…"
            : "正在更新插件…")
        Task {
            do {
                try await MainWindowController.shared.withRuntimeOperation {
                    guard let context = DshLaunchContext.makeStartup(from: DshStateManager.shared.current) else {
                        throw DshLaunchContextError.invalidProfileName
                    }
                    try await DshPluginManager.shared.updateAllPlugins(
                        ignoringMinimumReleaseAge: ignoringMinimumReleaseAge,
                        profileDirectory: context.profileDirectory,
                        profile: context.profile,
                        registry: context.runtimeDescriptor.registry
                    )
                    self.outdatedPluginsMap.removeAll()
                    self.refreshPlugins(for: context)
                    self.operatingPluginName = "插件更新完成，正在重启 DSH 服务…"
                    _ = try await MainWindowController.shared.restartDshServiceDuringOperation(context: context)
                    self.refreshPlugins(for: context)
                }
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.showPluginStatus("全部插件已更新至最新版本，服务已重启")
            } catch {
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                if !ignoringMinimumReleaseAge,
                   DshPluginManager.isMinimumReleaseAgeViolation(error) {
                    self.pendingPluginUpdate = .all
                    return
                }
                self.alertMessage = DshSettingsUIMessage.safe(error)
            }
        }
        return true
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
        guard pluginMutationsAllowed else {
            alertMessage = "DSH 当前正在恢复未完成状态，请先完成恢复后再升级 Runtime。"
            return
        }
        guard appProfile == .desktop else {
            alertMessage = "web Profile 与终端共享，暂不允许升级 DSH Runtime；请切回 desktop Profile。"
            return
        }
        let targetVersion: String?
        switch channel {
        case .latest:
            targetVersion = latestVersion
        case .next:
            targetVersion = nextVersion
        case .alpha:
            targetVersion = alphaVersion
        }
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
        guard pluginMutationsAllowed else {
            alertMessage = "DSH 当前正在恢复未完成状态，请先完成恢复后再升级 Runtime。"
            return
        }
        guard appProfile == .desktop else {
            alertMessage = "web Profile 与终端共享，暂不允许升级 DSH Runtime；请切回 desktop Profile。"
            return
        }
        let selectedTarget: String?
        switch runtimeChannel {
        case .latest:
            selectedTarget = latestVersion
        case .next:
            selectedTarget = nextVersion
        case .alpha:
            selectedTarget = alphaVersion
        }
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
        guard state.appProfile == .desktop,
              autoFollowLatest,
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
            syncRuntimeRecoveryState()

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
            syncRuntimeRecoveryState()

        case .reset(let candidate):
            let message = "检测到上次 Runtime 更新在\(recoveryPhaseDescription(state.runtimeState.phase))中断，且没有可用的回滚 Runtime，请重新安装。"
            let snapshotID = state.runtimeState.webProfileSnapshotID
            let snapshotProfile = state.runtimeState.profile
            guard state.appProfile == snapshotProfile else {
                let diagnostic = "\(message) 但快照属于 \(snapshotProfile.rawValue) Profile，当前为 \(state.appProfile.rawValue)，为保护 Profile 数据暂不恢复。"
                self.alertMessage = diagnostic
                syncRuntimeRecoveryState()
                return
            }
            if let snapshotID {
                do {
                    try await DshPluginManager.shared.restoreWebProfileSnapshot(
                        snapshotID,
                        profile: snapshotProfile
                    ) { progress in
                        Task { @MainActor in
                            self.installProgressPhase = DshSettingsUIMessage.safe(progress.phase)
                            self.installProgressDetail = progress.detail.map(DshSettingsUIMessage.safe)
                        }
                    }
                } catch {
                    let diagnostic = "\(message) 但 web Profile 恢复失败，事务仍保留待下次启动重试：\(DshSettingsUIMessage.safe(error))"
                    DshStateManager.shared.update { state in
                        state.runtimeState = DshRuntimeTransaction.recordRollbackFailure(
                            state.runtimeState,
                            diagnostic: diagnostic
                        )
                    }
                    self.alertMessage = diagnostic
                    syncRuntimeRecoveryState()
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
                finalMessage += " Candidate \(candidate.version) 清理失败：\(DshSettingsUIMessage.safe(error))"
                DshStateManager.shared.update { $0.runtimeState.lastDiagnostic = finalMessage }
            }
            if let snapshotID {
                do {
                    try await DshPluginManager.shared.deleteWebProfileSnapshot(snapshotID)
                } catch {
                    finalMessage += " web Profile 快照清理失败：\(DshSettingsUIMessage.safe(error))"
                    DshStateManager.shared.update { state in
                        state.runtimeState.webProfileSnapshotID = snapshotID
                        state.runtimeState.lastDiagnostic = finalMessage
                    }
                }
            }
            self.alertMessage = finalMessage
            syncRuntimeRecoveryState()
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
        snapshotID: String?,
        transactionID: String?
    ) -> Bool {
        guard let transactionID else { return false }
        return state.selectedVersion == selectedVersion
            && state.runtimeState.phase == phase
            && state.runtimeState.active?.version == activeVersion
            && state.runtimeState.previous?.version == previousVersion
            && state.runtimeState.pending?.version == pendingVersion
            && state.runtimeState.webProfileSnapshotID == snapshotID
            && state.runtimeState.transactionID == transactionID
    }

    /// Count a successful app/service start after an update. Keep the old
    /// runtime until the new one has survived two starts, then remove only
    /// the exact recorded previous directory.
    public func recordHealthyRuntimeStart(for context: DshLaunchContext) async {
        let state = DshStateManager.shared.current
        guard context.isFresh(in: state),
              context.purpose == .normal,
              let contextTransactionID = context.transactionID,
              state.runtimeState.transactionID == contextTransactionID,
              context.profile == state.runtimeState.profile,
              context.runtimeDescriptor.version == state.runtimeState.active?.version,
              state.runtimeState.phase == .confirmed,
              let previous = state.runtimeState.previous else { return }

        let expectedSelectedVersion = state.selectedVersion
        let expectedActiveVersion = state.runtimeState.active?.version
        let expectedPreviousVersion = previous.version
        let expectedPendingVersion = state.runtimeState.pending?.version
        let expectedSnapshotID = state.runtimeState.webProfileSnapshotID
        let expectedTransactionID = contextTransactionID
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
                    snapshotID: expectedSnapshotID,
                    transactionID: expectedTransactionID
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
            snapshotID: expectedSnapshotID,
            transactionID: expectedTransactionID
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
                    snapshotID: expectedSnapshotID,
                    transactionID: expectedTransactionID
                ), state.runtimeState.healthyStartCount == nextCount - 1 else { return }
                didCommit = true
                state.runtimeState.previous = nil
                state.runtimeState.healthyStartCount = 0
                state.runtimeState.phase = .idle
                state.runtimeState.transactionID = nil
                state.runtimeState.webProfileSnapshotID = snapshotCleanupError == nil ? nil : snapshotID
                state.runtimeState.lastDiagnostic = snapshotCleanupError.map {
                    "旧 Runtime 已清理，但 web Profile 快照清理失败：\(DshSettingsUIMessage.safe($0))"
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
                    snapshotID: expectedSnapshotID,
                    transactionID: expectedTransactionID
                ) else { return }
                state.runtimeState.healthyStartCount = nextCount
            }
            self.alertMessage = "新 Runtime 已连续启动，但旧 Runtime 清理失败：\(DshSettingsUIMessage.safe(error))"
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
            alertMessage = "web Profile 快照清理仍失败，将在下次启动继续重试：\(DshSettingsUIMessage.safe(error))"
        }
    }

    /// Finish a rollback that was left pending because the previous process
    /// could not be started during the original update attempt. The next app
    /// launch restores the Profile before starting the previous Runtime; once
    /// that start is healthy, this method can safely settle the transaction.
    public func finalizeRecoveredRuntimeAfterSuccessfulStart(for context: DshLaunchContext) async {
        let state = DshStateManager.shared.current
        guard context.isFresh(in: state),
              context.purpose == .runtimeRollback,
              let contextTransactionID = context.transactionID,
              state.runtimeState.transactionID == contextTransactionID,
              context.profile == state.runtimeState.profile,
              context.runtimeDescriptor.version == state.runtimeState.previous?.version,
              state.runtimeState.phase == .rollingBack,
              let active = state.runtimeState.previous,
              let candidate = state.runtimeState.pending,
              state.selectedVersion == active.version else { return }

        let expectedSelectedVersion = state.selectedVersion
        let expectedActiveVersion = state.runtimeState.active?.version
        let expectedPreviousVersion = active.version
        let expectedPendingVersion = candidate.version
        let snapshotID = state.runtimeState.webProfileSnapshotID
        let expectedTransactionID = contextTransactionID
        var cleanupErrors: [String] = []
        do {
            try DshVersionManager.shared.discardInstalledVersion(candidate.version)
        } catch {
            cleanupErrors.append("candidate 清理失败：\(DshSettingsUIMessage.safe(error))")
        }

        var retainedSnapshotID: String?
        if let snapshotID {
            do {
                try await DshPluginManager.shared.deleteWebProfileSnapshot(snapshotID)
            } catch {
                retainedSnapshotID = snapshotID
                cleanupErrors.append("web Profile 快照清理失败：\(DshSettingsUIMessage.safe(error))")
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
            snapshotID: snapshotID,
            transactionID: expectedTransactionID
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
                snapshotID: snapshotID,
                transactionID: expectedTransactionID
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
        syncRuntimeRecoveryState()
        if let diagnostic {
            alertMessage = "已恢复到 \(active.version)，但\(diagnostic)"
        }
    }

    private func runRuntimeUpdate(_ item: DshVersionItem, isAutomatic: Bool = false) async {
        guard pluginMutationsAllowed, !isUpdatingRuntime else { return }
        guard DshStateManager.shared.current.appProfile == .desktop else {
            alertMessage = "web Profile 与终端共享，暂不允许升级 DSH Runtime；请切回 desktop Profile。"
            return
        }
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
            syncRuntimeRecoveryState()
            alertMessage = DshSettingsUIMessage.safe(error)
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
            channel: state.runtimeState.channel,
            profile: state.appProfile
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
                        self.installProgressPhase = DshSettingsUIMessage.safe(progress.phase)
                        self.installProgressDetail = progress.detail.map(DshSettingsUIMessage.safe)
                    }
                }
            } catch {
                throw DshRuntimeUpdateFailure.candidateInstall(
                    version: item.version,
                    detail: DshSettingsUIMessage.safe(error)
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
                    detail: DshSettingsUIMessage.safe(error)
                )
            }

            DshStateManager.shared.update { state in
                state.runtimeState = DshRuntimeTransaction.confirm(state.runtimeState)
            }
        } catch {
            let failureDescription = DshSettingsUIMessage.safe(error)
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
                let diagnostic = "Runtime 回滚失败：\(DshSettingsUIMessage.safe(rollbackError))"
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
                    userInfo: [NSLocalizedDescriptionKey: "更新到 \(item.version) 失败：\(failureDescription)；自动恢复 \(active.version) 也失败：\(DshSettingsUIMessage.safe(rollbackError))"]
                )
            }

            var cleanupErrors: [String] = []
            do {
                try DshVersionManager.shared.discardInstalledVersion(item.version)
            } catch {
                cleanupErrors.append("candidate 清理失败：\(DshSettingsUIMessage.safe(error))")
            }
            let snapshotID = DshStateManager.shared.current.runtimeState.webProfileSnapshotID
            var retainedSnapshotID: String?
            if let snapshotID {
                do {
                    try await DshPluginManager.shared.deleteWebProfileSnapshot(snapshotID)
                } catch {
                    retainedSnapshotID = snapshotID
                    cleanupErrors.append("web Profile 快照清理失败：\(DshSettingsUIMessage.safe(error))")
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
        guard pluginMutationsAllowed, pendingPluginInstallSpec == nil else { return }
        startPluginInstall(spec: spec, ignoringMinimumReleaseAge: false)
    }

    public func confirmPendingPluginInstall() {
        guard let spec = pendingPluginInstallSpec else { return }
        guard pluginMutationsAllowed else {
            alertMessage = "插件安装仍在等待恢复完成；请求已保留，请完成恢复后重试。"
            return
        }
        guard !isOperatingPlugin, !isSwitchingProfile else {
            alertMessage = "当前已有插件操作排队，请稍后重试。"
            return
        }
        if startPluginInstall(spec: spec, ignoringMinimumReleaseAge: true) {
            pendingPluginInstallSpec = nil
        }
    }

    public func cancelPendingPluginInstall() {
        pendingPluginInstallSpec = nil
    }

    public var pendingPluginInstallMessage: String? {
        guard let spec = pendingPluginInstallSpec else { return nil }
        return "安装插件 \(spec) 时，npm 检测到依赖版本发布时间过近。继续安装将仅对本次操作使用 --config.minimum-release-age=0，不会修改全局 pnpm 配置。"
    }

    @discardableResult
    private func startPluginInstall(spec: String, ignoringMinimumReleaseAge: Bool) -> Bool {
        let trimmedSpec = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pluginMutationsAllowed else {
            alertMessage = "插件安装暂不可用；请求已保留，请完成恢复后重试。"
            return false
        }
        guard !isOperatingPlugin, !isSwitchingProfile else {
            alertMessage = "当前已有插件操作排队，请稍后重试。"
            return false
        }
        guard !trimmedSpec.isEmpty else { return false }
        isOperatingPlugin = true
        clearPluginStatus()
        operatingPluginName = DshSettingsUIMessage.safe("正在安装插件 \(trimmedSpec)…")
        Task {
            do {
                try await MainWindowController.shared.withRuntimeOperation {
                    guard let context = DshLaunchContext.makeStartup(from: DshStateManager.shared.current) else {
                        throw DshLaunchContextError.invalidProfileName
                    }
                    try await DshPluginManager.shared.addPlugin(
                        spec: trimmedSpec,
                        ignoringMinimumReleaseAge: ignoringMinimumReleaseAge,
                        profileDirectory: context.profileDirectory,
                        profile: context.profile,
                        registry: context.runtimeDescriptor.registry
                    )
                    self.refreshPlugins(for: context)
                    _ = try await MainWindowController.shared.restartDshServiceDuringOperation(context: context)
                    self.refreshPlugins(for: context)
                }
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.showPluginStatus("插件 \(trimmedSpec) 安装成功，服务已重启")
            } catch {
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                if !ignoringMinimumReleaseAge,
                   DshPluginManager.isMinimumReleaseAgeViolation(error) {
                    self.pendingPluginInstallSpec = trimmedSpec
                    return
                }
                let message = DshSettingsUIMessage.safe(error).trimmingCharacters(in: .whitespacesAndNewlines)
                self.alertMessage = message.isEmpty ? "安装插件 \(trimmedSpec) 失败" : message
            }
        }
        return true
    }

    public func removePlugin(name: String) {
        guard pluginMutationsAllowed, !isOperatingPlugin, !isSwitchingProfile else { return }
        isOperatingPlugin = true
        clearPluginStatus()
        operatingPluginName = DshSettingsUIMessage.safe("正在卸载插件 \(name)…")
        Task {
            do {
                try await MainWindowController.shared.withRuntimeOperation {
                    guard let context = DshLaunchContext.makeStartup(from: DshStateManager.shared.current) else {
                        throw DshLaunchContextError.invalidProfileName
                    }
                    try await DshPluginManager.shared.removePlugin(
                        name: name,
                        profileDirectory: context.profileDirectory,
                        profile: context.profile,
                        registry: context.runtimeDescriptor.registry
                    )
                    self.outdatedPluginsMap.removeValue(forKey: name)
                    self.refreshPlugins(for: context)
                    _ = try await MainWindowController.shared.restartDshServiceDuringOperation(context: context)
                    self.refreshPlugins(for: context)
                }
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.showPluginStatus("插件 \(name) 已卸载，服务已重启")
            } catch {
                self.isOperatingPlugin = false
                self.operatingPluginName = nil
                self.alertMessage = DshSettingsUIMessage.safe(error)
            }
        }
    }

    public func saveGeneralSettings() {
        let stateBeforeSave = DshStateManager.shared.current
        let profileMutationAllowed = pluginMutationsAllowed
        if !profileMutationAllowed, appProfile != stateBeforeSave.appProfile {
            // A binding or an older caller may have changed the published
            // value before reaching this persistence boundary. Restore the
            // durable Profile while still allowing unrelated appearance and
            // access settings to be saved.
            appProfile = stateBeforeSave.appProfile
        }
        let profileToPersist = profileMutationAllowed ? appProfile : stateBeforeSave.appProfile
        let persistedExposure = browserAccessEnabled ? networkExposure : .loopback
        if networkExposure != persistedExposure {
            networkExposure = persistedExposure
        }
        if (runtimeChannel != .latest || appProfile == .web), autoFollowLatest {
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
            alphaVersion = nil
        }
        npmRegistry = normalizedRegistry
        DshStateManager.shared.update { state in
            state.dshPort = dshPort
            state.appProfile = profileToPersist
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

    /// Switch the app's DSH profile and restart the managed service. The
    /// default desktop profile is isolated from terminal `dsh web`; selecting
    /// web is an explicit opt-in to sharing its plugin and dependency tree.
    public func setAppProfile(_ profile: DshAppProfile) {
        guard pluginMutationsAllowed,
              profile != appProfile,
              !isSwitchingProfile,
              !isOperatingPlugin,
              !isUpdatingRuntime,
              !isInstallingVersion else { return }

        let state = DshStateManager.shared.current
        guard state.pendingProfileSwitch == nil else {
            alertMessage = "上一次 Profile 切换尚未完成恢复，请重启 DSH 后再试。"
            return
        }
        if state.runtimeState.pending != nil,
           profile != state.runtimeState.profile {
            alertMessage = "Runtime 回滚尚未完成，只能使用 \(state.runtimeState.profile.rawValue) Profile；为保护 Profile 数据，暂不允许切换。"
            return
        }

        let previous = appProfile
        let leavingSharedWeb = previous == .web && profile == .desktop
        let transaction = DshProfileSwitchTransaction(from: previous, to: profile)

        // Persist the transaction together with the target Profile before any
        // pnpm or Node work begins. A force-quit after this point can therefore
        // be repaired deterministically during the next app launch.
        var didPersistTransaction = false
        DshStateManager.shared.update { state in
            guard state.appProfile == previous, state.pendingProfileSwitch == nil else { return }
            state.appProfile = profile
            state.pendingProfileSwitch = transaction
            didPersistTransaction = true
        }
        guard didPersistTransaction else {
            loadFromState()
            return
        }
        appProfile = profile
        saveGeneralSettings()
        isSwitchingProfile = true
        clearPluginStatus()

        Task { [self] in
            do {
                let cleanupError = try await MainWindowController.shared.withRuntimeOperation { () -> Error? in
                    guard let context = DshLaunchContext.makeStartup(from: DshStateManager.shared.current) else {
                        throw DshLaunchContextError.invalidProfileName
                    }
                    if leavingSharedWeb {
                        await DshService.shared.stopAndWait()
                    }
                    _ = try await MainWindowController.shared.restartDshServiceDuringOperation(context: context)

                    var cleanupError: Error?
                    var finalizingTransaction = transaction
                    if leavingSharedWeb {
                        // The desktop target is already healthy. Mark this
                        // phase before touching the shared web tree so a
                        // force-quit can keep desktop and retry cleanup.
                        finalizingTransaction.phase = .finalizing
                        DshStateManager.shared.update { state in
                            guard state.pendingProfileSwitch == transaction else { return }
                            state.pendingProfileSwitch = finalizingTransaction
                        }
                        do {
                            try await DshPluginManager.shared.removeDesktopHostArtifacts(
                                from: .web,
                                registry: context.runtimeDescriptor.registry
                            )
                        } catch {
                            cleanupError = error
                        }
                    }

                    // Commit only after the target Profile has passed the
                    // complete startup and health gate. This closes the small
                    // window where a successful restart could be followed by
                    // a force-quit before the UI task resumes.
                    DshStateManager.shared.update { state in
                        guard let pending = state.pendingProfileSwitch,
                              pending.from == transaction.from,
                              pending.to == transaction.to,
                              pending.transactionID == transaction.transactionID else { return }
                        state.appProfile = profile
                        state.pendingProfileSwitch = cleanupError == nil ? nil : finalizingTransaction
                    }
                    return cleanupError
                }
                self.refreshPlugins()
                self.isSwitchingProfile = false
                if let cleanupError {
                    self.alertMessage = "已切换到 \(profile.rawValue) Profile，服务已重启，但 web 桥接清理失败，将在下次启动重试：\(DshSettingsUIMessage.safe(cleanupError))"
                } else {
                    self.showPluginStatus("已切换到 \(profile.rawValue) Profile，服务已重启")
                }
            } catch {
                // Keep the transaction marker while restoring. If this task
                // is interrupted, startup will still know to return to the
                // previous Profile and retry web cleanup.
                DshStateManager.shared.update { state in
                    guard state.pendingProfileSwitch == transaction else { return }
                    state.appProfile = previous
                }
                self.appProfile = previous
                self.saveGeneralSettings()
                var restoreError: Error?
                var restoreCleanupError: Error?
                do {
                    restoreCleanupError = try await MainWindowController.shared.withRuntimeOperation { () -> Error? in
                        guard let context = DshLaunchContext.makeStartup(from: DshStateManager.shared.current) else {
                            throw DshLaunchContextError.invalidProfileName
                        }
                        await DshService.shared.stopAndWait()
                        var cleanupError: Error?
                        if profile == .web && previous == .desktop {
                            do {
                                try await DshPluginManager.shared.removeDesktopHostArtifacts(
                                    from: .web,
                                    registry: context.runtimeDescriptor.registry
                                )
                            } catch {
                                // Bridge cleanup is app-owned housekeeping. It
                                // must not prevent the known-good desktop
                                // service from coming back; leave the marker
                                // pending so startup can retry the cleanup.
                                cleanupError = error
                            }
                        }
                        _ = try await MainWindowController.shared.restartDshServiceDuringOperation(context: context)
                        DshStateManager.shared.update { state in
                            guard state.pendingProfileSwitch == transaction else { return }
                            state.appProfile = previous
                            state.pendingProfileSwitch = cleanupError == nil ? nil : transaction
                        }
                        return cleanupError
                    }
                    self.refreshPlugins()
                } catch {
                    restoreError = error
                }
                self.isSwitchingProfile = false
                if let restoreError {
                    self.alertMessage = "切换到 \(profile.rawValue) Profile 失败，原 Profile 也无法恢复：\(DshSettingsUIMessage.safe(restoreError))"
                } else if let restoreCleanupError {
                    self.alertMessage = "切换到 \(profile.rawValue) Profile 失败，已恢复 \(previous.rawValue) Profile，但 web 桥接清理失败，将在下次启动重试：\(DshSettingsUIMessage.safe(restoreCleanupError))"
                } else {
                    self.alertMessage = "切换到 \(profile.rawValue) Profile 失败，已恢复 \(previous.rawValue) Profile：\(DshSettingsUIMessage.safe(error))"
                }
            }
        }
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
                self.alertMessage = "更新浏览器访问设置失败：\(DshSettingsUIMessage.safe(error))"
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
                self.alertMessage = "更新局域网访问设置失败：\(DshSettingsUIMessage.safe(error))"
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
                self.alertMessage = "获取局域网地址失败：\(DshSettingsUIMessage.safe(error))"
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
                self.alertMessage = "获取局域网地址失败：\(DshSettingsUIMessage.safe(error))"
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
                self.alertMessage = "打开浏览器失败：\(DshSettingsUIMessage.safe(error))"
            }
            self.isOpeningBrowser = false
        }
    }

    public func restartDshService() {
        MainWindowController.shared.startAndLoadDsh()
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
