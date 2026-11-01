import Foundation

/// Speech recognition: audio is 16 kHz mono Float32 throughout.
public enum SpeechAudio {
    public static let sampleRate = 16_000.0
}

/// Cuts a continuous 16 kHz stream into phrases at pauses, for phrase-by-phrase recognition.
///
/// Energy-based voice activity detection with an adaptive noise floor: a frame is speech when it is
/// clearly louder than the recent background. A phrase starts after a short run of speech frames
/// (with some audio before it kept as pre-roll) and ends after a pause, or is cut at `maxDuration`
/// at the quietest recent frame so long monologues still flow. Not thread-safe; feed it from one queue.
public struct SpeechSegmenter: Sendable {
    public struct Configuration: Sendable {
        /// 30 ms frames.
        public var frameSize = 480
        /// Speech must be this much louder than the noise floor…
        public var speechAboveFloorDB: Float = 12
        /// …and at least this loud in absolute terms.
        public var minSpeechDB: Float = -50
        /// Consecutive speech frames that open a phrase (~90 ms).
        public var startFrames = 3
        /// Audio kept from before the phrase opened (~300 ms), so the first syllable is not clipped.
        public var preRollFrames = 10
        /// Pause that closes a phrase (~600 ms).
        public var endSilenceFrames = 20
        /// Longer phrases are cut, so subtitles keep up with someone who talks without pausing
        /// (a real call had 10–11 s phrases at 12 s). Cut at the quietest recent frame.
        public var maxDuration: TimeInterval = 7
        /// Phrases with less speech than this (a cough, a click) are dropped. Counts speech frames only.
        public var minSpeech: TimeInterval = 0.25
        /// The first frames only measure the room (~450 ms), so a steady background is never taken for speech.
        public var calibrationFrames = 15

        public init() {}
    }

    public let configuration: Configuration
    private var pending: [Float] = []
    private var preRoll: [[Float]] = []
    private var phrase: [Float] = []
    private var frameLevels: [Float] = []
    private var inPhrase = false
    private var speechRun = 0
    private var silenceRun = 0
    private var speechFrames = 0
    private var calibration: [Float] = []
    private var noiseFloorDB: Float = -60

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Feeds audio and returns any phrases that finished.
    public mutating func append(_ samples: [Float]) -> [[Float]] {
        pending += samples
        var finished: [[Float]] = []
        let size = configuration.frameSize
        var offset = 0
        while pending.count - offset >= size {
            if let done = process(Array(pending[offset..<(offset + size)])) { finished.append(done) }
            offset += size
        }
        pending.removeFirst(offset)
        return finished
    }

    /// Ends the stream: returns the phrase in progress, if it is long enough.
    public mutating func flush() -> [Float]? {
        defer { reset() }
        return inPhrase ? accept(phrase, speechFrames: speechFrames) : nil
    }

    public mutating func reset() {
        pending = []; preRoll = []; phrase = []; frameLevels = []; calibration = []
        inPhrase = false; speechRun = 0; silenceRun = 0; speechFrames = 0; noiseFloorDB = -60
    }

    private mutating func process(_ frame: [Float]) -> [Float]? {
        let db = Self.levelDB(frame)
        if calibration.count < configuration.calibrationFrames {
            calibration.append(db)
            noiseFloorDB = calibration.sorted()[calibration.count / 2]
            preRoll.append(frame)
            if preRoll.count > configuration.preRollFrames { preRoll.removeFirst() }
            return nil
        }
        let isSpeech = db > max(noiseFloorDB + configuration.speechAboveFloorDB, configuration.minSpeechDB)
        // Follow the background: quickly downwards, slowly upwards, and very slowly while "speaking",
        // so a room that got louder is not taken for one endless phrase.
        let rate: Float = db < noiseFloorDB ? 0.3 : (isSpeech ? 0.002 : 0.02)
        noiseFloorDB += (db - noiseFloorDB) * rate

        guard inPhrase else {
            preRoll.append(frame)
            if preRoll.count > configuration.preRollFrames + configuration.startFrames { preRoll.removeFirst() }
            speechRun = isSpeech ? speechRun + 1 : 0
            if speechRun >= configuration.startFrames {
                inPhrase = true
                silenceRun = 0
                speechFrames = speechRun
                phrase = preRoll.flatMap { $0 }
                frameLevels = preRoll.map(Self.levelDB)
                preRoll = []
            }
            return nil
        }

        phrase += frame
        frameLevels.append(db)
        silenceRun = isSpeech ? 0 : silenceRun + 1
        if isSpeech { speechFrames += 1 }

        if silenceRun >= configuration.endSilenceFrames {
            // Drop most of the trailing pause.
            let keep = phrase.count - (silenceRun - 3) * configuration.frameSize
            let done = Array(phrase.prefix(max(0, keep)))
            let speech = speechFrames
            endPhrase()
            return accept(done, speechFrames: speech)
        }
        if Double(phrase.count) / SpeechAudio.sampleRate >= configuration.maxDuration {
            return cutLongPhrase()
        }
        return nil
    }

    /// Splits at the quietest frame of the last ~1.5 s and keeps the rest as the start of the next phrase.
    private mutating func cutLongPhrase() -> [Float]? {
        let size = configuration.frameSize
        let window = min(50, frameLevels.count)
        let start = frameLevels.count - window
        let quietest = (start..<frameLevels.count).min { frameLevels[$0] < frameLevels[$1] } ?? frameLevels.count - 1
        let cut = (quietest + 1) * size
        let done = Array(phrase.prefix(cut))
        phrase = Array(phrase.dropFirst(cut))
        frameLevels = Array(frameLevels.dropFirst(quietest + 1))
        let speech = speechFrames
        speechFrames = frameLevels.count { $0 > noiseFloorDB + configuration.speechAboveFloorDB }
        return accept(done, speechFrames: speech)
    }

    private mutating func endPhrase() {
        inPhrase = false
        phrase = []; frameLevels = []; speechRun = 0; silenceRun = 0; speechFrames = 0
    }

    private func accept(_ samples: [Float], speechFrames: Int) -> [Float]? {
        let speech = Double(speechFrames * configuration.frameSize) / SpeechAudio.sampleRate
        return speech >= configuration.minSpeech ? samples : nil
    }

    static func levelDB(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return -120 }
        let meanSquare = frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)
        return meanSquare > 0 ? 10 * log10(meanSquare) : -120
    }
}

public enum Whisper {
    /// Encoder window (`audio_ctx`) for a phrase. Whisper always encodes a fixed window (1500 = 30 s), so a
    /// smaller one is the main speed lever: ~0.6 s instead of ~1.25 s per phrase on an M4 Pro.
    /// 768 (~15 s) fits every phrase (they are capped at 7 s) with room to spare: ~0.33 s per phrase on an M4 Pro.
    /// Reduced windows only work with temperature fallback on (see WhisperServer); without it, 512 and 640 looped.
    public static func audioContext(forDuration seconds: TimeInterval) -> Int {
        seconds <= 12 ? 768 : 1500
    }

    /// whisper.cpp reports detected languages by English name ("turkish").
    public static func language(named name: String) -> Language? {
        Language.all.first { $0.englishName.lowercased() == name.lowercased() } ?? Language.code(name)
    }
}

/// Learns which language a meeting is in, for phrases too short to detect reliably.
/// In real calls Whisper took 0.8–1.8 s phrases for Portuguese, Spanish, Arabic or English; from ~2.2 s on it was right.
public struct LanguageVote: Sendable {
    /// Phrases at least this long are detected per phrase and count as votes.
    public static let reliableDuration: TimeInterval = 2.5
    private var votes: [(language: Language, duration: TimeInterval)] = []
    private var givenSinceCheck = 0

    public init() {}

    public mutating func record(_ language: Language, duration: TimeInterval) {
        guard duration >= Self.reliableDuration else { return }
        votes.append((language, duration))
        // About the last minute of speech: meetings can switch language.
        while votes.dropFirst().reduce(0, { $0 + $1.duration }) > 60 { votes.removeFirst() }
    }

    /// The language holding at least 70 % of the recent speech, once there are 5 s of it (two phrases or so).
    public var dominant: Language? {
        let total = votes.reduce(0) { $0 + $1.duration }
        guard total >= 5 else { return nil }
        let byLanguage = Dictionary(grouping: votes, by: \.language).mapValues { $0.reduce(0) { $0 + $1.duration } }
        guard let best = byLanguage.max(by: { $0.value < $1.value }), best.value / total >= 0.7 else { return nil }
        return best.key
    }

    /// The language to pass to Whisper for a phrase, nil to let it detect. Detection costs ~0.3 s, so once the
    /// meeting language is known it is passed on, and only every fourth long phrase is checked again,
    /// so a meeting that switches language is still followed.
    public mutating func hint(forDuration duration: TimeInterval) -> Language? {
        guard let dominant else { return nil }
        if duration >= Self.reliableDuration, givenSinceCheck >= 3 {
            givenSinceCheck = 0
            return nil
        }
        givenSinceCheck += 1
        return dominant
    }
}

public enum WAV {
    /// 16-bit PCM mono WAV, the format whisper-server reads directly.
    public static func encode(_ samples: [Float], sampleRate: Int = Int(SpeechAudio.sampleRate)) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36) + payload)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(payload)
        for sample in samples { put(Int16((max(-1, min(1, sample)) * 32767).rounded())) }
        return data
    }
}

public enum TranscriptFilter {
    /// Whisper invents these on silence, music or noise: subtitle credits from its training data.
    static let hallucinations = [
        "amara.org", "untertitel", "untertitelung", "copyright", "thanks for watching", "thank you for watching",
        "subtitles by", "altyazı m.k", "abone ol", "izlediğiniz için teşekkür", "sous-titres", "sottotitoli",
        "продолжение следует",
    ]

    /// Cleans one recognized phrase; nil when nothing worth showing is left.
    public static func clean(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Non-speech annotations: [Music], (laughs), ♪.
        text = text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|[♪♫]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(where: \.isLetter) else { return nil }
        let lower = text.lowercased()
        if hallucinations.contains(where: lower.contains) { return nil }
        return removingRepetition(text)
    }

    /// Whisper sometimes loops and writes a sentence again (or several times). Keeps the first of
    /// consecutive identical sentences.
    static func removingRepetition(_ text: String) -> String {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty else { return }
            if sentences.last.map({ normalized($0) == normalized(sentence) }) != true { sentences.append(sentence) }
        }
        return sentences.isEmpty ? text : sentences.joined(separator: " ")
    }

    private static func normalized(_ sentence: String) -> String {
        sentence.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
