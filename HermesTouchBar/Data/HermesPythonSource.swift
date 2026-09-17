// HermesPythonSource.swift
// Spawns the long-running `hermes_source.py` subprocess and surfaces its
// JSON-lines stdout as an `AsyncStream<HermesWireStatus>`. Tier A
// implementation — replaces the old filesystem-poll reader for the
// fields the Python feed actually exposes (gateway up/down, active
// session id/model/source, current skin, etc.).
//
// Lifecycle:
//   1. AppDelegate calls `start()` once at launch.
//   2. Pipe handler reads stdout line by line, JSONDecoder parses each
//      frame, yielding HermesWireStatus into the stream.
//   3. On subprocess crash, `terminationHandler` schedules a 1s restart.
//   4. AppDelegate calls `stop()` at shutdown.
//
// Failure handling:
//   - Python interpreter not found → throws `SourceError.pythonNotFound`
//     (caller falls back to StatusReader).
//   - Script not found → throws `SourceError.scriptNotFound`.
//   - Subprocess dies after start → silent restart (no exception escapes).
//   - Bad JSON line / unknown schema version → logged to stderr, frame
//     dropped, stream continues with previous (or empty) value.
//
// Threading:
//   - actor-isolated mutable state (process, restart task).
//   - stdout reads happen on a background queue (Pipe's readabilityHandler).
//   - Stream yields are nonisolated via Task; consumers must be on the
//     actor's continuation or downstream `@MainActor` consumer.

import Foundation
import HermesDomain

actor HermesPythonSource {

    enum SourceError: Error {
        case pythonNotFound
        case scriptNotFound
        case spawnFailed(String)
    }

    /// Stream of decoded wire frames. `bufferingNewest(1)` means a slow
    /// consumer will not block the subprocess; the oldest pending frame
    /// is dropped instead. UI repaints don't care about every frame.
    let stream: AsyncStream<HermesWireStatus>
    private let continuation: AsyncStream<HermesWireStatus>.Continuation

    private var process: Process?
    private var restartTask: Task<Void, Never>?
    private var stdoutBuffer = Data()

    /// Set once `start()` succeeds so callers can check liveness cheaply.
    private(set) var isRunning: Bool = false

    init() {
        var cont: AsyncStream<HermesWireStatus>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c in
            cont = c
        }
        self.continuation = cont
    }

    deinit {
        continuation.finish()
        process?.terminate()
    }

    // MARK: - Public API

    func start() throws {
        let python: String
        do {
            python = try PythonLocator.findPython()
        } catch {
            throw error
        }
        guard let script = locateScript() else {
            throw SourceError.scriptNotFound
        }
        try spawn(python: python, script: script)
        isRunning = true
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        process?.terminate()
        process = nil
        isRunning = false
    }

    // MARK: - Spawn

    private func spawn(python: String, script: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script]
        // Inherit HERMES_HOME if set so the Python side can find the install.
        var env = ProcessInfo.processInfo.environment
        if env["HERMES_HOME"] == nil {
            env["HERMES_HOME"] = NSString("~/.hermes").expandingTildeInPath
        }
        p.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr

        // Stdout handler: read lines, parse each frame, yield.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.ingest(data: data) }
        }

        // Stderr handler: forward to our stderr (visible in Console.app).
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                FileHandle.standardError.write(data)
            }
        }

        // Termination: schedule restart if we didn't ask for it.
        p.terminationHandler = { [weak self] proc in
            let wasGraceful = (proc.terminationReason == .uncaughtSignal)
                ? false
                : (proc.terminationStatus == 0)
            Task { await self?.handleTermination(wasGraceful: wasGraceful) }
        }

        do {
            try p.run()
            self.process = p
        } catch {
            throw SourceError.spawnFailed("\(error)")
        }
    }

    // MARK: - Stream ingestion

    private func ingest(data: Data) {
        stdoutBuffer.append(data)
        // Lines are delimited by '\n'; split by scanning for it.
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard !lineData.isEmpty else { continue }
            decodeAndYield(lineData)
        }
    }

    private func decodeAndYield(_ data: Data) {
        do {
            let wire = try Self.decoder.decode(HermesWireStatus.self, from: data)
            guard wire.v == HermesWireStatus.supportedVersion else {
                FileHandle.standardError.write(
                    "HermesPythonSource: unsupported schema v\(wire.v), skipping frame\n"
                        .data(using: .utf8) ?? Data()
                )
                return
            }
            continuation.yield(wire)
        } catch {
            let preview = String(data: data.prefix(120), encoding: .utf8) ?? "<binary>"
            FileHandle.standardError.write(
                "HermesPythonSource: decode failed: \(error) — line: \(preview)\n"
                    .data(using: .utf8) ?? Data()
            )
        }
    }

    // MARK: - Termination / restart

    private func handleTermination(wasGraceful: Bool) {
        process = nil
        isRunning = false
        guard !wasGraceful else {
            // User-initiated stop — don't restart.
            return
        }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self else { return }
            do {
                try await self.start()
            } catch {
                FileHandle.standardError.write(
                    "HermesPythonSource: restart failed: \(error)\n"
                        .data(using: .utf8) ?? Data()
                )
            }
        }
    }

    // MARK: - Script location

    private func locateScript() -> String? {
        // 1) Inside the app bundle (production / after ./scripts/build.sh)
        if let bundled = Bundle.main.url(forResource: "hermes_source", withExtension: "py") {
            return bundled.path
        }
        // 2) Dev fallback: hermes_source.py is the sibling of this source file.
        //    #file is resolved at compile time to the path passed to swiftc;
        //    scripts/build.sh + scripts/test.sh both invoke swiftc from
        //    PROJECT_DIR with relative paths, so the sibling lookup works
        //    regardless of who cloned the repo or where it lives.
        let sibling = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("hermes_source.py")
        if FileManager.default.fileExists(atPath: sibling.path) {
            return sibling.path
        }
        return nil
    }

    // MARK: - Decoder

    static let decoder: JSONDecoder = {
        // Do NOT use `keyDecodingStrategy = .convertFromSnakeCase` here:
        // every nested struct in HermesWireStatus.swift declares explicit
        // CodingKeys (snake_case ↔ camelCase). Mixing the strategy with
        // explicit mappings produced `keyNotFound` on `recent_messages`
        // because the strategy re-mapped an already-mapped key.
        JSONDecoder()
    }()
}

// MARK: - Python interpreter discovery

enum PythonLocator {
    /// Find a Python that can `import hermes_cli.gateway`. Order:
    ///   1. `$HERMES_PYTHON` env var
    ///   2. `~/.hermes/hermes-agent/venv/bin/python3` (the hermes install)
    ///   3. `/usr/bin/python3`
    static func findPython() throws -> String {
        let env = ProcessInfo.processInfo.environment["HERMES_PYTHON"]
        if let env, !env.isEmpty, FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        let candidates = [
            "\(NSString("~/.hermes").expandingTildeInPath)/hermes-agent/venv/bin/python3",
            "/usr/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        throw HermesPythonSource.SourceError.pythonNotFound
    }
}
