import AppKit
import SwiftUI
import WebKit

/// A real WebKit auxiliary window: keeps window.opener, POST requests and the
/// supplied website data store intact. No credentials or tokens pass through Rust.
@MainActor final class BrowserPopup: NSObject, ObservableObject, NSWindowDelegate {
    let id = UUID()
    weak var opener: PageDelegate?
    let window: NSWindow
    let webView: WKWebView
    let page: PageDelegate
    @Published private(set) var origin = "Opening…"
    private var observations: [NSKeyValueObservation] = []
    private var closed = false

    init(opener: PageDelegate, configuration: WKWebViewConfiguration, features: WKWindowFeatures, initialURL: URL?) {
        self.opener = opener
        let width = min(max(features.width?.doubleValue ?? 520, 360), 1000)
        let height = min(max(features.height?.doubleValue ?? 680, 400), 900)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height - 46), configuration: configuration)
        webView.customUserAgent = opener.webView?.customUserAgent
        webView.isInspectable = true
        page = PageDelegate(window: opener.window, id: opener.id, generation: opener.generation,
                            webView: webView, uiDelegate: opener.ui)
        page.adPreferences = opener.adPreferences
        // The supplied content controller already contains the opener's filters.
        page.installedAdRules = opener.installedAdRules
        super.init()
        page.popup = self
        webView.navigationDelegate = page
        webView.uiDelegate = page
        let root = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        page.container.frame = webView.frame
        page.container.autoresizingMask = [.width, .height]
        root.addSubview(page.container)
        page.container.addSubview(webView)
        webView.frame = page.container.bounds
        webView.autoresizingMask = [.width, .height]
        let address = NSHostingView(rootView: PopupOriginView(popup: self))
        address.frame = CGRect(x: 0, y: height - 46, width: width, height: 46)
        address.autoresizingMask = [.width, .minYMargin]
        root.addSubview(address)
        window.contentView = root
        window.delegate = self
        window.center()
        updateOrigin(initialURL)
        observations = [webView.observe(\.url, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.updateOrigin(view.url) }
        }]
    }
    private func updateOrigin(_ url: URL?) {
        origin = url.flatMap(BrowserFeatures.origin) ?? (url?.scheme == "about" ? "about:blank" : "Opening…")
        // The site cannot replace the browser's displayed origin with its page title.
        window.title = origin + " — Moth"
    }
    func showError(_ message: String) {
        guard !closed else { return }
        let alert = NSAlert(); alert.messageText = "Page could not load"; alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
    func close() { window.close() }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        page.closePopups()
        webView.stopLoading()
        observations.removeAll()
        // Notify WebKit as well as AppKit so the opener sees child.closed.
        // An isolated world uses the browser's close function even if the page
        // replaces window.close. Keep the view alive until WebKit processes it.
        webView.evaluateJavaScript("window.close()", in: nil, in: .defaultClient) { [self] _ in
            webView.navigationDelegate = nil; webView.uiDelegate = nil
        }
        window.contentView = nil
        page.container.removeFromSuperview()
        webView.removeFromSuperview()
        opener?.popups.removeValue(forKey: id)
    }
}

@MainActor private struct PopupOriginView: View {
    @ObservedObject var popup: BrowserPopup
    var body: some View {
        Text(popup.origin).font(.callout).lineLimit(1).truncationMode(.middle)
            .textSelection(.enabled).accessibilityLabel("Website origin").help(popup.origin)
            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 30)
            .glassEffect(.regular, in: Capsule()).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
