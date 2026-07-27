import AppKit
import Darwin
import Foundation

enum CodexAppServerTransportError: LocalizedError, Equatable {
    case executableNotFound
    case processLaunchFailed(String)
    case processExited(Int32, String)
    case unexpectedEndOfStream(String)
    case inputClosed
    case messageTooLarge

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "설치된 OpenAI Codex 실행 파일을 찾을 수 없습니다. Codex 앱 설치 상태를 확인해 주세요."
        case let .processLaunchFailed(message):
            "Codex App Server를 시작하지 못했습니다: \(message)"
        case let .processExited(status, details):
            details.isEmpty
                ? "Codex App Server가 예기치 않게 종료되었습니다 (코드 \(status))."
                : "Codex App Server가 예기치 않게 종료되었습니다 (코드 \(status)): \(details)"
        case let .unexpectedEndOfStream(details):
            details.isEmpty
                ? "Codex App Server 연결이 예기치 않게 종료되었습니다."
                : "Codex App Server 연결이 예기치 않게 종료되었습니다: \(details)"
        case .inputClosed:
            "Codex App Server 입력 연결이 닫혀 있습니다."
        case .messageTooLarge:
            "Codex App Server 응답이 허용된 크기를 초과했습니다."
        }
    }
}

protocol CodexAppServerTransporting: AnyObject, Sendable {
    var messages: AsyncThrowingStream<Data, Error> { get }

    func send(_ data: Data) throws
    func close()
}

protocol CodexAppServerLaunching: Sendable {
    func launch() throws -> any CodexAppServerTransporting
}

struct CodexAppServerProcessLauncher: CodexAppServerLaunching {
    private let resolver: CodexExecutableResolving

    init(resolver: CodexExecutableResolving = CodexExecutableResolver()) {
        self.resolver = resolver
    }

    func launch() throws -> any CodexAppServerTransporting {
        let executableURL = try resolver.resolve()
        return try CodexAppServerProcessTransport(executableURL: executableURL)
    }
}

protocol CodexExecutableResolving: Sendable {
    func resolve() throws -> URL
}

// FileManager's read-only path queries are safe here, but Foundation does not
// yet declare FileManager as Sendable.
struct CodexExecutableResolver: CodexExecutableResolving, @unchecked Sendable {
    static let overrideEnvironmentKey = "KCDEEPL_CODEX_EXECUTABLE"

    private let environment: [String: String]
    private let applicationURL: @Sendable () -> URL?
    private let fileManager: FileManager

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationURL: @escaping @Sendable () -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        },
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.applicationURL = applicationURL
        self.fileManager = fileManager
    }

    func resolve() throws -> URL {
        var candidates: [URL] = []

        if let overridePath = environment[Self.overrideEnvironmentKey],
           !overridePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: overridePath))
        }

        if let appURL = applicationURL() {
            candidates.append(
                appURL
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent("codex", isDirectory: false)
            )
        }

        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent("ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ])

        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent("codex", isDirectory: false)
            })
        }

        var visitedPaths = Set<String>()
        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            guard visitedPaths.insert(path).inserted else {
                continue
            }
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        throw CodexAppServerTransportError.executableNotFound
    }
}

final class CodexAppServerProcessTransport: CodexAppServerTransporting, @unchecked Sendable {
    private static let maximumPendingLineBytes = 16 * 1_024 * 1_024
    private static let maximumDiagnosticBytes = 4_096
    private static let disabledToolFeatures = [
        "apps",
        "browser_use",
        "computer_use",
        "goals",
        "hooks",
        "image_generation",
        "multi_agent",
        "plugins",
        "remote_plugin",
        "shell_snapshot",
        "shell_tool",
        "skill_search",
        "tool_suggest",
        "unified_exec",
        "workspace_dependencies"
    ]

    let messages: AsyncThrowingStream<Data, Error>

    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lineBuffer = CodexJSONLineBuffer(maximumBytes: maximumPendingLineBytes)
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var diagnosticData = Data()
    private var isClosed = false

    init(executableURL: URL) throws {
        var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation!
        messages = AsyncThrowingStream { continuation in
            streamContinuation = continuation
        }
        continuation = streamContinuation

        process.executableURL = executableURL
        process.arguments = [
            "app-server",
            "--listen", "stdio://",
            "-c", #"web_search="disabled""#,
            "-c", "mcp_servers={}"
        ] + Self.disabledToolFeatures.flatMap { ["--disable", $0] }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStandardOutput(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStandardError(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            self?.processDidTerminate(status: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            close()
            throw CodexAppServerTransportError.processLaunchFailed(error.localizedDescription)
        }
    }

    func send(_ data: Data) throws {
        stateLock.lock()
        let canWrite = !isClosed && process.isRunning
        stateLock.unlock()
        guard canWrite else {
            throw CodexAppServerTransportError.inputClosed
        }

        var framedData = data
        framedData.append(0x0A)

        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: framedData)
        } catch {
            throw CodexAppServerTransportError.processLaunchFailed(error.localizedDescription)
        }
    }

    func close() {
        guard markClosed() else {
            return
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        continuation.finish()
        terminateProcessIfNeeded()
    }

    private func consumeStandardOutput(_ data: Data) {
        guard !data.isEmpty else {
            finish(
                throwing: CodexAppServerTransportError.unexpectedEndOfStream(
                    boundedDiagnosticText()
                )
            )
            return
        }

        do {
            for line in try lineBuffer.append(data) where !line.isEmpty {
                continuation.yield(line)
            }
        } catch {
            finish(throwing: error)
        }
    }

    private func consumeStandardError(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        stateLock.lock()
        diagnosticData.append(data)
        if diagnosticData.count > Self.maximumDiagnosticBytes {
            diagnosticData.removeFirst(diagnosticData.count - Self.maximumDiagnosticBytes)
        }
        stateLock.unlock()
    }

    private func processDidTerminate(status: Int32) {
        if status == 0 {
            finish(
                throwing: CodexAppServerTransportError.unexpectedEndOfStream(
                    boundedDiagnosticText()
                )
            )
        } else {
            finish(
                throwing: CodexAppServerTransportError.processExited(
                    status,
                    boundedDiagnosticText()
                )
            )
        }
    }

    private func finish(throwing error: Error) {
        guard markClosed() else {
            return
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        continuation.finish(throwing: error)

        terminateProcessIfNeeded()
    }

    private func markClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isClosed else {
            return false
        }
        isClosed = true
        return true
    }

    private func boundedDiagnosticText() -> String {
        stateLock.lock()
        let data = diagnosticData
        stateLock.unlock()

        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func terminateProcessIfNeeded() {
        guard process.isRunning else {
            return
        }

        process.terminate()
        let runningProcess = process
        let processIdentifier = runningProcess.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            guard runningProcess.isRunning else {
                return
            }
            kill(processIdentifier, SIGKILL)
        }
    }
}

final class CodexJSONLineBuffer: @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var pendingData = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ data: Data) throws -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        pendingData.append(data)

        var lines: [Data] = []
        while let newlineIndex = pendingData.firstIndex(of: 0x0A) {
            guard newlineIndex <= maximumBytes else {
                pendingData.removeAll(keepingCapacity: false)
                throw CodexAppServerTransportError.messageTooLarge
            }

            var line = pendingData[..<newlineIndex]
            if line.last == 0x0D {
                line = line.dropLast()
            }
            lines.append(Data(line))
            pendingData.removeSubrange(...newlineIndex)
        }

        guard pendingData.count <= maximumBytes else {
            pendingData.removeAll(keepingCapacity: false)
            throw CodexAppServerTransportError.messageTooLarge
        }
        return lines
    }
}
