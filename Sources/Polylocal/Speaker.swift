import AVFoundation
import Observation
import PolylocalCore

/// Reads a text aloud with the best installed system voice (the speaker buttons in the translator).
@MainActor
@Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    /// Identifies what is being read, so only that button shows "stop".
    private(set) var speakingID: String?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Starts reading, or stops if `id` is already being read.
    func toggle(_ text: String, language: Language?, id: String) {
        let wasSpeaking = speakingID == id
        stop()
        guard !wasSpeaking, !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = language.flatMap(MeetingVoice.voice(for:))
        speakingID = id
        synthesizer.speak(utterance)
    }

    func stop() {
        speakingID = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingID = nil }
    }
}
