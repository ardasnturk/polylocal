import Foundation
import Testing
@testable import PolylocalCore

@Suite struct SpeechSegmenterTests {
    let rate = Int(SpeechAudio.sampleRate)

    /// A 220 Hz tone stands in for speech; low-level noise for the room.
    func tone(_ seconds: Double, amplitude: Float = 0.2) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(rate)) }
    }

    func noise(_ seconds: Double, amplitude: Float = 0.0005) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * Double(rate))).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
    }

    func feed(_ segmenter: inout SpeechSegmenter, _ samples: [Float]) -> [[Float]] {
        // In audio-callback-sized chunks.
        stride(from: 0, to: samples.count, by: 1600).flatMap {
            segmenter.append(Array(samples[$0..<min($0 + 1600, samples.count)]))
        }
    }

    @Test func splitsPhrasesAtPauses() {
        var segmenter = SpeechSegmenter()
        let phrases = feed(&segmenter, noise(1) + tone(1.5) + noise(1) + tone(2) + noise(1))
        #expect(phrases.count == 2)
        let durations = phrases.map { Double($0.count) / Double(rate) }
        // Speech plus pre-roll and a little of the pause.
        #expect(durations[0] > 1.5 && durations[0] < 2.2)
        #expect(durations[1] > 2.0 && durations[1] < 2.7)
    }

    @Test func dropsShortBlips() {
        var segmenter = SpeechSegmenter()
        #expect(feed(&segmenter, noise(1) + tone(0.1) + noise(1.5)).isEmpty)
    }

    @Test func microphoneNeedsHalfASecondOfSpeech() {
        var segmenter = SpeechSegmenter(configuration: .microphone)
        // A 0.35 s sound passes the meeting lane's minimum but not the microphone's.
        #expect(feed(&segmenter, noise(1) + tone(0.35) + noise(1.5)).isEmpty)
        #expect(feed(&segmenter, tone(1.2) + noise(1.5)).count == 1)
    }

    @Test func silenceProducesNothing() {
        var segmenter = SpeechSegmenter()
        #expect(feed(&segmenter, noise(5)).isEmpty)
        #expect(segmenter.flush() == nil)
    }

    @Test func cutsLongMonologues() {
        var segmenter = SpeechSegmenter()
        // Speech-like: syllable runs with short dips, never a pause long enough to end the phrase.
        let monologue = (0..<60).flatMap { _ in tone(0.4) + noise(0.1) }
        let phrases = feed(&segmenter, noise(0.5) + monologue)
        #expect(phrases.count >= 2)
        #expect(phrases.allSatisfy { Double($0.count) / Double(rate) <= 7.1 })
        #expect(segmenter.flush() != nil)
    }

    @Test func steadyDroneFadesIntoBackground() {
        var segmenter = SpeechSegmenter()
        // A fan or music bed that never pauses must not stay one endless phrase.
        let phrases = feed(&segmenter, noise(0.5) + tone(60, amplitude: 0.05))
        #expect(phrases.count < 6)
    }

    @Test func adaptsToLouderRooms() {
        var segmenter = SpeechSegmenter()
        // Steady background hum well above the absolute minimum is not speech.
        #expect(feed(&segmenter, noise(4, amplitude: 0.02)).isEmpty)
        #expect(feed(&segmenter, tone(1.5, amplitude: 0.4) + noise(1, amplitude: 0.02)).count == 1)
    }
}

@Suite struct LanguageVoteTests {
    let en = Language.code("en")!, de = Language.code("de")!, pt = Language.code("pt")!

    @Test func learnsTheMeetingLanguageFromLongPhrases() {
        var vote = LanguageVote()
        #expect(vote.hint(forDuration: 1.5) == nil)  // nothing learned yet: detect
        vote.record(en, duration: 3)
        vote.record(pt, duration: 1.4)  // too short to count
        #expect(vote.dominant == nil)   // 3 s is not enough yet
        vote.record(en, duration: 3.6)
        #expect(vote.hint(forDuration: 1.5) == en)
    }

    @Test func rechecksEveryFourthLongPhrase() {
        var vote = LanguageVote()
        vote.record(en, duration: 6)
        let hints = (0..<8).map { _ in vote.hint(forDuration: 5) }
        #expect(hints == [en, en, en, nil, en, en, en, nil])
        // Short phrases are never used for a check.
        #expect((0..<5).allSatisfy { _ in vote.hint(forDuration: 1) == en })
    }

    @Test func noDominantLanguageInMixedMeetings() {
        var vote = LanguageVote()
        vote.record(en, duration: 6)
        vote.record(de, duration: 6)
        #expect(vote.dominant == nil)
    }

    @Test func followsALanguageSwitch() {
        var vote = LanguageVote()
        for _ in 0..<10 { vote.record(en, duration: 6) }
        for _ in 0..<12 { vote.record(de, duration: 6) }
        #expect(vote.dominant == de)
    }
}

@Suite struct WhisperTests {
    @Test func audioContextUsesOnlySizesThatWork() {
        #expect(Whisper.audioContext(forDuration: 2) == 768)
        #expect(Whisper.audioContext(forDuration: 7) == 768)
        #expect(Whisper.audioContext(forDuration: 20) == 1500)
    }

    @Test func mapsLanguageNames() {
        #expect(Whisper.language(named: "turkish")?.code == "tr")
        #expect(Whisper.language(named: "German")?.code == "de")
        #expect(Whisper.language(named: "de")?.code == "de")
        #expect(Whisper.language(named: "klingon") == nil)
    }

    @Test func encodesWAV() {
        let data = WAV.encode([0, 1, -1, 0.5])
        #expect(data.count == 44 + 8)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(data[44] == 0 && data[46] == 0xFF && data[47] == 0x7F)  // 0, then 32767 little-endian
    }

    @Test func filtersHallucinationsAndNoise() {
        #expect(TranscriptFilter.clean(" Untertitel im Auftrag des ZDF, 2021 ") == nil)
        #expect(TranscriptFilter.clean("Altyazı M.K.") == nil)
        #expect(TranscriptFilter.clean("[Musik]") == nil)
        #expect(TranscriptFilter.clean("...") == nil)
        #expect(TranscriptFilter.clean("Gut, (lacht) dann machen wir das so.") == "Gut, dann machen wir das so.")
        #expect(TranscriptFilter.clean("Yeni sürüm hazır.") == "Yeni sürüm hazır.")
    }

    @Test func removesWhisperRepetitionLoops() {
        let sentence = "Die neue Version ist fertig, und wir können sie nächste Woche ausliefern."
        #expect(TranscriptFilter.clean("\(sentence) \(sentence)") == sentence)
        #expect(TranscriptFilter.clean("Guten Morgen. Guten Morgen. Guten Morgen. Mhm.") == "Guten Morgen. Mhm.")
        // Different sentences, and a repeat that is not consecutive, stay.
        #expect(TranscriptFilter.clean("Ja. Nein. Ja.") == "Ja. Nein. Ja.")
    }
}

@Suite struct SpeechBacklogTests {
    func phrase(seconds: Double) -> String {
        String(repeating: "a", count: Int(seconds * SpeechBacklog.charactersPerSecond))
    }

    @Test func speedsUpOnlyWhenBehind() {
        #expect(SpeechBacklog.speedup(forBacklog: 1) == 1)
        #expect(SpeechBacklog.speedup(forBacklog: 3) == 1)
        let middle = SpeechBacklog.speedup(forBacklog: 5.5)
        #expect(middle > 1.1 && middle < 1.15)
        #expect(SpeechBacklog.speedup(forBacklog: 30) == SpeechBacklog.maxSpeedup)
    }

    @Test func skipsTheOldestWhenTooFarBehind() {
        let pending = [phrase(seconds: 4), phrase(seconds: 3), phrase(seconds: 3), phrase(seconds: 2)]
        let kept = SpeechBacklog.trimmed(pending)
        #expect(kept == Array(pending.suffix(3)))
        #expect(SpeechBacklog.seconds(kept) <= SpeechBacklog.limit)
    }

    @Test func alwaysKeepsTheNewestPhrase() {
        let long = phrase(seconds: 20)
        #expect(SpeechBacklog.trimmed([phrase(seconds: 2), long]) == [long])
    }
}
