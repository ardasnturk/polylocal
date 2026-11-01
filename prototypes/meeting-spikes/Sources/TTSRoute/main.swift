// S4 spike: synthesize speech into PCM buffers and play them on a chosen output device,
// without changing the system default. Measures time to the first audio buffer.
//
//   swift run TTSRoute --devices
//   swift run TTSRoute <language> "<text>" [--device <name-substring>] [--volume 0.3] [--rate 0.5]
//   e.g. swift run TTSRoute tr-TR "Yeni sürüm hazır." --device "MacBook Pro"

import AVFoundation
import CoreAudio
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

struct Device { let id: AudioDeviceID; let name: String; let outputChannels: Int }

func outputDevices() -> [Device] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids.compactMap { id in
        var nameAddr = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name)
        var streamAddr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var streamSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize)
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(streamSize), alignment: 16)
        defer { list.deallocate() }
        AudioObjectGetPropertyData(id, &streamAddr, 0, nil, &streamSize, list)
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channels > 0 else { return nil }
        return Device(id: id, name: name?.takeRetainedValue() as String? ?? "?", outputChannels: channels)
    }
}

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "--devices" {
    for d in outputDevices() { print("\(d.id)\t\(d.name) (\(d.outputChannels) ch)") }
    exit(0)
}
guard args.count >= 2 else { fail("usage: TTSRoute <language> \"<text>\" [--device name] [--volume v] [--rate r] | --devices") }
func option(_ name: String) -> String? {
    args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
}
let language = args[0], text = args[1]
guard let voice = AVSpeechSynthesisVoice.speechVoices()
    .filter({ $0.language == language })
    .max(by: { $0.quality.rawValue < $1.quality.rawValue }) else { fail("no voice for \(language)") }
print("voice: \(voice.name) (\(voice.language), quality \(voice.quality.rawValue))")

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)
if let wanted = option("--device") {
    guard let device = outputDevices().first(where: { $0.name.localizedCaseInsensitiveContains(wanted) }) else {
        fail("no output device matching \(wanted)")
    }
    // Route only this engine; the system default output stays as it is.
    do { try engine.outputNode.auAudioUnit.setDeviceID(device.id) } catch { fail("cannot select \(device.name): \(error)") }
    print("device: \(device.name)")
}

let utterance = AVSpeechUtterance(string: text)
utterance.voice = voice
utterance.rate = option("--rate").flatMap(Float.init) ?? AVSpeechUtteranceDefaultSpeechRate
let synthesizer = AVSpeechSynthesizer()
let start = Date()
var firstBuffer: TimeInterval?
var connectedFormat: AVAudioFormat?
var scheduledFrames: AVAudioFramePosition = 0
let done = DispatchSemaphore(value: 0)

synthesizer.write(utterance) { buffer in
    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
    if pcm.frameLength == 0 { done.signal(); return }  // end of speech
    if firstBuffer == nil {
        firstBuffer = Date().timeIntervalSince(start)
        connectedFormat = pcm.format
        engine.connect(player, to: engine.mainMixerNode, format: pcm.format)
        engine.mainMixerNode.outputVolume = option("--volume").flatMap(Float.init) ?? 0.3
        do { try engine.start() } catch { fail("engine: \(error)") }
        player.play()
    }
    scheduledFrames += AVAudioFramePosition(pcm.frameLength)
    player.scheduleBuffer(pcm)
}
while done.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
let synthesized = Date().timeIntervalSince(start)
let audioSeconds = Double(scheduledFrames) / (connectedFormat?.sampleRate ?? 22050)
print(String(format: "first buffer %.0f ms · synthesis done %.0f ms · audio %.2f s", (firstBuffer ?? -1) * 1000,
             synthesized * 1000, audioSeconds))
// Let playback finish.
RunLoop.current.run(until: start.addingTimeInterval(max(synthesized, audioSeconds) + 0.3))
