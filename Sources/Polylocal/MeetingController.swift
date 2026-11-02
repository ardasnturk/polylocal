import AppKit
import AVFoundation
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
            playing = Set(AppAudioCapture.processes().filter(\.isOutputting).flatMap { [$0.bundleID, $0.ownerBundleID].compactMap { $0 } })
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
        /// Said by the user (level 4): `translation` is what the others hear.
        var isMine = false
    }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { Log.meeting.notice("state \(String(describing: self.state), privacy: .public)") } }
    }
    private(set) var lines: [Line] = []
    private(set) var source: MeetingApp?
    /// The folder of the last meeting whose notes were saved.
    private(set) var lastNotesFolder: URL?
    private(set) var isSummarizing = false
    private(set) var isSavingNotes = false
    /// The meeting app is muted for the user and translations are spoken instead.
    private(set) var isHearingTranslation = false
    /// Level 4 is running: the user's speech is translated into the Polylocal Microphone.
    private(set) var isSpeakingTranslation = false
    /// Level 4 paused: the user's own voice goes to the Polylocal Microphone unchanged.
    private(set) var isSpeakingDirectly = false
    /// Why level 4 could not start, shown in the subtitle bar.
    private(set) var speakProblem: String? {
        didSet { if let speakProblem { Log.meeting.error("speak translation: \(speakProblem, privacy: .public)") } }
    }

    var isActive: Bool { state != .idle }

    var notesRoot: URL {
        app.settings.meetingNotesFolder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? MeetingNotesWriter.defaultRoot
    }

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var whisper: WhisperServer?
    @ObservationIgnored private var capture: AnyObject?  // AppAudioCapture, macOS 14.2+
    @ObservationIgnored private var pipeline: Task<Void, Never>?
    @ObservationIgnored private var phrases: AsyncStream<[Float]>.Continuation?
    @ObservationIgnored private var watchTimer: Timer?
    @ObservationIgnored private var languageVote = LanguageVote()
    @ObservationIgnored private var notes: MeetingNotesWriter?
    @ObservationIgnored private var segmenter: SegmenterBox?
    @ObservationIgnored private lazy var voice = MeetingVoice()
    @ObservationIgnored private var microphone: MicrophoneCapture?
    @ObservationIgnored private var virtualMicrophone: VirtualMicrophoneOutput?
    @ObservationIgnored private var outgoingVoice: MeetingVoice?
    @ObservationIgnored private var ownPhrases: AsyncStream<[Float]>.Continuation?
    @ObservationIgnored private var outgoing: Task<Void, Never>?
    /// The last time the incoming voice (level 3) was speaking, to ignore its echo in the microphone.
    @ObservationIgnored private var incomingVoiceUntil = Date.distantPast
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
        languageVote = LanguageVote()
        if app.settings.meetingSaveNotes {
            notes = MeetingNotesWriter(root: notesRoot, app: source.name, started: Date(),
                                       targetLanguage: app.settings.meetingLanguage)
        }
        isSavingNotes = notes != nil
        isHearingTranslation = app.settings.meetingHearTranslation
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
            // The first request pays for loading the weights onto the GPU (~1 s); pay it before anyone speaks.
            _ = try? await server.transcribe([Float](repeating: 0, count: Int(SpeechAudio.sampleRate)), language: nil)
            startCapture()
            if app.settings.meetingSpeakTranslation { await startSpeaking(with: server) }
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
        if let notes {
            if let folder = notes.finish() { lastNotesFolder = folder }
            if app.settings.meetingSummarize, notes.transcript.segments.count >= 3 { summarize(notes) }
        }
        notes = nil
        isSavingNotes = false
        voice.stop()
        isHearingTranslation = false
        stopSpeaking()
        segmenter = nil
        state = .idle
        panel.hide()
    }

    // MARK: - Capture

    @available(macOS 14.2, *)
    private func startCapture() {
        segmenter = SegmenterBox()
        guard let capture = makeCapture() else { return }
        attachCapture(capture)
        // Meeting apps start audio processes late (joining a call, a new browser tab): follow them.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followAudioProcesses() }
        }
    }

    /// Muted for the user while they hear the translation instead.
    @available(macOS 14.2, *)
    private func makeCapture() -> AppAudioCapture? {
        guard let source, let phrases, let segmenter else { return nil }
        let capture = AppAudioCapture(bundleIDPrefix: source.bundleID, mute: isHearingTranslation) { samples in
            // Runs on the capture queue, the segmenter's only user.
            for phrase in segmenter.append(samples) { phrases.yield(phrase) }
        }
        self.capture = capture
        return capture
    }

    /// Switches between hearing the meeting as it is and hearing the translation, during a meeting too.
    func setHearingTranslation(_ on: Bool) {
        app.settings.meetingHearTranslation = on
        guard isActive, on != isHearingTranslation else { return }
        isHearingTranslation = on
        if !on { voice.stop() }
        // A tap's mute behavior is fixed when it is created, so swap it for one with the other setting.
        guard #available(macOS 14.2, *), let old = capture as? AppAudioCapture else { return }
        old.stop()
        if let capture = makeCapture() { attachCapture(capture) }
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
        let duration = Double(phrase.count) / SpeechAudio.sampleRate
        let chosen = app.settings.meetingTheirLanguage
        let expected = chosen ?? languageVote.hint(forDuration: duration)
        let asrStart = Date()
        let result: Transcription
        do {
            result = try await server.transcribe(phrase, language: expected)
        } catch {
            Log.meeting.error("recognition failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !Task.isCancelled else { return }
        if chosen == nil, expected == nil, let detected = result.language {
            languageVote.record(detected, duration: duration)
        }
        let asrMS = Int(Date().timeIntervalSince(asrStart) * 1000)
        // Never log the text itself.
        guard let text = TranscriptFilter.clean(result.text) else {
            Log.meeting.notice("phrase audio=\(duration, format: .fixed(precision: 1), privacy: .public)s asr=\(asrMS, privacy: .public)ms dropped")
            return
        }
        let target = app.settings.meetingLanguage
        let ownLanguage = result.language == target
        let line = Line(original: text, language: result.language, translation: "",
                        isOwnLanguage: ownLanguage, isTranslating: !ownLanguage)
        lines.append(line)
        if lines.count > 50 { lines.removeFirst(lines.count - 50) }
        let notes = self.notes
        notes?.add(line.id, .init(time: asrStart.addingTimeInterval(-duration), language: result.language?.code,
                                  original: text, translation: nil))
        Log.meeting.notice("phrase audio=\(duration, format: .fixed(precision: 1), privacy: .public)s asr=\(asrMS, privacy: .public)ms lang=\(result.language?.code ?? "?", privacy: .public)\(expected == nil ? "" : " (given)", privacy: .public) chars=\(text.count, privacy: .public)")
        guard !ownLanguage else {
            // The app is muted, so even what is already in the user's language has to be spoken.
            if isHearingTranslation { voice.say(text, language: target) }
            return
        }

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
            let translation = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            notes?.setTranslation(id, translation.isEmpty ? nil : translation)
            if isHearingTranslation, !translation.isEmpty {
                voice.say(translation, language: target)
                incomingVoiceUntil = Date().addingTimeInterval(SpeechBacklog.seconds([translation]) + 1)
            }
            Log.meeting.notice("translated in \(Int(Date().timeIntervalSince(asrStart) * 1000) - asrMS, privacy: .public)ms chars=\(buffer.count, privacy: .public)")
        }
    }

    // MARK: - Speaking the translation (level 4)

    /// The language the others hear: the one set for them, the one learned from the meeting, or the secondary language.
    var theirLanguage: Language {
        let mine = app.settings.meetingLanguage
        if let set = app.settings.meetingTheirLanguage ?? languageVote.dominant, set != mine { return set }
        // Before anyone spoke: the other language of the user's pair.
        return [app.settings.secondaryLanguage, app.settings.primaryLanguage, Language.code("en")!].first { $0 != mine }!
    }

    /// Starts translating the user's microphone into the Polylocal Microphone. Meeting mode keeps running
    /// without it if the driver or the microphone permission is missing.
    private func startSpeaking(with server: WhisperServer) async {
        speakProblem = nil
        guard PolylocalMicrophone.isInstalled else {
            speakProblem = String(localized: "Polylocal Microphone is not installed (Settings → Meeting).")
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            speakProblem = String(localized: "Microphone access is off (System Settings → Privacy & Security → Microphone).")
            return
        }
        guard isActive else { return }
        let output = VirtualMicrophoneOutput()
        do {
            try output.start()
        } catch {
            speakProblem = error.localizedDescription
            return
        }
        virtualMicrophone = output
        outgoingVoice = MeetingVoice(output: output)

        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(4))
        ownPhrases = continuation
        let segmenter = SegmenterBox()
        let microphone = MicrophoneCapture(
            onSamples: { samples in
                // Runs on the audio thread, the segmenter's only user.
                for phrase in segmenter.append(samples) { continuation.yield(phrase) }
            },
            onBuffer: { [weak self] buffer in
                // "Speak directly": the user's voice, unchanged. The tap reuses its buffer, so pass a copy.
                guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
                let box = BufferBox(buffer: copy)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.isSpeakingDirectly else { return }
                        self.virtualMicrophone?.play(box.buffer)
                    }
                }
            })
        do {
            try microphone.start()
        } catch {
            speakProblem = error.localizedDescription
            output.stop()
            virtualMicrophone = nil
            return
        }
        self.microphone = microphone
        Log.meeting.notice("microphone \(microphone.deviceName ?? "?", privacy: .public) format=\(microphone.format?.description ?? "?", privacy: .public)")
        isSpeakingTranslation = true
        isSpeakingDirectly = false
        Log.meeting.notice("speaking translation started")
        outgoing = Task {
            for await phrase in stream {
                await recognizeOwn(phrase, with: server)
            }
        }
    }

    private func stopSpeaking() {
        microphone?.stop()
        microphone = nil
        ownPhrases?.finish()
        ownPhrases = nil
        outgoing?.cancel()
        outgoing = nil
        outgoingVoice?.stop()
        outgoingVoice = nil
        virtualMicrophone?.stop()
        virtualMicrophone = nil
        isSpeakingTranslation = false
        isSpeakingDirectly = false
    }

    /// Pauses the translation so the user can talk to the meeting in their own voice, and back.
    func setSpeakingDirectly(_ on: Bool) {
        guard isSpeakingTranslation else { return }
        isSpeakingDirectly = on
        if on { outgoingVoice?.stop() }
    }

    private func recognizeOwn(_ phrase: [Float], with server: WhisperServer) async {
        guard !isSpeakingDirectly else { return }
        // Without headphones the microphone hears the incoming translation too; that is not the user speaking.
        if Date() < incomingVoiceUntil || voice.isSpeaking {
            Log.meeting.notice("own phrase skipped (incoming voice playing)")
            return
        }
        let duration = Double(phrase.count) / SpeechAudio.sampleRate
        let mine = app.settings.meetingLanguage
        let asrStart = Date()
        let result: Transcription
        // While the meeting is muted for the user, the microphone can only hear the user: give Whisper the language.
        // Otherwise the speakers may play the others, so detect the language and keep only the user's own.
        let forced = isHearingTranslation ? mine : nil
        do {
            result = try await server.transcribe(phrase, language: forced)
        } catch {
            Log.meeting.error("own recognition failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        if forced == nil, result.language != mine {
            Log.meeting.notice("own phrase skipped (lang=\(result.language?.code ?? "?", privacy: .public), likely the speakers)")
            return
        }
        guard !Task.isCancelled, let text = TranscriptFilter.clean(result.text) else {
            Log.meeting.notice("own phrase audio=\(duration, format: .fixed(precision: 1), privacy: .public)s dropped")
            return
        }
        let asrMS = Int(Date().timeIntervalSince(asrStart) * 1000)
        let target = theirLanguage
        let line = Line(original: text, language: mine, translation: "", isOwnLanguage: false, isTranslating: true, isMine: true)
        lines.append(line)
        if lines.count > 50 { lines.removeFirst(lines.count - 50) }
        let notes = self.notes
        notes?.add(line.id, .init(time: asrStart.addingTimeInterval(-duration), language: mine.code,
                                  original: text, translation: nil))
        Log.meeting.notice("own phrase audio=\(duration, format: .fixed(precision: 1), privacy: .public)s asr=\(asrMS, privacy: .public)ms to=\(target.code, privacy: .public) chars=\(text.count, privacy: .public)")

        let id = line.id
        let request = TranslationRequest(text: text, source: mine, target: target,
                                         formality: app.settings.formality(for: target),
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
        let translation = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        notes?.setTranslation(id, translation.isEmpty ? nil : translation)
        guard !translation.isEmpty, !isSpeakingDirectly else { return }
        outgoingVoice?.say(translation, language: target)
        Log.meeting.notice("own translated in \(Int(Date().timeIntervalSince(asrStart) * 1000) - asrMS, privacy: .public)ms")
    }

    // MARK: - Summary

    /// Writes summary.md with the local model once the meeting ends: decisions, action items, open questions.
    /// Long meetings are summarized in parts first, then the parts are combined.
    private func summarize(_ notes: MeetingNotesWriter) {
        let target = Language.code(notes.transcript.targetLanguage) ?? app.settings.meetingLanguage
        isSummarizing = true
        Task {
            defer { isSummarizing = false }
            // Let translations still streaming for the last phrases land first.
            try? await Task.sleep(for: .seconds(2))
            let started = Date()
            do {
                let chunks = notes.transcript.summaryChunks()
                var text = chunks.joined(separator: "\n")
                if chunks.count > 1 {
                    var parts: [String] = []
                    for chunk in chunks { parts.append(try await complete(.init(text: chunk, source: nil, target: target, kind: .summarize))) }
                    text = parts.joined(separator: "\n\n")
                }
                let summary = try await complete(.init(text: text, source: nil, target: target, kind: .summarize))
                notes.writeSummary(summary)
                Log.meeting.notice("summary in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)ms parts=\(chunks.count, privacy: .public)")
            } catch {
                Log.meeting.error("summary failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func complete(_ request: TranslationRequest) async throws -> String {
        var output = ""
        for try await token in app.engine.translate(request) { output += token }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
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

/// Hands a copied audio buffer to the main thread; nothing else touches it.
private struct BufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}
