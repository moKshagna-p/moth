import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct SavedEntry: Decodable { let url: String; let title: String }
struct ProjectPreset: Codable, Equatable {
    var local = ""
    var repository = ""
    var docs = ""
    var staging = ""
    var production = ""
    var split = false
}

func developerAddress(_ value: String) -> String {
    guard let url = URL(string: value), let host = url.host else { return value }
    let displayHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    let authority = displayHost + (url.port.map { ":\($0)" } ?? "")
    return authority + (url.path == "/" ? "" : url.path) + (url.query.map { "?\($0)" } ?? "") + (url.fragment.map { "#\($0)" } ?? "")
}

struct PaletteResult: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    var shortcut = ""
    let command: String
    var values: [String: Any] = [:]
}

enum PaletteSearch {
    // Subsequence matching rewards contiguous words and penalizes gaps.
    static func score(_ query: String, in value: String) -> Int? {
        let query = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let value = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if query.isEmpty { return 0 }
        if value == query { return 1000 }
        if value.hasPrefix(query) { return 800 }
        if value.contains(query) { return 600 }
        let characters = Array(value)
        var cursor = 0, gaps = 0
        for character in query {
            guard let found = characters[cursor...].firstIndex(of: character) else { return nil }
            gaps += found - cursor; cursor = found + 1
        }
        return max(1, 300 - gaps)
    }
    static func results(snapshot: ChromeSnapshot, query: String, newTab: Bool) -> [PaletteResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = snapshot.tabs.map { tab in
            PaletteResult(id: "tab:\(tab.id)", title: tab.title, subtitle: "Tab · " + tab.url, symbol: "rectangle.on.rectangle", command: "switch_tab", values: ["id": tab.id])
        }
        let actions: [(String, String, String, String)] = [
            ("Web Inspector", "inspect", "curlybraces", "⌥⌘I"),
            ("Picture in Picture", "picture_in_picture", "pip", ""),
            ("Find in Page", "find", "text.magnifyingglass", "⌘F"),
            ("Projects", "local_projects", "folder", ""),
            ("Open Project", "open_project", "folder", ""),
            ("Project Preset", "project_settings", "folder.badge.gearshape", ""),
            ("Save Viewport Screenshot", "screenshot", "camera", "⇧⌘S"),
            ("Swap Split Panes", "swap_panes", "arrow.left.arrow.right", ""),
            ("Close Split", "close_split", "rectangle", ""),
            ("Clear This Website’s Data", "clear_current_site_data", "trash", ""),
            ("Settings", "settings", "gearshape", "⌘,"),
            ("Reload", "reload", "arrow.clockwise", "⌘R")
        ]
        candidates += actions.map { PaletteResult(id: "action:" + $0.1, title: $0.0, subtitle: "Browser action", symbol: $0.2, shortcut: $0.3, command: $0.1) }
        if let current = snapshot.tabs.first(where: { $0.id == snapshot.active }) {
            candidates.append(PaletteResult(id: "awake", title: current.keep_awake ? "Allow Tab to Sleep" : "Keep Tab Awake", subtitle: "Preserve this tab’s live state", symbol: "bolt", command: "toggle_keep_awake", values: ["id": current.id]))
            candidates.append(PaletteResult(id: "media", title: current.media_suspended ? "Resume Media" : "Suspend Media", subtitle: "Audio and video playback", symbol: "speaker.slash", command: "toggle_media", values: ["id": current.id]))
            for tab in snapshot.tabs where tab.id != current.id && tab.workspace == current.workspace && tab.url != "about:blank" {
                candidates.append(PaletteResult(id: "split:\(tab.id)", title: "Split right: " + tab.title, subtitle: tab.url, symbol: "rectangle.split.2x1", command: "split_tab", values: ["id": tab.id]))
            }
        }
        for workspace in snapshot.workspaces {
            candidates.append(PaletteResult(id: "workspace:\(workspace.id)", title: workspace.name, subtitle: "Workspace", symbol: "square.stack", command: "switch_workspace", values: ["id": workspace.id]))
        }
        if let project = snapshot.workspaces.first(where: { $0.id == snapshot.active_workspace })?.project {
            for (label, value, environment) in [("Local", project.local, "local"), ("Staging", project.staging, "staging"), ("Production", project.production, "production")] where !value.isEmpty {
                candidates.append(PaletteResult(id: "env:" + environment, title: "Switch to " + label, subtitle: value, symbol: "server.rack", command: "switch_environment", values: ["environment": environment]))
            }
        }
        // Saved links appear when searching, so an empty palette stays compact.
        if !query.isEmpty {
            var seen = Set<String>()
            for (kind, links) in [("Bookmark", snapshot.bookmarks), ("History", snapshot.history)] {
                for link in links where seen.insert(link.url).inserted {
                    candidates.append(PaletteResult(id: "saved:" + link.url, title: link.title, subtitle: kind + " · " + link.url, symbol: kind == "Bookmark" ? "star" : "clock", command: "open_new_tab", values: ["value": link.url]))
                }
            }
        }
        var result = candidates.enumerated().compactMap { index, item -> (Int, Int, PaletteResult)? in
            guard let score = score(query, in: item.title + " " + item.subtitle) else { return nil }
            return (score, index, item)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.prefix(30).map { $0.2 }
        if newTab || !query.isEmpty && result.isEmpty {
            result.insert(PaletteResult(id: "navigate", title: query.isEmpty ? "Blank Tab" : "Open “\(query)”", subtitle: query.isEmpty ? "Start with an empty canvas" : "Search or navigate in a new tab", symbol: "plus", command: query.isEmpty ? "open_blank_tab" : "open_new_tab", values: query.isEmpty ? [:] : ["value": query]), at: 0)
        }
        return result
    }
}

struct DeveloperMenuContent: View {
    @ObservedObject var model: ChromeModel
    var body: some View {
        Group {
            Button("Web Inspector    ⌥⌘I") { model.send("inspect") }
            Button("Save Viewport Screenshot…    ⇧⌘S") { model.send("screenshot") }
            Divider()
            Menu("Viewport Size") {
                Button("Fit Pane") { viewport(0, 0) }
                Button("Phone · 390 × 844") { viewport(390, 844) }
                Button("Tablet · 768 × 1024") { viewport(768, 1024) }
                Button("Desktop · 1280 × 800") { viewport(1280, 800) }
                Text("Sizes fit within the pane; no device emulation")
            }
            Menu("Zoom · \(Int((model.activeTab?.zoom ?? 1) * 100))%") {
                Button("Zoom In") { model.send("zoom", ["delta": 1]) }
                Button("Zoom Out") { model.send("zoom", ["delta": -1]) }
                Button("Reset to 100%") { model.send("zoom", ["delta": 0]) }
            }
            Menu("Split Right") {
                ForEach(model.snapshot?.tabs.filter { $0.id != model.snapshot?.active && $0.workspace == model.snapshot?.active_workspace && $0.url != "about:blank" } ?? []) { tab in
                    Button(tab.title) { model.send("split_tab", ["id": tab.id]) }
                }
            }
            if model.snapshot?.split != nil {
                Button("Swap Panes") { model.send("swap_panes") }
                Button("Equal Split") { model.send("set_split_ratio", ["ratio": 0.5]) }
                Button("Close Split") { model.send("close_split") }
            }
            Divider()
            Button("Projects…") { ProjectLauncher.show(model) }
            Button("Project Preset…") { model.send("project_settings") }
            Button("Open Project") { model.send("open_project") }
            if let project = model.activeWorkspace?.project {
                ForEach([("Local", project.local, "local"), ("Staging", project.staging, "staging"), ("Production", project.production, "production")], id: \.0) { label, url, environment in
                    if !url.isEmpty { Button("Switch to " + label) { model.send("switch_environment", ["environment": environment]) } }
                }
            }
            Divider()
            if let tab = model.activeTab {
                Button(tab.keep_awake ? "Allow Tab to Sleep" : "Keep Tab Awake") { model.send("toggle_keep_awake", ["id": tab.id]) }
                Button(tab.media_suspended ? "Resume Media" : "Suspend Media") { model.send("toggle_media", ["id": tab.id]) }
            }
            Button("Clear This Website’s Data…") { model.send("clear_current_site_data") }
        }
    }
    private func viewport(_ width: Int, _ height: Int) { model.send("set_viewport", ["width": width, "height": height]) }
}

struct ProjectPresetView: View {
    @ObservedObject var model: ChromeModel
    let workspace: UInt64
    let name: String
    @State var preset: ProjectPreset
    var body: some View {
        Form {
            Text(name).font(.title2.weight(.semibold))
            Text("Open this workspace’s working set together. Existing tabs are reused.").foregroundStyle(.secondary)
            TextField("Local app", text: $preset.local, prompt: Text("http://localhost:3000"))
            TextField("Repository", text: $preset.repository, prompt: Text("https://github.com/…"))
            TextField("Documentation", text: $preset.docs, prompt: Text("https://…"))
            TextField("Staging", text: $preset.staging, prompt: Text("https://…"))
            TextField("Production", text: $preset.production, prompt: Text("https://…"))
            Toggle("Open the first two links side by side", isOn: $preset.split)
            Text("Workspaces share website logins. Private windows use a separate temporary store.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { BrowserFeatures.projectWindows.removeValue(forKey: model.windowID)?.close() }
                Button("Save Preset") {
                    if let data = try? JSONEncoder().encode(preset), let object = try? JSONSerialization.jsonObject(with: data) { model.send("set_project", ["workspace": workspace, "project": object]) }
                }.keyboardShortcut(.defaultAction)
            }.buttonStyle(.glass)
        }.formStyle(.grouped).scrollContentBackground(.hidden).padding().frame(width: 560, height: 480)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }
}

// Pure layout shared by the outline, divider hit-testing, and inline tools.
struct DeveloperLayout {
    let divider: CGRect?
    let active: CGRect
    init(size: CGSize, sidebar: CGFloat, split: Bool, activeRight: Bool, ratio: Double) {
        let width = max(1, size.width - sidebar), height = max(1, size.height - 50)
        let left = max(1, width * CGFloat(min(0.8, max(0.2, ratio))) - 3)
        divider = split ? CGRect(x: sidebar + left, y: 50, width: 6, height: height) : nil
        active = CGRect(x: sidebar + (split && activeRight ? left + 6 : 0), y: 50,
                        width: split ? (activeRight ? max(1, width - left - 6) : left) : width, height: height)
    }
}

struct DeveloperOverlay: View {
    @ObservedObject var model: ChromeModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragStart: Double?
    var body: some View {
        GeometryReader { geometry in
            let layout = DeveloperLayout(size: geometry.size, sidebar: model.sidebarWidth,
                split: model.snapshot?.split != nil, activeRight: model.snapshot?.split_right == model.snapshot?.active, ratio: model.snapshot?.split_ratio ?? 0.5)
            ZStack(alignment: .topLeading) {
                if let divider = layout.divider, model.snapshot?.panel == nil {
                    Rectangle().fill(Color.primary.opacity(0.04))
                        .overlay { Capsule().fill(Color.primary.opacity(0.3)).frame(width: 2, height: 36) }
                        .frame(width: divider.width, height: divider.height).position(x: divider.midX, y: divider.midY)
                        .onHover { hovering in if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { value in
                            if dragStart == nil { dragStart = model.snapshot?.split_ratio ?? 0.5 }
                            let ratio = (dragStart ?? 0.5) + Double(value.translation.width / max(1, geometry.size.width - model.sidebarWidth))
                            model.send("set_split_ratio", ["ratio": ratio])
                        }.onEnded { _ in dragStart = nil })
                        .accessibilityLabel("Split divider")
                        .accessibilityAdjustableAction { direction in
                            model.send("set_split_ratio", ["ratio": (model.snapshot?.split_ratio ?? 0.5) + (direction == .increment ? 0.05 : -0.05)])
                        }
                    Capsule().fill(Color.accentColor).frame(width: min(80, layout.active.width), height: 2)
                        .position(x: layout.active.midX, y: 51).allowsHitTesting(false)
                }
                if let tab = model.activeTab, let error = tab.page_error, model.snapshot?.panel == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Couldn’t load this page", systemImage: "exclamationmark.triangle").font(.headline)
                        Text(error).font(.callout).lineLimit(4)
                        HStack {
                            Button("Retry") { model.send("reload") }
                            Button("Dismiss") { model.send("dismiss_page_error", ["id": tab.id]) }
                        }.buttonStyle(.glass)
                    }.padding(18).frame(width: max(1, min(400, layout.active.width - 24)), alignment: .leading)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
                        .position(x: layout.active.midX, y: 155)
                        .transition(.opacity)
                }
            }.foregroundStyle(model.chromeInk)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.activeTab?.page_error)
        }
    }
}

final class DeveloperHostingView: NSHostingView<DeveloperOverlay> {
    weak var model: ChromeModel?
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let model, model.snapshot?.panel == nil, model.paletteMode == nil else { return nil }
        let local = convert(point, from: superview)
        let topPoint = CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
        let layout = DeveloperLayout(size: bounds.size, sidebar: model.sidebarWidth,
            split: model.snapshot?.split != nil, activeRight: model.snapshot?.split_right == model.snapshot?.active, ratio: model.snapshot?.split_ratio ?? 0.5)
        let errorRegion = CGRect(x: layout.active.midX - min(400, layout.active.width - 24) / 2, y: 65, width: min(400, layout.active.width - 24), height: 180)
        if layout.divider?.contains(topPoint) == true || (model.activeTab?.page_error != nil && errorRegion.contains(topPoint)) { return super.hitTest(point) }
        return nil
    }
}
