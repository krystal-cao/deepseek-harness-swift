import Foundation

public enum DshProcessIOError: Error, LocalizedError, Sendable {
    case timedOut(String)
    case processExited(String)
    case generationMismatch
    case policyMismatch

    public var errorDescription: String? {
        switch self {
        case .timedOut(let detail):
            return detail.isEmpty ? "等待 DSH 桌面控制握手超时。" : "等待 DSH 桌面控制握手超时：\n\n\(detail)"
        case .processExited(let detail):
            return "DSH 进程在完成桌面控制握手前退出：\n\n\(detail)"
        case .generationMismatch:
            return "DSH 桌面控制代际不匹配。"
        case .policyMismatch:
            return "DSH 桌面浏览器访问策略确认不匹配。"
        }
    }
}

/// Drains child stdout/stderr for the complete process lifetime and resolves
/// readiness only after both the Web URL and the matching desktop handshake.
public final class DshProcessIO: @unchecked Sendable {
    private static let readyRegex = try! NSRegularExpression(
        pattern: #"dsh web: (http://127\.0\.0\.1:\d+)\b"#
    )
    private static let controlReadyRegex = try! NSRegularExpression(
        pattern: #"dsh desktop control ready: ([0-9A-Fa-f-]{36})\b"#
    )
    private static let policyRegex = try! NSRegularExpression(
        pattern: #"dsh desktop policy applied: ([0-9A-Fa-f-]{36}) (\d+) (true|false) (loopback|lan)\b"#
    )
    private static let maxLogBytes = 256 * 1024

    private let proc: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let expectedGeneration: UUID
    private let secrets: [String]
    private let lock = NSLock()

    private var stdoutPartial = ""
    private var stderrPartial = ""
    private var ringBuffer = Data()
    private var webURL: URL?
    private var controlReadyGeneration: UUID?
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var readyTimeoutTask: DispatchWorkItem?
    private var readySettled = false
    private var policyAcks: [Int: (generation: UUID, enabled: Bool, exposure: DshNetworkExposure)] = [:]
    private var policyContinuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var policyExpectations: [Int: Bool] = [:]
    private var policyExposureExpectations: [Int: DshNetworkExposure] = [:]
    private var policyTimeoutTasks: [Int: DispatchWorkItem] = [:]
    private var terminalError: Error?
    private var started = false

    public init(
        proc: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        expectedGeneration: UUID,
        secrets: [String] = []
    ) {
        self.proc = proc
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.expectedGeneration = expectedGeneration
        self.secrets = secrets.filter { !$0.isEmpty }
    }

    public func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, isStdout: true, handle: handle)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, isStdout: false, handle: handle)
        }
        proc.terminationHandler = { [weak self] terminatedProcess in
            self?.processTerminated(terminatedProcess)
        }
    }

    public func waitForReady(timeout: TimeInterval = 60) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            var immediateResult: Result<URL, Error>?
            lock.lock()
            if let webURL, controlReadyGeneration == expectedGeneration {
                immediateResult = .success(webURL)
            } else if let terminalError {
                immediateResult = .failure(terminalError)
            } else {
                readyContinuation = continuation
                let timeoutTask = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.failReady(DshProcessIOError.timedOut(self.diagnosticOutput()))
                }
                readyTimeoutTask = timeoutTask
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + timeout,
                    execute: timeoutTask
                )
            }
            lock.unlock()

            if let immediateResult {
                continuation.resume(with: immediateResult)
            }
        }
    }

    public func diagnosticOutput() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: ringBuffer, encoding: .utf8) ?? ""
    }

    public func waitForPolicyApplied(
        generation: UUID,
        revision: Int,
        ordinaryBrowserEnabled: Bool,
        networkExposure: DshNetworkExposure,
        timeout: TimeInterval = 10
    ) async throws {
        guard generation == expectedGeneration, revision >= 1 else {
            throw DshProcessIOError.policyMismatch
        }

        try await withCheckedThrowingContinuation { continuation in
            var immediateResult: Result<Void, Error>?
            lock.lock()
            if let terminalError {
                immediateResult = .failure(terminalError)
            } else if let ack = policyAcks.removeValue(forKey: revision) {
                immediateResult = ack.generation == generation && ack.enabled == ordinaryBrowserEnabled && ack.exposure == networkExposure
                    ? .success(())
                    : .failure(DshProcessIOError.policyMismatch)
            } else if policyContinuations[revision] != nil {
                immediateResult = .failure(DshProcessIOError.policyMismatch)
            } else {
                policyContinuations[revision] = continuation
                policyExpectations[revision] = ordinaryBrowserEnabled
                policyExposureExpectations[revision] = networkExposure
                let timeoutTask = DispatchWorkItem { [weak self] in
                    self?.failPolicy(revision: revision, error: DshProcessIOError.timedOut(self?.diagnosticOutput() ?? ""))
                }
                policyTimeoutTasks[revision] = timeoutTask
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + timeout,
                    execute: timeoutTask
                )
            }
            lock.unlock()

            if let immediateResult {
                continuation.resume(with: immediateResult)
            }
        }
    }

    public func fail(_ error: Error) {
        failReady(error)
    }

    private func consume(_ data: Data, isStdout: Bool, handle: FileHandle) {
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            return
        }
        guard let chunk = String(data: data, encoding: .utf8) else {
            appendLog("[非 UTF-8 输出已忽略]")
            return
        }

        var lines: [String] = []
        lock.lock()
        if isStdout {
            stdoutPartial.append(chunk)
            while let newline = stdoutPartial.firstIndex(of: "\n") {
                lines.append(String(stdoutPartial[..<newline]).trimmingCharacters(in: .newlines))
                stdoutPartial.removeSubrange(...newline)
            }
        } else {
            stderrPartial.append(chunk)
            while let newline = stderrPartial.firstIndex(of: "\n") {
                lines.append(String(stderrPartial[..<newline]).trimmingCharacters(in: .newlines))
                stderrPartial.removeSubrange(...newline)
            }
        }
        for line in lines {
            let redacted = redact(line)
            ringBuffer.append(contentsOf: Data((redacted + "\n").utf8))
        }
        if ringBuffer.count > Self.maxLogBytes {
            ringBuffer.removeFirst(ringBuffer.count - Self.maxLogBytes)
        }
        lock.unlock()

        for line in lines {
            inspect(line)
        }
    }

    private func inspect(_ line: String) {
        let range = NSRange(line.startIndex..., in: line)
        if let match = Self.readyRegex.firstMatch(in: line, range: range),
           let urlRange = Range(match.range(at: 1), in: line),
           let url = URL(string: String(line[urlRange])) {
            lock.lock()
            webURL = url
            lock.unlock()
            resolveReadyIfPossible()
            return
        }

        if let match = Self.controlReadyRegex.firstMatch(in: line, range: range),
           let generationRange = Range(match.range(at: 1), in: line),
           let generation = UUID(uuidString: String(line[generationRange])) {
            lock.lock()
            controlReadyGeneration = generation
            lock.unlock()
            if generation != expectedGeneration {
                failReady(DshProcessIOError.generationMismatch)
            } else {
                resolveReadyIfPossible()
            }
            return
        }

        if let match = Self.policyRegex.firstMatch(in: line, range: range),
           let generationRange = Range(match.range(at: 1), in: line),
           let revisionRange = Range(match.range(at: 2), in: line),
           let enabledRange = Range(match.range(at: 3), in: line),
           let exposureRange = Range(match.range(at: 4), in: line),
           let generation = UUID(uuidString: String(line[generationRange])),
           let revision = Int(line[revisionRange]) {
            let enabled = String(line[enabledRange]) == "true"
            guard let exposure = DshNetworkExposure(rawValue: String(line[exposureRange])) else { return }
            var continuation: CheckedContinuation<Void, Error>?
            var result: Result<Void, Error> = .success(())
            lock.lock()
            policyAcks[revision] = (generation, enabled, exposure)
            continuation = policyContinuations.removeValue(forKey: revision)
            let expectedEnabled = policyExpectations.removeValue(forKey: revision)
            let expectedExposure = policyExposureExpectations.removeValue(forKey: revision)
            policyTimeoutTasks.removeValue(forKey: revision)?.cancel()
            if continuation != nil {
                if generation != expectedGeneration {
                    result = .failure(DshProcessIOError.generationMismatch)
                } else if expectedEnabled != enabled || expectedExposure != exposure {
                    result = .failure(DshProcessIOError.policyMismatch)
                }
            }
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    private func resolveReadyIfPossible() {
        lock.lock()
        guard !readySettled,
              let webURL,
              controlReadyGeneration == expectedGeneration,
              let continuation = readyContinuation else {
            lock.unlock()
            return
        }
        readySettled = true
        readyContinuation = nil
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        lock.unlock()
        continuation.resume(returning: webURL)
    }

    private func failReady(_ error: Error) {
        var readyContinuation: CheckedContinuation<URL, Error>?
        var policyContinuations: [CheckedContinuation<Void, Error>] = []
        lock.lock()
        if terminalError == nil { terminalError = error }
        if !readySettled {
            readySettled = true
            readyContinuation = self.readyContinuation
            self.readyContinuation = nil
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
        }
        policyContinuations = Array(self.policyContinuations.values)
        self.policyContinuations.removeAll()
        self.policyExpectations.removeAll()
        self.policyExposureExpectations.removeAll()
        for task in policyTimeoutTasks.values { task.cancel() }
        policyTimeoutTasks.removeAll()
        lock.unlock()
        readyContinuation?.resume(throwing: error)
        for continuation in policyContinuations { continuation.resume(throwing: error) }
    }

    private func failPolicy(revision: Int, error: Error) {
        lock.lock()
        let continuation = policyContinuations.removeValue(forKey: revision)
        policyExpectations.removeValue(forKey: revision)
        policyExposureExpectations.removeValue(forKey: revision)
        policyTimeoutTasks.removeValue(forKey: revision)
        lock.unlock()
        continuation?.resume(throwing: error)
    }


    private func processTerminated(_ terminatedProcess: Process) {
        let detail = "退出码 \(terminatedProcess.terminationStatus)，信号 \(terminatedProcess.terminationReason.rawValue)\n\(diagnosticOutput())"
        failReady(DshProcessIOError.processExited(detail))
    }

    private func appendLog(_ line: String) {
        lock.lock()
        let redacted = redact(line)
        ringBuffer.append(contentsOf: Data((redacted + "\n").utf8))
        if ringBuffer.count > Self.maxLogBytes {
            ringBuffer.removeFirst(ringBuffer.count - Self.maxLogBytes)
        }
        lock.unlock()
    }

    private func redact(_ text: String) -> String {
        secrets.reduce(text) { partial, secret in
            partial.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
    }
}
