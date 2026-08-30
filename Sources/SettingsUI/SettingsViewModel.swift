import Foundation
import AppKit
import SwiftUI
import Combine

public extension Notification.Name {
    static let dshSettingsPanelDidChange = Notification.Name("dsh.settingsPanelDidChange")
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
    @Published public var autoFollowLatest: Bool = false
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
    @Published public var isSwitchingVersion: Bool = false
    @Published public var isUninstallingVersion: Bool = false
    @Published public var installingVersionName: String? = nil
    @Published public var uninstallingVersionName: String? = nil
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
    private var pluginStatusDismissTask: Task<Void, Never>?
    private var pluginStatusGeneration = 0

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
        self.autoFollowLatest = state.autoFollowLatest
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
        isLoadingCatalog = true
        let startedAt = Date()
        defer { isLoadingCatalog = false }
        do {
            let res = try await DshVersionManager.shared.fetchCatalog(registry: npmRegistry)
            self.latestVersion = res.latest
            self.availableVersions = res.versions
            self.installedVersions = DshVersionManager.shared.listInstalledVersions()
        } catch {
            self.alertMessage = error.localizedDescription
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
                try await DshPluginManager.shared.updatePlugin(name: name)
                self.outdatedPluginsMap.removeValue(forKey: name)
                self.refreshPlugins()
                try await self.restartDshServiceAndWait()
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
                try await DshPluginManager.shared.updateAllPlugins()
                self.outdatedPluginsMap.removeAll()
                self.refreshPlugins()
                try await self.restartDshServiceAndWait()
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

    public func installVersion(_ version: String) {
        guard !isInstallingVersion else { return }
        isInstallingVersion = true
        installingVersionName = version
        installProgressPhase = "准备安装 DSH \(version)..."
        installProgressDetail = nil

        Task { [self] in
            do {
                let selectedByInstall = try await DshVersionManager.shared.installVersion(version: version, registry: npmRegistry) { progress in
                    Task { @MainActor in
                        self.installProgressPhase = progress.phase
                        self.installProgressDetail = progress.detail
                    }
                }
                self.loadFromState()
                await self.refreshCatalog()
                if selectedByInstall {
                    try await self.restartDshServiceAndWait()
                }
                self.isInstallingVersion = false
                self.installingVersionName = nil
            } catch {
                self.isInstallingVersion = false
                self.installingVersionName = nil
                self.alertMessage = "安装版本失败：\(error.localizedDescription)"
            }
        }
    }

    public func selectVersion(_ version: String) {
        guard !isInstallingVersion, !isSwitchingVersion, !isUninstallingVersion else { return }
        guard DshVersionManager.shared.isVersionInstalled(version) else {
            alertMessage = "该版本尚未安装"
            return
        }
        let previous = DshStateManager.shared.current.selectedVersion
        guard previous != version else { return }

        isSwitchingVersion = true
        DshStateManager.shared.update { $0.selectedVersion = version }
        selectedVersion = version
        installedVersions = DshVersionManager.shared.listInstalledVersions()

        Task { [self] in
            do {
                try await restartDshServiceAndWait()
                self.loadFromState()
                await self.refreshCatalog()
                self.isSwitchingVersion = false
            } catch {
                DshStateManager.shared.update { $0.selectedVersion = previous }
                self.loadFromState()
                await self.refreshCatalog()
                self.isSwitchingVersion = false
                self.alertMessage = "切换版本失败：\(error.localizedDescription)"
                if previous != nil {
                    try? await self.restartDshServiceAndWait()
                }
            }
        }
    }

    /// Match Electron's startup auto-follow behavior. With no bundled DSH,
    /// this only runs when a valid user-installed current version exists.
    public func followLatestIfEnabled() async {
        guard autoFollowLatest,
              !isInstallingVersion,
              !isSwitchingVersion,
              !isFollowingLatest,
              let latest = latestVersion,
              let current = DshStateManager.shared.current.selectedVersion,
              DshVersionManager.shared.isVersionInstalled(current),
              DshVersionManager.shared.isVersionNewer(latest, than: current) else { return }

        isFollowingLatest = true
        defer { isFollowingLatest = false }
        isInstallingVersion = true
        installingVersionName = latest
        installProgressPhase = "准备自动更新 DSH \(latest)..."
        installProgressDetail = nil
        do {
            _ = try await DshVersionManager.shared.installVersion(version: latest, registry: npmRegistry) { progress in
                Task { @MainActor in
                    self.installProgressPhase = progress.phase
                    self.installProgressDetail = progress.detail
                }
            }
            DshStateManager.shared.update { $0.selectedVersion = latest }
            selectedVersion = latest
            installedVersions = DshVersionManager.shared.listInstalledVersions()
            try await restartDshServiceAndWait()
            isInstallingVersion = false
            installingVersionName = nil
        } catch {
            DshStateManager.shared.update { $0.selectedVersion = current }
            selectedVersion = current
            isInstallingVersion = false
            installingVersionName = nil
            try? await restartDshServiceAndWait()
            alertMessage = "自动更新 DSH 失败：\(error.localizedDescription)"
        }
    }

    public func uninstallVersion(_ version: String) {
        guard !isInstallingVersion, !isSwitchingVersion, !isUninstallingVersion else { return }
        isUninstallingVersion = true
        uninstallingVersionName = version
        Task { [self] in
            do {
                try await performUninstall(version)
                self.loadFromState()
                await self.refreshCatalog()
            } catch {
                self.alertMessage = "卸载失败：\(error.localizedDescription)"
            }
            self.isUninstallingVersion = false
            self.uninstallingVersionName = nil
        }
    }

    private func performUninstall(_ version: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try DshVersionManager.shared.uninstallVersion(version: version)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func addPlugin(spec: String) {
        guard !isOperatingPlugin, !spec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isOperatingPlugin = true
        clearPluginStatus()
        operatingPluginName = "正在安装插件 \(spec)…"
        Task {
            do {
                try await DshPluginManager.shared.addPlugin(spec: spec)
                self.refreshPlugins()
                try await self.restartDshServiceAndWait()
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
                try await DshPluginManager.shared.removePlugin(name: name)
                self.outdatedPluginsMap.removeValue(forKey: name)
                self.refreshPlugins()
                try await self.restartDshServiceAndWait()
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
        DshStateManager.shared.update { state in
            state.dshPort = dshPort
            state.npmRegistry = npmRegistry
            state.uiTheme = uiTheme
            state.translateCommands = translateCommands
            state.autoFollowLatest = autoFollowLatest
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
