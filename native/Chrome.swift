import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let toolbarHeight: CGFloat = 50
private let ink = Color(red: 0.16, green: 0.18, blue: 0.16)
private let muted = Color(red: 0.44, green: 0.47, blue: 0.43)
private let accent = Color(red: 0.29, green: 0.39, blue: 0.31)

struct TabInfo: Decodable, Identifiable {
    let id: UInt64
    let url: String
    let title: String
    let favicon: String?
    let loading: Bool
    let sleeping: Bool
    let pinned: Bool
    let keep_awake: Bool
    let playing: Bool
    let media_suspended: Bool
    let zoom: Double
    let page_error: String?
    let viewport: [UInt16]?
    let workspace: UInt64
}

struct WorkspaceInfo: Decodable, Identifiable {
    let id: UInt64
    let name: String
    let project: ProjectPreset
}

struct ChromeSnapshot: Decodable {
    let tabs: [TabInfo]
    let bookmarks: [SavedEntry]
    let history: [SavedEntry]
    let split: UInt64?
    let split_right: UInt64?
    let split_ratio: Double
    let workspaces: [WorkspaceInfo]
    let active: UInt64
    let active_workspace: UInt64
    let panel: String?
    let private_mode: Bool
    let error: String?
    let settings: BrowserSettings
    let bookmarked: Bool
    let can_go_back: Bool
    let can_go_forward: Bool
    let has_photo: Bool
    let photo_version: UInt64
    let photo_focus_x: UInt8
    let photo_focus_y: UInt8
    let sidebar_width: UInt16?
    let site_color: [UInt8]?
}

@MainActor final class ChromeModel: ObservableObject {
    @Published var snapshot: ChromeSnapshot?
    @Published var swipeWorkspaces = UserDefaults.standard.object(forKey: "swipeWorkspaces") as? Bool ?? true {
        didSet { UserDefaults.standard.set(swipeWorkspaces, forKey: "swipeWorkspaces") }
    }
    @Published var matchSiteColors = UserDefaults.standard.object(forKey: "matchSiteColors") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(matchSiteColors, forKey: "matchSiteColors")
            updateContrast()
        }
    }
    @Published var customizingWallpaper = false
    @Published var sidebarWidth: CGFloat = 220
    @Published var address = ""
    @Published var addressFocus = 0
    @Published var paletteMode: PaletteMode?
    @Published var paletteFocus = 0
    @Published var paletteQuery = "" { didSet { rebuildPalette(reset: true) } }
    @Published var paletteResults: [PaletteResult] = []
    @Published var paletteSelection = 0
    @Published var renamingWorkspace = false
    @Published var workspaceName = ""
    @Published var windowSize = CGSize(width: 1000, height: 768) { didSet { if oldValue != windowSize { updateContrast() } } }
    @Published var chromeScheme: ColorScheme = .light
    private var appearanceObservation: NSKeyValueObservation?

    init() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateContrast()
                self?.bridge?.updateAppearance()
            }
        }
        updateContrast()
    }

    private var photoSample: NSBitmapImageRep?
    @Published var wallpaper: NSImage?
    var photoPath = ""
    private var loadedPhotoVersion: UInt64?
    weak var bridge: ChromeBridge?
    var windowID: UInt64 = 0
    var editingAddress = false
    var callback: (@convention(c) (UnsafePointer<CChar>?) -> Void)?

    var activeTab: TabInfo? { snapshot?.tabs.first { $0.id == snapshot?.active } }
    var activeWorkspace: WorkspaceInfo? { snapshot?.workspaces.first { $0.id == snapshot?.active_workspace } }

    func update(_ json: String) {
        guard let data = json.data(using: .utf8),
              let next = try? JSONDecoder().decode(ChromeSnapshot.self, from: data) else { return }
        let cropChanged = snapshot?.photo_focus_x != next.photo_focus_x || snapshot?.photo_focus_y != next.photo_focus_y
        let photoChanged = next.photo_version != loadedPhotoVersion
        let themeChanged = snapshot?.site_color != next.site_color || snapshot?.settings.appearance != next.settings.appearance
        let nextWidth = CGFloat(next.sidebar_width ?? 220)
        if sidebarWidth != nextWidth { sidebarWidth = nextWidth }
        snapshot = next
        if paletteMode != nil { rebuildPalette(reset: false) }
        if next.photo_version != loadedPhotoVersion {
            loadedPhotoVersion = next.photo_version
            wallpaper = next.has_photo ? NSImage(contentsOfFile: photoPath) : nil
            photoSample = wallpaper.flatMap(makePhotoSample)
        }
        if photoChanged || cropChanged || themeChanged { updateContrast() }
        if !editingAddress {
            let nextAddress = activeTab?.url == "about:blank" ? "" : activeTab?.url ?? ""
            if address != nextAddress { address = nextAddress }
        }
    }

    var chromeInk: Color { chromeScheme == .dark ? .white : Color(white: 0.08) }
    var chromeMuted: Color { chromeScheme == .dark ? .white : Color(white: 0.18) }

    var wallpaperVisible: Bool {
        wallpaper != nil
    }

    var siteColor: Color? {
        guard wallpaperVisible, let rgb = siteRGB,
              (rgb.max() ?? 0) - (rgb.min() ?? 0) > 0.08 else { return nil }
        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    private var siteRGB: [Double]? {
        guard matchSiteColors, let rgb = snapshot?.site_color, rgb.count == 3 else { return nil }
        return rgb.map { Double($0) / 255 }
    }

    private func updateContrast() {
        guard wallpaperVisible else {
            chromeScheme = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
            return
        }
        if snapshot?.settings.appearance == "dark" { chromeScheme = .dark; return }
        if snapshot?.settings.appearance == "light" { chromeScheme = .light; return }
        guard let sample = photoSample, let wallpaper else {
            chromeScheme = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
            return
        }
        let frame = wallpaperFrame(image: wallpaper.size, window: windowSize,
                                   focusX: CGFloat(snapshot?.photo_focus_x ?? 50),
                                   focusY: CGFloat(snapshot?.photo_focus_y ?? 50))
        var luminance = 0.0
        var count = 0.0
        // Sample only the chrome, using the same crop as the rendered photo.
        for y in 0..<32 {
            for x in 0..<32 {
                let point = CGPoint(x: (CGFloat(x) + 0.5) * windowSize.width / 32,
                                    y: (CGFloat(y) + 0.5) * windowSize.height / 32)
                guard point.x < sidebarWidth || point.y < toolbarHeight else { continue }
                let px = min(31, max(0, Int((point.x - frame.minX) / frame.width * 32)))
                let py = min(31, max(0, Int((point.y - frame.minY) / frame.height * 32)))
                if let color = sample.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) {
                    luminance += relativeLuminance(color.redComponent, color.greenComponent, color.blueComponent)
                    count += 1
                }
            }
        }
        chromeScheme = count > 0 && luminance / count < 0.35 ? .dark : .light
    }

    func switchAdjacentWorkspace(_ direction: Int) {
        guard let snapshot,
              let index = snapshot.workspaces.firstIndex(where: { $0.id == snapshot.active_workspace }),
              snapshot.workspaces.indices.contains(index + direction) else { return }
        send("switch_workspace", ["id": snapshot.workspaces[index + direction].id])
    }

    func send(_ type: String, _ values: [String: Any] = [:]) {
        guard let callback else { return }
        var message = values
        message["type"] = type
        message["window_id"] = windowID
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        text.withCString { callback($0) }
    }

    func focusAddress() { addressFocus += 1 }
    func showSwitcher() {
        showPalette(.switcher)
    }
    func showNewTab() { showPalette(.newTab) }
    func showPalette(_ mode: PaletteMode) {
        paletteQuery = ""
        paletteMode = mode
        rebuildPalette(reset: true)
        bridge?.setPaletteVisible(true)
        DispatchQueue.main.async { self.paletteFocus += 1 }
    }
    func closePalette() {
        paletteMode = nil
        bridge?.setPaletteVisible(false)
    }
    func rebuildPalette(reset: Bool) {
        guard let snapshot else { return }
        let selectedID = paletteResults.indices.contains(paletteSelection) ? paletteResults[paletteSelection].id : nil
        paletteResults = PaletteSearch.results(snapshot: snapshot, query: paletteQuery, newTab: paletteMode == .newTab)
        paletteSelection = reset ? 0 : (paletteResults.firstIndex { $0.id == selectedID } ?? 0)
    }
    func movePalette(_ direction: Int) {
        guard !paletteResults.isEmpty else { return }
        paletteSelection = (paletteSelection + direction + paletteResults.count) % paletteResults.count
    }
    func submitPalette(_ result: PaletteResult? = nil) {
        guard let item = result ?? (paletteResults.indices.contains(paletteSelection) ? paletteResults[paletteSelection] : nil) else { return }
        closePalette()
        send(item.command, item.values)
    }
    func choosePhoto() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic]
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        picker.prompt = "Use Photo"
        picker.begin { response in
            if response == .OK, let url = picker.url {
                self.send("set_new_tab_photo", ["path": url.path])
            }
        }
    }
}

enum PaletteMode: Equatable { case newTab, switcher }

private struct SymbolButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let symbol: String
    let label: String
    var enabled = true
    var size: CGFloat = 30
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: size, height: size)
                .glassEffect(.regular.interactive(enabled), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle((colorScheme == .dark ? Color.white : Color(white: 0.08)).opacity(enabled ? 1 : 0.4))
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

// Shared crop math keeps every part of the chrome in window coordinates.
func wallpaperFrame(image: CGSize, window: CGSize, focusX: CGFloat, focusY: CGFloat) -> CGRect {
    let scale = max(window.width / max(image.width, 1), window.height / max(image.height, 1))
    let width = image.width * scale
    let height = image.height * scale
    return CGRect(x: -(width - window.width) * min(100, max(0, focusX)) / 100,
                  y: -(height - window.height) * min(100, max(0, focusY)) / 100,
                  width: width, height: height)
}

func relativeLuminance(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> Double {
    func linear(_ value: CGFloat) -> Double {
        let value = Double(value)
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
}

private func makePhotoSample(_ image: NSImage) -> NSBitmapImageRep? {
    guard let sample = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: sample) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 32, height: 32).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
    NSGraphicsContext.restoreGraphicsState()
    return sample
}

private struct ChromeShape: Shape {
    var sidebarWidth: CGFloat
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addRect(CGRect(x: 0, y: 0, width: sidebarWidth, height: rect.height))
            path.addRect(CGRect(x: sidebarWidth, y: 0, width: max(0, rect.width - sidebarWidth), height: toolbarHeight))
        }
    }
}

private struct ChromeSurface: View {
    @ObservedObject var model: ChromeModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image = model.wallpaper {
                let frame = wallpaperFrame(image: image.size, window: model.windowSize,
                                           focusX: CGFloat(model.snapshot?.photo_focus_x ?? 50),
                                           focusY: CGFloat(model.snapshot?.photo_focus_y ?? 50))
                ZStack(alignment: .topLeading) {
                    Image(nsImage: image).resizable()
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
                .frame(width: model.windowSize.width, height: model.windowSize.height, alignment: .topLeading)
                .blur(radius: 22, opaque: true)
                .overlay(model.chromeScheme == .dark ? Color.black.opacity(0.16) : Color.white.opacity(0.10))
                .clipShape(ChromeShape(sidebarWidth: model.sidebarWidth))
                .allowsHitTesting(false)
            }
            if !model.wallpaperVisible {
                ChromeShape(sidebarWidth: model.sidebarWidth).fill(model.chromeScheme == .dark ? Color.black : Color.white).allowsHitTesting(false)
            }
            if let color = model.siteColor {
                // Keep the original frosted photo visible; tint only the chrome.
                ChromeShape(sidebarWidth: model.sidebarWidth)
                    .fill(LinearGradient(colors: [color.opacity(0.14), color.opacity(0.025)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .allowsHitTesting(false)
            }
            GlassEffectContainer(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    SidebarView(model: model).frame(width: model.sidebarWidth)
                    ToolbarView(model: model).frame(height: toolbarHeight)
                }
            }
        }
        .environment(\.colorScheme, model.chromeScheme)
    }
}

// The full-window host must let clicks reach the shell beneath the content area.
private final class ChromeHostingView: NSHostingView<ChromeSurface> {
    private var sidebarWidth: CGFloat { rootView.model.sidebarWidth }
    private var horizontalScroll: CGFloat = 0
    private var switchedDuringGesture = false
    private var scrollMonitor: Any?
    private var resizingSidebar = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        guard window != nil else { return }
        // Observe before child scroll views consume the gesture.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleWorkspaceScroll(event) ? nil : event
        }
    }

    deinit {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    private func handleWorkspaceScroll(_ event: NSEvent) -> Bool {
        if event.phase.contains(.began) {
            horizontalScroll = 0
            switchedDuringGesture = false
        }
        let local = convert(event.locationInWindow, from: nil)
        guard rootView.model.swipeWorkspaces,
              rootView.model.paletteMode == nil,
              bounds.contains(local), local.x < sidebarWidth,
              event.hasPreciseScrollingDeltas,
              !event.phase.isEmpty,
              event.momentumPhase.isEmpty,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return false }
        horizontalScroll += event.scrollingDeltaX
        if !switchedDuringGesture && abs(horizontalScroll) >= 40 {
            rootView.model.switchAdjacentWorkspace(horizontalScroll > 0 ? -1 : 1)
            switchedDuringGesture = true
        }
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(NSRect(x: sidebarWidth - 4, y: 0, width: 8, height: bounds.height), cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        resizingSidebar = abs(local.x - sidebarWidth) <= 4
        if !resizingSidebar { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard resizingSidebar else { super.mouseDragged(with: event); return }
        let width = min(360, max(180, convert(event.locationInWindow, from: nil).x))
        rootView.model.send("set_sidebar_width", ["width": Int(width)])
    }

    override func mouseUp(with event: NSEvent) {
        if resizingSidebar {
            resizingSidebar = false
            window?.invalidateCursorRects(for: self)
        } else { super.mouseUp(with: event) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if abs(local.x - sidebarWidth) <= 4 { return self }
        let top = isFlipped ? local.y : bounds.height - local.y
        if local.x >= sidebarWidth && top >= toolbarHeight { return nil }
        return super.hitTest(point)
    }
}

private struct TabRow: View {
    @ObservedObject var model: ChromeModel
    let tab: TabInfo
    @State private var hovering = false

    private var selected: Bool { tab.id == model.snapshot?.active }

    var body: some View {
        HStack(spacing: 0) {
            Button { model.send("switch_tab", ["id": tab.id]) } label: {
                HStack(spacing: 10) {
                    AsyncImage(url: tab.favicon.flatMap(URL.init(string:))) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else {
                            Image(systemName: tab.sleeping ? "moon.zzz" : tab.url == "about:blank" ? "square.dashed" : "globe")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(model.chromeMuted)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                    Text(tab.title.isEmpty ? "New Tab" : tab.title)
                        .foregroundStyle(model.chromeInk)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if tab.playing || tab.media_suspended {
                        Image(systemName: tab.media_suspended ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 10)).frame(width: 18, height: 22)
                            .accessibilityLabel(tab.media_suspended ? "Media suspended" : "Media playing")
                    }
                    if tab.keep_awake {
                        Image(systemName: "bolt.fill").font(.system(size: 8)).help("Kept awake")
                    }
                    if tab.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(model.chromeMuted)
                            .accessibilityLabel("Pinned")
                    }
                    Spacer(minLength: 4)
                    if tab.loading { ProgressView().controlSize(.mini) }
                }
                .padding(.horizontal, 10)
                .padding(.trailing, 22)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.sleeping ? "Sleeping tab — reloads when opened" : tab.url)
            .overlay(alignment: .trailing) {
                Button { model.send("close_tab", ["id": tab.id]) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(model.chromeMuted)
                        .frame(width: 20, height: 20)
                        .background(hovering || selected ? Color.white.opacity(0.16) : .clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(selected || hovering ? 1 : 0)
                .allowsHitTesting(selected || hovering)
                .help("Close Tab")
                .accessibilityLabel("Close " + tab.title)
                .padding(.trailing, 6)
            }
        }
        .frame(height: 32)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(tab.pinned ? "Unpin Tab" : "Pin Tab") { model.send("toggle_pin", ["id": tab.id]) }
            Button(tab.keep_awake ? "Allow Tab to Sleep" : "Keep Tab Awake") { model.send("toggle_keep_awake", ["id": tab.id]) }
            Button(tab.media_suspended ? "Resume Media" : "Suspend Media") { model.send("toggle_media", ["id": tab.id]) }
            Button("Duplicate Tab") { model.send("duplicate_tab", ["id": tab.id]) }
            Button("Close Other Tabs") { model.send("close_other_tabs", ["id": tab.id]) }
            Button("Open Beside Current Tab") { model.send("split_tab", ["id": tab.id]) }
            Button("Move Up") {
                let tabs = model.snapshot?.tabs.filter { $0.workspace == tab.workspace } ?? []
                if let index = tabs.firstIndex(where: { $0.id == tab.id }), index > 0 {
                    model.send("reorder_tab", ["id": tab.id, "before": tabs[index - 1].id])
                }
            }
            Button("Close Tab") { model.send("close_tab", ["id": tab.id]) }
            Menu("Move to Workspace") {
                ForEach(model.snapshot?.workspaces.filter { $0.id != tab.workspace } ?? []) { workspace in
                    Button(workspace.name) { model.send("move_tab", ["id": tab.id, "workspace": workspace.id]) }
                }
            }
        }
        .draggable(String(tab.id))
        .dropDestination(for: String.self) { ids, _ in
            guard let value = ids.first, let id = UInt64(value), id != tab.id else { return false }
            model.send("reorder_tab", ["id": id, "before": tab.id]); return true
        }
    }

    // Rows share the panel's glass surface; only selection and hover read as filled.
    @ViewBuilder private var rowBackground: some View {
        if selected {
            Capsule().fill(model.chromeInk.opacity(0.13))
        } else if hovering {
            Capsule().fill(model.chromeInk.opacity(0.07))
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var model: ChromeModel

    private var workspaceTabs: [TabInfo] {
        guard let snapshot = model.snapshot else { return [] }
        return snapshot.tabs.filter { $0.workspace == snapshot.active_workspace }.sorted { $0.pinned && !$1.pinned }
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(workspaceTabs.enumerated()), id: \.element.id) { index, tab in
                            if index > 0 && workspaceTabs[index - 1].pinned && !tab.pinned {
                                Divider().padding(.horizontal, 12).padding(.vertical, 5)
                            }
                            TabRow(model: model, tab: tab)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }

                workspaceSwitcher
                    .padding(.horizontal, 10)
                    .padding(.bottom, 14)
                Spacer().frame(height: 16)
            }
        }
        .foregroundStyle(model.chromeInk)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Rename Workspace", isPresented: $model.renamingWorkspace) {
            TextField("Name", text: $model.workspaceName)
            Button("Rename") { model.send("rename_workspace", ["name": model.workspaceName]) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var workspaceSwitcher: some View {
        HStack(spacing: 10) {
            Menu {
                if model.snapshot?.private_mode == true { Text("Private Window — browsing is not saved") }
                Button("Settings…") { model.send("settings") }
                Button("New Window") { model.send("new_window", ["private": false]) }
                Button("New Private Window") { model.send("new_window", ["private": true]) }
                Button("Close Split View") { model.send("close_split") }
                Button("New Tab") { model.showNewTab() }
                Divider()
                ForEach(model.snapshot?.workspaces ?? []) { workspace in
                    Button(workspace.name) { model.send("switch_workspace", ["id": workspace.id]) }
                }
                Toggle("Swipe to switch workspaces", isOn: $model.swipeWorkspaces)
                Toggle("Website color highlights", isOn: $model.matchSiteColors)
                Button(model.customizingWallpaper ? "Hide wallpaper controls" : "Customize wallpaper") {
                    model.customizingWallpaper.toggle()
                    model.bridge?.updatePhotoControls()
                }
                Button("Project Preset…") { model.send("project_settings") }
                Button("Open Project") { model.send("open_project") }
                Button("New Workspace") { model.send("new_workspace") }
                Button("Rename Workspace") {
                    model.workspaceName = model.activeWorkspace?.name ?? ""
                    model.renamingWorkspace = true
                }
                Divider()
                Button("Bookmarks") { model.send("show_panel", ["panel": "bookmarks"]) }
                Button("History") { model.send("show_panel", ["panel": "history"]) }
                Button("Downloads") { model.send("show_panel", ["panel": "downloads"]) }
            } label: {
                HStack(spacing: 7) {
                    Circle().frame(width: 5, height: 5)
                    Text(model.activeWorkspace?.name ?? "Workspace").font(.system(size: 11)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }.padding(.horizontal, 9).frame(height: 30)
                    .glassEffect(.regular.interactive(), in: Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Workspace and browser actions")
            .accessibilityLabel("Workspace and browser actions")
            Spacer(minLength: 4)
            SymbolButton(symbol: "plus", label: "New Tab (⌘T)") { model.showNewTab() }
        }
    }

}

private struct ToolbarView: View {
    @ObservedObject var model: ChromeModel
    @FocusState private var addressFocused: Bool

    var body: some View {
        GlassEffectContainer(spacing: 10) {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                SymbolButton(symbol: "chevron.left", label: "Back (⌘[)", enabled: model.snapshot?.can_go_back ?? false) { model.send("back") }
                SymbolButton(symbol: "chevron.right", label: "Forward (⌘])", enabled: model.snapshot?.can_go_forward ?? false) { model.send("forward") }
                SymbolButton(symbol: "arrow.clockwise", label: "Reload (⌘R)") { model.send("reload") }
            }
            Spacer(minLength: 8)

            HStack(spacing: 10) {
                Image(systemName: model.address.hasPrefix("https://") ? "lock" : "globe")
                    .font(.system(size: 12)).foregroundStyle(model.chromeMuted)
                    .frame(width: 28)
                TextField("Search or enter an address", text: Binding(
                    get: { addressFocused ? model.address : developerAddress(model.address) },
                    set: { model.address = $0 }
                ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .focused($addressFocused)
                    .onSubmit {
                        model.send("navigate", ["value": model.address])
                        addressFocused = false
                    }
                    .onChange(of: addressFocused) { _, focused in model.editingAddress = focused }
                Text("⌘ L")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(model.chromeMuted)
                    .opacity(model.address.isEmpty ? 1 : 0)
                    .frame(width: 28)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 15)
            .frame(maxWidth: 600)
            .frame(height: 30)
            .glassEffect(.regular.interactive(), in: Capsule())
            Spacer(minLength: 8)

            HStack(spacing: 10) {
                DeveloperMenu(model: model)
                SymbolButton(symbol: model.snapshot?.bookmarked == true ? "star.fill" : "star", label: "Bookmark (⌘D)") { model.send("toggle_bookmark") }
                SymbolButton(symbol: "magnifyingglass", label: "Quick Switch (⌘K)") { model.showSwitcher() }
            }
        }
        .padding(.horizontal, 17)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(model.chromeInk)
        .clipped()
        .onChange(of: model.addressFocus) { _, _ in addressFocused = true }
        }
    }
}

private struct CommandPalette: View {
    @ObservedObject var model: ChromeModel
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.paletteMode == .newTab ? "Search, enter a URL, or run an action" : "Tabs, history, bookmarks, and actions", text: $model.paletteQuery)
                    .textFieldStyle(.plain).font(.system(size: 17)).focused($searchFocused)
                    .onSubmit { model.submitPalette() }
                    .onKeyPress(.upArrow) { model.movePalette(-1); return .handled }
                    .onKeyPress(.downArrow) { model.movePalette(1); return .handled }
                Text("esc").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(20)
            Divider().padding(.horizontal, 16)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.paletteResults.enumerated()), id: \.element.id) { index, result in
                            Button { model.submitPalette(result) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: result.symbol).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(result.title).lineLimit(1).font(.system(size: 13, weight: .medium))
                                        Text(result.subtitle).lineLimit(1).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Text(index == model.paletteSelection ? "↵" : result.shortcut)
                                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                }.padding(.horizontal, 14).frame(height: 52).contentShape(Rectangle())
                                    .background(index == model.paletteSelection ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).id(result.id)
                            .accessibilityAddTraits(index == model.paletteSelection ? .isSelected : [])
                        }
                    }.padding(.horizontal, 10).padding(.vertical, 8)
                }.frame(height: CGFloat(min(6, model.paletteResults.count)) * 54 + 16)
                    .onChange(of: model.paletteSelection) { _, index in
                        if model.paletteResults.indices.contains(index) { proxy.scrollTo(model.paletteResults[index].id) }
                    }
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        .onChange(of: model.paletteFocus) { _, _ in searchFocused = true }
        .onExitCommand { model.closePalette() }
    }
}

private struct PaletteOverlay: View {
    @ObservedObject var model: ChromeModel
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.16).ignoresSafeArea()
                    .onTapGesture { model.closePalette() }
                CommandPalette(model: model)
                    .frame(width: min(560, max(1, geometry.size.width - 32)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct PhotoControls: View {
    @ObservedObject var model: ChromeModel
    @State private var positioning = false

    var body: some View {
        HStack(spacing: 0) {
            photoButton(
                symbol: model.snapshot?.has_photo == true ? "photo.badge.arrow.down" : "photo.badge.plus",
                label: model.snapshot?.has_photo == true ? "Change new tab photo" : "Choose new tab photo"
            ) { model.choosePhoto() }
            if model.snapshot?.has_photo == true {
                photoButton(symbol: "slider.horizontal.3", label: "Position new tab photo") {
                    positioning = true
                }
                .popover(isPresented: $positioning) { PhotoPositionEditor(model: model) }
                photoButton(symbol: "xmark", label: "Remove new tab photo") {
                    model.send("remove_new_tab_photo")
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .glassEffect(.regular.tint(.white.opacity(0.08)).interactive(), in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    private func photoButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct PhotoPositionEditor: View {
    @ObservedObject var model: ChromeModel
    @State private var horizontal: Double
    @State private var vertical: Double

    init(model: ChromeModel) {
        self.model = model
        _horizontal = State(initialValue: Double(model.snapshot?.photo_focus_x ?? 50))
        _vertical = State(initialValue: Double(model.snapshot?.photo_focus_y ?? 50))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Position photo")
                .font(.system(size: 15, weight: .semibold))
            HStack {
                Text("Horizontal").frame(width: 72, alignment: .leading)
                Slider(value: $horizontal, in: 0...100, step: 1)
            }
            HStack {
                Text("Vertical").frame(width: 72, alignment: .leading)
                Slider(value: $vertical, in: 0...100, step: 1)
            }
            Button("Center photo") {
                horizontal = 50
                vertical = 50
            }
            .buttonStyle(.glass)
        }
        .padding(18)
        .frame(width: 290)
        .onChange(of: horizontal) { _, _ in sendPosition() }
        .onChange(of: vertical) { _, _ in sendPosition() }
    }

    private func sendPosition() {
        model.send("set_photo_position", ["x": Int(horizontal), "y": Int(vertical)])
    }
}

@MainActor final class ChromeBridge {
    static var instances: [UInt64: ChromeBridge] = [:]
    static func instance(_ id: UInt64) -> ChromeBridge { instances[id]! }
    let model = ChromeModel()
    var parent: NSView?
    private var chrome: ChromeHostingView?
    private var palette: NSHostingView<PaletteOverlay>?
    private var photoControls: NSHostingView<PhotoControls>?
    private var escapeMonitor: Any?
    private var developerOverlay: DeveloperHostingView?

    deinit { if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) } }

    func install(_ parent: NSView, callback: @escaping @convention(c) (UnsafePointer<CChar>?) -> Void, photoPath: String) {
        self.parent = parent
        model.bridge = self
        model.callback = callback
        model.photoPath = photoPath
        let chrome = ChromeHostingView(rootView: ChromeSurface(model: model))
        let palette = NSHostingView(rootView: PaletteOverlay(model: model))
        let photoControls = NSHostingView(rootView: PhotoControls(model: model))
        parent.window?.appearance = nil
        chrome.autoresizingMask = []
        palette.autoresizingMask = []
        photoControls.autoresizingMask = []
        parent.addSubview(chrome)
        parent.addSubview(palette)
        parent.addSubview(photoControls)
        let developerOverlay = DeveloperHostingView(rootView: DeveloperOverlay(model: model))
        developerOverlay.model = model
        parent.addSubview(developerOverlay)
        self.developerOverlay = developerOverlay
        palette.isHidden = true
        photoControls.isHidden = true
        self.chrome = chrome
        self.palette = palette
        self.photoControls = photoControls
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window == self.parent?.window, self.model.paletteMode != nil, event.keyCode == 53 else { return event }
                self.model.closePalette()
                return nil
            }
        }
        resize(parent.bounds.width, parent.bounds.height)
    }

    func updateAppearance() {
        let preference = model.wallpaperVisible ? (model.snapshot?.settings.appearance ?? "system") : "system"
        parent?.window?.appearance = preference == "system" ? nil : NSAppearance(named: preference == "dark" ? .darkAqua : .aqua)
        chrome?.appearance = NSAppearance(named: model.chromeScheme == .dark ? .darkAqua : .aqua)
    }
    func resize(_ width: CGFloat, _ height: CGFloat) {
        guard let parent else { return }
        let nextSize = CGSize(width: width, height: height)
        if model.windowSize != nextSize { model.windowSize = nextSize }
        chrome?.frame = parent.bounds
        chrome?.appearance = NSAppearance(named: model.chromeScheme == .dark ? .darkAqua : .aqua)
        developerOverlay?.frame = parent.bounds
        BrowserFeatures.layoutFind(model.windowID)
        palette?.frame = parent.bounds
        photoControls?.frame = CGRect(x: max(model.sidebarWidth, width - 130), y: parent.isFlipped ? height - 62 : 22, width: 108, height: 40)
    }

    func setPaletteVisible(_ visible: Bool) {
        guard let parent, let palette else { return }
        if visible {
            palette.removeFromSuperview()
            parent.addSubview(palette, positioned: .above, relativeTo: nil)
            palette.frame = parent.bounds
        }
        palette.isHidden = !visible
    }

    func raiseDeveloperOverlay() {
        guard let parent, let developerOverlay else { return }
        parent.addSubview(developerOverlay, positioned: .above, relativeTo: nil)
        BrowserFeatures.layoutFind(model.windowID)
        if model.paletteMode != nil, let palette { parent.addSubview(palette, positioned: .above, relativeTo: nil) }
    }
    func updatePhotoControls() {
        guard let parent, let photoControls else { return }
        let show = model.snapshot?.private_mode != true && model.customizingWallpaper && model.activeTab?.url == "about:blank" && model.snapshot?.panel == nil
        if show && photoControls.isHidden {
            photoControls.removeFromSuperview()
            parent.addSubview(photoControls, positioned: .above, relativeTo: nil)
        }
        photoControls.isHidden = !show
    }
}


@_cdecl("moth_install_chrome")
func moth_install_chrome(_ id: UInt64, _ parent: UnsafeMutableRawPointer?, _ callback: @escaping @convention(c) (UnsafePointer<CChar>?) -> Void, _ photoPath: UnsafePointer<CChar>?) {
    guard let parent else { return }
    MainActor.assumeIsolated {
        let bridge = ChromeBridge()
        bridge.model.windowID = id
        ChromeBridge.instances[id] = bridge
        bridge.install(Unmanaged<NSView>.fromOpaque(parent).takeUnretainedValue(), callback: callback, photoPath: photoPath.map(String.init(cString:)) ?? "")
    }
}
@_cdecl("moth_remove_chrome")
func moth_remove_chrome(_ id: UInt64) {
    MainActor.assumeIsolated { BrowserFeatures.removeWindow(id); ChromeBridge.instances.removeValue(forKey: id) }
}
@_cdecl("moth_resize_chrome")
func moth_resize_chrome(_ id: UInt64, _ width: Double, _ height: Double) {
    MainActor.assumeIsolated { ChromeBridge.instance(id).resize(width, height) }
}
@_cdecl("moth_update_chrome")
func moth_update_chrome(_ id: UInt64, _ json: UnsafePointer<CChar>?) {
    guard let json else { return }
    let text = String(cString: json)
    MainActor.assumeIsolated {
        let bridge = ChromeBridge.instance(id)
        bridge.model.update(text)
        bridge.updateAppearance()
        bridge.updatePhotoControls()
        bridge.raiseDeveloperOverlay()
        BrowserFeatures.update(id, model: bridge.model)
    }
}
@_cdecl("moth_focus_address")
func moth_focus_address(_ id: UInt64) {
    MainActor.assumeIsolated { ChromeBridge.instance(id).model.focusAddress() }
}
@_cdecl("moth_focus_switcher")
func moth_focus_switcher(_ id: UInt64) {
    MainActor.assumeIsolated { ChromeBridge.instance(id).model.showSwitcher() }
}
@_cdecl("moth_focus_new_tab")
func moth_focus_new_tab(_ id: UInt64) {
    MainActor.assumeIsolated { ChromeBridge.instance(id).model.showNewTab() }
}
