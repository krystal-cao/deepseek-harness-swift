import AppKit
import WebKit

/// The native shell around the DSH Web UI.
///
/// DSH continues to own the page, sessions, plugins and message rendering.
/// This layer owns only the macOS window chrome, WebKit policies and the
/// small bridge used for native window integration.
@MainActor
public final class DshWebShell {
    public let rootView: NSVisualEffectView
    public let webView: WKWebView

    private let bridgeHandler: DshBridgeHandler

#if DEBUG
    private static let developerToolsEnabledByDefault = true
#else
    private static let developerToolsEnabledByDefault = false
#endif

    private static let shellCSS = """
    :root {
      --dsh-shell-traffic-light-safe-height: 20px;
      --dsh-shell-sidebar-width: 88px;
    }
    [class*="sidebarCol"] {
      padding-top: var(--dsh-shell-traffic-light-safe-height) !important;
      min-width: var(--dsh-shell-sidebar-width) !important;
      background: color-mix(in srgb, var(--dsw-specific-sidebar-fill) 70%, transparent) !important;
    }
    [data-sidebar-collapsed] {
      grid-template-columns: var(--dsh-shell-sidebar-width) minmax(0px, 1fr) 0px !important;
    }
    html, body { background: transparent !important; }
    [class*="frame"] {
      background: transparent !important;
    }
    [class*="frame"]:has(> [class*="sidebarCol"]) {
      padding-top: 0 !important;
    }
    [class*="centerCol"], [class*="detailsCol"] {
      background: var(--dsw-alias-bg-base) !important;
      box-sizing: border-box !important;
    }
    [class*="centerCol"] {
      padding-top: 0 !important;
    }
    [class*="detailsCol"] {
      padding-top: 20px !important;
    }
    [class*="sidebarCol"] [class*="logoRow"] {
      position: relative !important;
      top: 6px !important;
    }
    [class*="sidebarCol"] [class*="_root"],
    [class*="sidebarCol"] [class*="listArea"] { background: transparent !important; }
    [class*="sidebarCol"] [class*="footArea"],
    [class*="sidebarCol"] [class*="footerActions"],
    [class*="sidebarCol"] [class*="settingsArea"],
    [class*="sidebarCol"] [class*="fade"] { background: transparent !important; }
    [class*="railIn"] [class*="iconButton"],
    [class*="railIn"] [class*="newSession"],
    [class*="railIn"] [class*="searchButton"],
    [class*="railIn"] [class*="headerActions"],
    [class*="railIn"] [class*="search"] {
      margin-left: auto !important;
      margin-right: auto !important;
    }
    html.dsh-native-window-drag,
    html.dsh-native-window-drag * {
      cursor: default !important;
      -webkit-user-select: none !important;
      user-select: none !important;
    }
    .dsh-native-window-drag-hover,
    .dsh-native-window-drag-hover * {
      cursor: default !important;
    }
    """

    private static let loadingCSS = """
    #dsh-plugin-loading-overlay, [class*="pluginLoading"] {
      display: none !important;
    }
    """

    /// Disable browser-style menus on non-interactive page chrome while
    /// retaining useful editing, link and selected-text menus.
    private static let contextMenuScript = """
    (() => {
      if (window.__DSH_CONTEXT_MENU_POLICY_INSTALLED__) return;
      window.__DSH_CONTEXT_MENU_POLICY_INSTALLED__ = true;
      const interactiveSelector = [
        'a[href]', 'button', 'input', 'select', 'textarea', 'summary',
        '[role="button"]', '[role="menuitem"]', '[role="tab"]',
        '[role="switch"]',
        '[contenteditable]:not([contenteditable="false"])',
        '[data-dsh-context-menu="allow"]'
      ].join(',');
      document.addEventListener('contextmenu', (event) => {
        const target = event.target instanceof Element ? event.target : null;
        const selection = window.getSelection?.()?.toString() ?? '';
        if (target?.closest(interactiveSelector) || selection.length > 0) return;
        event.preventDefault();
        event.stopImmediatePropagation();
      }, true);
    })();
    """

    /// Keep WebKit in charge of titlebar hit testing. A drag starts only
    /// after the pointer moves beyond a small threshold on non-interactive
    /// titlebar content, so buttons and links remain clickable.
    private static let windowDragScript = """
    (() => {
      if (window.__DSH_NATIVE_WINDOW_DRAG_INSTALLED__) return;
      window.__DSH_NATIVE_WINDOW_DRAG_INSTALLED__ = true;
      const titlebarHeight = 52;
      const dragThreshold = 4;
      const interactiveSelector = [
        'a[href]', 'button', 'input', 'select', 'textarea', 'summary',
        '[role="button"]', '[role="tab"]', '[role="menuitem"]',
        '[role="switch"]',
        '[contenteditable]:not([contenteditable="false"])',
        '[tabindex]:not([tabindex="-1"])'
      ].join(',');
      let candidate = null;
      let dragging = false;
      let suppressClick = false;
      let suppressTitlebarSelection = false;
      let hoverElement = null;
      const post = (type) => {
        window.webkit?.messageHandlers?.dshDesktop?.postMessage({ type });
      };
      const isInteractive = (target) => {
        if (!(target instanceof Element)) return false;
        if (target.closest(interactiveSelector)) return true;
        let current = target;
        while (current && current !== document.documentElement) {
          const cursor = window.getComputedStyle(current).cursor;
          if (cursor && cursor !== 'auto' && cursor !== 'default') return true;
          current = current.parentElement;
        }
        return false;
      };
      const isTextEditingTarget = (target) => {
        if (!(target instanceof Element)) return false;
        return Boolean(target.closest('input, textarea, [contenteditable]:not([contenteditable="false"])'));
      };
      const setDragSurfaceActive = (active) => {
        document.documentElement.classList.toggle('dsh-native-window-drag', active);
      };
      const clearHoverElement = () => {
        hoverElement?.classList.remove('dsh-native-window-drag-hover');
        hoverElement = null;
      };
      const updateTitlebarHover = (event) => {
        clearHoverElement();
        if (candidate || event.clientY > titlebarHeight || isInteractive(event.target)) return;
        if (!(event.target instanceof Element)) return;
        hoverElement = event.target;
        hoverElement.classList.add('dsh-native-window-drag-hover');
      };
      const reset = () => {
        candidate = null;
        dragging = false;
        setDragSurfaceActive(false);
      };
      window.__DSH_NATIVE_WINDOW_DRAG_CLEANUP__ = reset;
      document.addEventListener('mousedown', (event) => {
        suppressClick = false;
        clearHoverElement();
        suppressTitlebarSelection = event.clientY <= titlebarHeight && !isTextEditingTarget(event.target);
        setDragSurfaceActive(false);
        if (event.button !== 0 || event.clientY > titlebarHeight || isInteractive(event.target)) {
          candidate = null;
          return;
        }
        event.preventDefault();
        candidate = { x: event.screenX, y: event.screenY };
        setDragSurfaceActive(true);
        post('windowDragPrepare');
      }, { capture: true, passive: false });
      document.addEventListener('mousemove', (event) => {
        updateTitlebarHover(event);
        if (!candidate) return;
        if (!dragging) {
          const distance = Math.hypot(event.screenX - candidate.x, event.screenY - candidate.y);
          if (distance < dragThreshold) return;
          dragging = true;
          suppressClick = true;
          post('windowDragStart');
        }
        event.preventDefault();
        event.stopImmediatePropagation();
        post('windowDragMove');
      }, { capture: true, passive: false });
      document.addEventListener('mouseup', (event) => {
        suppressTitlebarSelection = false;
        if (!candidate) return;
        if (dragging) {
          event.preventDefault();
          event.stopImmediatePropagation();
          post('windowDragEnd');
        }
        reset();
        updateTitlebarHover(event);
      }, { capture: true, passive: false });
      document.addEventListener('click', (event) => {
        if (!suppressClick) return;
        suppressClick = false;
        event.preventDefault();
        event.stopImmediatePropagation();
      }, true);
      document.addEventListener('selectstart', (event) => {
        if (suppressTitlebarSelection) event.preventDefault();
      }, { capture: true, passive: false });
      document.addEventListener('dblclick', (event) => {
        clearHoverElement();
        if (event.button !== 0 || event.clientY > titlebarHeight || isInteractive(event.target)) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        window.getSelection?.()?.removeAllRanges();
        post('windowTitlebarDoubleClick');
      }, true);
      window.addEventListener('blur', () => {
        if (dragging) post('windowDragEnd');
        suppressClick = false;
        suppressTitlebarSelection = false;
        clearHoverElement();
        reset();
      });
      document.addEventListener('mouseleave', clearHoverElement, true);
    })();
    """

    public static let webUIReadinessScript = """
    (() => {
      const body = document.body;
      const text = body && typeof body.textContent === 'string' ? body.textContent.trim() : '';
      const hasAppShell = Boolean(document.querySelector('[class*="sidebarCol"], [class*="railIn"], [class*="centerCol"]'));
      const authenticationRequired = /dsh web authentication required|上游认证|required.*authentication/i.test(text);
      return {
        loading: text.includes('Loading plugins') || text.includes('加载插件'),
        length: text.length,
        hasAppShell,
        authenticationRequired
      };
    })();
    """

    /// Probe the same Remote stream carrier used by the DSH frontend. The
    /// script runs inside the page so WebKit, rather than a native URLSession,
    /// decides which HttpOnly cookies are attached to the handshake.
    public static let webUIConnectionProbeScript = """
    const target = new URL('/api/remote.mux', window.location.href);
    target.protocol = target.protocol === 'https:' ? 'wss:' : 'ws:';
    const timeoutMs = 5000;
    return await new Promise((resolve) => {
      let socket;
      let settled = false;
      const finish = (ok, reason) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (socket && socket.readyState === WebSocket.OPEN) {
          socket.close(1000, 'health-check');
        }
        resolve({ ok, reason: reason || '' });
      };
      const timer = setTimeout(() => finish(false, 'timeout'), timeoutMs);
      try {
        socket = new WebSocket(target.toString());
        socket.addEventListener('open', () => finish(true, 'open'), { once: true });
        socket.addEventListener('error', () => finish(false, 'error'), { once: true });
        socket.addEventListener('close', () => finish(false, 'closed-before-open'), { once: true });
      } catch (_) {
        finish(false, 'construct');
      }
    });
    """

    public init(delegate: DshBridgeDelegate) {
        self.rootView = NSVisualEffectView(frame: .zero)
        self.bridgeHandler = DshBridgeHandler()

        let config = WKWebViewConfiguration()
        config.preferences.setValue(Self.developerToolsEnabledByDefault, forKey: "developerExtrasEnabled")

        let userContent = WKUserContentController()
        self.bridgeHandler.delegate = delegate
        userContent.add(self.bridgeHandler, name: "dshDesktop")
        userContent.addUserScript(WKUserScript(
            source: DshBridgeHandler.scriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        userContent.addUserScript(WKUserScript(
            source: Self.windowDragScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let styleScript = """
        (() => {
          const style = document.createElement('style');
          style.id = 'dsh-shell-styles';
          style.textContent = `\(Self.shellCSS)\n\(Self.loadingCSS)`;
          (document.head || document.documentElement).appendChild(style);
        })();
        """
        userContent.addUserScript(WKUserScript(
            source: styleScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        userContent.addUserScript(WKUserScript(
            source: Self.contextMenuScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        config.userContentController = userContent

        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.autoresizingMask = [.width, .height]
        self.webView.setValue(false, forKey: "drawsBackground")
#if DEBUG
        if #available(macOS 13.3, *) {
            self.webView.isInspectable = Self.developerToolsEnabledByDefault
        }
#endif
        configureRootView()
    }

    public func syncTheme(_ theme: String) {
        let serialized = theme == "claude" ? "\"claude\"" : "\"default\""
        evaluate("""
        (() => {
          const theme = \(serialized);
          window.__DSH_DESKTOP_UI_THEME__ = theme;
          window.dispatchEvent(new CustomEvent('dsh-desktop-ui-theme-change', { detail: { theme } }));
        })();
        """)
    }

    public func syncTranslateCommands(enabled: Bool) {
        evaluate("""
        (() => {
          const enabled = \(enabled ? "true" : "false");
          window.__DSH_DESKTOP_TRANSLATE_COMMANDS__ = enabled;
          window.dispatchEvent(new CustomEvent('dsh-desktop-translate-commands-change', { detail: { enabled } }));
        })();
        """)
    }

    public func enableDeveloperTools() {
#if DEBUG
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        if #available(macOS 13.3, *) { webView.isInspectable = true }
#endif
    }

    public func closeDeveloperTools() {
        webView.configuration.preferences.setValue(false, forKey: "developerExtrasEnabled")
        if #available(macOS 13.3, *) { webView.isInspectable = false }
    }

    private func configureRootView() {
        rootView.material = .sidebar
        rootView.blendingMode = .behindWindow
        rootView.state = .followsWindowActiveState
        rootView.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: rootView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])
    }

    private func evaluate(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}
