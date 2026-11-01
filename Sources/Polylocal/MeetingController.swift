import AppKit
import Engines
import Foundation
import Observation
import PolylocalCore
import SystemIntegration

/// An app that can be the meeting source.
struct MeetingApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }

    /// Known meeting and browser apps, recognized by bundle ID prefix.
    static let known = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.google.Chrome", "com.apple.Safari",
        "com.tinyspeck.slackmacgap", "com.apple.FaceTime", "com.hnc.Discord", "company.thebrowser.Browser",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser", "net.whatsapp.WhatsApp",
        "com.cisco.webexmeetingsapp", "com.webex.meetingmanager",
    ]

    /// Running apps that could host a meeting: known ones first, then any other app playing audio.
    @MainActor
    static func candidates() -> [MeetingApp] {
        let playing: Set<String>
        if #available(macOS 14.2, *) {
            playing = Set(AppAudioCapture.processes().filter(\.isOutputting).map(\.bundleID))
        } else {
            playing = []
        }
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (MeetingApp, Int)? in
                guard let id = app.bundleIdentifier, id != own else { return nil }
                let isKnown = known.contains { id.hasPrefix($0) }
                let isPlaying = playing.contains { $0.hasPrefix(id) }
                guard isKnown || isPlaying else { return nil }
                return (MeetingApp(bundleID: id, name: app.localizedName ?? id), isKnown ? 0 : 1)
            }
            .sorted { ($0.1, $0.0.name) < ($1.1, $1.0.name) }
            .map(\.0)
    }
}

/// Meeting mode, level 1: live subtitles for what the other participants say.
/// The meeting app's audio → phrases (SpeechSegmenter) → Whisper → translation into the user's language.
@MainActor
@Observable
final class MeetingController {
    enum State: Equatable {
        case idle
        case starting(String)
        /// The app has no audio yet (not in a call); retried automatically.
        case waiting(String)
        case listening
        case failed(String)
    }

    struct Line: Identifiable, Equatable {
        let id = UUID()
        let original: String
        let language: Language?
        var translation: String
        /// No translation needed: the phrase is already in the user's language.
        var isOwnLanguage: Bool
        var isTranslating: Bool
    }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { Log.meeting.notice("state \(String(describing: self.state), privacy: .public)") } }
    }
    private(set) var lines: [Line] = []
    private(set) var source: MeetingApp?

    var isActive: Bool { state != .idle }

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var whisper: WhisperServer?
    @ObservationIgnored private var capture: AnyObject?  // AppAudioCapture, macOS 14.2+
    @ObservationIgnored private var pipeline: Task<Void, Never>?
    @ObservationIgnored private var phrases: AsyncStream<[Float]>.Continuation?
    @ObservationIgnored private var watchTimer: Timer?
    @ObservationIgnored private lazy var panel = SubtitlePanel(app: app)

    init(app: AppModel) {
        self.app = app
    }

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { WhisperServer.findBinary() != nil } else { false }
    }

    var speechModel: CatalogModel? { app.store.models(.speech).first }
    var isSpeechModelInstalled: Bool { speechModel.map { app.store.state(of: $0) == .installed } ?? false }

    func start(_ source: MeetingApp) {
        guard #available(macOS 14.2, *) else { return }
        stop()
        guard let model = speechModel, isSpeechModelInstalled else {
            app.windows.showSettings(tab: .meeting)
            return
        }
        self.source = source
        app.settings.meetingLastApp = source.bundleID
        lines = []
        state = .starting(String(localized: "Loading speech recognition…"))
        panel.show()

        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(4))
        phrases = continuation
        let server = WhisperServer(modelPath: app.store.fileURL(for: model),
                                   pidFile: app.store.directory.appendingPathComponent("whisper-server.pid"))
        whisper = server
        pipeline = Task {
            do {
                try await server.start()
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
            guard !Task.isCancelled else { return }
            startCapture()
            for await phrase in stream {
                await recognize(phrase, with: server)
            }
        }
    }

    func stop() {
        watchTimer?.invalidate()
        watchTimer = nil
        if #available(macOS 14.2, *) { (capture as? AppAudioCapture)?.stop() }
        capture = nil
        phrases?.finish()
        phrases = nil
        pipeline?.cancel()
        pipeline = nil
        whisper?.stop()
        whisper = nil
        state = .idle
        panel.hide()
    }

    // MARK: - Capture

    @available(macOS 14.2, *)
    private func startCapture() {
        guard let source, let phrases else { return }
        let segmenter = SegmenterBox()
        let capture = AppAudioCapture(bundleIDPrefix: source.bundleID) { samples in
            // Runs on the capture queue, the segmenter's only user.
            for phrase in segmenter.append(samples) { phrases.yield(phrase) }
        }
        self.capture = capture
        attachCapture(capture)
        // Meeting apps start audio processes late (joining a call, a new browser tab): follow them.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followAudioProcesses() }
        }
    }

    @available(macOS 14.2, *)
    private func attachCapture(_ capture: AppAudioCapture) {
        do {
            try capture.start()
            Log.meeting.notice("capture started processes=\(capture.tappedProcesses.count, privacy: .public)")
            state = .listening
        } catch AppAudioCapture.CaptureError.noAudioProcess {
            state = .waiting(String(localized: "Waiting for audio from \(source?.name ?? "")…"))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func followAudioProcesses() {
        guard #available(macOS 14.2, *), let capture = capture as? AppAudioCapture else { return }
        if NSWorkspace.shared.runningApplications.allSatisfy({ $0.bundleIdentifier != source?.bundleID }) {
            stop()  // the meeting app quit
            return
        }
        let current = capture.matchingProcesses()
        if !current.isEmpty, current != capture.tappedProcesses {
            attachCapture(capture)
        }
    }

    // MARK: - Recognition and translation

    private func recognize(_ phrase: [Float], with server: WhisperServer) async {
        let expected = app.settings.meetingTheirLanguage
        let asrStart = Date()
        let duration = Double(phrase.count) / SpeechAudio.sampleRate
        let result: Transcription
        do {
            result = try await server.transcribe(phrase, language: expected)
        } catch {
            Log.meeting.error("recognition failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !Task.isCancelled else { return }
        let asrMS = Int(Date().timeIntervalSince(asrStart) * 1000)
        // Never log the text itself.
        guard let text = TranscriptFilter.clean(result.text) else {
            Log.meeting.notice("phrase audio=\(duration, format: .fixed(precision: 1), privacy: .public)s asr=\(asrMS, privacy: .public)ms dropped")
            return
        }
        let target = app.settings.primaryLanguage
        let ownLanguage = result.language == target
        let line = Line(original: text, language: result.language, translation: "",
                        isOwnLanguage: ownLanguage, isTranslating: !ownLanguage)
        lines.append(line)
        if lines.count > 50 { lines.removeFirst(lines.count - 50) }
        Log.meeting.notice("phrase audio=\(duration, format: .fixed(precision: 1), privacy: .public)s asr=\(asrMS, privacy: .public)ms lang=\(result.language?.code ?? "?", privacy: .public) chars=\(text.count, privacy: .public)")
        guard !ownLanguage else { return }

        // Recognition continues while this phrase translates.
        let id = line.id
        Task {
            let request = TranslationRequest(text: text, source: result.language, target: target,
                                             glossary: Glossary.relevant(app.settings.glossary, for: text, target: target))
            var buffer = ""
            do {
                for try await token in app.engine.translate(request) {
                    buffer += token
                    let partial = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    update(id) { $0.translation = partial }
                }
            } catch {
                update(id) { $0.translation = "" }
            }
            update(id) { $0.isTranslating = false }
            Log.meeting.notice("translated in \(Int(Date().timeIntervalSince(asrStart) * 1000) - asrMS, privacy: .public)ms chars=\(buffer.count, privacy: .public)")
        }
    }

    private func update(_ id: UUID, _ change: (inout Line) -> Void) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        change(&lines[index])
    }
}

/// Owns a SpeechSegmenter on the capture queue.
private final class SegmenterBox: @unchecked Sendable {
    private var segmenter = SpeechSegmenter()

    func append(_ samples: [Float]) -> [[Float]] {
        segmenter.append(samples)
    }
}
