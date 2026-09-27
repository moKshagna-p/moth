import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let sidebarWidth: CGFloat = 252
private let toolbarHeight: CGFloat = 68
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
}

@MainActor private final class ChromeModel: ObservableObject {
    @Published var snapshot: ChromeSnapshot?
    @Published var address = ""
    @Published var addressFocus = 0
    @Published var paletteMode: PaletteMode?
    @Published var paletteFocus = 0
    @Published var paletteQuery = ""
    @Published var renamingWorkspace = false
    @Published var workspaceName = ""
    @Published var windowSize = CGSize(width: 1000, height: 768)
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
        snapshot = next
        if next.photo_version != loadedPhotoVersion {
            loadedPhotoVersion = next.photo_version
            wallpaper = next.has_photo ? NSImage(contentsOfFile: photoPath) : nil
        }
        if !editingAddress { address = activeTab?.url == "about:blank" ? "" : activeTab?.url ?? "" }
    }

    var wallpaperVisible: Bool {
        activeTab?.url == "about:blank" && snapshot?.panel == nil && wallpaper != nil
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
    let symbol: String
    let label: String
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 35, height: 35)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? ink : muted.opacity(0.35))
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct WallpaperBackdrop: View {
    let image: NSImage
    let windowSize: CGSize
    let xOffset: CGFloat
    let focusX: CGFloat
    let focusY: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let scale = max(windowSize.width / max(image.size.width, 1), windowSize.height / max(image.size.height, 1))
            let imageWidth = image.size.width * scale
            let imageHeight = image.size.height * scale
            Image(nsImage: image)
                .resizable()
                .frame(width: imageWidth, height: imageHeight)
                .offset(
                    x: -(imageWidth - windowSize.width) * focusX / 100 - xOffset,
                    y: -(imageHeight - windowSize.height) * focusY / 100
                )
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
        }
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
            if model.wallpaperVisible, let wallpaper = model.wallpaper {
                WallpaperBackdrop(
                    image: wallpaper, windowSize: model.windowSize, xOffset: 0,
                    focusX: CGFloat(model.snapshot?.photo_focus_x ?? 50),
                    focusY: CGFloat(model.snapshot?.photo_focus_y ?? 50)
                )
                Rectangle().fill(.ultraThinMaterial)
            } else {
                sidebarColor
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("moth")
                        .font(.system(size: 27, weight: .semibold, design: .serif))
                        .tracking(-1.4)
                    Text(".")
                        .font(.system(size: 27, weight: .bold, design: .serif))
                        .foregroundStyle(accent)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 19)
                .padding(.bottom, 25)

                Text("WORKSPACE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.15)
                    .foregroundStyle(muted)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 9)

                Menu {
                    ForEach(model.snapshot?.workspaces ?? []) { workspace in
                        Button(workspace.name) { model.send("switch_workspace", ["id": workspace.id]) }
                    }
                    Divider()
                    Button("New Workspace") { model.send("new_workspace") }
                    Button("Rename Workspace") {
                        model.workspaceName = model.activeWorkspace?.name ?? ""
                        model.renamingWorkspace = true
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(accent)
                            .frame(width: 18)
                        Text(model.activeWorkspace?.name ?? "Personal")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(muted)
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 39)
                    .frame(maxWidth: .infinity)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 10)

                HStack {
                    Text("OPEN TABS")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.15)
                        .foregroundStyle(muted)
                    Spacer()
                    Text("\(workspaceTabs.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(muted)
                }
                .padding(.horizontal, 22)
                .padding(.top, 29)
                .padding(.bottom, 9)

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(workspaceTabs) { tab in
                            tabRow(tab)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }

                Button { model.showNewTab() } label: {
                    Label("New Tab", systemImage: "plus")
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .padding(.horizontal, 10)
                .help("New tab (⌘T)")

                Rectangle().fill(ink.opacity(0.10)).frame(height: 1)
                    .padding(.horizontal, 20).padding(.top, 17).padding(.bottom, 12)
                sideAction("Quick Switch", "magnifyingglass", "switcher", shortcut: "⌘K")
                sideAction("Bookmarks", "bookmark", "bookmarks")
                sideAction("History", "clock.arrow.circlepath", "history")
                sideAction("Downloads", "arrow.down.to.line", "downloads")
                Spacer().frame(height: 16)
            }
        }
        .foregroundStyle(ink)
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
                        .foregroundStyle(selected ? accent : muted)
                        .frame(width: 17)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tab.title.isEmpty ? "New Tab" : tab.title)
                            .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                            .lineLimit(1)
                        if selected && tab.url != "about:blank" {
                            Text(URL(string: tab.url)?.host ?? tab.url)
                                .font(.system(size: 10))
                                .foregroundStyle(muted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if tab.loading { ProgressView().controlSize(.mini) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .frame(height: selected ? 47 : 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.sleeping ? "Sleeping tab — reloads when opened" : tab.url)
            Button { model.send("close_tab", ["id": tab.id]) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(muted)
            .opacity(selected ? 0.8 : 0.5)
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
        return Group {
            if selected {
                row.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 10))
            } else {
                row
            }
        }
    }

    private func sideAction(_ title: String, _ symbol: String, _ panel: String, shortcut: String = "") -> some View {
        Button {
            if panel == "switcher" { model.showSwitcher() }
            else { model.send("show_panel", ["panel": model.snapshot?.panel == panel ? NSNull() : panel]) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 17)
                Text(title).font(.system(size: 12.5, weight: .medium))
                Spacer()
                if !shortcut.isEmpty { Text(shortcut).font(.system(size: 10)).foregroundStyle(muted) }
            }
            .padding(.horizontal, 22)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.snapshot?.panel == panel ? accent : muted)
    }
}

private struct ToolbarView: View {
    @ObservedObject var model: ChromeModel
    @FocusState private var addressFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                SymbolButton(symbol: "chevron.left", label: "Back (⌘[)", enabled: model.snapshot?.can_go_back ?? false) { model.send("back") }
                SymbolButton(symbol: "chevron.right", label: "Forward (⌘])", enabled: model.snapshot?.can_go_forward ?? false) { model.send("forward") }
                SymbolButton(symbol: "arrow.clockwise", label: "Reload (⌘R)") { model.send("reload") }
            }
            Spacer(minLength: 8)

            HStack(spacing: 10) {
                Image(systemName: model.address.hasPrefix("https://") ? "lock" : "globe")
                    .font(.system(size: 12)).foregroundStyle(muted)
                TextField("Search or enter an address", text: $model.address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($addressFocused)
                    .onSubmit {
                        model.send("navigate", ["value": model.address])
                        addressFocused = false
                    }
                    .onChange(of: addressFocused) { _, focused in model.editingAddress = focused }
                if model.address.isEmpty { Text("⌘ L").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted) }
            }
            .padding(.horizontal, 15)
            .frame(maxWidth: 840)
            .frame(height: 38)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 11))
            Spacer(minLength: 8)

            HStack(spacing: 2) {
                SymbolButton(symbol: model.snapshot?.bookmarked == true ? "star.fill" : "star", label: "Bookmark (⌘D)") { model.send("toggle_bookmark") }
                SymbolButton(symbol: "magnifyingglass", label: "Quick Switch (⌘K)") { model.showSwitcher() }
            }
        }
        .padding(.horizontal, 17)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if model.wallpaperVisible, let wallpaper = model.wallpaper {
                WallpaperBackdrop(
                    image: wallpaper, windowSize: model.windowSize, xOffset: sidebarWidth,
                    focusX: CGFloat(model.snapshot?.photo_focus_x ?? 50),
                    focusY: CGFloat(model.snapshot?.photo_focus_y ?? 50)
                )
                    .overlay(.ultraThinMaterial)
            } else {
                toolbarColor
            }
        }
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
    var sidebar: NSHostingView<SidebarView>?
    var toolbar: NSHostingView<ToolbarView>?
    var palette: NSHostingView<PaletteOverlay>?
    var photoControls: NSHostingView<PhotoControls>?
    private var escapeMonitor: Any?

    func install(_ parent: NSView, callback: @escaping @convention(c) (UnsafePointer<CChar>?) -> Void, photoPath: String) {
        self.parent = parent
        model.callback = callback
        model.photoPath = photoPath
        let sidebar = NSHostingView(rootView: SidebarView(model: model))
        let toolbar = NSHostingView(rootView: ToolbarView(model: model))
        let palette = NSHostingView(rootView: PaletteOverlay(model: model))
        let photoControls = NSHostingView(rootView: PhotoControls(model: model))
        parent.window?.appearance = NSAppearance(named: .aqua)
        sidebar.autoresizingMask = []
        toolbar.autoresizingMask = []
        toolbar.wantsLayer = true
        toolbar.layer?.masksToBounds = true
        palette.autoresizingMask = []
        photoControls.autoresizingMask = []
        parent.addSubview(sidebar)
        parent.addSubview(toolbar)
        parent.addSubview(palette)
        parent.addSubview(photoControls)
        palette.isHidden = true
        photoControls.isHidden = true
        self.sidebar = sidebar
        self.toolbar = toolbar
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
        sidebar?.frame = CGRect(x: 0, y: 0, width: sidebarWidth, height: height)
        toolbar?.frame = CGRect(x: sidebarWidth, y: parent.isFlipped ? 0 : height - toolbarHeight, width: max(1, width - sidebarWidth), height: toolbarHeight)
        palette?.frame = parent.bounds
        photoControls?.frame = CGRect(x: max(sidebarWidth, width - 150), y: parent.isFlipped ? height - 66 : 22, width: 128, height: 44)
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
        let show = model.activeTab?.url == "about:blank" && model.snapshot?.panel == nil
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
