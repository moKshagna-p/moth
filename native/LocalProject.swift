import AppKit
import Foundation

struct LocalProject: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var command: String
    var branch = ""
    var lastOpened: Date?
    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    static func suggestedCommand(at folder: URL) -> String {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else { return "" }
        let script = scripts["dev"] != nil ? "dev" : scripts["start"] != nil ? "start" : ""
        guard !script.isEmpty else { return "" }
        let files = FileManager.default
        if files.fileExists(atPath: folder.appendingPathComponent("pnpm-lock.yaml").path) { return "pnpm run \(script)" }
        if files.fileExists(atPath: folder.appendingPathComponent("yarn.lock").path) { return "yarn \(script)" }
        if ["bun.lock", "bun.lockb"].contains(where: { files.fileExists(atPath: folder.appendingPathComponent($0).path) }) { return "bun run \(script)" }
        return "npm run \(script)"
    }

    static func icon(at path: String) -> NSImage? {
        let folder = URL(fileURLWithPath: path)
        for file in ["public/favicon.ico", "public/favicon.png", "static/favicon.ico", "static/favicon.png",
                     "src/app/favicon.ico", "app/favicon.ico", "src/app/icon.png", "app/icon.png", "favicon.ico"] {
            let url = folder.appendingPathComponent(file)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000,
                  let image = NSImage(contentsOf: url) else { continue }
            return image
        }
        return nil
    }
}

struct ProjectInspection {
    var branches: [String] = []
    var currentBranch = ""
    var repository: String?
    var dirty = false

    static func read(at path: String) throws -> ProjectInspection {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
            throw ProjectFailure("This folder is no longer available. Add it again from its new location.")
        }
        // A plain folder is also a valid project; Git is optional.
        let root: String
        do { root = try git(["rev-parse", "--show-toplevel"], at: path) }
        catch {
            if error.localizedDescription.contains("not a git repository") { return ProjectInspection() }
            throw error
        }
        return try ProjectInspection(
            branches: git(["for-each-ref", "--format=%(refname:short)", "refs/heads/"], at: path).split(separator: "\n").map(String.init),
            currentBranch: (try? git(["symbolic-ref", "--quiet", "--short", "HEAD"], at: path)) ?? "",
            repository: URL(fileURLWithPath: root).resolvingSymlinksInPath().path,
            dirty: !git(["status", "--porcelain", "--untracked-files=normal"], at: path).isEmpty
        )
    }

    static func prepare(path: String, branch: String) throws -> ProjectInspection {
        var info = try read(at: path)
        guard info.repository != nil, !branch.isEmpty, branch != info.currentBranch else { return info }
        try info.validateSwitch(to: branch)
        _ = try git(["switch", "--no-guess", branch], at: path)
        info = try read(at: path)
        guard info.currentBranch == branch else { throw ProjectFailure("The branch changed while starting. Please try again.") }
        return info
    }

    func validateSwitch(to branch: String) throws {
        guard repository != nil, !branch.isEmpty, branch != currentBranch else { return }
        guard branches.contains(branch) else { throw ProjectFailure("That local branch no longer exists. Select another branch.") }
        guard !dirty else { throw ProjectFailure("Commit or stash your changes before switching branches. You can still start the current branch.") }
    }

    static func git(_ arguments: [String], at path: String) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // Do not run repository hooks or filesystem monitor programs while inspecting/switching.
        process.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", path] + arguments
        process.standardOutput = output; process.standardError = output
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw ProjectFailure(text.isEmpty ? "Git could not read this project." : String(text.suffix(1500))) }
        return text
    }
}

struct ProjectFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum ProjectOutput {
    static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    // Only loopback URLs from the server's output can open automatically.
    static func localURL(in output: String) -> URL? {
        let pattern = #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|\[::\])(?::[0-9]{1,5})?(?=[/\s<>\"'\)\]]|$)(?:/[^\s<>\"'\)\]]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let text = clean(output)
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text),
                  var parts = URLComponents(string: String(text[range])),
                  ["localhost", "127.0.0.1", "0.0.0.0", "[::1]", "[::]"].contains(parts.host ?? ""),
                  parts.user == nil, parts.password == nil,
                  parts.port.map({ (1...65535).contains($0) }) ?? true else { continue }
            if ["0.0.0.0", "[::]"].contains(parts.host ?? "") { parts.host = "localhost" }
            if let url = parts.url { return url }
        }
        return nil
    }
}
