import AppKit
import Darwin
import WebKit

/// A small, real AppKit/WKWebView process used by F07. It deliberately loads
/// only caller-supplied localhost fixture URLs. The native recovery surface is
/// representative of the product boundary: a failed navigation must leave a
/// usable AppKit surface instead of relying on a page that did not load.
final class F07WKWebViewDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private struct Step {
        let name: String
        let url: URL
        let expectedProfile: String?
        let expectsFailure: Bool
    }

    private let steps: [Step]
    private var stepIndex = 0
    private var webView: WKWebView!
    private var mainWindow: NSWindow?
    private var recoveryWindow: NSWindow?
    private var stepTimeout: DispatchWorkItem?
    private var didFinish = false

    init(arguments: [String]) {
        guard arguments.count == 4,
              let desktopURL = URL(string: arguments[0]),
              let webURL = URL(string: arguments[1]),
              let chatTextURL = URL(string: arguments[2]),
              let failureURL = URL(string: arguments[3]) else {
            fputs("F07 WKWebView harness requires desktop, web, chat-text, and failure URLs\n", stderr)
            exit(64)
        }
        steps = [
            Step(name: "desktop", url: desktopURL, expectedProfile: "desktop", expectsFailure: false),
            Step(name: "web", url: webURL, expectedProfile: "web", expectsFailure: false),
            Step(name: "chat-text", url: chatTextURL, expectedProfile: "desktop", expectsFailure: false),
            Step(name: "frontend-failure", url: failureURL, expectedProfile: nil, expectsFailure: true),
        ]
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 500),
            configuration: configuration
        )
        webView.navigationDelegate = self

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "F07 WKWebView acceptance"
        window.contentView = webView
        window.center()
        window.orderFrontRegardless()
        mainWindow = window

        loadCurrentStep()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !didFinish else { return }
        let step = steps[stepIndex]
        guard !step.expectsFailure else {
            fail("frontend-failure unexpectedly finished as a document")
            return
        }

        evaluateDocument(for: step)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        print("wkwebview did-start url=\(safeURL(webView.url ?? URL(string: "about:blank")!))")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        print("wkwebview did-commit url=\(safeURL(webView.url ?? URL(string: "about:blank")!))")
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(error)
    }

    private func loadCurrentStep() {
        guard !didFinish else { return }
        guard stepIndex < steps.count else {
            pass("swift wkwebview acceptance harness passed")
            return
        }

        let step = steps[stepIndex]
        stepTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            self?.fail("timed out while loading \(step.name)")
        }
        stepTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)

        print("wkwebview loading step=\(step.name) url=\(safeURL(step.url))")
        webView.load(URLRequest(url: step.url))
    }

    private func evaluateDocument(for step: Step) {
        let script = """
        (() => JSON.stringify({
          profile: document.body?.dataset?.profile ?? null,
          ready: document.body?.dataset?.dshReady === 'true',
          text: document.body?.innerText ?? ''
        }))()
        """
        webView.evaluateJavaScript(script) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, !self.didFinish else { return }
                guard error == nil, let json = result as? String,
                      let data = json.data(using: .utf8),
                      let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (document["ready"] as? Bool) == true,
                      document["profile"] as? String == step.expectedProfile else {
                    self.fail("\(step.name) did not expose the expected ready document")
                    return
                }

                if step.name == "chat-text" {
                    let text = (document["text"] as? String) ?? ""
                    guard text.contains("PORT_IN_USE"), text.contains("FRONTEND_LOAD_FAILED") else {
                        self.fail("chat-text fixture did not contain its inert error text")
                        return
                    }
                    print("wkwebview chat-text remained ready despite inert failure words")
                }
                print("wkwebview ready step=\(step.name) profile=\(step.expectedProfile ?? "unknown")")
                self.stepTimeout?.cancel()
                self.stepIndex += 1
                self.loadCurrentStep()
            }
        }
    }

    private func handleNavigationFailure(_ error: Error) {
        guard !didFinish else { return }
        let step = steps[stepIndex]
        guard step.expectsFailure else {
            fail("\(step.name) navigation failed unexpectedly: \(error.localizedDescription)")
            return
        }

        stepTimeout?.cancel()
        showRecoverySurface(error: error)
        print("wkwebview recovery-visible phase=loadingInterface code=pageLoadFailed")
        pass("swift wkwebview acceptance harness passed")
    }

    private func showRecoverySurface(error: Error) {
        mainWindow?.orderOut(nil)

        let title = NSTextField(labelWithString: "无法完成启动")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let phase = NSTextField(labelWithString: "阶段：加载界面")
        let code = NSTextField(labelWithString: "错误码：pageLoadFailed")
        let detail = NSTextField(labelWithString: "页面加载失败：\(error.localizedDescription)")
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        let retry = NSButton(title: "重试", target: nil, action: nil)
        let settings = NSButton(title: "打开设置", target: nil, action: nil)
        let safeMode = NSButton(title: "安全模式", target: nil, action: nil)
        for button in [retry, settings, safeMode] {
            button.bezelStyle = .rounded
            button.isEnabled = false
        }

        let buttons = NSStackView(views: [retry, settings, safeMode])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let stack = NSStackView(views: [title, phase, code, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 30, bottom: 30, right: 30)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "DSH 恢复"
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        recoveryWindow = window
    }

    private func pass(_ message: String) {
        guard !didFinish else { return }
        didFinish = true
        stepTimeout?.cancel()
        print(message)
        NSApp.stop(nil)
    }

    private func fail(_ message: String) {
        guard !didFinish else { return }
        didFinish = true
        stepTimeout?.cancel()
        fputs("F07 WKWebView harness failed: \(message)\n", stderr)
        NSApp.stop(nil)
        exit(1)
    }

    private func safeURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<invalid>"
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? "<invalid>"
    }
}

@main
struct F07WKWebViewAcceptanceMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = F07WKWebViewDelegate(arguments: arguments)
        app.delegate = delegate
        app.run()
    }
}
