import AppKit
import SwiftUI

struct ProjectRun {
    enum Phase { case starting, running, stopping, stopped, failed }
    var phase: Phase = .stopped
    var message = ""
    var log = ""
    var url: URL?
    var active: Bool { [.starting, .running, .stopping].contains(phase) }
}

// Never follow a development server's redirect during the readiness probe.
private final class ProjectProbe: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor final class LocalProjects: ObservableObject {
    static let shared = LocalProjects()
    @Published private(set) var projects: [LocalProject]
    @Published private(set) var runs: [UUID: ProjectRun] = [:]
    @Published private(set) var inspections: [UUID: ProjectInspection] = [:]
    @Published private(set) var icons: [UUID: NSImage] = [:]
    @Published private(set) var inspecting: Set<UUID> = []
    private let defaults: UserDefaults
    private let work = DispatchQueue(label: "dev.moth.project-git")
    private var jobs: [UUID: ProjectProcess] = [:]
    private var generations: [UUID: UUID] = [:]
    private var roots: [UUID: String] = [:]
    private var probes: [UUID: Task<Void, Never>] = [:]
    private let session: URLSession
    private var terminationObserver: NSObjectProtocol?
    private static let key = "moth.local-projects.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        projects = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([LocalProject].self, from: $0) } ?? []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration, delegate: ProjectProbe(), delegateQueue: nil)
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
        for project in projects { refresh(project.id) }
    }

    @discardableResult func remember(_ folder: URL) -> UUID {
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        if let existing = projects.first(where: { $0.path == path }) { refresh(existing.id); return existing.id }
        let project = LocalProject(path: path, command: LocalProject.suggestedCommand(at: folder))
        projects.append(project); save(); refresh(project.id)
        return project.id
    }

    func forget(_ id: UUID) {
        guard runs[id]?.active != true else { return }
        projects.removeAll { $0.id == id }; runs[id] = nil; inspections[id] = nil; icons[id] = nil
        generations[id] = nil; save()
    }

    private func save() { if let data = try? JSONEncoder().encode(projects) { defaults.set(data, forKey: Self.key) } }

    func refresh(_ id: UUID) {
        guard let project = projects.first(where: { $0.id == id }), runs[id]?.active != true, !inspecting.contains(id) else { return }
        inspecting.insert(id)
        work.async { [weak self] in
            let result = Result { try ProjectInspection.read(at: project.path) }
            let icon = LocalProject.icon(at: project.path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inspecting.remove(id)
                guard self.projects.contains(where: { $0.id == id }), self.runs[id]?.active != true else { return }
                self.icons[id] = icon
                switch result {
                case .success(let info): self.inspections[id] = info
                case .failure(let error): self.runs[id] = ProjectRun(phase: .failed, message: error.localizedDescription)
                }
            }
        }
    }

    func start(_ id: UUID, branch: String, command: String, open: @escaping (URL) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }), runs[id]?.active != true else { return }
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { runs[id] = ProjectRun(phase: .failed, message: "Enter a start command in Launch options."); return }
        projects[index].command = command; projects[index].branch = branch; save()
        let project = projects[index], token = UUID()
        generations[id] = token; runs[id] = ProjectRun(phase: .starting, message: "Checking branch…")
        work.async { [weak self] in
            let result = Result { try ProjectInspection.read(at: project.path) }
            Task { @MainActor [weak self] in
                guard let self, self.generations[id] == token else { return }
                do {
                    let info = try result.get()
                    let root = info.repository ?? project.path
                    guard !self.roots.values.contains(root) else { throw ProjectFailure("Another project in this repository is running. Stop it before starting this one.") }
                    self.roots[id] = root
                    self.prepare(project, branch: branch, token: token, open: open)
                } catch { self.fail(id, token: token, error: error) }
            }
        }
    }

    private func prepare(_ project: LocalProject, branch: String, token: UUID, open: @escaping (URL) -> Void) {
        let id = project.id
        work.async { [weak self] in
            let result = Result { try ProjectInspection.prepare(path: project.path, branch: branch) }
            Task { @MainActor [weak self] in
                guard let self, self.generations[id] == token else { return }
                do {
                    self.inspections[id] = try result.get()
                    self.runs[id]?.message = "Waiting for the server…"
                    self.jobs[id] = try ProjectProcess.launch(path: project.path, command: project.command,
                        onOutput: { [weak self] chunk in
                            Task { @MainActor in self?.output(chunk, id: id, token: token, open: open) }
                        }, onExit: { [weak self] status in
                            Task { @MainActor in self?.exited(id, token: token, status: status) }
                        })
                    // A server without a printed local URL remains manageable from this panel.
                    self.probes[id] = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(90))
                        guard !Task.isCancelled, let self, self.generations[id] == token, self.runs[id]?.phase == .starting else { return }
                        self.runs[id]?.message = "No responding local address yet. Check the output below."
                    }
                } catch { self.fail(id, token: token, error: error) }
            }
        }
    }

    private func fail(_ id: UUID, token: UUID, error: Error) {
        guard generations[id] == token else { return }
        roots[id] = nil; runs[id]?.phase = .failed; runs[id]?.message = error.localizedDescription
    }

    private func output(_ chunk: String, id: UUID, token: UUID, open: @escaping (URL) -> Void) {
        guard generations[id] == token else { return }
        runs[id]?.log = String(((runs[id]?.log ?? "") + ProjectOutput.clean(chunk)).suffix(40_000))
        guard runs[id]?.phase == .starting, let url = ProjectOutput.localURL(in: runs[id]?.log ?? ""), runs[id]?.url != url else { return }
        runs[id]?.url = url
        probes[id]?.cancel()
        probes[id] = Task { [weak self] in
            for _ in 0..<90 {
                guard !Task.isCancelled, let self, self.generations[id] == token, self.runs[id]?.phase == .starting else { return }
                var request = URLRequest(url: url); request.cachePolicy = .reloadIgnoringLocalCacheData
                request.httpMethod = "HEAD"
                if let (_, response) = try? await self.session.data(for: request), response is HTTPURLResponse {
                    guard !Task.isCancelled, self.generations[id] == token, self.runs[id]?.phase == .starting else { return }
                    self.runs[id]?.phase = .running; self.runs[id]?.message = ""
                    if let index = self.projects.firstIndex(where: { $0.id == id }) { self.projects[index].lastOpened = Date(); self.save() }
                    open(url)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled, self.generations[id] == token else { return }
            self.runs[id]?.message = "The server isn’t responding yet. Check the output below."
        }
    }

    private func exited(_ id: UUID, token: UUID, status: Int32) {
        guard generations[id] == token else { return }
        let stopped = runs[id]?.phase == .stopping
        probes.removeValue(forKey: id)?.cancel(); jobs[id] = nil; roots[id] = nil
        runs[id]?.phase = stopped || status == 0 ? .stopped : .failed
        runs[id]?.url = nil
        runs[id]?.message = stopped ? "" : "Server exited\(status == 0 ? "." : " with an error. Check the output below.")"
        refresh(id)
    }

    func stop(_ id: UUID) {
        guard runs[id]?.active == true else { return }
        probes.removeValue(forKey: id)?.cancel()
        if let job = jobs[id] { runs[id]?.phase = .stopping; runs[id]?.message = "Stopping…"; job.stop() }
        else { generations[id] = nil; roots[id] = nil; runs[id] = ProjectRun(); refresh(id) }
    }

    func stopAll() {
        probes.values.forEach { $0.cancel() }; probes.removeAll()
        jobs.values.forEach { $0.stopImmediately() }
        generations.removeAll(); jobs.removeAll(); roots.removeAll()
    }
}

@MainActor enum ProjectLauncher {
    static func show(_ model: ChromeModel) {
        guard model.snapshot?.private_mode == false else { return }
        model.paletteMode = nil
        model.projectsVisible = true
        model.bridge?.setPaletteVisible(true)
    }
    static func hide(_ id: UInt64) { ChromeBridge.instances[id]?.model.closePalette() }
    static func isVisible(_ id: UInt64) -> Bool { ChromeBridge.instances[id]?.model.projectsVisible == true }
    static func removeWindow(_ id: UInt64) {
        if ChromeBridge.instances.count <= 1 { LocalProjects.shared.stopAll() }
    }
}

@MainActor struct LocalProjectsView: View {
    @ObservedObject var model: ChromeModel
    @ObservedObject private var store = LocalProjects.shared
    var close: () -> Void
    @State private var selected: UUID?
    @State private var branch = ""
    @State private var command = ""
    @State private var options = false
    @State private var choosingFolder = false
    private var project: LocalProject? { store.projects.first { $0.id == selected } }
    private var run: ProjectRun { selected.flatMap { store.runs[$0] } ?? ProjectRun() }
    private var info: ProjectInspection? { selected.flatMap { store.inspections[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Projects").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button(action: add) { Image(systemName: "plus").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("Add project folder").accessibilityLabel("Add project folder")
                Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("Close Projects").accessibilityLabel("Close Projects")
            }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 18)
            if store.projects.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text("Your projects, one click away").font(.system(size: 14, weight: .medium))
                    Text("Add a local folder to start its dev server here.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Add folder…", action: add).buttonStyle(.glass).padding(.top, 4)
                }.frame(maxWidth: .infinity).frame(height: 220)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(store.projects) { item in row(item) }
                    }.padding(.horizontal, 14)
                }.frame(height: min(220, CGFloat(store.projects.count) * 59))
                if let project { launchArea(project) }
                else { Text("Select a project to get started").font(.system(size: 12)).foregroundStyle(.secondary).padding(24) }
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .onExitCommand(perform: close)
        .onChange(of: selected) { _, id in
            guard let id, let item = store.projects.first(where: { $0.id == id }) else { return }
            command = item.command; options = item.command.isEmpty
            branch = store.inspections[id]?.currentBranch ?? ""; store.refresh(id)
        }
        .onChange(of: info?.currentBranch) { _, value in branch = value ?? "" }
        .onAppear {
            store.projects.forEach { store.refresh($0.id) }
            // Projects is also the entry point for a first folder. Defer until
            // the overlay is attached so the chooser is a sheet on this window.
            if store.projects.isEmpty {
                DispatchQueue.main.async {
                    if model.projectsVisible { add() }
                }
            }
        }
    }

    private func row(_ item: LocalProject) -> some View {
        Button { selected = item.id } label: {
            HStack(spacing: 12) {
                if let icon = store.icons[item.id] { Image(nsImage: icon).resizable().scaledToFit().frame(width: 26, height: 26).accessibilityHidden(true) }
                else { Image(systemName: "globe").font(.system(size: 22, weight: .light)).foregroundStyle(.secondary).frame(width: 26, height: 26).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text((item.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let state = store.runs[item.id], state.active {
                    if state.phase == .running { Circle().fill(.green).frame(width: 6, height: 6).accessibilityLabel("Running") }
                    else { ProgressView().controlSize(.mini).accessibilityLabel(state.phase == .stopping ? "Stopping" : "Starting") }
                }
                if selected == item.id { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 12).padding(.vertical, 11).contentShape(Rectangle())
                .background(selected == item.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityAddTraits(selected == item.id ? .isSelected : [])
        .contextMenu { Button("Remove from Projects", role: .destructive) { if selected == item.id { selected = nil }; store.forget(item.id) }.disabled(store.runs[item.id]?.active == true) }
    }

    private func launchArea(_ project: LocalProject) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack(spacing: 12) {
                if store.inspecting.contains(project.id) { ProgressView().controlSize(.small); Text("Reading branches…").font(.caption).foregroundStyle(.secondary) }
                else if info?.repository != nil {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                    Picker("Branch", selection: $branch) {
                        if info?.currentBranch.isEmpty == true { Text("Detached HEAD").tag("") }
                        ForEach(info?.branches ?? [], id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).buttonStyle(.plain).accessibilityLabel("Branch").disabled(run.active)
                } else { Text("Local folder").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                if run.active {
                    Button("Stop") { store.stop(project.id) }.buttonStyle(.glass).disabled(run.phase == .stopping)
                    if run.phase == .running, let url = run.url {
                        Button("Open tab") { open(url) }.buttonStyle(.glassProminent)
                    }
                } else {
                    Button("Start") { store.start(project.id, branch: branch, command: command, open: open) }
                        .buttonStyle(.glassProminent).disabled(store.inspecting.contains(project.id) || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
            if !run.message.isEmpty { Text(run.message).font(.system(size: 11)).foregroundStyle(run.phase == .failed ? Color.red : Color.secondary).fixedSize(horizontal: false, vertical: true) }
            DisclosureGroup("Launch options & output", isExpanded: $options) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Start command, e.g. npm run dev", text: $command).font(.system(size: 12, design: .monospaced)).textFieldStyle(.roundedBorder).disabled(run.active).accessibilityLabel("Start command")
                    Text("Runs in this folder using your login shell.").font(.system(size: 10)).foregroundStyle(.secondary)
                    if !run.log.isEmpty {
                        ScrollView { Text(run.log).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(height: 80).accessibilityLabel("Server output")
                    }
                }.padding(.top, 8)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(.horizontal, 24).padding(.bottom, 22).padding(.top, 6)
    }

    private func add() {
        guard !choosingFolder else { return }
        choosingFolder = true
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Add Project"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            choosingFolder = false
            if response == .OK, let folder = panel.url { selected = store.remember(folder) }
        }
        if let window = model.bridge?.parent?.window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func open(_ url: URL) {
        // The originating browser may have closed while the server was starting.
        let target = model.bridge != nil ? model : ChromeBridge.instances.values.first(where: { $0.model.snapshot?.private_mode == false })?.model
        target?.send("open_new_tab", ["value": url.absoluteString]); close()
    }
}
