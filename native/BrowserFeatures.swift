import AppKit
import SwiftUI
import WebKit

struct BrowserSettings: Codable {
    var search_engine: String
    var download_directory: String
    var restore_session: Bool
    var appearance: String
    var site_permissions: [String: String]
}

@MainActor struct SettingsView: View {
    @ObservedObject var model: ChromeModel
    @State var settings: BrowserSettings
    var body: some View {
        Form {
            Picker("Search engine", selection: $settings.search_engine) {
                Text("Google").tag("google")
                Text("DuckDuckGo").tag("duckduckgo")
                Text("Bing").tag("bing")
            }
            Picker("Appearance", selection: $settings.appearance) {
                Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }
            Toggle("Restore tabs on startup", isOn: $settings.restore_session)
            HStack {
                Text(settings.download_directory.isEmpty ? "Downloads folder" : settings.download_directory).lineLimit(2)
                Button("Choose…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    if panel.runModal() == .OK { settings.download_directory = panel.url?.path ?? "" }
                }
            }
            Section("Privacy") {
                Text("Private windows keep history and website storage in memory. Files you download remain on disk.")
                    .font(.caption)
                if let origin = model.activeTab.flatMap({ URL(string: $0.url) }).flatMap(BrowserFeatures.origin) {
                    Picker("Camera and microphone for \(origin)", selection: Binding(
                        get: { settings.site_permissions[origin] ?? "ask" },
                        set: { settings.site_permissions[origin] = $0 }
                    )) { Text("Ask each time").tag("ask"); Text("Block").tag("deny") }
                }
                Text("Camera and microphone requests show the requesting site's origin. Other permissions use WebKit and macOS controls.").font(.caption)
                Button("Reset saved site rules") { settings.site_permissions = [:] }
                Button("Clear cookies and cache…") {
                    let alert = NSAlert(); alert.messageText = "Clear website data?"
                    alert.informativeText = "This signs you out of websites. All tabs in this window will close. Other normal windows must be closed first."
                    alert.addButton(withTitle: "Clear Data"); alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn { model.send("clear_site_data") }
                }
            }
            Button("Make Moth the default browser…") { model.send("default_browser") }
            HStack { Spacer(); Button("Save Settings") {
                if let data = try? JSONEncoder().encode(settings),
                   let value = try? JSONSerialization.jsonObject(with: data) {
                    model.send("set_settings", ["settings": value])
                }
            }.keyboardShortcut(.defaultAction) }
        }.formStyle(.grouped).padding().frame(width: 540, height: 550)
    }
}

@MainActor struct FindView: View {
    weak var webView: WKWebView?
    @State private var query = ""
    @State private var status = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack {
            TextField("Find in page", text: $query).focused($focused).onSubmit { find(false) }
            Text(status).font(.caption).accessibilityLabel(status)
            Button("Previous") { find(true) }.keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Next") { find(false) }.keyboardShortcut("g", modifiers: .command)
        }.padding().frame(width: 500).onAppear { focused = true }
    }
    private func find(_ backwards: Bool) {
        guard !query.isEmpty else { status = ""; return }
        let configuration = WKFindConfiguration(); configuration.backwards = backwards
        configuration.wraps = true; configuration.caseSensitive = false
        webView?.find(query, configuration: configuration) { result in
            status = result.matchFound ? "Match found" : "No matches"
        }
    }
}

@MainActor enum BrowserFeatures {
    static var privateStores: [UInt64: WKWebsiteDataStore] = [:]
    static var pages: [String: PageDelegate] = [:]
    static var downloads: [String: DownloadDelegate] = [:]
    static var settingsWindows: [UInt64: NSWindow] = [:]
    static var findWindows: [UInt64: NSPanel] = [:]
    static var displayedErrors: [UInt64: String] = [:]
    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme, ["http", "https"].contains(scheme), let host = url.host else { return nil }
        let port = url.port.flatMap { ($0 == 80 && scheme == "http") || ($0 == 443 && scheme == "https") ? nil : $0 }
        return "\(scheme.lowercased())://\(host.lowercased())" + (port.map { ":\($0)" } ?? "")
    }
    static func removeWindow(_ id: UInt64) {
        privateStores.removeValue(forKey: id)
        pages = pages.filter { $0.value.window != id }
        let replacement = ChromeBridge.instances.values.first {
            $0.model.windowID != id && $0.model.snapshot?.private_mode == false
        }
        let isPrivate = ChromeBridge.instances[id]?.model.snapshot?.private_mode != false
        for download in downloads.values.filter({ $0.window == id }) {
            if !isPrivate, let replacement {
                download.window = replacement.model.windowID
            } else {
                download.cancel()
            }
        }
        settingsWindows.removeValue(forKey: id)?.close()
        findWindows.removeValue(forKey: id)?.close()
        displayedErrors.removeValue(forKey: id)
    }
    static func update(_ id: UInt64, model: ChromeModel) {
        pages = pages.filter { $0.value.webView != nil }
        if let error = model.snapshot?.error, displayedErrors[id] != error {
            displayedErrors[id] = error
            let alert = NSAlert(); alert.messageText = "Moth needs your attention"; alert.informativeText = error
            alert.addButton(withTitle: "OK")
            if let window = model.bridge?.parent?.window { alert.beginSheetModal(for: window) { _ in model.send("dismiss_error") } }
        } else if model.snapshot?.error == nil { displayedErrors.removeValue(forKey: id) }
    }
    static func action(_ window: UInt64, _ id: UInt64, _ action: String) {
        guard let bridge = ChromeBridge.instances[window] else { return }
        let model = bridge.model
        let page = pages["\(window):\(id)"]
        switch action {
        case "settings":
            if let existing = settingsWindows[window], existing.isVisible { existing.makeKeyAndOrderFront(nil); return }
            guard let settings = model.snapshot?.settings else { return }
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 550), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Moth Settings"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: SettingsView(model: model, settings: settings))
            panel.center(); panel.makeKeyAndOrderFront(nil); settingsWindows[window] = panel
        case "settings_saved": settingsWindows.removeValue(forKey: window)?.close()
        case "find":
            guard let webView = page?.webView else { return }
            findWindows.removeValue(forKey: window)?.close()
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 65), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Find in Page"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: FindView(webView: webView))
            panel.center(); panel.makeKeyAndOrderFront(nil); findWindows[window] = panel
        case "default_browser":
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http") { error in
                if let error { Task { @MainActor in model.send("page_error", ["id": id, "generation": page?.generation ?? 0, "message": error.localizedDescription]) } }
            }
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "https") { error in
                if let error { Task { @MainActor in model.send("page_error", ["id": id, "generation": page?.generation ?? 0, "message": error.localizedDescription]) } }
            }
        case "clear_data":
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                model.send("dismiss_error")
            }
        default:
            if action.hasPrefix("cancel:") { downloads[String(action.dropFirst(7))]?.cancel() }
        }
    }
}

// Forward callbacks not handled here to Wry, preserving its navigation and popup lifecycle.
@MainActor final class PageDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    let window: UInt64
    let id: UInt64
    let generation: UInt64
    weak var webView: WKWebView?
    let navigation: WKNavigationDelegate?
    let ui: WKUIDelegate?
    var focusObserver: Any?
    init(window: UInt64, id: UInt64, generation: UInt64, webView: WKWebView) {
        self.window = window; self.id = id; self.generation = generation; self.webView = webView
        navigation = webView.navigationDelegate; ui = webView.uiDelegate
        super.init()
        focusObserver = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, let view = self.webView, event.window == view.window,
                  !view.isHidden, view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return event }
            self.model?.send("focus_pane", ["id": self.id]); return event
        }
    }
    deinit { if let focusObserver { NSEvent.removeMonitor(focusObserver) } }
    var model: ChromeModel? { ChromeBridge.instances[window]?.model }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || navigation?.responds(to: selector) == true || ui?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        if navigation?.responds(to: selector) == true { return navigation }
        if ui?.responds(to: selector) == true { return ui }
        return super.forwardingTarget(for: selector)
    }
    func report(_ error: Error) {
        let failure = error as NSError
        // WebKit interrupts navigation when a response becomes a download.
        // That policy transition is not a page failure.
        guard !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled),
              !(failure.domain == "WebKitErrorDomain" && failure.code == 102) else { return }
        model?.send("page_error", ["id": id, "generation": generation, "message": error.localizedDescription + " Use Reload to retry."])
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        model?.send("page_error", ["id": id, "generation": generation, "message": "This page stopped responding. Use Reload to reopen it."])
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let port = origin.port == 0 || (origin.protocol == "https" && origin.port == 443) || (origin.protocol == "http" && origin.port == 80) ? "" : ":\(origin.port)"
        let host = origin.host.contains(":") && !origin.host.hasPrefix("[") ? "[\(origin.host)]" : origin.host
        let site = "\(origin.protocol.lowercased())://\(host.lowercased())\(port)"
        guard model?.snapshot?.settings.site_permissions[site] != "deny" else { decisionHandler(.deny); return }
        let alert = NSAlert(); alert.messageText = "Allow \(site) to use \(type == .camera ? "your camera" : type == .microphone ? "your microphone" : "your camera and microphone")?"
        alert.addButton(withTitle: "Don't Allow"); alert.addButton(withTitle: "Allow Once")
        guard let window = webView.window else { decisionHandler(.deny); return }
        let requestedURL = webView.url
        alert.beginSheetModal(for: window) { [weak webView] result in
            decisionHandler(result == .alertSecondButtonReturn && webView?.url == requestedURL && webView?.window != nil ? .grant : .deny)
        }
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { attach(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { attach(download) }
    func attach(_ download: WKDownload) {
        let delegate = DownloadDelegate(window: window, download: download)
        BrowserFeatures.downloads[delegate.id] = delegate; download.delegate = delegate
    }
}

@MainActor final class DownloadDelegate: NSObject, WKDownloadDelegate {
    let id = UUID().uuidString
    var window: UInt64
    let download: WKDownload
    var path = ""
    var filename = ""
    var complete = false
    var observation: NSKeyValueObservation?
    init(window: UInt64, download: WKDownload) { self.window = window; self.download = download }
    func update(success: Bool = false) {
        ChromeBridge.instances[window]?.model.send("download_update", ["download": [
            "id": id, "url": download.originalRequest?.url?.absoluteString ?? "", "filename": filename,
            "path": path, "complete": complete, "success": success,
            "progress": download.progress.fractionCompleted.isFinite ? download.progress.fractionCompleted : 0
        ]])
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let setting = ChromeBridge.instances[window]?.model.snapshot?.settings.download_directory ?? ""
        let directory = setting.isEmpty ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] : URL(fileURLWithPath: setting, isDirectory: true)
        let component = (suggestedFilename as NSString).lastPathComponent
        let safe = component == "." || component == ".." || component == "/" ? "download" : component
        var destination = directory.appendingPathComponent(safe.isEmpty ? "download" : safe)
        let ext = destination.pathExtension; let stem = destination.deletingPathExtension().lastPathComponent
        var number = 1
        let active = Set(BrowserFeatures.downloads.values.map(\.path))
        while FileManager.default.fileExists(atPath: destination.path) || active.contains(destination.path) {
            destination = directory.appendingPathComponent("\(stem) (\(number))" + (ext.isEmpty ? "" : ".\(ext)")); number += 1
        }
        path = destination.path; filename = destination.lastPathComponent
        observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.update() }
        }
        update(); completionHandler(destination)
    }
    func downloadDidFinish(_ download: WKDownload) { finish(true) }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { finish(false) }
    func finish(_ success: Bool) {
        guard !complete else { return }; complete = true; observation = nil; update(success: success)
        BrowserFeatures.downloads.removeValue(forKey: id)
    }
    func cancel() { download.cancel { [weak self] _ in self?.finish(false) } }
}

@_cdecl("moth_page_attach")
func moth_page_attach(_ window: UInt64, _ id: UInt64, _ generation: UInt64, _ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    MainActor.assumeIsolated {
        let view = Unmanaged<WKWebView>.fromOpaque(pointer).takeUnretainedValue()
        let delegate = PageDelegate(window: window, id: id, generation: generation, webView: view)
        BrowserFeatures.pages["\(window):\(id)"] = delegate
        view.navigationDelegate = delegate; view.uiDelegate = delegate
    }
}
@_cdecl("moth_page_action")
func moth_page_action(_ window: UInt64, _ id: UInt64, _ action: UnsafePointer<CChar>?) {
    guard let action else { return }
    let value = String(cString: action)
    MainActor.assumeIsolated { BrowserFeatures.action(window, id, value) }
}

@_cdecl("moth_private_configuration")
func moth_private_configuration(_ window: UInt64) -> UnsafeMutableRawPointer {
    MainActor.assumeIsolated {
        let store = BrowserFeatures.privateStores[window] ?? WKWebsiteDataStore.nonPersistent()
        BrowserFeatures.privateStores[window] = store
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        return Unmanaged.passRetained(configuration).toOpaque()
    }
}
