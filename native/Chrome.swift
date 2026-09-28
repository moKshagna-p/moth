import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let toolbarHeight: CGFloat = 50
private let ink = Color(red: 0.16, green: 0.18, blue: 0.16)
private let muted = Color(red: 0.44, green: 0.47, blue: 0.43)
private let accent = Color(red: 0.29, green: 0.39, blue: 0.31)
private let sidebarColor = Color(red: 0.92, green: 0.93, blue: 0.90)
private let toolbarColor = Color(red: 0.97, green: 0.97, blue: 0.95)

private struct TabInfo: Decodable, Identifiable {
    let id: UInt64
    let url: String
    let title: String
    let loading: Bool
    let sleeping: Bool
    let workspace: UInt64
}

private struct WorkspaceInfo: Decodable, Identifiable {
    let id: UInt64
    let name: String
}

private struct ChromeSnapshot: Decodable {
    let tabs: [TabInfo]
    let workspaces: [WorkspaceInfo]
    let active: UInt64
    let active_workspace: UInt64
    let panel: String?
    let bookmarked: Bool
    let can_go_back: Bool
    let can_go_forward: Bool
    let has_photo: Bool
    let photo_version: UInt64
    let photo_focus_x: UInt8
    let photo_focus_y: UInt8
    let sidebar_width: UInt16?
}

@MainActor private final class ChromeModel: ObservableObject {
    @Published var snapshot: ChromeSnapshot?
    @Published var swipeWorkspaces = UserDefaults.standard.object(forKey: "swipeWorkspaces") as? Bool ?? true {
        didSet { UserDefaults.standard.set(swipeWorkspaces, forKey: "swipeWorkspaces") }
    }
    @Published var customizingWallpaper = false
    @Published var sidebarWidth: CGFloat = 220
    @Published var address = ""
    @Published var addressFocus = 0
    @Published var paletteMode: PaletteMode?
    @Published var paletteFocus = 0
    @Published var paletteQuery = ""
    @Published var renamingWorkspace = false
    @Published var workspaceName = ""
    @Published var windowSize = CGSize(width: 1000, height: 768) { didSet { updateContrast() } }
    @Published var chromeScheme: ColorScheme = .light
    private var photoSample: NSBitmapImageRep?
    @Published var wallpaper: NSImage?
    var photoPath = ""
    private var loadedPhotoVersion: UInt64?
    var editingAddress = false
    var callback: (@convention(c) (UnsafePointer<CChar>?) -> Void)?

    var activeTab: TabInfo? { snapshot?.tabs.first { $0.id == snapshot?.active } }
    var activeWorkspace: WorkspaceInfo? { snapshot?.workspaces.first { $0.id == snapshot?.active_workspace } }

    func update(_ json: String) {
        guard let data = json.data(using: .utf8),
              let next = try? JSONDecoder().decode(ChromeSnapshot.self, from: data) else { return }
        let cropChanged = snapshot?.photo_focus_x != next.photo_focus_x || snapshot?.photo_focus_y != next.photo_focus_y
        let photoChanged = next.photo_version != loadedPhotoVersion
        sidebarWidth = CGFloat(next.sidebar_width ?? 220)
        snapshot = next
        if next.photo_version != loadedPhotoVersion {
            loadedPhotoVersion = next.photo_version
            wallpaper = next.has_photo ? NSImage(contentsOfFile: photoPath) : nil
            photoSample = wallpaper.flatMap(makePhotoSample)
        }
        if photoChanged || cropChanged { updateContrast() }
        if !editingAddress { address = activeTab?.url == "about:blank" ? "" : activeTab?.url ?? "" }
    }

    var chromeInk: Color { chromeScheme == .dark ? .white : Color(white: 0.08) }
    var chromeMuted: Color { chromeScheme == .dark ? .white : Color(white: 0.18) }

    var wallpaperVisible: Bool {
        wallpaper != nil
    }

    private func updateContrast() {
        guard let sample = photoSample, let wallpaper else {
            chromeScheme = .light
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
        ChromeBridge.shared.setPaletteVisible(true)
        DispatchQueue.main.async { self.paletteFocus += 1 }
    }
    func closePalette() {
        paletteMode = nil
        ChromeBridge.shared.setPaletteVisible(false)
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

private enum PaletteMode: Equatable { case newTab, switcher }

private struct SymbolButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let symbol: String
    let label: String
    var enabled = true
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 30)
                .glassEffect(hovering && enabled ? .regular.interactive() : .identity, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle((colorScheme == .dark ? Color.white : Color(white: 0.08)).opacity(enabled ? 1 : 0.4))
        .onHover { hovering = $0 }
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
                ChromeShape(sidebarWidth: model.sidebarWidth).fill(toolbarColor).allowsHitTesting(false)
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

private struct SidebarView: View {
    @ObservedObject var model: ChromeModel

    private var workspaceTabs: [TabInfo] {
        guard let snapshot = model.snapshot else { return [] }
        return snapshot.tabs.filter { $0.workspace == snapshot.active_workspace }
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(workspaceTabs) { tab in
                            tabRow(tab)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
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

    private func tabRow(_ tab: TabInfo) -> some View {
        let selected = tab.id == model.snapshot?.active
        let row = HStack(spacing: 10) {
            Button { model.send("switch_tab", ["id": tab.id]) } label: {
                HStack(spacing: 11) {
                    Image(systemName: tab.sleeping ? "moon.zzz" : tab.url == "about:blank" ? "square.dashed" : "globe")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(model.chromeInk)
                        .frame(width: 17)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tab.title.isEmpty ? "New Tab" : tab.title)
                            .foregroundStyle(model.chromeInk)
                            .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if tab.loading { ProgressView().controlSize(.mini) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.sleeping ? "Sleeping tab — reloads when opened" : tab.url)
            Button { model.send("close_tab", ["id": tab.id]) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.chromeMuted)
            .opacity(0.85)
            .help("Close Tab")
            .padding(.trailing, 6)
        }
        .contextMenu {
            Button("Close Tab") { model.send("close_tab", ["id": tab.id]) }
            Menu("Move to Workspace") {
                ForEach(model.snapshot?.workspaces.filter { $0.id != tab.workspace } ?? []) { workspace in
                    Button(workspace.name) { model.send("move_tab", ["id": tab.id, "workspace": workspace.id]) }
                }
            }
        }
        return row.glassEffect(selected ? .regular.interactive() : .identity, in: Capsule())
    }

    private var workspaceSwitcher: some View {
        HStack(spacing: 10) {
            Menu {
                Button("New Tab") { model.showNewTab() }
                Divider()
                ForEach(model.snapshot?.workspaces ?? []) { workspace in
                    Button(workspace.name) { model.send("switch_workspace", ["id": workspace.id]) }
                }
                Toggle("Swipe to switch workspaces", isOn: $model.swipeWorkspaces)
                Button(model.customizingWallpaper ? "Hide wallpaper controls" : "Customize wallpaper") {
                    model.customizingWallpaper.toggle()
                    ChromeBridge.shared.updatePhotoControls()
                }
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
                }.frame(height: 30)
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
                    get: { addressFocused ? model.address : (URL(string: model.address)?.host ?? model.address) },
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

private struct CommandPalette: View {
    @ObservedObject var model: ChromeModel
    @FocusState private var searchFocused: Bool

    private var matches: [TabInfo] {
        guard let tabs = model.snapshot?.tabs else { return [] }
        if model.paletteQuery.isEmpty { return model.paletteMode == .switcher ? tabs : [] }
        return tabs.filter { ($0.title + " " + $0.url).localizedCaseInsensitiveContains(model.paletteQuery) }
    }

    private var paletteHeight: CGFloat {
        let visibleMatches = min(matches.count, 5)
        let actionHeight: CGFloat = model.paletteMode == .newTab ? 49 : 0
        return 60 + actionHeight + CGFloat(visibleMatches) * 54 + (visibleMatches > 0 ? 16 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.paletteMode == .newTab ? "Search or enter a URL" : "Switch to a tab", text: $model.paletteQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($searchFocused)
                    .onSubmit { submit() }
                Text("esc").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .padding(20)
            if model.paletteMode == .newTab && model.paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    model.send("open_blank_tab")
                    model.closePalette()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus").frame(width: 20)
                        Text("Blank tab")
                        Spacer()
                        Text("↵").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 18).frame(height: 49)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if model.paletteMode == .newTab && !model.paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { openQuery() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.left").frame(width: 20)
                        Text(model.paletteQuery).lineLimit(1)
                        Spacer()
                        Text("Open in new tab").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 18).frame(height: 49)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !matches.isEmpty {
                Divider().padding(.horizontal, 16)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches) { tab in
                            Button { select(tab) } label: {
                                HStack(spacing: 13) {
                                    Image(systemName: "globe").frame(width: 20)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(tab.title).lineLimit(1).font(.system(size: 13, weight: .medium))
                                        Text(tab.url).lineLimit(1).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(model.snapshot?.workspaces.first { $0.id == tab.workspace }?.name ?? "")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 14).frame(height: 52).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
        }
        .frame(height: paletteHeight)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        .onChange(of: model.paletteFocus) { _, _ in searchFocused = true }
        .onExitCommand { model.closePalette() }
    }

    private func select(_ tab: TabInfo) {
        model.send("switch_tab", ["id": tab.id])
        model.closePalette()
    }

    private func submit() {
        if model.paletteMode == .newTab { openQuery() }
        else if let first = matches.first { select(first) }
    }

    private func openQuery() {
        let value = model.paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            model.send("open_blank_tab")
            model.closePalette()
            return
        }
        model.send("open_new_tab", ["value": value])
        model.closePalette()
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
        HStack(spacing: 2) {
            Button { model.choosePhoto() } label: {
                Image(systemName: model.snapshot?.has_photo == true ? "photo.badge.arrow.down" : "photo.badge.plus")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 38, height: 38)
            }
            .help(model.snapshot?.has_photo == true ? "Change new tab photo" : "Choose new tab photo")
            .accessibilityLabel(model.snapshot?.has_photo == true ? "Change new tab photo" : "Choose new tab photo")
            if model.snapshot?.has_photo == true {
                Button { positioning = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 38)
                }
                .help("Position new tab photo")
                .accessibilityLabel("Position new tab photo")
                .popover(isPresented: $positioning) { PhotoPositionEditor(model: model) }
                Button { model.send("remove_new_tab_photo") } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                        .frame(width: 32, height: 38)
                }
                .help("Remove new tab photo")
                .accessibilityLabel("Remove new tab photo")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(ink)
        .glassEffect(.regular.interactive(), in: Capsule())
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
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
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

@MainActor private final class ChromeBridge {
    static let shared = ChromeBridge()
    let model = ChromeModel()
    var parent: NSView?
    var chrome: ChromeHostingView?
    var palette: NSHostingView<PaletteOverlay>?
    var photoControls: NSHostingView<PhotoControls>?
    private var escapeMonitor: Any?

    func install(_ parent: NSView, callback: @escaping @convention(c) (UnsafePointer<CChar>?) -> Void, photoPath: String) {
        self.parent = parent
        model.callback = callback
        model.photoPath = photoPath
        let chrome = ChromeHostingView(rootView: ChromeSurface(model: model))
        let palette = NSHostingView(rootView: PaletteOverlay(model: model))
        let photoControls = NSHostingView(rootView: PhotoControls(model: model))
        parent.window?.appearance = NSAppearance(named: .aqua)
        chrome.autoresizingMask = []
        palette.autoresizingMask = []
        photoControls.autoresizingMask = []
        parent.addSubview(chrome)
        parent.addSubview(palette)
        parent.addSubview(photoControls)
        palette.isHidden = true
        photoControls.isHidden = true
        self.chrome = chrome
        self.palette = palette
        self.photoControls = photoControls
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.model.paletteMode != nil, event.keyCode == 53 else { return event }
                self.model.closePalette()
                return nil
            }
        }
        resize(parent.bounds.width, parent.bounds.height)
    }

    func resize(_ width: CGFloat, _ height: CGFloat) {
        guard let parent else { return }
        model.windowSize = CGSize(width: width, height: height)
        chrome?.frame = parent.bounds
        chrome?.appearance = NSAppearance(named: model.chromeScheme == .dark ? .darkAqua : .aqua)
        palette?.frame = parent.bounds
        photoControls?.frame = CGRect(x: max(model.sidebarWidth, width - 150), y: parent.isFlipped ? height - 66 : 22, width: 128, height: 44)
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

    func updatePhotoControls() {
        guard let parent, let photoControls else { return }
        let show = model.customizingWallpaper && model.activeTab?.url == "about:blank" && model.snapshot?.panel == nil
        if show && photoControls.isHidden {
            photoControls.removeFromSuperview()
            parent.addSubview(photoControls, positioned: .above, relativeTo: nil)
        }
        photoControls.isHidden = !show
    }
}

@_cdecl("moth_install_chrome")
func moth_install_chrome(_ parent: UnsafeMutableRawPointer?, _ callback: @escaping @convention(c) (UnsafePointer<CChar>?) -> Void, _ photoPath: UnsafePointer<CChar>?) {
    guard let parent else { return }
    MainActor.assumeIsolated {
        ChromeBridge.shared.install(Unmanaged<NSView>.fromOpaque(parent).takeUnretainedValue(), callback: callback, photoPath: photoPath.map(String.init(cString:)) ?? "")
    }
}

@_cdecl("moth_resize_chrome")
func moth_resize_chrome(_ width: Double, _ height: Double) {
    MainActor.assumeIsolated { ChromeBridge.shared.resize(width, height) }
}

@_cdecl("moth_update_chrome")
func moth_update_chrome(_ json: UnsafePointer<CChar>?) {
    guard let json else { return }
    let text = String(cString: json)
    MainActor.assumeIsolated {
        ChromeBridge.shared.model.update(text)
        ChromeBridge.shared.chrome?.appearance = NSAppearance(named: ChromeBridge.shared.model.chromeScheme == .dark ? .darkAqua : .aqua)
        ChromeBridge.shared.updatePhotoControls()
    }
}

@_cdecl("moth_focus_address")
func moth_focus_address() {
    MainActor.assumeIsolated { ChromeBridge.shared.model.focusAddress() }
}

@_cdecl("moth_focus_switcher")
func moth_focus_switcher() {
    MainActor.assumeIsolated { ChromeBridge.shared.model.showSwitcher() }
}

@_cdecl("moth_focus_new_tab")
func moth_focus_new_tab() {
    MainActor.assumeIsolated { ChromeBridge.shared.model.showNewTab() }
}
