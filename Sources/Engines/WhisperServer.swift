import Foundation
import PolylocalCore

/// One recognized phrase.
public struct Transcription: Sendable, Hashable {
    public var text: String
    /// What Whisper detected (or was told); nil if it named a language Polylocal does not list.
    public var language: Language?

    public init(text: String, language: Language?) {
        self.text = text
        self.language = language
    }
}

/// Runs `whisper-server` (whisper.cpp) as a child process for one model, like `LlamaServer`, and
/// transcribes 16 kHz phrases over its local HTTP API.
public final class WhisperServer: @unchecked Sendable {
    public let modelPath: URL
    public let pidFile: URL?
    public private(set) var port: Int = 0

    private var process: Process?
    private let lock = NSLock()

    public init(modelPath: URL, pidFile: URL? = nil) {
        self.modelPath = modelPath
        self.pidFile = pidFile
    }

    deinit { stop() }

    /// `POLYLOCAL_WHISPER_SERVER` first, then the copy bundled in Contents/Helpers.
    public static func findBinary() -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["POLYLOCAL_WHISPER_SERVER"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/whisper-server"))
        // `swift run` during development: the output of scripts/build-whisper-server.sh.
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repoRoot.appendingPathComponent("build/whisper-server/whisper-server"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func start(timeout: TimeInterval = 60) async throws {
        guard let binary = Self.findBinary() else {
            throw TranslationError.engineUnavailable(String(localized: "whisper-server not found. In a development build, run scripts/build-whisper-server.sh."))
        }
        if let pidFile { LlamaServer.reapStale(pidFile: pidFile, executableName: "whisper-server") }
        let port = try LlamaServer.freePort()
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "--model", modelPath.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--threads", String(max(4, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))),
            // Each phrase is independent; temperature fallback only adds latency on hard audio.
            "--no-fallback",
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
                throw TranslationError.engineUnavailable(String(localized: "whisper-server exited while starting (exit code \(Int(process.terminationStatus)))."))
            }
            if let (_, response) = try? await URLSession.shared.data(from: health),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        stop()
        throw TranslationError.engineUnavailable(String(localized: "whisper-server was not ready within \(Int(timeout)) seconds."))
    }

    public func stop() {
        lock.withLock {
            if let process, process.isRunning { process.terminate() }
            process = nil
        }
        if let pidFile { try? FileManager.default.removeItem(at: pidFile) }
    }

    public var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

    /// Transcribes one phrase. `language` nil lets Whisper detect it (~0.2–0.3 s slower).
    public func transcribe(_ samples: [Float], language: Language?) async throws -> Transcription {
        let duration = Double(samples.count) / SpeechAudio.sampleRate
        var form = MultipartForm()
        form.addFile("file", fileName: "phrase.wav", contentType: "audio/wav", data: WAV.encode(samples))
        form.addField("language", language?.code ?? "auto")
        form.addField("response_format", "verbose_json")
        form.addField("temperature", "0")
        form.addField("audio_ctx", String(Whisper.audioContext(forDuration: duration)))

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.upload(for: request, from: form.finish())
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TranslationError.engineUnavailable(String(localized: "Speech recognition failed."))
        }
        struct Reply: Decodable { var text: String; var language: String? }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return Transcription(text: reply.text, language: reply.language.flatMap(Whisper.language(named:)) ?? language)
    }
}

struct MultipartForm {
    private let boundary = "polylocal-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func addFile(_ name: String, fileName: String, contentType: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finish() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }
}
