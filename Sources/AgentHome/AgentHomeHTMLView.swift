import AppKit
import SwiftUI
import WebKit

/// GitHub's rendered HTML for a description or comment, sized to its content
/// so it sits in a SwiftUI scroll view like any other text. Links don't
/// navigate the view; they go to `onLink`.
///
/// Each block is its own web view, so a long timeline lists them lazily; a
/// block coming back on screen starts at the height it last measured, not a
/// one-line placeholder, so scrolling doesn't jump.
struct AgentHomeHTMLBlock: View {
    let html: String
    let onLink: (URL) -> Void

    @State private var height: CGFloat

    init(html: String, onLink: @escaping (URL) -> Void) {
        self.html = html
        self.onLink = onLink
        _height = State(initialValue: AgentHomeHTMLHeights.shared.height(for: html) ?? 24)
    }

    var body: some View {
        AgentHomeHTMLView(html: html, height: $height, onLink: onLink)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .onChange(of: height) { _, measured in AgentHomeHTMLHeights.shared.remember(measured, for: html) }
    }
}

/// The last measured height of each HTML block, by its content.
@MainActor
final class AgentHomeHTMLHeights {
    static let shared = AgentHomeHTMLHeights()

    private var heights: [String: CGFloat] = [:]
    private static let limit = 400

    func height(for html: String) -> CGFloat? { heights[html] }

    func remember(_ height: CGFloat, for html: String) {
        if heights.count >= Self.limit, heights[html] == nil { heights.removeAll(keepingCapacity: true) }
        heights[html] = height
    }
}

private struct AgentHomeHTMLView: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat
    let onLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakHandler(context.coordinator), name: "height")
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
                const report = () => window.webkit.messageHandlers.height.postMessage(document.documentElement.scrollHeight);
                new ResizeObserver(report).observe(document.body);
                document.addEventListener('toggle', report, true);
                window.addEventListener('load', report);
                report();
                """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let webView = PassThroughScrollWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsLinkPreview = false
        Self.applyAppearance(context.environment.colorScheme, to: webView)
        context.coordinator.load(html, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        Self.applyAppearance(context.environment.colorScheme, to: webView)
        context.coordinator.load(html, in: webView)
    }

    /// The page's `prefers-color-scheme` follows the web view's appearance, not
    /// SwiftUI's colour scheme, so pin it to the scheme the page around it uses.
    private static func applyAppearance(_ colorScheme: ColorScheme, to webView: WKWebView) {
        let name: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if webView.appearance?.name != name { webView.appearance = NSAppearance(named: name) }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "height")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: AgentHomeHTMLView
        private var loadedHTML: String?

        init(_ parent: AgentHomeHTMLView) { self.parent = parent }

        func load(_ html: String, in webView: WKWebView) {
            guard html != loadedHTML else { return }
            loadedHTML = html
            webView.loadHTMLString(Self.page(html), baseURL: URL(string: "https://github.com/"))
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? NSNumber else { return }
            let height = max(CGFloat(value.doubleValue), 16)
            if abs(height - parent.height) > 0.5 { parent.height = height }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                decisionHandler(.cancel)
                // In-page anchors (footnotes) stay put.
                if url.fragment != nil, url.absoluteString.hasPrefix("https://github.com/#") { return }
                parent.onLink(url)
                return
            }
            decisionHandler(.allow)
        }

        // target=_blank links.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { parent.onLink(url) }
            return nil
        }

        static func page(_ body: String) -> String {
            """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width">
            <style>
            :root { color-scheme: light dark; --text: #1f2328; --muted: #59636e; --border: rgba(127,127,127,.28); --code: rgba(127,127,127,.14); --link: #0969da; }
            @media (prefers-color-scheme: dark) { :root { --text: #e6e6e6; --muted: #9198a1; --link: #6ea8ff; } }
            html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
            body { font: 13px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; color: var(--text); word-wrap: break-word; }
            body > :first-child { margin-top: 0 !important; } body > :last-child { margin-bottom: 0 !important; }
            a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
            p, ul, ol, blockquote, pre, table, details { margin: 0 0 10px; }
            h1, h2, h3, h4 { margin: 16px 0 8px; line-height: 1.3; } h1 { font-size: 1.45em; } h2 { font-size: 1.25em; } h3 { font-size: 1.08em; }
            code, tt { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code); padding: .12em .35em; border-radius: 5px; }
            pre { background: var(--code); padding: 10px 12px; border-radius: 8px; overflow-x: auto; }
            pre code { background: none; padding: 0; }
            blockquote { color: var(--muted); border-left: 3px solid var(--border); padding: 0 10px; margin-left: 0; }
            table { border-collapse: collapse; display: block; overflow-x: auto; }
            th, td { border: 1px solid var(--border); padding: 4px 9px; }
            img { max-width: 100%; height: auto; border-radius: 4px; }
            summary { cursor: pointer; }
            hr { border: 0; border-top: 1px solid var(--border); }
            .markdown-alert { border-left: 3px solid var(--link); padding: 2px 10px; margin: 0 0 10px; }
            .markdown-alert-title { font-weight: 600; }
            .markdown-alert-important { border-color: #8250df; } .markdown-alert-warning { border-color: #d29922; } .markdown-alert-caution { border-color: #cf222e; }
            .task-list-item { list-style: none; } .task-list-item input { margin: 0 .3em 0 -1.3em; }
            svg.octicon { display: none; }
            .email-hidden-toggle, .email-hidden-reply { display: none; }
            </style></head><body>\(body)</body></html>
            """
        }
    }
}

/// Lets scroll-wheel events reach the SwiftUI scroll view around it; the
/// page is sized to its content, so it never scrolls itself.
private final class PassThroughScrollWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
