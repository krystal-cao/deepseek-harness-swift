import Foundation
import Darwin

/// Non-blocking FIFO gate shared by service startup and the desktop shell's
/// wider Runtime/Profile operation. Waiting callers suspend instead of
/// blocking the main actor.
final class DshAsyncOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            var resumeImmediately = false
            lock.lock()
            if isHeld {
                waiters.append(continuation)
            } else {
                isHeld = true
                resumeImmediately = true
            }
            lock.unlock()

            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>?
        lock.lock()
        if waiters.isEmpty {
            isHeld = false
            next = nil
        } else {
            next = waiters.removeFirst()
        }
        lock.unlock()
        next?.resume()
    }
}

/// Spawns and supervises the DSH Web child process.
public final class DshService: @unchecked Sendable {
    public static let shared = DshService()

    private struct ManagedDshProcess {
        let process: Process
        let hasProcessGroup: Bool
        let controlWriteHandle: FileHandle
        let generationID: UUID
        let processIO: DshProcessIO
        let access: DshAccessController
    }

    private struct DshProcessRecord: Codable {
        let pid: Int32
        let port: Int
        let nodePath: String
        let processGroupID: Int32?
        let generationID: String?
        let processStartTime: Double?
    }

    private var process: ManagedDshProcess?
    private let lock = NSLock()
    private let startOperationGate = DshAsyncOperationGate()
    private var processRecordURL: URL {
        DshStateManager.appSupportDirectory.appendingPathComponent("dsh-service-process.json")
    }

    public enum ServiceError: Error, LocalizedError {
        case dshEntryNotFound
        case nodeNotFound
        case runtimeBootstrapNotFound
        case serviceNotRunning
        case portInUse(Int)
        case startupFailed(String)

        public var errorDescription: String? {
            switch self {
            case .dshEntryNotFound:
                return "找不到 DSH 运行时入口。请确认已安装或在设置中下载版本。"
            case .nodeNotFound:
                return "找不到 Node.js 运行时可执行文件。"
            case .runtimeBootstrapNotFound:
                return "找不到 DSH 运行时启动器。请重新安装应用。"
            case .serviceNotRunning:
                return "DSH 服务尚未就绪，无法更新浏览器访问策略。"
            case .portInUse(let port):
                return "端口 \(port) 已被占用。请关闭占用该端口的程序或在设置中修改端口。"
            case .startupFailed(let detail):
                return "DSH 服务启动失败：\n\n\(detail)"
            }
        }
    }

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

    /// Stop this app's current or persisted child before another component
    /// mutates a Profile on disk. A force-quit can leave the Node child alive
    /// after the in-memory `ManagedDshProcess` has gone away, so the persisted
    /// PID/process-group record must be checked before Profile recovery too.
    ///
    /// The configured port is also required to be free before returning. This
    /// prevents an unrelated DSH process sharing the web Profile from racing
    /// pnpm cleanup when ownership cannot be established safely.
    public func prepareForProfileMutation() async throws {
        await startOperationGate.acquire()
        defer { startOperationGate.release() }

        await stopAndWait()

        let actualPort = DshStateManager.shared.current.dshPort ?? 3080
        // The persisted record belongs to the previous app-owned process,
        // not to the current port setting. This must run before checking the
        // new port so a port change cannot strand the old child.
        recycleStaleDshServerIfNeeded()

        let deadline = Date().addingTimeInterval(3.0)
        while !isPortAvailable(actualPort), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard isPortAvailable(actualPort) else {
            throw ServiceError.portInUse(actualPort)
        }
    }

    /// Start or restart the DSH service and return the protected session.
    public func start(port: Int? = nil) async throws -> DshServiceSession {
        await startOperationGate.acquire()
        defer { startOperationGate.release() }

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
        recycleStaleDshServerIfNeeded()
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
        guard let runtimeBootstrap = NodeRuntime.shared.resolveRuntimeBootstrap() else {
            throw ServiceError.runtimeBootstrapNotFound
        }

        let state = DshStateManager.shared.current
        // Do not gate startup on a Runtime-version allow-list. DshProcessIO
        // derives the supported authentication shape from the validated ready
        // URL, and MainWindowController performs the behavioral health gate.
        let access = try DshAccessController(
            ordinaryBrowserEnabled: state.browserAccessEnabled,
            networkExposure: state.networkExposure
        )

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = Self.buildArguments(runtimeBootstrap: runtimeBootstrap)
        proc.standardInput = access.controlReadHandle

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        let environment = NodeRuntime.shared.buildEnvironment()
        var managedEnvironment = environment
        managedEnvironment["DSH_DESKTOP_LAUNCH"] = "1"
        managedEnvironment["DSH_DESKTOP_PORT"] = String(actualPort)
        proc.environment = managedEnvironment

        let processIO = DshProcessIO(
            proc: proc,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            expectedGeneration: access.generation.id,
            expectedPort: actualPort,
            secrets: [access.generation.rendererToken]
        )
        processIO.start()

        do {
            try proc.run()
        } catch {
            processIO.fail(error)
            access.closeWriteHandle()
            throw ServiceError.startupFailed(error.localizedDescription)
        }
        // Put the child into its own process group so a single kill(-pgid) can
        // reach node and any subprocesses DSH forked; killing only the direct
        // pid leaves the actual web worker alive and holding the port.
        let hasProcessGroup = makeProcessGroupLeader(proc)
        let processGroupID = hasProcessGroup ? proc.processIdentifier : nil
        setProcess(ManagedDshProcess(
            process: proc,
            hasProcessGroup: hasProcessGroup,
            controlWriteHandle: access.controlWriteHandle,
            generationID: access.generation.id,
            processIO: processIO,
            access: access
        ))
        saveProcessRecord(DshProcessRecord(
            pid: proc.processIdentifier,
            port: actualPort,
            nodePath: canonicalPath(nodePath),
            processGroupID: processGroupID,
            generationID: access.generation.id.uuidString,
            processStartTime: processStartTime(proc.processIdentifier)
        ))

        do {
            try access.sendBootstrap(
                entryPath: entry,
                profile: state.appProfile,
                port: actualPort
            )
            let endpoint = try await processIO.waitForReady()
            return DshServiceSession(endpoint: endpoint, access: access.generation)
        } catch {
            await stopAndWait()
            if let serviceError = error as? ServiceError { throw serviceError }
            throw ServiceError.startupFailed(error.localizedDescription)
        }
    }

    /// Apply a browser-access change to the running generation and wait for
    /// the matching Node acknowledgement before reporting success.
    public func setBrowserAccessEnabled(_ enabled: Bool) async throws {
        guard let managed = currentProcess() else {
            throw ServiceError.serviceNotRunning
        }
        let exposure = enabled ? managed.access.currentPolicy.networkExposure : .loopback
        let revision = try managed.access.sendPolicy(
            ordinaryBrowserEnabled: enabled,
            networkExposure: exposure
        )
        try await managed.processIO.waitForPolicyApplied(
            generation: managed.generationID,
            revision: revision,
            ordinaryBrowserEnabled: enabled,
            networkExposure: exposure
        )
    }

    /// Enable or disable the separate LAN ingress. The DSH WebServer itself
    /// remains loopback-only; the Node Host owns the temporary forwarding
    /// listener and reports its readiness through the policy acknowledgement.
    public func setNetworkExposure(_ exposure: DshNetworkExposure) async throws {
        guard let managed = currentProcess() else {
            throw ServiceError.serviceNotRunning
        }
        let browserEnabled = managed.access.currentPolicy.ordinaryBrowserEnabled
        guard exposure == .loopback || browserEnabled else {
            throw DshControlProtocolError.invalidPolicy
        }
        let revision = try managed.access.sendPolicy(
            ordinaryBrowserEnabled: browserEnabled,
            networkExposure: exposure
        )
        try await managed.processIO.waitForPolicyApplied(
            generation: managed.generationID,
            revision: revision,
            ordinaryBrowserEnabled: browserEnabled,
            networkExposure: exposure
        )
    }

    public static func buildArguments(runtimeBootstrap: String) -> [String] {
        ["--expose-internals", runtimeBootstrap]
    }

    public func stop() {
        let managed = takeProcess()
        guard let managed else { return }
        managed.controlWriteHandle.closeFile()
        guard managed.process.isRunning || managed.hasProcessGroup else { return }
        managed.process.terminationHandler = nil
        signalManagedProcess(managed, SIGTERM)
        // This runs from applicationWillTerminate. The old code scheduled SIGKILL
        // on a background queue 3 seconds later; once the app exits that delayed
        // callback never fires, leaving the managed `node bin.js --profile ...` alive and the
        // port occupied. Escalate here, synchronously, so quitting never orphans
        // the server. Keep the grace short so Cmd+Q stays responsive.
        let deadline = Date().addingTimeInterval(0.6)
        while managed.process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        signalManagedProcess(managed, SIGKILL)
    }

    /// Stop the managed child without blocking the caller while waiting for
    /// its termination. Runtime/Profile transactions use this before taking
    /// a Profile snapshot so Node cannot mutate the tree during the clone.
    public func stopAndWait() async {
        let managed = takeProcess()

        guard let managed else { return }
        managed.controlWriteHandle.closeFile()
        guard managed.process.isRunning || managed.hasProcessGroup else { return }
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

    /// Reclaim this app's stale DSH web server after a hard kill. The
    /// persisted record is authoritative for the old process and may point
    /// to a port that is no longer the current setting.
    private func recycleStaleDshServerIfNeeded() {
        guard let record = loadProcessRecord() else { return }

        let recordedLeaderIsAlive = isRecordedDshServer(
            pid: pid_t(record.pid),
            record: record
        )
        let recordedListenerIsAlive = listeningPids(on: record.port).contains {
            isRecordedDshServer(pid: $0, record: record)
        }
        guard recordedLeaderIsAlive || recordedListenerIsAlive else { return }

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
        if let groupID = record.processGroupID,
           listeningPids(on: record.port).contains(where: { isRecordedDshServer(pid: $0, record: record) }) {
            _ = kill(-pid_t(groupID), SIGKILL)
        } else if isRecordedDshServer(pid: pid, record: record) {
            _ = kill(pid, SIGKILL)
        }
    }

    /// Verify the recorded process using kernel identity, not its command line.
    /// A PID alone is not ownership: it can be reused after a process exits.
    private func isRecordedDshServer(pid: pid_t, record: DshProcessRecord) -> Bool {
        guard processExecutablePath(pid) == canonicalPath(record.nodePath) else { return false }
        if pid == pid_t(record.pid) {
            guard let expectedStart = record.processStartTime,
                  let actualStart = processStartTime(pid) else { return false }
            return abs(expectedStart - actualStart) < 0.01
        }

        guard let groupID = record.processGroupID else { return false }
        // A surviving group member is only reclaimable while the recorded
        // leader still proves its own PID/start-time identity. This prevents
        // a recycled PGID from becoming an ownership claim by itself.
        return getpgid(pid) == pid_t(groupID)
            && isRecordedLeader(record)
    }

    private func isRecordedLeader(_ record: DshProcessRecord) -> Bool {
        isRecordedDshServer(pid: pid_t(record.pid), record: record)
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func processExecutablePath(_ pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C macro that is not imported by the
        // Swift Darwin overlay; 16 KiB safely covers macOS executable paths.
        var buffer = [CChar](repeating: 0, count: 16 * 1024)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return canonicalPath(String(cString: buffer))
    }

    private func processStartTime(_ pid: pid_t) -> Double? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
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

    private func currentProcess() -> ManagedDshProcess? {
        lock.lock()
        defer { lock.unlock() }
        return process
    }
}
