import Darwin
import Foundation

// A separate process group owns the shell and all its dev-server children.
// All PID access, signalling and reaping happen on this one queue, so a delayed
// stop can never signal a recycled PID.
final class ProjectProcess {
    private let queue = DispatchQueue(label: "dev.moth.project-process")
    private var pid: pid_t = 0
    private var output: FileHandle?
    private var reader: DispatchSourceRead?
    private var observer: DispatchSourceProcess?
    private var onOutput: ((String) -> Void)?
    private var onExit: ((Int32) -> Void)?

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func launch(path: String, command: String, onOutput: @escaping (String) -> Void,
                       onExit: @escaping (Int32) -> Void) throws -> ProjectProcess {
        let job = ProjectProcess()
        try job.queue.sync {
            let pipe = Pipe()
            let read = pipe.fileHandleForReading.fileDescriptor, write = pipe.fileHandleForWriting.fileDescriptor
            _ = fcntl(read, F_SETFL, O_NONBLOCK)
            _ = fcntl(read, F_SETFD, FD_CLOEXEC)
            _ = fcntl(write, F_SETFD, FD_CLOEXEC)
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
            posix_spawn_file_actions_adddup2(&actions, write, STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, write, STDERR_FILENO)
            posix_spawn_file_actions_addclose(&actions, read)
            posix_spawn_file_actions_addclose(&actions, write)
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
            posix_spawnattr_setpgroup(&attributes, 0)
            let preferred = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let shell = ["/bin/zsh", "/bin/bash"].contains(preferred) ? preferred : "/bin/zsh"
            // Login + interactive startup restores the user's PATH/version manager.
            // Folder quoting is separate from the explicitly editable shell command.
            let script = "builtin cd -- \(shellQuote(path)) || exit\n" +
                "if [ -f .nvmrc ] && command -v nvm >/dev/null 2>&1; then nvm use || exit; fi\n" + command
            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "dumb"; environment["NO_COLOR"] = "1"
            environment["BROWSER"] = "true"
            // Next.js and other PORT-aware tools avoid an interactive port prompt.
            // Vite and tools with their own port selection keep their normal fallback.
            environment["PORT"] = String(try ProjectPort.available(startingAt: Int(environment["PORT"] ?? "") ?? 3000))
            let argv = ([shell, "-ilc", script] as [String]).map { value in value.withCString { strdup($0)! } }
            let env = environment.map { entry in "\(entry.key)=\(entry.value)".withCString { strdup($0)! } }
            defer { argv.forEach { free($0) }; env.forEach { free($0) } }
            var arguments: [UnsafeMutablePointer<CChar>?] = argv.map { $0 } + [nil]
            var variables: [UnsafeMutablePointer<CChar>?] = env.map { $0 } + [nil]
            let status = posix_spawn(&job.pid, shell, &actions, &attributes, &arguments, &variables)
            try? pipe.fileHandleForWriting.close()
            guard status == 0 else { throw ProjectFailure("Couldn’t start the shell: \(String(cString: strerror(status)))") }
            job.output = pipe.fileHandleForReading
            job.onOutput = onOutput; job.onExit = onExit
            let reader = DispatchSource.makeReadSource(fileDescriptor: read, queue: job.queue)
            reader.setEventHandler { [weak job] in job?.drain() }
            job.reader = reader; reader.resume()
            let observer = DispatchSource.makeProcessSource(identifier: job.pid, eventMask: .exit, queue: job.queue)
            observer.setEventHandler { [job] in job.finish() }
            job.observer = observer; observer.resume()
        }
        return job
    }

    func stop() {
        queue.async { [self] in
            guard pid > 0 else { return }
            Darwin.kill(-pid, SIGTERM)
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                if pid > 0 { Darwin.kill(-pid, SIGKILL) }
            }
        }
    }

    func stopImmediately() {
        queue.sync { if pid > 0 { Darwin.kill(-pid, SIGKILL) } }
    }

    private func drain() {
        guard let output else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        // Yield to queued Stop/exit events even when a tool writes continuously.
        for _ in 0..<16 {
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            guard count > 0 else { return }
            onOutput?(String(decoding: bytes.prefix(count), as: UTF8.self))
        }
    }

    private func finish() {
        guard pid > 0 else { return }
        // Dispatch reports exit without reaping: the PID still belongs to us here.
        Darwin.kill(-pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        pid = 0
        drain()
        reader?.cancel(); observer?.cancel()
        reader = nil; observer = nil
        try? output?.close(); output = nil
        let callback = onExit
        onOutput = nil; onExit = nil
        callback?(status == 0 ? 0 : status)
    }
}

enum ProjectPort {
    static func available(startingAt preferred: Int) throws -> Int {
        let start = (1024...65435).contains(preferred) ? preferred : 3000
        for port in start..<(start + 100) {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw ProjectFailure("Couldn’t check for an available local port.") }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            Darwin.close(descriptor)
            if result == 0 { return port }
        }
        throw ProjectFailure("No free port nearby. Stop an unused server and try again.")
    }
}
