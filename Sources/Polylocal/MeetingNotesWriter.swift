import Foundation
import PolylocalCore

/// Saves one meeting's transcript to its own folder as it happens, so a crash loses at most the current phrase.
/// Layout (docs/MEETING_MODE.md §4): transcript.md (original + translation), transcript.original.md,
/// transcript.<target>.md, meeting.json, and summary.md once the meeting ends. No audio is ever written.
@MainActor
final class MeetingNotesWriter {
    static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Polylocal Meetings", isDirectory: true)
    }

    let root: URL
    private(set) var transcript: MeetingTranscript
    /// Created with the first phrase, so a meeting where nobody spoke leaves no empty folder.
    private(set) var folder: URL?
    private var indexByID: [UUID: Int] = [:]

    init(root: URL, app: String, started: Date, targetLanguage: Language) {
        self.root = root
        transcript = MeetingTranscript(app: app, started: started, targetLanguage: targetLanguage.code)
    }

    func add(_ id: UUID, _ segment: MeetingTranscript.Segment) {
        indexByID[id] = transcript.segments.count
        transcript.segments.append(segment)
        write()
    }

    func setTranslation(_ id: UUID, _ translation: String?) {
        guard let index = indexByID[id] else { return }
        transcript.segments[index].translation = translation
        write()
    }

    /// Records the end time; returns the folder if anything was saved.
    @discardableResult
    func finish(at date: Date = Date()) -> URL? {
        transcript.ended = date
        if folder != nil { write() }
        return folder
    }

    func writeSummary(_ markdown: String) {
        guard let folder else { return }
        save("# \(transcript.title)\n\n\(markdown)\n", to: folder.appendingPathComponent("summary.md"))
    }

    private func write() {
        guard let folder = folder ?? makeFolder() else { return }
        save(transcript.markdown(.interleaved), to: folder.appendingPathComponent("transcript.md"))
        save(transcript.markdown(.original), to: folder.appendingPathComponent("transcript.original.md"))
        save(transcript.markdown(.translation), to: folder.appendingPathComponent("transcript.\(transcript.targetLanguage).md"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let json = try? encoder.encode(transcript) {
            save(json, to: folder.appendingPathComponent("meeting.json"))
        }
    }

    private func makeFolder() -> URL? {
        let fm = FileManager.default
        // Like history: readable only by this user.
        try? fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var candidate = root.appendingPathComponent(transcript.folderName, isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(transcript.folderName) (\(suffix))", isDirectory: true)
            suffix += 1
        }
        do {
            try fm.createDirectory(at: candidate, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            Log.meeting.error("notes folder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        folder = candidate
        return candidate
    }

    private func save(_ text: String, to url: URL) {
        save(Data(text.utf8), to: url)
    }

    private func save(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.meeting.error("notes write: \(error.localizedDescription, privacy: .public)")
        }
    }
}
