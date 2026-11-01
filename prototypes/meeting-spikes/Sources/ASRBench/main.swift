// S2 spike: on-device speech recognition speed and output with Apple's SpeechAnalyzer (macOS 26+).
//
//   swift run ASRBench --locales                 # supported / installed locales
//   swift run ASRBench <audio-file> <locale>     # e.g. tap-de.wav de-DE
//
// Reports time to first result, time to the final result and the real-time factor.
// whisper.cpp is benchmarked separately with its own CLI (see README.md).

import AVFoundation
import Foundation
import Speech

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

@available(macOS 26.0, *)
func listLocales() async {
    let supported = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.sorted()
    let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
    for id in supported { print("\(installed.contains(id) ? "✓" : " ") \(id)") }
}

@available(macOS 26.0, *)
func transcribe(_ url: URL, locale requested: Locale) async throws {
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
        fail("\(requested.identifier) is not supported")
    }
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                        reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        print("downloading the \(locale.identifier) speech model…")
        let t = Date()
        try await request.downloadAndInstall()
        print(String(format: "model installed in %.1f s", Date().timeIntervalSince(t)))
    }

    let file = try AVAudioFile(forReading: url)
    let duration = Double(file.length) / file.processingFormat.sampleRate
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let start = Date()
    var firstResult: TimeInterval?
    var finals: [String] = []

    let collector = Task {
        for try await result in transcriber.results {
            if firstResult == nil { firstResult = Date().timeIntervalSince(start) }
            let text = String(result.text.characters)
            if result.isFinal {
                let range = result.range
                print(String(format: "  [%5.2f–%5.2f s] %@", range.start.seconds, range.end.seconds, text))
                finals.append(text)
            }
        }
    }
    try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
    try await collector.value
    let total = Date().timeIntervalSince(start)
    print(String(format: "audio %.1f s · first result %.0f ms · done %.0f ms · RTF %.3f",
                 duration, (firstResult ?? -1) * 1000, total * 1000, total / duration))
    print("TEXT: \(finals.joined(separator: " "))")
}

let args = Array(CommandLine.arguments.dropFirst())
if #unavailable(macOS 26.0) { fail("SpeechAnalyzer needs macOS 26 or later") }
if #available(macOS 26.0, *) {
if args.first == "--locales" {
    await listLocales()
} else if args.count == 2 {
    do { try await transcribe(URL(fileURLWithPath: args[0]), locale: Locale(identifier: args[1])) }
    catch { fail("\(error)") }
} else {
    fail("usage: ASRBench <audio-file> <locale> | --locales")
}
}
