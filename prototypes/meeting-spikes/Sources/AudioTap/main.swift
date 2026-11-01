// S1 spike: record the audio of one app (and its helper processes) with a Core Audio process tap.
//
//   swift run AudioTap <bundle-id-prefix | pid> [--seconds 10] [--mute] [--out tap.wav]
//   swift run AudioTap --list
//
// --mute sets CATapDescription.muteBehavior = .mutedWhenTapped: the app goes silent on the speakers
// while the tap still receives its audio. Prints the level once per second.

import AVFoundation
import CoreAudio
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr { fail("\(what) failed: \(status)") }
}

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func readArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _: T.Type) -> [T] {
    var addr = address(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.stride
    let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
    defer { buffer.deallocate() }
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer) == noErr else { return [] }
    return Array(UnsafeBufferPointer(start: buffer, count: count))
}

func readValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var addr = address(selector)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

struct AudioProcess {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isOutputting: Bool
}

func audioProcesses() -> [AudioProcess] {
    readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, AudioObjectID.self)
        .map { id in
            AudioProcess(id: id,
                         pid: readValue(id, kAudioProcessPropertyPID, pid_t(0)) ?? 0,
                         bundleID: readString(id, kAudioProcessPropertyBundleID) ?? "",
                         isOutputting: (readValue(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0)
        }
}

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "--list" {
    for p in audioProcesses().sorted(by: { $0.bundleID < $1.bundleID }) {
        print("\(p.isOutputting ? "▶︎" : " ") pid \(p.pid)\t\(p.bundleID)")
    }
    exit(0)
}
guard let prefix = args.first, !prefix.hasPrefix("--") else {
    fail("usage: AudioTap <bundle-id-prefix> [--seconds N] [--mute] [--out file.wav] | --list")
}
func option(_ name: String) -> String? {
    args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
}
let seconds = option("--seconds").flatMap(Double.init) ?? 10
let mute = args.contains("--mute")
let outURL = URL(fileURLWithPath: option("--out") ?? "tap.wav")

// MARK: - Tap

// A number selects one process by PID (command-line tools such as afplay have no bundle ID).
let wantedPID = pid_t(prefix)
let targets = audioProcesses().filter { process in wantedPID.map { process.pid == $0 } ?? process.bundleID.hasPrefix(prefix) }
guard !targets.isEmpty else { fail("no audio process with bundle id prefix \(prefix) (try --list)") }
print("tapping \(targets.map { "\($0.bundleID)(\($0.pid))" }.joined(separator: ", ")) mute=\(mute)")

let description = CATapDescription(stereoMixdownOfProcesses: targets.map(\.id))
description.name = "Polylocal spike tap"
description.isPrivate = true
description.muteBehavior = mute ? .mutedWhenTapped : .unmuted
var tapID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")

guard var format = readValue(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription()) else {
    fail("could not read the tap format")
}
print("tap format: \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) ch")

// The tap is read through a private aggregate device clocked by the default output device.
guard let outputID = readValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                               AudioObjectID(0)),
      let outputUID = readString(outputID, kAudioDevicePropertyDeviceUID) else { fail("no default output device") }
let aggregateDescription: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Polylocal spike",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                       kAudioSubTapUIDKey: description.uuid.uuidString]],
]
var aggregateID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID), "create aggregate device")

guard let avFormat = AVAudioFormat(streamDescription: &format) else { fail("unsupported tap format") }
var file: AVAudioFile?
do {
    file = try AVAudioFile(forWriting: outURL, settings: avFormat.settings, commonFormat: .pcmFormatFloat32,
                           interleaved: avFormat.isInterleaved)
} catch { fail("cannot write \(outURL.path): \(error)") }

let lock = NSLock()
var sumSquares = 0.0
var sampleCount = 0
var totalFrames: AVAudioFramePosition = 0
var firstCallback: Date?
let started = Date()

var procID: AudioDeviceIOProcID?
check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, DispatchQueue(label: "tap")) { _, input, _, _, _ in
    guard let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, bufferListNoCopy: input, deallocator: nil) else { return }
    try? file?.write(from: buffer)
    let channels = Int(avFormat.channelCount)
    let frames = Int(buffer.frameLength)
    var sum = 0.0
    if let data = buffer.floatChannelData {
        if avFormat.isInterleaved {
            for i in 0..<(frames * channels) { let s = Double(data[0][i]); sum += s * s }
        } else {
            for c in 0..<channels { for i in 0..<frames { let s = Double(data[c][i]); sum += s * s } }
        }
    }
    lock.lock()
    if firstCallback == nil { firstCallback = Date() }
    sumSquares += sum
    sampleCount += frames * channels
    totalFrames += AVAudioFramePosition(frames)
    lock.unlock()
}, "create IO proc")
check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")

func cleanup() {
    AudioDeviceStop(aggregateID, procID)
    if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
    AudioHardwareDestroyAggregateDevice(aggregateID)
    AudioHardwareDestroyProcessTap(tapID)
}
signal(SIGINT) { _ in cleanup(); exit(130) }

var peakRMS = 0.0
for second in 1...Int(seconds.rounded(.up)) {
    Thread.sleep(forTimeInterval: 1)
    lock.lock()
    let rms = sampleCount > 0 ? (sumSquares / Double(sampleCount)).squareRoot() : 0
    sumSquares = 0; sampleCount = 0
    lock.unlock()
    peakRMS = max(peakRMS, rms)
    let db = rms > 0 ? 20 * log10(rms) : -.infinity
    print(String(format: "%2ds  rms %.4f  (%.1f dBFS)  %@", second, rms, db, String(repeating: "█", count: min(40, Int(rms * 200)))))
}
cleanup()
file = nil  // closes the file and finalizes the WAV header; exit() would skip it
let latency = firstCallback.map { $0.timeIntervalSince(started) * 1000 } ?? -1
print(String(format: "frames %lld (%.1f s)  first buffer after %.0f ms  peak rms %.4f  → %@",
             totalFrames, Double(totalFrames) / format.mSampleRate, latency, peakRMS, outURL.path))
exit(peakRMS > 0.001 ? 0 : 2)
