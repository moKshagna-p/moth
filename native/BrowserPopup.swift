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
    @Published private(set) var fitToWindow = false
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
    func requestMerge(workspace: UInt64) {
        guard !closed else { return }
        opener?.model?.send("merge_popup", ["popup": id.uuidString, "workspace": workspace])
    }
    func toggleFitToWindow() {
        fitToWindow.toggle()
        page.fitToWindow = fitToWindow
        page.updatePageZoom()
    }
    /// Transfer ownership without stopping or reloading the document.
    func movePage(to parent: NSView, tabID: UInt64, generation: UInt64) {
        closed = true
        observations.removeAll()
        page.container.removeFromSuperview()
        page.container.autoresizingMask = []
        parent.addSubview(page.container)
        page.id = tabID; page.generation = generation; page.adopted = true
        page.popup = nil
        BrowserFeatures.pages["\(page.window):\(tabID)"] = page
        page.observeAdoptedPage()
        opener?.popups.removeValue(forKey: id)
        window.close()
        window.contentView = nil
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
        HStack(spacing: 8) {
            Text(popup.origin).font(.callout).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled).accessibilityLabel("Website origin").help(popup.origin)
                .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 30)
                .glassEffect(.regular, in: Capsule())
            Button { popup.toggleFitToWindow() } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 14, weight: .medium)).frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(popup.fitToWindow ? .accentColor.opacity(0.2) : .clear).interactive(), in: Circle())
            .help(popup.fitToWindow ? "Turn Off Fit to Window" : "Fit to Window")
            .accessibilityLabel("Fit to Window")
            .accessibilityValue(popup.fitToWindow ? "On" : "Off")
            if let model = popup.opener?.model { PopupWorkspaceMenu(popup: popup, model: model) }
        }
        .padding(.horizontal, 10).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor private struct PopupWorkspaceMenu: View {
    @ObservedObject var popup: BrowserPopup
    @ObservedObject var model: ChromeModel
    var body: some View {
        Menu {
            ForEach(model.snapshot?.workspaces ?? []) { workspace in
                Button { popup.requestMerge(workspace: workspace.id) } label: {
                    if workspace.id == model.snapshot?.active_workspace {
                        Label(workspace.name, systemImage: "checkmark")
                    } else { Text(workspace.name) }
                }
            }
        } label: {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 14, weight: .medium)).frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 30, height: 30)
        .glassEffect(.regular.interactive(), in: Circle())
        .help("Move to Workspace").accessibilityLabel("Move to Workspace")
        .disabled(model.snapshot?.workspaces.isEmpty != false)
    }
}

@_cdecl("moth_popup_merge")
func moth_popup_merge(_ window: UInt64, _ popupID: UnsafePointer<CChar>?, _ tabID: UInt64, _ generation: UInt64) -> Bool {
    guard let popupID, let uuid = UUID(uuidString: String(cString: popupID)) else { return false }
    return MainActor.assumeIsolated {
        guard let parent = ChromeBridge.instances[window]?.parent,
              BrowserFeatures.pages["\(window):\(tabID)"] == nil else { return false }
        @MainActor func find(in page: PageDelegate) -> BrowserPopup? {
            if let popup = page.popups[uuid] { return popup }
            for popup in page.popups.values { if let match = find(in: popup.page) { return match } }
            return nil
        }
        // Only this browser window's auxiliary pages can enter its workspaces.
        for page in Array(BrowserFeatures.pages.values) where page.window == window {
            if let popup = find(in: page) {
                popup.movePage(to: parent, tabID: tabID, generation: generation)
                return true
            }
        }
        return false
    }
}

@_cdecl("moth_page_operation")
func moth_page_operation(_ window: UInt64, _ id: UInt64, _ operation: UnsafePointer<CChar>?, _ argument: UnsafePointer<CChar>?,
                         _ callback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void,
                         _ context: UnsafeMutableRawPointer?) {
    guard let operationPointer = operation, let argumentPointer = argument else { callback(nil, context); return }
    let operation = String(cString: operationPointer), argument = String(cString: argumentPointer)
    MainActor.assumeIsolated {
        guard let page = BrowserFeatures.pages["\(window):\(id)"], page.adopted, let view = page.webView else {
            callback(nil, context); return
        }
        var result = ""
        switch operation {
        case "url": result = view.url?.absoluteString ?? "about:blank"
        case "title": result = view.title ?? ""
        case "loading": result = String(view.isLoading)
        case "zoom_value": result = String(Double(page.requestedZoom))
        case "fit_to_window": result = String(page.fitToWindow)
        case "can_go_back": result = String(view.canGoBack)
        case "can_go_forward": result = String(view.canGoForward)
        case "navigate":
            guard let url = URL(string: argument) else { callback(nil, context); return }
            view.load(URLRequest(url: url))
        case "go_back": view.goBack()
        case "go_forward": view.goForward()
        case "reload": view.reload()
        case "zoom":
            if let zoom = Double(argument), zoom.isFinite, zoom >= 0.25, zoom <= 3 {
                page.requestedZoom = zoom; page.updatePageZoom()
            }
        case "inspect":
            let inspector = view.perform(NSSelectorFromString("_inspector"))?.takeUnretainedValue() as? NSObject
            inspector?.perform(NSSelectorFromString("show"))
        case "print": view.printOperation(with: NSPrintInfo.shared).run()
        case "close":
            page.nativeObservations.removeAll()
            page.closePopups(); view.stopLoading()
            view.navigationDelegate = nil; view.uiDelegate = nil
            // A transferred auxiliary page still has an opener; notify it on real close.
            view.evaluateJavaScript("window.close()", in: nil, in: .defaultClient) { [view] _ in _ = view }
            page.container.removeFromSuperview(); view.removeFromSuperview()
            BrowserFeatures.pages.removeValue(forKey: "\(window):\(id)")
        default: callback(nil, context); return
        }
        result.withCString { callback($0, context) }
    }
}

@_cdecl("moth_page_evaluate")
func moth_page_evaluate(_ window: UInt64, _ id: UInt64, _ script: UnsafePointer<CChar>?,
                        _ callback: @escaping @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void,
                        _ context: UnsafeMutableRawPointer?) {
    guard let scriptPointer = script else { callback(nil, context); return }
    let script = String(cString: scriptPointer)
    MainActor.assumeIsolated {
        guard let view = BrowserFeatures.pages["\(window):\(id)"]?.webView else { callback(nil, context); return }
        view.evaluateJavaScript(script) { value, _ in
            let data = try? JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.fragmentsAllowed])
            let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            json.withCString { callback($0, context) }
        }
    }
}
