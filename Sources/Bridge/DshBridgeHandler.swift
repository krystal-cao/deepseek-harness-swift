import Foundation
import WebKit
import AppKit

public protocol DshBridgeDelegate: AnyObject {
    func bridgeDidReceiveReady()
    func bridgeDidReceiveTheme(colorScheme: String?, externalTheme: String?)
    func bridgeDidReceiveLocale(language: String)
    func bridgeDidPrepareWindowDrag()
    func bridgeDidStartWindowDrag()
    func bridgeDidMoveWindowDrag()
    func bridgeDidEndWindowDrag()
    func bridgeDidDoubleClickWindowTitlebar()
}

public final class DshBridgeHandler: NSObject, WKScriptMessageHandler {
    public weak var delegate: DshBridgeDelegate?

    private let contextLock = NSLock()
    private var validationContext: DshBridgeValidationContext?
    private let validator = DshBridgeMessageValidator()

    /// Bind one WebKit view to one launch and process generation. A nil
    /// context disables every bridge action until the next authenticated
    /// service session is ready.
    public func updateValidationContext(_ context: DshBridgeValidationContext?) {
        contextLock.lock()
        validationContext = context
        contextLock.unlock()
    }

    private func currentValidationContext() -> DshBridgeValidationContext? {
        contextLock.lock()
        defer { contextLock.unlock() }
        return validationContext
    }

    public static let scriptSource = """
    (function() {
        if (window.dshDesktop) return;
        window.dshDesktop = {
            ready: function() {
                window.webkit.messageHandlers.dshDesktop.postMessage({ type: 'ready' });
            },
            openSettings: function() {
                window.webkit.messageHandlers.dshDesktop.postMessage({ type: 'openSettings' });
            },
            theme: function(snapshot) {
                window.webkit.messageHandlers.dshDesktop.postMessage({ type: 'theme', payload: snapshot });
            },
            locale: function(payload) {
                window.webkit.messageHandlers.dshDesktop.postMessage({ type: 'locale', payload: payload });
            },
            notify: function(payload) {
                window.webkit.messageHandlers.dshDesktop.postMessage({ type: 'notify', payload: payload });
            },
            debug: function(message) {
                window.webkit.messageHandlers.dshDesktop.postMessage({ type: 'debug', payload: message });
            }
        };
    })();
    """

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Take a single context snapshot. The context contains the exact
        // WebView identity, launch/generation IDs, origin and capabilities;
        // none of these may be supplied by page JavaScript.
        guard let context = currentValidationContext() else { return }
        let body = trustedBody(message.body, context: context)
        let origin = DshBridgeOrigin(
            scheme: message.frameInfo.securityOrigin.protocol,
            host: message.frameInfo.securityOrigin.host,
            port: message.frameInfo.securityOrigin.port
        )
        let incoming = DshBridgeIncomingMessage(
            handlerName: message.name,
            isMainFrame: message.frameInfo.isMainFrame,
            webViewIdentity: message.webView.map { DshBridgeWebViewIdentity(object: $0) },
            origin: origin,
            body: body
        )
        guard case .success(let validated) = validator.validate(incoming, context: context) else {
            // Do not echo untrusted bodies or payloads into logs. Rejection is
            // intentionally silent at the WebKit boundary.
            return
        }

        let type = validated.type
        let payload = validated.payload as? [String: Any]

        switch type.rawValue {
        case "ready":
            delegate?.bridgeDidReceiveReady()

        case "openSettings":
            DispatchQueue.main.async {
                SettingsWindowController.shared.show()
            }

        case "theme":
            let colorScheme = payload?["colorScheme"] as? String
            let externalTheme = payload?["externalTheme"] as? String
            delegate?.bridgeDidReceiveTheme(colorScheme: colorScheme, externalTheme: externalTheme)

        case "locale":
            let lang = payload?["language"] as? String ?? "zh"
            delegate?.bridgeDidReceiveLocale(language: lang)

        case "notify":
            let title = payload?["title"] as? String
            let cwd = payload?["cwd"] as? String
            if !MainWindowController.shared.isFocusedForNotifications {
                NotificationManager.shared.showTaskDoneNotification(title: title, cwd: cwd)
            }

        case "windowDragPrepare":
            delegate?.bridgeDidPrepareWindowDrag()

        case "windowDragStart":
            delegate?.bridgeDidStartWindowDrag()

        case "windowDragMove":
            delegate?.bridgeDidMoveWindowDrag()

        case "windowDragEnd":
            delegate?.bridgeDidEndWindowDrag()

        case "windowTitlebarDoubleClick":
            delegate?.bridgeDidDoubleClickWindowTitlebar()

        case "debug":
            if let msg = validated.payload as? String {
                print("[DshBridge:debug]", msg)
            }

        default:
            break
        }
    }

    /// Page JavaScript intentionally sends only an action request. Identity
    /// fields are attached here from the captured native context, while any
    /// page-supplied identity is left intact so the validator rejects it when
    /// it does not match the active launch.
    private func trustedBody(_ body: Any, context: DshBridgeValidationContext) -> Any {
        guard var dictionary = body as? [String: Any] else { return body }
        if dictionary["launchID"] == nil {
            dictionary["launchID"] = context.launchID.uuidString
        }
        if dictionary["generationID"] == nil {
            dictionary["generationID"] = context.generationID.uuidString
        }
        return dictionary
    }
}
