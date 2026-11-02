import AVFoundation
import PolylocalCore

/// Speaks meeting translations with the system voices, one phrase at a time: on the user's speakers (level 3,
/// "hear the translation"), or into the Polylocal Microphone (level 4, "speak the translation"). Keeps its own
/// queue so it can speed up or skip the oldest phrases when it falls behind (SpeechBacklog).
@MainActor
final class MeetingVoice: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var pending: [(text: String, language: Language)] = []
    private(set) var isSpeaking = false
    /// nil: the default output (the user's speakers).
    private let output: VirtualMicrophoneOutput?
    /// Bumped on stop(), so callbacks of an interrupted phrase are ignored.
    private var generation = 0

    init(output: VirtualMicrophoneOutput? = nil) {
        self.output = output
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
        generation += 1
        synthesizer.stopSpeaking(at: .immediate)
        output?.flush()
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
        if let output {
            write(utterance, to: output)
        } else {
            synthesizer.speak(utterance)
        }
        Log.meeting.notice("voice chars=\(next.text.count, privacy: .public) speedup=\(speedup, format: .fixed(precision: 2), privacy: .public) waiting=\(self.pending.count, privacy: .public) voice=\(utterance.voice?.name ?? "-", privacy: .public)")
    }

    /// Renders the phrase to PCM and plays it into the virtual microphone; the next phrase starts once the last
    /// buffer has been played.
    private func write(_ utterance: AVSpeechUtterance, to output: VirtualMicrophoneOutput) {
        let generation = generation
        var scheduled = 0
        var played = 0
        var finished = false
        func phraseDone() {
            guard generation == self.generation, finished, played == scheduled else { return }
            isSpeaking = false
            speakNext()
        }
        // The callback may come on the synthesizer's own queue; DispatchQueue.main keeps the buffers in order.
        synthesizer.write(utterance) { [weak self] buffer in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, generation == self.generation else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    // An empty buffer marks the end of the phrase.
                    finished = true
                    phraseDone()
                    return
                }
                scheduled += 1
                output.play(pcm) {
                    played += 1
                    phraseDone()
                }
            } }
        }
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
