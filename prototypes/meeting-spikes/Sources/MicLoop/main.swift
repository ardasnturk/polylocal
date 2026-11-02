// S5 spike: plays a test tone into the hidden "Polylocal Voice" device and records "Polylocal Microphone",
// the way a meeting app would. Passes when the tone comes back out of the microphone.
//
//   swift run MicLoop [--seconds 3] [--frequency 440]
//   swift run MicLoop --record out.wav [--seconds 20]   # only record the microphone, e.g. while Polylocal speaks

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func device(uid: String) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cfUID = uid as CFString
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafeMutablePointer(to: &cfUID) {
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                   UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
    }
    return status == noErr && id != kAudioObjectUnknown ? id : nil
}

func setDevice(_ engine: AVAudioEngine, input: Bool, _ id: AudioDeviceID) {
    var id = id
    let unit = (input ? engine.inputNode : engine.outputNode).audioUnit!
    let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                      &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    if status != noErr { fail("cannot select device \(id): \(status)") }
}

let args = CommandLine.arguments
func option(_ name: String, _ fallback: Double) -> Double {
    args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? fallback
}
let seconds = option("--seconds", 3)
let frequency = option("--frequency", 440)

guard let voiceID = device(uid: "dev.polylocal.microphone.voice") else { fail("Polylocal Voice not found; is the driver installed?") }
guard let micID = device(uid: "dev.polylocal.microphone.input") else { fail("Polylocal Microphone not found") }
print("voice device \(voiceID), microphone device \(micID)")

// Recorder: like a meeting app reading its microphone.
let recorder = AVAudioEngine()
setDevice(recorder, input: true, micID)
let inFormat = recorder.inputNode.inputFormat(forBus: 0)
print("microphone format: \(inFormat)")
let lock = NSLock()
var captured: [Float] = []
var firstSoundAt: Date?
recorder.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buffer, _ in
    guard let data = buffer.floatChannelData?[0] else { return }
    let samples = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    lock.lock()
    if firstSoundAt == nil, samples.contains(where: { abs($0) > 0.05 }) { firstSoundAt = Date() }
    captured += samples
    lock.unlock()
}
do { try recorder.start() } catch { fail("recorder: \(error)") }

if let index = args.firstIndex(of: "--record"), args.indices.contains(index + 1) {
    let url = URL(fileURLWithPath: args[index + 1])
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: inFormat.sampleRate,
                                   AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
    Thread.sleep(forTimeInterval: seconds)
    recorder.stop()
    lock.lock()
    let samples = captured
    lock.unlock()
    // In a function scope so the file is closed (and its header written) before exit().
    func save() {
    let file = try! AVAudioFile(forWriting: url, settings: settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: 1)!,
                                  frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try! file.write(from: buffer)
    }
    save()
    let voiced = samples.filter { abs($0) > 0.02 }.count
    print(String(format: "recorded %.1f s to %@, %.1f s with sound", Double(samples.count) / inFormat.sampleRate, url.path,
                 Double(voiced) / inFormat.sampleRate))
    exit(0)
}

// Player: like Polylocal speaking into the voice device.
let player = AVAudioEngine()
setDevice(player, input: false, voiceID)
let outFormat = player.outputNode.outputFormat(forBus: 0)
print("voice format: \(outFormat)")
let sampleRate = outFormat.sampleRate
var phase = 0.0
let source = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    for frame in 0..<Int(frameCount) {
        let value = Float(sin(phase) * 0.5)
        phase += 2 * .pi * frequency / sampleRate
        for buffer in buffers { buffer.mData!.assumingMemoryBound(to: Float.self)[frame] = value }
    }
    return noErr
}
let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
player.attach(source)
player.connect(source, to: player.mainMixerNode, format: mono)
let startedAt = Date()
do { try player.start() } catch { fail("player: \(error)") }

Thread.sleep(forTimeInterval: seconds)
player.stop()
Thread.sleep(forTimeInterval: 0.3)
recorder.stop()

lock.lock()
let samples = captured
lock.unlock()
let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count)))
var crossings = 0
for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
let measured = Double(crossings) / 2 / (Double(samples.count) / inFormat.sampleRate)
print(String(format: "captured %.2f s, rms %.3f, frequency ~%.0f Hz", Double(samples.count) / inFormat.sampleRate, rms, measured))
if let firstSoundAt { print(String(format: "first sound after %.0f ms", firstSoundAt.timeIntervalSince(startedAt) * 1000)) }
print(rms > 0.1 ? "PASS: the tone came out of Polylocal Microphone" : "FAIL: no tone on Polylocal Microphone")
exit(rms > 0.1 ? 0 : 1)
