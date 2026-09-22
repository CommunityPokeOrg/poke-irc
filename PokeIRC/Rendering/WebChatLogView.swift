import SwiftUI
import WebKit

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// The sandboxed WebKit chat renderer. Runs a fully self-contained page
/// (all CSS/JS inline, CSP `default-src 'none'`), receives messages via
/// `PokeIRC.enqueue(json)` and reports user intents back through the
/// `pokeIRC` script-message handler.
struct WebChatLogView: PlatformViewRepresentable {
    let theme: ResolvedTheme
    let messages: [ChatMessage]
    var onLink: (URL) -> Void = { _ in }
    var onNickTap: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeView(context: context) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, context: context) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeView(context: context) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, context: context) }
    #endif

    private func makeView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // JavaScript stays on (themes need it) but the page cannot reach
        // the network — enforced by the CSP in the generated HTML plus a
        // navigation delegate that denies everything.
        config.userContentController.add(context.coordinator, name: "pokeIRC")
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")  // let theme paint
        #else
        webView.isOpaque = false
        webView.scrollView.backgroundColor = .clear
        #endif
        context.coordinator.attach(webView)
        return webView
    }

    private func update(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.push(messages)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: WebChatLogView
        private weak var webView: WKWebView?
        private var loadedThemeID: String?
        private var pageReady = false
        private var delivered = 0   // count of messages already pushed

        init(_ parent: WebChatLogView) { self.parent = parent }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            loadIfNeeded()
        }

        private func loadIfNeeded() {
            guard let webView, loadedThemeID != parent.theme.manifest.id else { return }
            loadedThemeID = parent.theme.manifest.id
            pageReady = false
            delivered = 0
            webView.loadHTMLString(ThemeEngine.pageHTML(theme: parent.theme),
                                   baseURL: nil)
        }

        func push(_ messages: [ChatMessage]) {
            loadIfNeeded()
            guard pageReady, delivered <= messages.count else { return }
            let fresh = messages.dropFirst(delivered)
            guard !fresh.isEmpty else { return }
            delivered = messages.count
            guard let data = try? JSONSerialization.data(
                    withJSONObject: fresh.map(\.jsonPayload)),
                  let json = String(data: data, encoding: .utf8)
            else { return }
            webView?.evaluateJavaScript("PokeIRC.enqueue(\(json))") { _, _ in }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "pokeIRC",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                pageReady = true
                delivered = 0           // replay everything into the fresh page
                push(parent.messages)
            case "link":
                if let raw = body["url"] as? String,
                   let url = URL(string: raw),
                   url.scheme == "http" || url.scheme == "https" {
                    parent.onLink(url)
                }
            case "nick":
                if let nick = body["nick"] as? String { parent.onNickTap(nick) }
            default:
                break
            }
        }

        // MARK: WKNavigationDelegate — deny all navigation.

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!,
                     withError _: any Error) {
            pageReady = false
        }
    }
}
