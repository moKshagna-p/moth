import AppKit
import SwiftUI
import WebKit

struct BrowserSettings: Codable {
    var search_engine = "google"
    var download_directory = ""
    var restore_session = true
    var appearance = "system"
    var site_permissions: [String: String] = [:]
    var ad_blocking = true
    var ad_block_exceptions: [String] = []
    init() {}
    enum CodingKeys: String, CodingKey {
        case search_engine, download_directory, restore_session, appearance, site_permissions, ad_blocking, ad_block_exceptions
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        search_engine = try values.decodeIfPresent(String.self, forKey: .search_engine) ?? "google"
        download_directory = try values.decodeIfPresent(String.self, forKey: .download_directory) ?? ""
        restore_session = try values.decodeIfPresent(Bool.self, forKey: .restore_session) ?? true
        appearance = try values.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        site_permissions = try values.decodeIfPresent([String: String].self, forKey: .site_permissions) ?? [:]
        ad_blocking = try values.decodeIfPresent(Bool.self, forKey: .ad_blocking) ?? true
        ad_block_exceptions = try values.decodeIfPresent([String].self, forKey: .ad_block_exceptions) ?? []
    }
    var adPreferences: AdBlockPreferences { AdBlockPreferences(enabled: ad_blocking, exceptions: ad_block_exceptions.sorted()) }
}

@MainActor struct SettingsView: View {
    @ObservedObject var model: ChromeModel
    @State var settings: BrowserSettings
    private var isPrivate: Bool { model.snapshot?.private_mode == true }
    var body: some View {
        Form {
            if isPrivate {
                Text("Private windows use your browser settings. Open Settings in a normal window to change them.")
            }
            Group {
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
            }.disabled(isPrivate)
            Section("Privacy") {
                Toggle("Block ads", isOn: $settings.ad_blocking).disabled(isPrivate)
                Text("Built-in filters block common third-party ad networks. Use the toolbar shield to pause for a website. Filters stay on your Mac.").font(.caption)
                if !settings.ad_block_exceptions.isEmpty {
                    Text("Paused on " + settings.ad_block_exceptions.joined(separator: ", ")).font(.caption).lineLimit(2)
                    Button("Reset ad blocking exceptions") { settings.ad_block_exceptions = [] }.disabled(isPrivate)
                }
                Text("Private windows keep history and website storage in memory. Files you download remain on disk.")
                    .font(.caption)
                if let origin = model.activeTab.flatMap({ URL(string: $0.url) }).flatMap(BrowserFeatures.origin) {
                    Picker("Camera and microphone for \(origin)", selection: Binding(
                        get: { settings.site_permissions[origin] ?? "ask" },
                        set: { settings.site_permissions[origin] = $0 }
                    )) { Text("Ask each time").tag("ask"); Text("Block").tag("deny") }.disabled(isPrivate)
                }
                Text("Camera and microphone requests show the requesting site's origin. Other permissions use WebKit and macOS controls.").font(.caption)
                Button("Reset saved site rules") { settings.site_permissions = [:] }.disabled(isPrivate)
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
            }.keyboardShortcut(.defaultAction).disabled(isPrivate) }
        }.buttonStyle(.glass).formStyle(.grouped).padding().frame(width: 540, height: 650)
    }
}

@MainActor struct FindView: View {
    weak var webView: WKWebView?
    var dismiss: () -> Void
    @State private var query = ""
    @State private var status = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack {
            TextField("Find in page", text: $query).textFieldStyle(.plain).focused($focused).onSubmit { find(false) }
                .onChange(of: query) { _, _ in find(false) }
            Text(status).font(.caption).accessibilityLabel(status)
            Button { find(true) } label: { Image(systemName: "chevron.up") }.help("Previous Match").keyboardShortcut("g", modifiers: [.command, .shift])
            Button { find(false) } label: { Image(systemName: "chevron.down") }.help("Next Match").keyboardShortcut("g", modifiers: .command)
            Button(action: dismiss) { Image(systemName: "xmark") }.help("Close Find")
        }.buttonStyle(.plain).padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14))
            .onAppear { focused = true }.onExitCommand(perform: dismiss)
    }
    private func find(_ backwards: Bool) {
        guard !query.isEmpty else { status = ""; return }
        let requested = query
        let configuration = WKFindConfiguration(); configuration.backwards = backwards
        configuration.wraps = true; configuration.caseSensitive = false
        webView?.find(query, configuration: configuration) { result in
            guard query == requested else { return }
            status = result.matchFound ? "Match found" : "No matches"
        }
    }
}

@MainActor enum BrowserFeatures {
    static var privateStores: [UInt64: WKWebsiteDataStore] = [:]
    static var pages: [String: PageDelegate] = [:]
    static var downloads: [String: DownloadDelegate] = [:]
    static var settingsWindows: [UInt64: NSWindow] = [:]
    static var projectWindows: [UInt64: NSWindow] = [:]
    static var findViews: [UInt64: NSHostingView<FindView>] = [:]
    static var findTabs: [UInt64: UInt64] = [:]
    static var mediaTimer: Timer?
    static var displayedErrors: [UInt64: String] = [:]
    static func prunePages() {
        pages = pages.filter { _, page in
            guard page.webView?.superview != nil else { page.closePopups(); page.container.removeFromSuperview(); return false }
            return true
        }
    }
    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme, ["http", "https"].contains(scheme), let host = url.host else { return nil }
        let port = url.port.flatMap { ($0 == 80 && scheme == "http") || ($0 == 443 && scheme == "https") ? nil : $0 }
        return "\(scheme.lowercased())://\(host.lowercased())" + (port.map { ":\($0)" } ?? "")
    }
    static func removeWindow(_ id: UInt64) {
        ProjectLauncher.removeWindow(id)
        privateStores.removeValue(forKey: id)
        for page in pages.values where page.window == id { page.closePopups(); page.container.removeFromSuperview() }
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
        projectWindows.removeValue(forKey: id)?.close()
        closeFind(id)
        displayedErrors.removeValue(forKey: id)
    }
    static func update(_ id: UInt64, model: ChromeModel) {
        prunePages()
        if let tab = findTabs[id], tab != model.snapshot?.active || model.snapshot?.panel != nil { closeFind(id) }
        for tab in model.snapshot?.tabs ?? [] {
            if let preferences = model.snapshot?.settings.adPreferences { pages["\(id):\(tab.id)"]?.updateAdBlocking(preferences) }
            if let page = pages["\(id):\(tab.id)"], page.mediaSuspended != tab.media_suspended {
                page.mediaSuspended = tab.media_suspended
                page.webView?.setAllMediaPlaybackSuspended(tab.media_suspended, completionHandler: nil)
            }
        }
        if mediaTimer == nil {
            mediaTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    prunePages()
                    for page in pages.values {
                        guard page.webView != nil else { continue }
                        page.updateMediaState()
                    }
                    if pages.isEmpty { mediaTimer?.invalidate(); mediaTimer = nil }
                }
            }
            mediaTimer?.tolerance = 0.5
        }
        if let error = model.snapshot?.error, displayedErrors[id] != error {
            displayedErrors[id] = error
            let alert = NSAlert(); alert.messageText = "Moth needs your attention"; alert.informativeText = error
            alert.addButton(withTitle: "OK")
            if let window = model.bridge?.parent?.window { alert.beginSheetModal(for: window) { _ in model.send("dismiss_error") } }
        } else if model.snapshot?.error == nil { displayedErrors.removeValue(forKey: id) }
    }
    static func closeFind(_ id: UInt64) {
        findViews.removeValue(forKey: id)?.removeFromSuperview(); findTabs.removeValue(forKey: id)
    }
    static func layoutFind(_ id: UInt64) {
        guard let bridge = ChromeBridge.instances[id], let parent = bridge.parent, let host = findViews[id] else { return }
        let model = bridge.model
        let layout = DeveloperLayout(size: parent.bounds.size, sidebar: model.sidebarWidth,
            split: model.snapshot?.split != nil, activeRight: model.snapshot?.split_right == model.snapshot?.active, ratio: model.snapshot?.split_ratio ?? 0.5)
        let width = min(420, max(1, layout.active.width - 24))
        host.frame = CGRect(x: layout.active.maxX - width - 12, y: parent.isFlipped ? 62 : parent.bounds.height - 114, width: width, height: 52)
        parent.addSubview(host, positioned: .above, relativeTo: nil)
    }
    // WebKit records are grouped by domain, across its subdomains and ports.
    static func recordMatches(host: String, domain: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !domain.isEmpty else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }
    static func clearCurrentSite(_ page: PageDelegate?, model: ChromeModel) {
        guard let view = page?.webView, let url = view.url, let host = url.host,
              ["http", "https"].contains(url.scheme ?? ""), let window = view.window else { return }
        let store = view.configuration.websiteDataStore
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            guard page?.webView === view, view.url == url else { return }
            let matches = records.filter { recordMatches(host: host, domain: $0.displayName) }
            let alert = NSAlert()
            if matches.isEmpty {
                alert.messageText = "No saved website data for \(host)"; alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window); return
            }
            alert.messageText = "Clear data for this website?"
            alert.informativeText = "WebKit groups data for these domains: " + matches.map(\.displayName).joined(separator: ", ") + ". This removes cookies, caches, and storage for their subdomains and ports, and may sign you out in other Moth windows."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Clear Website Data")
            alert.beginSheetModal(for: window) { response in
                guard response == .alertSecondButtonReturn, page?.webView === view, view.url == url else { return }
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matches) {
                    if view.url == url { view.reload() }
                }
            }
        }
    }
    static func saveScreenshot(_ page: PageDelegate?, model: ChromeModel) {
        guard let view = page?.webView, let window = view.window else { return }
        let url = view.url
        view.takeSnapshot(with: nil) { image, error in
            guard page?.webView === view, view.url == url else { return }
            guard let image, let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
                let alert = NSAlert(); alert.messageText = "Couldn’t capture this viewport"
                alert.informativeText = error?.localizedDescription ?? "WebKit did not return an image."
                alert.beginSheetModal(for: window); return
            }
            let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "Moth-\(url?.host ?? "viewport").png"
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let destination = panel.url {
                    do { try png.write(to: destination, options: .atomic) }
                    catch { let alert = NSAlert(); alert.messageText = "Couldn’t save screenshot"; alert.informativeText = error.localizedDescription; alert.beginSheetModal(for: window) }
                }
            }
        }
    }
    static func action(_ window: UInt64, _ id: UInt64, _ action: String) {
        guard let bridge = ChromeBridge.instances[window] else { return }
        let model = bridge.model
        let page = pages["\(window):\(id)"]
        switch action {
        case "settings":
            if let existing = settingsWindows[window], existing.isVisible { existing.makeKeyAndOrderFront(nil); return }
            guard let settings = model.snapshot?.settings else { return }
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Moth Settings"; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: SettingsView(model: model, settings: settings))
            panel.center(); panel.makeKeyAndOrderFront(nil); settingsWindows[window] = panel
        case "settings_saved": settingsWindows.removeValue(forKey: window)?.close()
        case "local_projects": ProjectLauncher.show(model)
        case "project":
            if let existing = projectWindows[window], existing.isVisible { existing.makeKeyAndOrderFront(nil); return }
            guard let workspace = model.activeWorkspace else { return }
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Project Preset"; panel.isReleasedWhenClosed = false
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.contentView = NSHostingView(rootView: ProjectPresetView(model: model, workspace: workspace.id, name: workspace.name, preset: workspace.project))
            panel.center(); panel.makeKeyAndOrderFront(nil); projectWindows[window] = panel
        case "project_saved": projectWindows.removeValue(forKey: window)?.close()
        case "find":
            guard let webView = page?.webView, let parent = bridge.parent else { return }
            closeFind(window)
            let host = NSHostingView(rootView: FindView(webView: webView, dismiss: { closeFind(window) }))
            findViews[window] = host; findTabs[window] = id
            parent.addSubview(host); layoutFind(window)
        case "picture_in_picture": PictureInPicture.toggle(page)
        case "screenshot": saveScreenshot(page, model: model)
        case "clear_current_site": clearCurrentSite(page, model: model)
        case "suspend_media": page?.webView?.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        case "resume_media": page?.webView?.setAllMediaPlaybackSuspended(false, completionHandler: nil)
        case "default_browser":
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http") { error in
                if let error { Task { @MainActor in model.send("page_error", ["id": id, "generation": page?.generation ?? 0, "message": error.localizedDescription]) } }
            }
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "https") { error in
                if let error { Task { @MainActor in model.send("page_error", ["id": id, "generation": page?.generation ?? 0, "message": error.localizedDescription]) } }
            }
        case "clear_data":
            let store = model.snapshot?.private_mode == true ? privateStores[window] : WKWebsiteDataStore.default()
            store?.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                model.send("dismiss_error")
            }
        default:
            if action.hasPrefix("cancel:") { downloads[String(action.dropFirst(7))]?.cancel() }
        }
    }
}

@MainActor final class PageContainer: NSView {
    var acceptsInteraction = true
    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsInteraction ? super.hitTest(point) : nil
    }
}

// Forward callbacks not handled here to Wry, preserving its navigation and file dialogs.
@MainActor final class PageDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    let window: UInt64
    let id: UInt64
    let generation: UInt64
    weak var webView: WKWebView?
    // WebKit docks its inspector against the inspected view's superview.
    // A pane-sized parent keeps those layout changes inside the pane.
    let container: PageContainer
    let navigation: WKNavigationDelegate?
    let ui: WKUIDelegate?
    var focusObserver: Any?
    var automaticPresentation = AutomaticPictureInPicture()
    private var windowFocused = true
    var pictureInPicture = false
    private(set) var visible: Bool
    var playing = false
    private var mediaRevision: UInt64 = 0
    private var checkingMedia = false
    var mediaSuspended = false
    var adPreferences = AdBlockPreferences()
    var installedAdRules: WKContentRuleList?
    var popups: [UUID: BrowserPopup] = [:]
    weak var popup: BrowserPopup?
    init(window: UInt64, id: UInt64, generation: UInt64, webView: WKWebView, uiDelegate: WKUIDelegate? = nil) {
        self.window = window; self.id = id; self.generation = generation; self.webView = webView
        navigation = webView.navigationDelegate; ui = uiDelegate ?? webView.uiDelegate
        container = PageContainer(frame: webView.frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = contentCornerRadius
        container.layer?.masksToBounds = true
        container.isHidden = webView.isHidden
        visible = !webView.isHidden
        if let parent = webView.superview {
            parent.addSubview(container, positioned: .above, relativeTo: webView)
            webView.removeFromSuperview()
            container.addSubview(webView)
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
        }
        super.init()
        windowFocused = webView.window?.isKeyWindow ?? true
        // Native notifications also cover switching to another app or macOS Space.
        NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged(_:)), name: NSWindow.didResignKeyNotification, object: nil)
        focusObserver = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, self.popup == nil, let view = self.webView, event.window == view.window,
                  self.visible, !view.isHidden, !self.container.isHidden, view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return event }
            self.model?.send("focus_pane", ["id": self.id]); return event
        }
    }
    deinit {
        NotificationCenter.default.removeObserver(self)
        if let focusObserver { NSEvent.removeMonitor(focusObserver) }
    }
    @objc private func windowFocusChanged(_ notification: Notification) {
        guard let source = notification.object as? NSWindow, source === webView?.window else { return }
        windowFocused = notification.name == NSWindow.didBecomeKeyNotification
        reconcilePresentation()
    }
    var model: ChromeModel? { ChromeBridge.instances[window]?.model }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || navigation?.responds(to: selector) == true || ui?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        if navigation?.responds(to: selector) == true { return navigation }
        if ui?.responds(to: selector) == true { return ui }
        return super.forwardingTarget(for: selector)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // An asynchronous sample from the previous document must never label a new page.
        mediaRevision &+= 1
        checkingMedia = false
        applyMediaState(playing: false, pip: false)
        self.navigation?.webView?(webView, didStartProvisionalNavigation: navigation)
    }
    func updateMediaState() {
        guard let webView, !webView.isLoading, !checkingMedia else { return }
        let revision = mediaRevision
        checkingMedia = true
        webView.requestMediaPlaybackState { [weak self, weak webView] state in
            guard let self, let webView, self.webView === webView, self.mediaRevision == revision else { return }
            // Most tabs have no media. Avoid JavaScript and DOM scans entirely for them.
            if state == .none && !self.pictureInPicture {
                self.checkingMedia = false
                self.applyMediaState(playing: false, pip: false)
                return
            }
            webView.evaluateJavaScript(PictureInPicture.mediaStateScript) { [weak self, weak webView] value, error in
                guard let self, let webView, self.webView === webView, self.mediaRevision == revision else { return }
                self.checkingMedia = false
                guard error == nil, let sample = value as? [String: Bool],
                      let audible = sample["playing"], let pip = sample["pip"] else { return }
                self.applyMediaState(playing: state == .playing && audible, pip: pip)
            }
        }
    }
    private func applyMediaState(playing: Bool, pip: Bool) {
        guard self.playing != playing || pictureInPicture != pip else { return }
        self.playing = playing; pictureInPicture = pip
        if !pip && !automaticPresentation.pending { automaticPresentation.dismissed() }
        applyVisibility()
        sendMediaState()
    }

    private func sendMediaState() {
        model?.send("media_state", ["id": id, "generation": generation,
            "playing": playing, "picture_in_picture": pictureInPicture])
    }
    func setVisible(_ visible: Bool) {
        self.visible = visible
        reconcilePresentation()
    }

    private func reconcilePresentation() {
        let action = automaticPresentation.update(foreground: visible && windowFocused)
        performAutomaticPresentation(action)
        applyVisibility()
    }
    private func performAutomaticPresentation(_ action: AutomaticPictureInPicture.Action) {
        guard action != .none, let webView else { return }
        let script = action == .enter ? PictureInPicture.automaticEntryScript : PictureInPicture.automaticExitScript
        webView.evaluateJavaScript(script, in: nil, in: .page) { [weak self, weak webView] result in
            guard let self, let webView, self.webView === webView else { return }
            var entered = false
            if case .success(let value) = result {
                entered = value as? String == "entered"
                if entered || value as? String == "existing" { self.pictureInPicture = true }
                if value as? String == "exited" { self.pictureInPicture = false }
            }
            let next = self.automaticPresentation.completed(action, entered: entered)
            self.performAutomaticPresentation(next)
            self.applyVisibility()
            self.sendMediaState()
            self.updateMediaState()
        }
    }
    private func applyVisibility() {
        // Hiding a WKWebView ends native PiP. Keep its attachment alive, with an
        // invisible, non-interactive pane until the floating player is dismissed.
        let hidden = !visible && !pictureInPicture && !automaticPresentation.pending
        webView?.isHidden = hidden
        container.isHidden = hidden
        container.alphaValue = visible ? 1 : 0
        container.acceptsInteraction = visible
        container.setAccessibilityHidden(!visible)
    }

    func prepareAdBlocking(completion: @escaping (Bool) -> Void) {
        let requested = adPreferences
        AdBlocker.shared.rules(for: requested) { [weak self] result in
            guard let self, let view = self.webView else { completion(false); return }
            // A settings change can arrive while WebKit is compiling. Never apply stale rules.
            guard self.adPreferences == requested else { self.prepareAdBlocking(completion: completion); return }
            switch result {
            case .success(let list):
                let controller = view.configuration.userContentController
                if self.installedAdRules !== list {
                    if let previous = self.installedAdRules { controller.remove(previous) }
                    if let list { controller.add(list) }
                    self.installedAdRules = list
                }
                completion(true)
            case .failure:
                completion(false)
            }
        }
    }
    func updateAdBlocking(_ preferences: AdBlockPreferences) {
        guard adPreferences != preferences else { return }
        let old = adPreferences
        adPreferences = preferences
        for popup in popups.values { popup.page.updateAdBlocking(preferences) }
        let host = webView?.url?.host
        let reload = old.blocks(host: host) != preferences.blocks(host: host)
        prepareAdBlocking { [weak self] success in
            guard let self, success, self.adPreferences == preferences, reload,
                  self.webView?.url?.host == host else { return }
            self.webView?.reload()
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        prepareAdBlocking { [weak self, weak webView] success in
            guard let self, let webView else { decisionHandler(.cancel); return }
            guard success else {
                if let popup = self.popup { popup.showError("Ad blocking could not start. Turn it off in Settings and retry.") }
                else { self.model?.send("page_error", ["id": self.id, "generation": self.generation,
                    "message": "Ad blocking could not start. Turn it off in Settings to load this page."]) }
                decisionHandler(.cancel); return
            }
            if self.navigation?.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")) == true {
                self.navigation?.webView?(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
            } else { decisionHandler(.allow) }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        // WebKit can emit an empty response during page navigation.
        // Wry treats its missing MIME type as a download, interrupting the page.
        // Only real responses should reach that download policy.
        guard navigationResponse.response.url != nil else { decisionHandler(.allow); return }
        if navigation?.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationResponse:decisionHandler:")) == true {
            navigation?.webView?(webView, decidePolicyFor: navigationResponse, decisionHandler: decisionHandler)
        } else { decisionHandler(.allow) }
    }
    func closePopups() {
        for popup in Array(popups.values) { popup.close() }
        popups.removeAll()
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        let popup = BrowserPopup(opener: self, configuration: configuration, features: windowFeatures,
                                 initialURL: navigationAction.request.url)
        popups[popup.id] = popup
        popup.window.makeKeyAndOrderFront(nil)
        // WebKit starts the original request after we return this view. Loading just
        // the URL ourselves would lose POST bodies and the JavaScript opener.
        return popup.webView
    }
    func webViewDidClose(_ webView: WKWebView) { popup?.close() }
    func report(_ error: Error) {
        let failure = error as NSError
        // WebKit interrupts navigation when a response becomes a download.
        // That policy transition is not a page failure.
        guard !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled),
              !(failure.domain == "WebKitErrorDomain" && failure.code == 102) else { return }
        if let popup { popup.showError(error.localizedDescription); return }
        model?.send("page_error", ["id": id, "generation": generation, "message": error.localizedDescription + " Use Reload to retry."])
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let popup { popup.showError("This page stopped responding. Close this window and retry sign-in."); return }
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
func moth_page_attach(_ window: UInt64, _ id: UInt64, _ generation: UInt64, _ pointer: UnsafeMutableRawPointer?, _ settingsJSON: UnsafePointer<CChar>?) {
    guard let pointer, let settingsJSON else { return }
    let settings = try? JSONDecoder().decode(BrowserSettings.self, from: Data(String(cString: settingsJSON).utf8))
    MainActor.assumeIsolated {
        let view = Unmanaged<WKWebView>.fromOpaque(pointer).takeUnretainedValue()
        view.isInspectable = true
        BrowserFeatures.pages["\(window):\(id)"]?.closePopups()
        BrowserFeatures.pages["\(window):\(id)"]?.container.removeFromSuperview()
        let delegate = PageDelegate(window: window, id: id, generation: generation, webView: view)
        delegate.adPreferences = (settings ?? BrowserSettings()).adPreferences
        BrowserFeatures.pages["\(window):\(id)"] = delegate
        view.navigationDelegate = delegate; view.uiDelegate = delegate
    }
}

@_cdecl("moth_page_layout")
func moth_page_layout(_ window: UInt64, _ id: UInt64, _ x: Double, _ y: Double, _ width: Double, _ height: Double) {
    MainActor.assumeIsolated {
        guard let pane = BrowserFeatures.pages["\(window):\(id)"]?.container, let parent = pane.superview else { return }
        pane.frame = CGRect(x: x, y: parent.isFlipped ? y : parent.bounds.height - y - height, width: width, height: height)
    }
}
@_cdecl("moth_page_visible")
func moth_page_visible(_ window: UInt64, _ id: UInt64, _ visible: Bool) {
    MainActor.assumeIsolated { BrowserFeatures.pages["\(window):\(id)"]?.setVisible(visible) }
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
