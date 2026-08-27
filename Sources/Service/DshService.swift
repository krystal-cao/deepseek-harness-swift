import Foundation
import Darwin

/// Spawns and supervises the DSH Web child process.
public final class DshService: @unchecked Sendable {
    public static let shared = DshService()

    private struct ManagedDshProcess {
        let process: Process
        let hasProcessGroup: Bool
    }

    private struct DshProcessRecord: Codable {
        let pid: Int32
        let port: Int
        let nodePath: String
        let entryPath: String
        let processGroupID: Int32?
    }

    private var process: ManagedDshProcess?
    private let lock = NSLock()
    private var processRecordURL: URL {
        DshStateManager.appSupportDirectory.appendingPathComponent("dsh-service-process.json")
    }

    public enum ServiceError: Error, LocalizedError {
        case dshEntryNotFound
        case nodeNotFound
        case portInUse(Int)
        case startupFailed(String)

        public var errorDescription: String? {
            switch self {
            case .dshEntryNotFound:
                return "找不到 DSH 运行时入口。请确认已安装或在设置中下载版本。"
            case .nodeNotFound:
                return "找不到 Node.js 运行时可执行文件。"
            case .portInUse(let port):
                return "端口 \(port) 已被占用。请关闭占用该端口的程序或在设置中修改端口。"
            case .startupFailed(let detail):
                return "DSH 服务启动失败：\n\n\(detail)"
            }
        }
    }

    private static let readyRegex = try! NSRegularExpression(
        pattern: #"dsh web: (http://127\.0\.0\.1:\d+)\b"#
    )

    private init() {}

    /// Check if a local TCP port is available to bind.
    public func isPortAvailable(_ port: Int) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var reuse = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int>.size))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }

    /// Start or restart the DSH service and return the ready URL.
    public func start(port: Int? = nil) async throws -> URL {
        let actualPort = port ?? (DshStateManager.shared.current.dshPort ?? 3080)

        // A settings change, version switch, or plugin mutation is a restart.
        // Wait for the old child to exit before probing the port; otherwise
        // the old service can make its own restart look like an external
        // conflict.
        await stopAndWait()
        // A hard kill (crash, kill -9, or an app-level kill during quit) can
        // leave the previous DSH web server holding the port because
        // applicationWillTerminate never ran. Reclaim only the process
        // recorded by this app before probing so an orphaned child process
        // never blocks this launch without killing an unrelated DSH instance.
        recycleStaleDshServerIfNeeded(onPort: actualPort)
        let portDeadline = Date().addingTimeInterval(3.0)
        while !isPortAvailable(actualPort), Date() < portDeadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard isPortAvailable(actualPort) else {
            throw ServiceError.portInUse(actualPort)
        }

        guard let entry = DshVersionManager.shared.resolveCurrentEntry() else {
            throw ServiceError.dshEntryNotFound
        }

        guard let nodePath = NodeRuntime.shared.resolveNodeBinary() else {
            throw ServiceError.nodeNotFound
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = Self.buildArguments(
            entry: entry,
            port: actualPort,
            version: Self.resolveDshVersion(forEntry: entry)
        )
        proc.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        let environment = NodeRuntime.shared.buildEnvironment()
        proc.environment = environment

        do {
            try proc.run()
        } catch {
            throw ServiceError.startupFailed(error.localizedDescription)
        }
        // Put the child into its own process group so a single kill(-pgid) can
        // reach node and any subprocesses DSH forked; killing only the direct
        // pid leaves the actual web worker alive and holding the port.
        let hasProcessGroup = makeProcessGroupLeader(proc)
        let processGroupID = hasProcessGroup ? proc.processIdentifier : nil
        setProcess(ManagedDshProcess(process: proc, hasProcessGroup: hasProcessGroup))
        saveProcessRecord(DshProcessRecord(
            pid: proc.processIdentifier,
            port: actualPort,
            nodePath: nodePath,
            entryPath: entry,
            processGroupID: processGroupID
        ))

        let waiter = ProcessWaiter(
            proc: proc,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            hasProcessGroup: hasProcessGroup
        )
        return try await waiter.wait()
    }

    public static func buildArguments(entry: String, port: Int, version: String?) -> [String] {
        var arguments = [
            "--expose-internals",
            entry,
            "--profile", "web",
            "--host", "127.0.0.1",
            "--port", String(port)
        ]
        if let version,
           let semanticVersion = DshSemanticVersion(version),
           semanticVersion.supportsNoOpen {
            arguments.append("--no-open")
        }
        return arguments
    }

    private static func resolveDshVersion(forEntry entry: String) -> String? {
        var directory = URL(fileURLWithPath: entry).deletingLastPathComponent()
        for _ in 0..<5 {
            let manifestURL = directory.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               manifest["name"] as? String == "@deepseek-ai/dsh",
               let version = manifest["version"] as? String {
                return version
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    public func stop() {
        let managed = takeProcess()
        guard let managed,
              managed.process.isRunning || managed.hasProcessGroup else { return }
        managed.process.terminationHandler = nil
        signalManagedProcess(managed, SIGTERM)
        // This runs from applicationWillTerminate. The old code scheduled SIGKILL
        // on a background queue 3 seconds later; once the app exits that delayed
        // callback never fires, leaving `node bin.js --profile web` alive and the
        // port occupied. Escalate here, synchronously, so quitting never orphans
        // the server. Keep the grace short so Cmd+Q stays responsive.
        let deadline = Date().addingTimeInterval(0.6)
        while managed.process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        signalManagedProcess(managed, SIGKILL)
    }

    private func stopAndWait() async {
        let managed = takeProcess()

        guard let managed,
              managed.process.isRunning || managed.hasProcessGroup else { return }
        managed.process.terminationHandler = nil
        signalManagedProcess(managed, SIGTERM)

        let deadline = Date().addingTimeInterval(3.0)
        while managed.process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        signalManagedProcess(managed, SIGKILL)
    }

    private func makeProcessGroupLeader(_ proc: Process) -> Bool {
        let pid = proc.processIdentifier
        // setpgid can race with the child's exec; retry briefly so the child
        // lands in its own process group and `kill(-pid)` can reach its subtree.
        for _ in 0..<5 {
            if setpgid(pid, pid) == 0 { return true }
            usleep(10_000)
        }
        return false
    }

    /// Signal the managed process without falling back to a potentially reused
    /// PID after the direct child has exited. A surviving process group can
    /// still contain the web worker, so it remains safe to signal that group.
    private func signalManagedProcess(_ managed: ManagedDshProcess, _ signal: Int32) {
        let pid = managed.process.processIdentifier
        if managed.hasProcessGroup {
            if kill(-pid, signal) != 0, managed.process.isRunning {
                _ = kill(pid, signal)
            }
        } else if managed.process.isRunning {
            _ = kill(pid, signal)
        }
    }

    /// Reclaim a port still held by this app's stale DSH web server after a
    /// hard kill. The record scopes recovery to the exact PID and, when
    /// available, the exact process group created for this app.
    private func recycleStaleDshServerIfNeeded(onPort port: Int) {
        guard !isPortAvailable(port),
              let record = loadProcessRecord(),
              record.port == port else { return }

        let listeners = listeningPids(on: port)
        guard listeners.contains(where: { isRecordedDshServer(pid: $0, record: record) }) else {
            return
        }

        terminateRecordedProcess(record)
    }

    private func terminateRecordedProcess(_ record: DshProcessRecord) {
        let pid = pid_t(record.pid)
        if let groupID = record.processGroupID {
            _ = kill(-pid_t(groupID), SIGTERM)
        } else if isRecordedDshServer(pid: pid, record: record) {
            _ = kill(pid, SIGTERM)
        }

        usleep(150_000)

        // Never fall back to a direct kill after the group leader has gone
        // away. If the group no longer exists, its members are gone too; a
        // direct kill at this point could hit a recycled PID.
        if let groupID = record.processGroupID {
            _ = kill(-pid_t(groupID), SIGKILL)
        } else if isRecordedDshServer(pid: pid, record: record) {
            _ = kill(pid, SIGKILL)
        }
    }

    /// Verify that a recorded PID still carries this app's DSH command line.
    /// A PID alone is not ownership: it can be reused after a process exits.
    private func isRecordedDshServer(pid: pid_t, record: DshProcessRecord) -> Bool {
        guard let command = processCommandLine(pid) else { return false }
        if pid == pid_t(record.pid) {
            return command.contains(record.nodePath)
                && command.contains(record.entryPath)
                && command.contains("--profile web")
                && command.contains("--host 127.0.0.1")
                && command.contains("--port \(record.port)")
        }

        guard let groupID = record.processGroupID else { return false }
        return getpgid(pid) == pid_t(groupID)
    }

    private func processCommandLine(_ pid: pid_t) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-ww", "-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private func listeningPids(on port: Int) -> [pid_t] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-ti", ":\(port)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return [] }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func loadProcessRecord() -> DshProcessRecord? {
        guard let data = try? Data(contentsOf: processRecordURL) else { return nil }
        return try? JSONDecoder().decode(DshProcessRecord.self, from: data)
    }

    private func saveProcessRecord(_ record: DshProcessRecord) {
        do {
            let data = try JSONEncoder().encode(record)
            try data.write(to: processRecordURL, options: .atomic)
        } catch {
            print("[DshService] Failed to save process record:", error)
        }
    }

    private func takeProcess() -> ManagedDshProcess? {
        lock.lock()
        defer { lock.unlock() }
        let proc = process
        process = nil
        return proc
    }

    private func setProcess(_ managed: ManagedDshProcess) {
        lock.lock()
        process = managed
        lock.unlock()
    }
}

private final class ProcessWaiter: @unchecked Sendable {
    private let proc: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let hasProcessGroup: Bool
    private let lock = NSLock()
    private var output = ""
    private var settled = false
    private var continuation: CheckedContinuation<URL, Error>?
    private var timeoutTask: DispatchWorkItem?

    private static let readyRegex = try! NSRegularExpression(
        pattern: #"dsh web: (http://127\.0\.0\.1:\d+)\b"#
    )

    init(proc: Process, stdoutPipe: Pipe, stderrPipe: Pipe, hasProcessGroup: Bool) {
        self.proc = proc
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.hasProcessGroup = hasProcessGroup
    }

    func wait() async throws -> URL {
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont

            let timeoutTask = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                let pid = self.proc.processIdentifier
                if self.hasProcessGroup {
                    _ = kill(-pid, SIGTERM)
                    _ = kill(-pid, SIGKILL)
                } else if self.proc.isRunning {
                    _ = kill(pid, SIGTERM)
                    _ = kill(pid, SIGKILL)
                }
                self.lock.lock()
                let currentOutput = self.output.isEmpty ? "等待 60 秒后超时。" : self.output
                self.lock.unlock()
                self.finish(.failure(DshService.ServiceError.startupFailed(currentOutput)))
            }
            self.timeoutTask = timeoutTask

            self.stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                self?.inspect(handle.availableData)
            }
            self.stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                self?.inspect(handle.availableData)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeoutTask)

            self.proc.terminationHandler = { [weak self] terminatedProcess in
                guard let self = self else { return }
                self.lock.lock()
                let detail = """
                退出码 \(terminatedProcess.terminationStatus)，信号 \(terminatedProcess.terminationReason.rawValue)
                \(self.output)
                """
                self.lock.unlock()
                self.finish(.failure(DshService.ServiceError.startupFailed(detail)))
            }
        }
    }

    private func inspect(_ data: Data) {
        guard !data.isEmpty,
              let chunk = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        output += chunk
        let range = NSRange(output.startIndex..., in: output)
        let match = Self.readyRegex.firstMatch(in: output, range: range)
        var matchedUrl: URL?
        if let match = match, let urlRange = Range(match.range(at: 1), in: output) {
            matchedUrl = URL(string: String(output[urlRange]))
        }
        lock.unlock()

        if let url = matchedUrl {
            finish(.success(url))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return }
        settled = true
        timeoutTask?.cancel()
        timeoutTask = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}
