import AVFoundation
import PolylocalCore

/// Speaks meeting translations (level 3, "hear the translation") with the system voices, one phrase at a
/// time. Keeps its own queue so it can speed up or skip the oldest phrases when it falls behind (SpeechBacklog).
@MainActor
final class MeetingVoice: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var pending: [(text: String, language: Language)] = []
    private var isSpeaking = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// The best installed voice: Premium, then Enhanced, then the default one.
    static func voice(for language: Language) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language.code) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }

    /// Only the default voice is installed: the Enhanced and Premium ones sound much more natural.
    static func hasOnlyBasicVoice(for language: Language) -> Bool {
        guard let voice = voice(for: language) else { return true }
        return voice.quality == .default
    }

    func say(_ text: String, language: Language) {
        pending.append((text, language))
        let kept = SpeechBacklog.trimmed(pending.map(\.text))
        if kept.count < pending.count {
            Log.meeting.notice("voice skipped \(self.pending.count - kept.count, privacy: .public) phrases (behind)")
            pending.removeFirst(pending.count - kept.count)
        }
        speakNext()
    }

    func stop() {
        pending = []
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func speakNext() {
        guard !isSpeaking, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        let utterance = AVSpeechUtterance(string: next.text)
        utterance.voice = Self.voice(for: next.language)
        // Only what waits behind this phrase means falling behind.
        let speedup = SpeechBacklog.speedup(forBacklog: SpeechBacklog.seconds(pending.map(\.text)))
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * speedup)
        isSpeaking = true
        synthesizer.speak(utterance)
        Log.meeting.notice("voice chars=\(next.text.count, privacy: .public) speedup=\(speedup, format: .fixed(precision: 2), privacy: .public) waiting=\(self.pending.count, privacy: .public) voice=\(utterance.voice?.name ?? "-", privacy: .public)")
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.speakNext()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
