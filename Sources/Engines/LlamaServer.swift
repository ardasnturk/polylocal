import Foundation
import Darwin
import PolylocalCore

/// Runs `llama-server` as a child process for one model file.
/// Keeping the model out of the app process means a crash or memory spike never takes down the shortcuts.
public final class LlamaServer: @unchecked Sendable {
    public let modelPath: URL
    /// Records the child's PID so a later launch can stop a server orphaned by a crash or force-quit.
    public let pidFile: URL?
    public private(set) var port: Int = 0

    private var process: Process?
    private let lock = NSLock()

    public init(modelPath: URL, pidFile: URL? = nil) {
        self.modelPath = modelPath
        self.pidFile = pidFile
    }

    deinit { stop() }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    /// `POLYLOCAL_LLAMA_SERVER` first, then the copy bundled in Contents/Helpers (release builds),
    /// then Homebrew locations (development builds without a bundled server).
    public static func findBinary() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["POLYLOCAL_LLAMA_SERVER"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llama-server"))
        candidates += ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"].map(URL.init(fileURLWithPath:))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Starts the server and waits until it answers `/health`.
    public func start(contextSize: Int = 4096, timeout: TimeInterval = 90) async throws {
        guard let binary = Self.findBinary() else {
            // Release builds bundle it; this only happens in development builds without scripts/build-llama-server.sh.
            throw TranslationError.engineUnavailable("llama-server bulunamadı. Geliştirme derlemesinde scripts/build-llama-server.sh çalıştır ya da `brew install llama.cpp` ile kur.")
        }
        if let pidFile { Self.reapStale(pidFile: pidFile) }
        let port = try Self.freePort()
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--model", modelPath.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--ctx-size", String(contextSize),
            "--n-gpu-layers", "999",
            "--parallel", "1",
            "--reasoning", "off",
            "--no-webui",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        if let pidFile { try? String(process.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8) }
        lock.withLock {
            self.process = process
            self.port = port
        }

        let deadline = Date().addingTimeInterval(timeout)
        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        while Date() < deadline {
            guard process.isRunning else {
                throw TranslationError.engineUnavailable("llama-server başlarken kapandı (çıkış kodu \(process.terminationStatus)).")
            }
            if let (_, response) = try? await URLSession.shared.data(from: health),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        stop()
        throw TranslationError.engineUnavailable("llama-server \(Int(timeout)) saniyede hazır olmadı.")
    }

    public func stop() {
        lock.withLock {
            if let process, process.isRunning { process.terminate() }
            process = nil
        }
        if let pidFile { try? FileManager.default.removeItem(at: pidFile) }
    }

    /// Stops a llama-server left behind by a previous run. Only kills the PID if it still is a llama-server.
    static func reapStale(pidFile: URL) {
        defer { try? FileManager.default.removeItem(at: pidFile) }
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
              String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasSuffix("/llama-server") else { return }
        kill(pid, SIGTERM)
    }

    public var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TranslationError.engineUnavailable("Port açılamadı.") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                bind(fd, ptr, len) == 0 && getsockname(fd, ptr, &len) == 0
            }
        }
        guard bound else { throw TranslationError.engineUnavailable("Port açılamadı.") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
