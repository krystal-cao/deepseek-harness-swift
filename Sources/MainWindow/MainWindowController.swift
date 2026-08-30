import AppKit
import WebKit
import SwiftUI

private final class DownloadStatusBanner: NSVisualEffectView {
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let revealButton = NSButton(title: "在访达中显示", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)

    var onReveal: (() -> Void)?
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        statusLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        pathLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1

        revealButton.bezelStyle = .rounded
        revealButton.controlSize = .small
        revealButton.target = self
        revealButton.action = #selector(revealDownload)

        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .small
        closeButton.target = self
        closeButton.action = #selector(closeBanner)

        let textStack = NSStackView(views: [statusLabel, pathLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3

        let stack = NSStackView(views: [spinner, textStack, revealButton, closeButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        addSubview(stack)

        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        revealButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(destination: URL, completed: Bool) {
        statusLabel.stringValue = completed ? "下载完成" : "正在下载"
        let fullPath = destination.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        pathLabel.stringValue = fullPath.hasPrefix(homePath + "/")
            ? "~" + String(fullPath.dropFirst(homePath.count))
            : fullPath
        pathLabel.toolTip = fullPath

        spinner.isHidden = completed
        if completed {
            spinner.stopAnimation(nil)
        } else {
            spinner.startAnimation(nil)
        }
        revealButton.isHidden = !completed
    }

    @objc private func revealDownload() {
        onReveal?()
    }

    @objc private func closeBanner() {
        onClose?()
    }
}

public final class MainWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, DshBridgeDelegate {
    public static let shared = MainWindowController()

    private var webView: WKWebView?
    private var vibrancyView: NSVisualEffectView?
    private var webShell: DshWebShell?
    private var rendererCookieStore: DshRendererCookieStore?
    private var serviceSession: DshServiceSession?
    private var onboardingHostingView: NSView?
    private var webUIReadinessGeneration = 0
    private var windowDragMouseDownEvent: NSEvent?
    private var isUsingNativeWindowDrag = false
    private var windowDragStartOrigin: NSPoint?
    private var windowDragStartMouseLocation: NSPoint?
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
    private var downloadStatusBanner: DownloadStatusBanner?


    private init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 960),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = ""
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.minSize = NSSize(width: 960, height: 640)
        win.center()
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isReleasedWhenClosed = false
        win.isMovableByWindowBackground = true

        super.init(window: win)
        win.delegate = self
        if let closeButton = win.standardWindowButton(.closeButton) {
            closeButton.target = self
            closeButton.action = #selector(hideMainWindow)
        }
        setupContentView(in: win)
        adjustTrafficLights(in: win)
        // NSWindow can become visible as soon as the application activates.
        // Keep the main window explicitly hidden until the DSH page has
        // finished rendering; otherwise the user sees a blank/boot screen
        // while the runtime and bridge plugin are still starting.
        win.orderOut(nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The full-size transparent content view makes AppKit place the traffic
    /// lights too close to the physical top edge. Match the vertical rhythm
    /// of normal macOS titlebars while keeping the content visually fused.
    private func adjustTrafficLights(in win: NSWindow) {
        win.layoutIfNeeded()
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = win.standardWindowButton(type) else { continue }
            var frame = button.frame
            frame.origin.x += 7
            frame.origin.y -= 8
            button.frame = frame
        }
    }

    private func setupContentView(in win: NSWindow) {
        let shell = DshWebShell(
            delegate: self
        )
        shell.webView.navigationDelegate = self
        shell.webView.uiDelegate = self
        self.webShell = shell
        self.webView = shell.webView
        self.rendererCookieStore = DshRendererCookieStore(dataStore: shell.webView.configuration.websiteDataStore)
        self.vibrancyView = shell.rootView
        win.contentView = shell.rootView
    }

    // MARK: - App Launch & Initialization

    public func launch() {
        let installed = DshVersionManager.shared.listInstalledVersions()
        if installed.isEmpty && DshVersionManager.shared.resolveCurrentEntry() == nil {
            showOnboardingView()
            revealWindow()
        } else {
            // Keep window hidden initially to eliminate gray flash
            startAndLoadDsh()
        }
    }

    public func startAndLoadDsh() {
        hideOnboardingView()
        Task { @MainActor in
            do {
                let session = try await restartDshService()
                print("[MainWindowController] DSH service ready at \(session.url)")
            } catch {
                print("[MainWindowController] Service start failed:", error)
                self.revealWindow()
                self.showErrorAlert(error.localizedDescription)
            }
        }
    }

    /// Restart the service and wait until the selected runtime is ready. The
    /// settings version switch uses this throwing form so it can restore the
    /// previous selection if the new runtime fails to boot.
    public func restartDshService() async throws -> DshServiceSession {
        // The profile must be complete and the access-control bundle must be
        // mounted before Node starts. This removes the old first-launch window
        // where DSH briefly listened through the unprotected upstream server.
        try DshPluginManager.shared.bootstrapWebProfileManifestIfMissing()
        _ = try await DshPluginManager.shared.ensureDesktopHostPlugin()
        serviceSession = nil
        let session = try await DshService.shared.start()

        do {
            guard let rendererCookieStore else {
                throw DshRendererCookieStore.CookieError.writeFailed
            }
            try await rendererCookieStore.install(for: session)
        } catch {
            // A service without its current Renderer credential must never be
            // left reachable after startup, even if Cookie installation fails.
            DshService.shared.stop()
            throw error
        }

        serviceSession = session
        webUIReadinessGeneration &+= 1
        self.webView?.load(URLRequest(url: session.url))
        return session
    }

    public enum BrowserURLError: Error, LocalizedError {
        case serviceUnavailable
        case accessDisabled
        case requestFailed(Int)
        case invalidResponse
        case openFailed

        public var errorDescription: String? {
            switch self {
            case .serviceUnavailable:
                return "DSH 服务尚未就绪，暂时无法生成浏览器访问地址。"
            case .accessDisabled:
                return "请先开启浏览器访问。"
            case .requestFailed(let status):
                return "生成浏览器访问地址失败（HTTP \(status)）。"
            case .invalidResponse:
                return "DSH 返回的浏览器访问地址无效。"
            case .openFailed:
                return "无法打开默认浏览器。"
            }
        }
    }

    /// Ask the Host-side bridge for a short-lived authenticated URL. The
    /// Renderer cookie is attached only to this in-memory request and the URL
    /// is never persisted or printed by the native app.
    public func fetchAuthenticatedBrowserURL() async throws -> URL {
        guard DshStateManager.shared.current.browserAccessEnabled else {
            throw BrowserURLError.accessDisabled
        }
        guard let session = serviceSession else {
            throw BrowserURLError.serviceUnavailable
        }

        var request = URLRequest(url: session.url.appendingPathComponent("__dsh_swift/browser-url"))
        request.httpMethod = "POST"
        request.setValue("dsh_swift_renderer=\(session.access.rendererToken)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BrowserURLError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw BrowserURLError.requestFailed(httpResponse.statusCode)
        }

        struct BrowserURLResponse: Decodable {
            let url: URL
        }
        guard let payload = try? JSONDecoder().decode(BrowserURLResponse.self, from: data),
              payload.url.scheme == "http",
              payload.url.host == "127.0.0.1",
              payload.url.port == session.url.port else {
            throw BrowserURLError.invalidResponse
        }
        return payload.url
    }

    public enum LANURLError: Error, LocalizedError {
        case serviceUnavailable
        case accessDisabled
        case networkAccessDisabled
        case requestFailed(Int)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .serviceUnavailable:
                return "DSH 服务尚未就绪，暂时无法生成局域网访问地址。"
            case .accessDisabled:
                return "请先开启浏览器访问。"
            case .networkAccessDisabled:
                return "请先开启局域网访问。"
            case .requestFailed(let status):
                return "生成局域网访问地址失败（HTTP \(status)）。"
            case .invalidResponse:
                return "DSH 返回的局域网访问地址无效。"
            }
        }
    }

    /// Ask the Host for a short-lived LAN URL. The URL remains in memory on
    /// the native side; the first HTTP navigation exchanges its query token
    /// for a session cookie at the LAN ingress.
    public func fetchLANURL() async throws -> URL {
        let state = DshStateManager.shared.current
        guard state.browserAccessEnabled else { throw LANURLError.accessDisabled }
        guard state.networkExposure == .lan else { throw LANURLError.networkAccessDisabled }
        guard let session = serviceSession else { throw LANURLError.serviceUnavailable }

        var request = URLRequest(url: session.url.appendingPathComponent("__dsh_swift/lan-url"))
        request.httpMethod = "POST"
        request.setValue("dsh_swift_renderer=\(session.access.rendererToken)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LANURLError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw LANURLError.requestFailed(httpResponse.statusCode)
        }

        struct LANURLResponse: Decodable {
            let url: URL
        }
        guard let payload = try? JSONDecoder().decode(LANURLResponse.self, from: data),
              payload.url.scheme == "http",
              let host = payload.url.host,
              !host.isEmpty,
              host != "127.0.0.1",
              host != "localhost",
              payload.url.port != nil else {
            throw LANURLError.invalidResponse
        }
        return payload.url
    }

    /// Reveal the native window only after DSH has replaced its plugin boot
    /// screen with real UI. The bridge activation callback is intentionally
    /// not used as the sole signal: Cordis can activate the desktop-host
    /// plugin before the page has finished rendering.
    private func waitForWebUIReady(timeout: TimeInterval = 30) {
        webUIReadinessGeneration &+= 1
        let generation = webUIReadinessGeneration
        let deadline = Date().addingTimeInterval(timeout)

        var check: (() -> Void)!
        check = { [weak self] in
            guard let self,
                  self.webUIReadinessGeneration == generation,
                  let webView = self.webView else { return }

            webView.evaluateJavaScript(DshWebShell.webUIReadinessScript) { [weak self] result, _ in
                DispatchQueue.main.async {
                    guard let self,
                          self.webUIReadinessGeneration == generation else { return }

                    let state = result as? [String: Any]
                    let loading = (state?["loading"] as? NSNumber)?.boolValue ?? true
                    let length = (state?["length"] as? NSNumber)?.intValue ?? 0
                    let hasAppShell = (state?["hasAppShell"] as? NSNumber)?.boolValue ?? false
                    if !loading && length > 120 && hasAppShell {
                        self.revealWindow()
                        return
                    }
                    if Date() >= deadline {
                        if loading || length == 0 || !hasAppShell {
                            self.showErrorAlert("DSH 页面加载超时，请重启 DSH 服务后重试。")
                        } else {
                            self.revealWindow()
                        }
                        return
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: check)
                }
            }
        }
        check()
    }

    public func revealWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let win = self?.window else { return }
            if !win.isVisible {
                win.alphaValue = 0
                win.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    win.animator().alphaValue = 1.0
                }
            }
        }
    }

    /// Treat the red traffic-light button as hide, like a utility window. The
    /// application stays alive and can be brought back from the Dock, the app
    /// menu, or applicationShouldHandleReopen.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideMainWindow()
        return false
    }

    @objc private func hideMainWindow() {
        window?.orderOut(nil)
    }

    public func showMainWindow() {
        revealWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Whether the main DSH window is the window the user is currently using.
    /// Settings/About can be key windows while the main window remains
    /// visible, so notification suppression must inspect this window directly.
    public var isFocusedForNotifications: Bool {
        guard let win = window else { return false }
        return NSApp.isActive && win.isVisible && !win.isMiniaturized && win.isKeyWindow
    }

    public func reloadDsh() {
        guard let currentUrl = webView?.url else {
            startAndLoadDsh()
            return
        }
        webView?.load(URLRequest(url: currentUrl))
    }

    // MARK: - Onboarding View

    private func showOnboardingView() {
        guard let vibrancy = vibrancyView else { return }
        let onboarding = OnboardingView { [weak self] in
            self?.startAndLoadDsh()
        }
        let hosting = NSHostingView(rootView: onboarding)
        hosting.frame = vibrancy.bounds
        hosting.autoresizingMask = [.width, .height]
        vibrancy.addSubview(hosting)
        self.onboardingHostingView = hosting
    }

    private func hideOnboardingView() {
        onboardingHostingView?.removeFromSuperview()
        onboardingHostingView = nil
    }

    private func showErrorAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "DSH 启动失败"
        alert.informativeText = message
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "退出")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            SettingsWindowController.shared.show()
        } else {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Styling & Theme Injection

    public func syncUiTheme() {
        let externalTheme = DshPluginManager.shared.detectExternalTheme()
        let theme = externalTheme == nil ? DshStateManager.shared.current.uiTheme : "default"
        webShell?.syncTheme(theme)
    }

    public func syncTranslateCommands() {
        webShell?.syncTranslateCommands(enabled: DshStateManager.shared.current.translateCommands)
    }

    // MARK: - WKNavigationDelegate

    private func isLocalWebURL(_ url: URL) -> Bool {
        url.host == "127.0.0.1" || url.host == "localhost"
    }

    private func isExpectedNavigationInterruption(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            return true
        }
        // WebKit uses its legacy policy-change error when a frame navigation
        // is intentionally converted into a WKDownload.
        return error.domain == "WebKitErrorDomain" && error.code == 102
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if isLocalWebURL(url) && navigationAction.shouldPerformDownload {
            decisionHandler(.download)
        } else if isLocalWebURL(url) {
            decisionHandler(.allow)
        } else {
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let url = navigationResponse.response.url,
              isLocalWebURL(url) else {
            decisionHandler(.cancel)
            return
        }

        let contentDisposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .lowercased()
        if contentDisposition?.contains("attachment") == true || !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                        didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                        didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncUiTheme()
        syncTranslateCommands()
        waitForWebUIReady()
    }

    @objc public func enableDeveloperTools() {
        webShell?.enableDeveloperTools()
    }

    @objc public func closeDeveloperTools() {
        webShell?.closeDeveloperTools()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if isExpectedNavigationInterruption(error) {
            print("[MainWindowController] Ignored expected navigation interruption:", error.localizedDescription)
            return
        }
        revealWindow()
        showErrorAlert("页面加载失败：\(error.localizedDescription)")
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if isExpectedNavigationInterruption(error) {
            print("[MainWindowController] Ignored expected provisional navigation interruption:", error.localizedDescription)
            return
        }
        revealWindow()
        showErrorAlert("页面加载失败：\(error.localizedDescription)")
    }

    // MARK: - WKDownloadDelegate

    private func downloadSelectionDefaults(suggestedFilename: String) throws -> (directory: URL, filename: String) {
        let fileManager = FileManager.default
        guard let downloadsDirectory = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "DSHDownload",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法找到用户下载目录。"]
            )
        }
        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)

        let lastPathComponent = (suggestedFilename as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = lastPathComponent.isEmpty || lastPathComponent == "." || lastPathComponent == ".."
            ? "download"
            : lastPathComponent
        return (downloadsDirectory, filename)
    }

    private func showDownloadError(_ message: String) {
        dismissDownloadStatus()
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "下载失败"
        alert.informativeText = message
        alert.addButton(withTitle: "好的")
        alert.beginSheetModal(for: window)
    }

    private func showDownloadStatus(destination: URL, completed: Bool) {
        guard let vibrancyView else { return }

        let banner: DownloadStatusBanner
        if let existing = downloadStatusBanner {
            banner = existing
        } else {
            banner = DownloadStatusBanner(frame: .zero)
            banner.translatesAutoresizingMaskIntoConstraints = false
            vibrancyView.addSubview(banner, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                banner.trailingAnchor.constraint(equalTo: vibrancyView.trailingAnchor, constant: -20),
                banner.bottomAnchor.constraint(equalTo: vibrancyView.bottomAnchor, constant: -20),
                banner.widthAnchor.constraint(equalToConstant: 500)
            ])
            downloadStatusBanner = banner
        }

        banner.onReveal = {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
        banner.onClose = { [weak self, weak banner] in
            guard let self, self.downloadStatusBanner === banner else { return }
            self.dismissDownloadStatus()
        }
        banner.update(destination: destination, completed: completed)
    }

    private func dismissDownloadStatus() {
        downloadStatusBanner?.removeFromSuperview()
        downloadStatusBanner = nil
    }

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                         suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        do {
            let defaults = try downloadSelectionDefaults(suggestedFilename: suggestedFilename)
            guard let window else {
                throw NSError(
                    domain: "DSHDownload",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "主窗口当前不可用。"]
                )
            }

            let panel = NSSavePanel()
            panel.title = "保存 Session 导出"
            panel.message = "选择 Session ZIP 文件的保存位置。"
            panel.prompt = "保存"
            panel.directoryURL = defaults.directory
            panel.nameFieldStringValue = defaults.filename
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false

            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self else {
                    completionHandler(nil)
                    return
                }
                guard response == .OK, let destination = panel.url else {
                    completionHandler(nil)
                    return
                }

                do {
                    // NSSavePanel has already asked the user to confirm an
                    // overwrite. WKDownload requires that its destination
                    // does not exist when the transfer begins.
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    self.downloadDestinations[ObjectIdentifier(download)] = destination
                    self.showDownloadStatus(destination: destination, completed: false)
                    completionHandler(destination)
                } catch {
                    completionHandler(nil)
                    self.showDownloadError(error.localizedDescription)
                }
            }
        } catch {
            completionHandler(nil)
            showDownloadError(error.localizedDescription)
        }
    }

    public func downloadDidFinish(_ download: WKDownload) {
        if let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
            print("[MainWindowController] Download completed:", destination.path)
            showDownloadStatus(destination: destination, completed: true)
        }
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        if isExpectedNavigationInterruption(error) {
            print("[MainWindowController] Download cancelled")
            return
        }
        print("[MainWindowController] Download failed:", error.localizedDescription)
        showDownloadError(error.localizedDescription)
    }

    // MARK: - WKUIDelegate

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    // MARK: - DshBridgeDelegate

    public func bridgeDidReceiveReady() {
        print("[MainWindowController] DSH Web UI ready signal received")
        syncUiTheme()
        syncTranslateCommands()
    }

    public func bridgeDidReceiveTheme(colorScheme: String?, externalTheme: String?) {
        // The manifest is the authoritative source for whether the native
        // theme control is available. Re-read it when the bridge publishes a
        // theme snapshot so the settings page follows plugin changes quickly.
        Task { @MainActor in
            DshNativeAppearance.update(colorScheme: colorScheme)
            SettingsViewModel.shared.refreshExternalThemeFromBridge()
        }
    }
    public func bridgeDidReceiveLocale(language: String) {}

    public func bridgeDidPrepareWindowDrag() {
        isUsingNativeWindowDrag = false
        windowDragStartOrigin = nil
        windowDragStartMouseLocation = nil

        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown else {
            windowDragMouseDownEvent = nil
            return
        }
        windowDragMouseDownEvent = event
    }

    public func bridgeDidStartWindowDrag() {
        guard let window else { return }
        if let mouseDownEvent = windowDragMouseDownEvent {
            windowDragMouseDownEvent = nil
            isUsingNativeWindowDrag = true
            window.performDrag(with: mouseDownEvent)
            webView?.evaluateJavaScript("window.__DSH_NATIVE_WINDOW_DRAG_CLEANUP__?.()", completionHandler: nil)
            return
        }

        windowDragStartOrigin = window.frame.origin
        windowDragStartMouseLocation = NSEvent.mouseLocation
    }

    public func bridgeDidMoveWindowDrag() {
        guard !isUsingNativeWindowDrag else { return }
        guard let window,
              let startOrigin = windowDragStartOrigin,
              let startMouseLocation = windowDragStartMouseLocation else { return }
        let currentMouseLocation = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: startOrigin.x + currentMouseLocation.x - startMouseLocation.x,
            y: startOrigin.y + currentMouseLocation.y - startMouseLocation.y
        ))
    }

    public func bridgeDidEndWindowDrag() {
        windowDragMouseDownEvent = nil
        isUsingNativeWindowDrag = false
        windowDragStartOrigin = nil
        windowDragStartMouseLocation = nil
    }

    public func bridgeDidDoubleClickWindowTitlebar() {
        bridgeDidEndWindowDrag()
        guard let window else { return }

        let globalDefaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let configuredAction = (globalDefaults?["AppleActionOnDoubleClick"] as? String)?.lowercased()
        let legacyMiniaturize = (globalDefaults?["AppleMiniaturizeOnDoubleClick"] as? NSNumber)?.boolValue ?? false

        if configuredAction == "none" {
            return
        }
        if configuredAction == "minimize" || (configuredAction == nil && legacyMiniaturize) {
            window.performMiniaturize(nil)
        } else {
            // AppKit toggles between the standard zoomed frame and the
            // previous frame, restoring the user's former centered position.
            window.performZoom(nil)
        }
    }
}

// MARK: - Onboarding View Model & View

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var statusText = "首次启动，正在准备 DSH 运行时..."
    @Published var detailText = ""
    @Published var isInstalling = false
    @Published var selectedRegistry = DshStateManager.shared.current.npmRegistry ?? DshVersionManager.defaultRegistry
    @Published var errorMessage: String?

    func startInitialInstall(onFinished: @escaping () -> Void) {
        isInstalling = true
        errorMessage = nil
        let registry = selectedRegistry
        DshStateManager.shared.update { $0.npmRegistry = registry }

        Task { [self] in
            do {
                let catalog = try await DshVersionManager.shared.fetchCatalog(registry: registry)
                guard let latest = catalog.latest ?? catalog.versions.first?.version else {
                    throw NSError(domain: "Onboarding", code: -1, userInfo: [NSLocalizedDescriptionKey: "未能获取到最新版本号"])
                }

                await MainActor.run {
                    self.statusText = "正在下载 DSH \(latest)..."
                }

                _ = try await DshVersionManager.shared.installVersion(version: latest, registry: registry) { progress in
                    Task { @MainActor in
                        self.statusText = progress.phase
                        self.detailText = progress.detail ?? ""
                    }
                }

                await MainActor.run {
                    onFinished()
                }
            } catch {
                await MainActor.run {
                    self.isInstalling = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct OnboardingView: View {
    let onFinished: () -> Void
    @ObservedObject private var vm = OnboardingViewModel()

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "cube.transparent")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundColor(.accentColor)

            VStack(spacing: 8) {
                Text("欢迎使用 DeepSeek Harness")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("正在配置运行环境与下载最新版本的 DSH")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if vm.isInstalling {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(1.2)
                    Text(vm.statusText)
                        .font(.body)
                    if !vm.detailText.isEmpty {
                        Text(vm.detailText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
                .frame(maxWidth: 400)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("下载镜像源：", selection: Binding(
                        get: { vm.selectedRegistry },
                        set: { vm.selectedRegistry = $0 }
                    )) {
                        Text("官方 npm (registry.npmjs.org)").tag(DshVersionManager.defaultRegistry)
                        Text("淘宝镜像 (registry.npmmirror.com)").tag(DshVersionManager.mirrorRegistry)
                    }
                    .pickerStyle(RadioGroupPickerStyle())

                    if let err = vm.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    Button(action: {
                        vm.startInitialInstall(onFinished: onFinished)
                    }) {
                        HStack {
                            Spacer()
                            Text("开始准备并启动")
                                .fontWeight(.medium)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor).opacity(0.8)))
                .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}
