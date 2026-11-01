import Foundation
import Darwin
import TranslaterCore

/// Runs `llama-server` as a child process for one model file.
/// Keeping the model out of the app process means a crash or memory spike never takes down the shortcuts.
public final class LlamaServer: @unchecked Sendable {
    public let modelPath: URL
    public private(set) var port: Int = 0

    private var process: Process?
    private let lock = NSLock()

    public init(modelPath: URL) {
        self.modelPath = modelPath
    }

    deinit { stop() }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    /// Bundled binary first, then common install locations. `TRANSLATER_LLAMA_SERVER` overrides both.
    public static func findBinary() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["TRANSLATER_LLAMA_SERVER"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("llama/llama-server") {
            candidates.append(bundled)
        }
        candidates += ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"].map(URL.init(fileURLWithPath:))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Starts the server and waits until it answers `/health`.
    public func start(contextSize: Int = 4096, timeout: TimeInterval = 90) async throws {
        guard let binary = Self.findBinary() else {
            throw TranslationError.engineUnavailable("llama-server bulunamadı. `brew install llama.cpp` ile kurabilirsin.")
        }
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
