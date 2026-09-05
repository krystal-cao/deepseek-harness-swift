import AppKit
import Darwin
import Foundation
import WebKit

// The production bridge handler deliberately references only these small
// native collaborators for the actions exercised by the product source. Keep
// the real handler and validator in this harness while stubbing unrelated UI
// services so the acceptance process remains isolated from the user's app.
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    func show() {}
}

final class NotificationManager {
    static let shared = NotificationManager()
    func showTaskDoneNotification(title: String?, cwd: String?) {}
}

final class MainWindowController {
    static let shared = MainWindowController()
    var isFocusedForNotifications = true
}

private final class RealBridgeDelegate: NSObject, DshBridgeDelegate {
    private(set) var readyCount = 0

    func bridgeDidReceiveReady() {
        readyCount += 1
        print("real B01 ready callback count=\(readyCount)")
    }

    func bridgeDidReceiveTheme(colorScheme: String?, externalTheme: String?) {}
    func bridgeDidReceiveLocale(language: String) {}
    func bridgeDidPrepareWindowDrag() {}
    func bridgeDidStartWindowDrag() {}
    func bridgeDidMoveWindowDrag() {}
    func bridgeDidEndWindowDrag() {}
    func bridgeDidDoubleClickWindowTitlebar() {}
}

private final class RealBridgeAcceptanceDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private let pageURL: URL
    private let launchID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    private let generationID = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
    private let oldGenerationID = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
    private let handler = DshBridgeHandler()
    private let bridgeDelegate = RealBridgeDelegate()
    private var primaryWebView: WKWebView!
    private var secondaryWebView: WKWebView!
    private var primaryWindow: NSWindow?
    private var secondaryWindow: NSWindow?
    private var timeoutWork: DispatchWorkItem?
    private var didFinish = false
    private var didStart = false
    private var primaryEvaluated = false
    private var secondaryEvaluated = false

    init(arguments: [String]) {
        guard arguments.count == 1, let pageURL = URL(string: arguments[0]) else {
            fputs("real B01 bridge harness requires one fixture URL\n", stderr)
            exit(64)
        }
        self.pageURL = pageURL
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        handler.delegate = bridgeDelegate
        primaryWebView = makeWebView()
        primaryWindow = makeWindow(content: primaryWebView, title: "B01 primary")
        primaryWindow?.orderFrontRegardless()

        guard let origin = DshBridgeOrigin(url: pageURL) else {
            fail("fixture URL did not provide a valid bridge origin")
            return
        }
        handler.updateValidationContext(DshBridgeValidationContext(
            webViewIdentity: DshBridgeWebViewIdentity(object: primaryWebView),
            launchID: launchID,
            generationID: generationID,
            origin: origin
        ))
        armTimeout()
        primaryWebView.load(URLRequest(url: pageURL))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // didFinish waits for every subframe and is not a reliable boundary
        // for this fixture. didCommit drives the test; retain this callback
        // only as a harmless fallback for WebKit versions that omit commit.
        handleNavigationBoundary(for: webView)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        fputs("real B01 did-start url=\(webView.url?.absoluteString ?? "<nil>")\n", stderr)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        fputs("real B01 did-commit url=\(webView.url?.absoluteString ?? "<nil>")\n", stderr)
        handleNavigationBoundary(for: webView)
    }

    private func handleNavigationBoundary(for webView: WKWebView) {
        guard !didFinish else { return }
        if webView === primaryWebView, !primaryEvaluated {
            primaryEvaluated = true
            evaluatePrimarySequence()
        } else if webView === secondaryWebView, !secondaryEvaluated {
            secondaryEvaluated = true
            secondaryWebView.evaluateJavaScript(
                "window.dshDesktop.ready();",
                completionHandler: { [weak self] _, error in
                    DispatchQueue.main.async {
                        guard let self, !self.didFinish else { return }
                        guard error == nil else {
                            self.fail("secondary WebView could not send ready: \(error!.localizedDescription)")
                            return
                        }
                        // The primary main-frame message is the only accepted
                        // action. The iframe, old generation and secondary
                        // WebView messages must all be rejected.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            self.assertResultsAndFinish()
                        }
                    }
                }
            )
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        fail("fixture navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("fixture navigation failed: \(error.localizedDescription)")
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let userContentController = configuration.userContentController
        userContentController.addUserScript(WKUserScript(
            source: DshBridgeHandler.scriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        userContentController.add(handler, name: DshBridgeMessageValidator.handlerName)
        let view = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 500),
            configuration: configuration
        )
        view.navigationDelegate = self
        return view
    }

    private func makeWindow(content: NSView, title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = content
        window.center()
        return window
    }

    private func evaluatePrimarySequence() {
        let oldLaunch = launchID.uuidString
        let oldGeneration = oldGenerationID.uuidString
        let script = """
        (() => {
          window.dshDesktop.ready();
          setTimeout(() => {
            window.webkit.messageHandlers.dshDesktop.postMessage({
              type: 'ready',
              launchID: '\(oldLaunch)',
              generationID: '\(oldGeneration)'
            });
          }, 600);
          return true;
        })()
        """
        primaryWebView.evaluateJavaScript(script) { [weak self] _, error in
            guard let self, !self.didFinish else { return }
            if let error {
                self.fail("primary WebView could not send bridge sequence: \(error.localizedDescription)")
                return
            }
            // Give the iframe and old-generation callbacks time to reach the
            // native handler before introducing the mismatched WebView.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                guard !self.didFinish else { return }
                fputs("real B01 before secondary WebView\n", stderr)
                self.secondaryWebView = self.makeWebView()
                fputs("real B01 after secondary WebView\n", stderr)
                self.secondaryWindow = self.makeWindow(content: self.secondaryWebView, title: "B01 secondary")
                fputs("real B01 after secondary window\n", stderr)
                self.secondaryWebView.load(URLRequest(url: self.pageURL))
                fputs("real B01 after secondary load\n", stderr)
            }
        }
    }

    private func assertResultsAndFinish() {
        let accepted = bridgeDelegate.readyCount
        guard accepted == 1 else {
            fail("expected one accepted main-frame/current-WebView/current-generation message, got \(accepted)")
            return
        }
        print("real B01 rejected iframe=1 old-generation=1 wrong-webview=1")
        pass("swift real bridge acceptance harness passed")
    }

    private func armTimeout() {
        // A WebKit navigation can fail to deliver a delegate callback while
        // its content process is unavailable. Keep the watchdog independent
        // of AppKit's main queue so the acceptance test fails with evidence
        // instead of letting Node kill the child with exit code null.
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.didFinish else { return }
            fputs("real B01 watchdog: no navigation completion callback\n", stderr)
            exit(1)
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.fail("timed out waiting for real bridge messages")
        }
        timeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    private func pass(_ message: String) {
        guard !didFinish else { return }
        didFinish = true
        timeoutWork?.cancel()
        print(message)
        fflush(stdout)
        exit(0)
    }

    private func fail(_ message: String) {
        guard !didFinish else { return }
        didFinish = true
        timeoutWork?.cancel()
        fputs("real B01 bridge harness failed: \(message)\n", stderr)
        NSApp.stop(nil)
        exit(1)
    }
}

@main
struct RealBridgeAcceptanceMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = RealBridgeAcceptanceDelegate(arguments: arguments)
        app.delegate = delegate
        // A command-line AppKit executable is not registered as an app bundle.
        // Finish launch explicitly so applicationDidFinishLaunching and the
        // harness timeout are armed deterministically even when another DSH
        // instance is already active in the desktop session.
        app.finishLaunching()
        delegate.start()
        app.run()
    }
}
