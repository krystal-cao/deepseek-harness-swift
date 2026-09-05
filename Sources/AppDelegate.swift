import AppKit
import Sparkle
import WebKit

private enum DshAppDelegateLog {
    static let maximumLength = 600

    static func safe(_ error: Error) -> String {
        let redacted = DshSecretRedactor().redactDiagnostic(error.localizedDescription)
        guard redacted.count > maximumLength else { return redacted }
        return String(redacted.prefix(maximumLength)) + "…"
    }
}

/// Marks only failures thrown by the P01 recovery handoff. Runtime/Profile
/// recovery runs in the same operation gate, but its errors must continue
/// through the original M1 startup/retry path even when a plugin record also
/// exists on disk.
private enum DshStartupRecoveryError: Error {
    case pluginOperation(Error)
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep one updater for the whole app. Sparkle starts its automatic
        // checker from the Info.plist settings and the same controller backs
        // the menu item and About settings row.
        _ = AppUpdateManager.shared
        setupAppMenu()
        Task { @MainActor in
            // Recovery and Profile cleanup can touch thousands of files. Keep
            // the UI responsive and let MainWindowController perform the one
            // actual snapshot restore immediately before the old Runtime is
            // started.
            // Profile switches are persisted separately from Runtime update
            // transactions. Recover them first so a force-quit during a
            // failed web switch can never make startup retry the bad Profile.
            // Reclaim an orphaned Node process before any recovery path can
            // touch package.json, pnpm-lock.yaml, or node_modules.
            var startupRecoveryError: Error?
            do {
                // Startup recovery, snapshot cleanup, and the first launch
                // share one operation gate. This prevents MainWindow from
                // queueing a start between the stale-process check and a
                // recovery write.
                try await MainWindowController.shared.withRuntimeOperation {
                    try await DshService.shared.prepareForProfileMutation()
                    await SettingsViewModel.shared.recoverPendingProfileSwitch()
                    await SettingsViewModel.shared.recoverPendingRuntimeUpdate()
                    await SettingsViewModel.shared.retryRetainedWebProfileSnapshotCleanup()

                    // P01 recovery runs inside this already-held Runtime /
                    // Profile gate. Its health hooks call
                    // restartDshServiceDuringOperation directly, so a
                    // pending plugin transaction cannot race the first
                    // ordinary launch or deadlock by reacquiring this gate.
                    do {
                        _ = try await MainWindowController.shared
                            .recoverPendingPluginOperationDuringStartup()
                    } catch {
                        // Preserve the exact stage. The outer catch must not
                        // infer plugin ownership from the mere presence of a
                        // durable record: a preceding Runtime/Profile step
                        // may have been the operation that actually failed.
                        throw DshStartupRecoveryError.pluginOperation(error)
                    }

                    _ = await Task.detached(priority: .utility) {
                        DshVersionManager.shared.cleanupUnreferencedVersions()
                    }.value
                    _ = await DshPluginManager.shared.cleanupOrphanedWebProfileSnapshots(
                        keeping: DshStateManager.shared.current.runtimeState.webProfileSnapshotID
                    )
                }
            } catch {
                // Keep M1's original MainWindow startup classification for
                // ordinary Runtime/Profile failures. Only the explicitly
                // marked P01 handoff failure blocks normal launch.
                if case let .pluginOperation(pluginError) = error as? DshStartupRecoveryError {
                    startupRecoveryError = pluginError
                }
                print("[AppDelegate] Profile recovery deferred until the DSH port is safe:", DshAppDelegateLog.safe(error))
            }
            if let startupRecoveryError {
                // Do not continue into a normal launch after an unresolved
                // Runtime/Profile/plugin recovery condition. The native
                // surface retains the redacted diagnostic and exposes only
                // explicit recovery actions.
                MainWindowController.shared.blockStartupForRecovery(startupRecoveryError)
            }
            MainWindowController.shared.launch()
            await SettingsViewModel.shared.refreshCatalog()
            await SettingsViewModel.shared.followLatestIfEnabled()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        DshService.shared.stop()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Settings is a separate visible window. Reopening from the Dock must
        // still restore the main window even while Settings remains open.
        MainWindowController.shared.showMainWindow()
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - App Menu Setup

    private func setupAppMenu() {
        let mainMenu = NSMenu()

        // 1. App Menu (DSH)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = appMenu.addItem(withTitle: "关于 DSH", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = appMenu.addItem(withTitle: "设置与版本管理...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        let restartItem = appMenu.addItem(withTitle: "重启 DSH 服务", action: #selector(restartService), keyEquivalent: "r")
        restartItem.target = self

        let checkForUpdatesItem = NSMenuItem(
            title: "检查更新…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = AppUpdateManager.shared.updaterController
        appMenu.addItem(checkForUpdatesItem)

        appMenu.addItem(NSMenuItem.separator())

        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        NSApp.servicesMenu = servicesMenu
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(withTitle: "隐藏 DSH", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(withTitle: "退出 DSH", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 2. Edit Menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // 3. View / Control Menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "视图")
        viewMenu.addItem(withTitle: "重新加载页面", action: #selector(reloadPage), keyEquivalent: "R")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "进入全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
#if DEBUG
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "启用开发者工具", action: #selector(MainWindowController.enableDeveloperTools), keyEquivalent: "")
        viewMenu.addItem(withTitle: "关闭开发者工具", action: #selector(MainWindowController.closeDeveloperTools), keyEquivalent: "")
#endif
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // 4. Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        // 5. Help Menu
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "帮助")
        let helpItem = helpMenu.addItem(withTitle: "DSH 帮助文档与源码", action: #selector(openHelp), keyEquivalent: "")
        helpItem.target = self
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openAbout() {
        AboutWindowController.shared.show()
    }

    @objc private func restartService() {
        MainWindowController.shared.startAndLoadDsh()
    }

    @objc private func reloadPage() {
        MainWindowController.shared.reloadDsh()
    }

    @objc private func openHelp() {
        if let url = URL(string: "https://github.com/summer-521/deepseek-harness-desktop") {
            NSWorkspace.shared.open(url)
        }
    }
}
