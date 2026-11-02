import AppKit
import AVFoundation
import CoreAudio
import Foundation
import PolylocalCore

/// Captures the audio one app plays (including its helper processes, where browsers play audio) through a
/// Core Audio process tap (macOS 14.2+), converted to 16 kHz mono for speech recognition.
/// No virtual audio driver is needed. With `mute`, the app goes silent for the user while the tap still hears it.
@available(macOS 14.2, *)
public final class AppAudioCapture: @unchecked Sendable {
    public struct AudioProcess: Hashable, Sendable {
        public let objectID: AudioObjectID
        public let pid: pid_t
        public let bundleID: String
        /// The app responsible for the process. Safari and other WebKit apps play web audio from a shared-name
        /// helper (`com.apple.WebKit.GPU`, one per app); this tells whose it is.
        public let ownerBundleID: String?
        public let isOutputting: Bool
        public var isInputting = false
        /// The input devices the process has open.
        public var inputDevices: [AudioDeviceID] = []

        public func belongs(to bundleIDPrefix: String) -> Bool {
            bundleID.hasPrefix(bundleIDPrefix) || ownerBundleID?.hasPrefix(bundleIDPrefix) == true
        }
    }

    public enum CaptureError: LocalizedError {
        case noAudioProcess(String)
        case coreAudio(String, OSStatus)

        public var errorDescription: String? {
            switch self {
            case .noAudioProcess:
                String(localized: "The app has not played any audio yet. Join the call first, then try again.")
            case .coreAudio(let step, let status):
                String(localized: "Could not capture the app's audio (\(step), error \(Int(status))).")
            }
        }
    }

    public let bundleIDPrefix: String
    public let mute: Bool
    private let onSamples: @Sendable ([Float]) -> Void
    private let queue = DispatchQueue(label: "dev.polylocal.audio-capture", qos: .userInteractive)
    private let lock = NSLock()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SpeechAudio.sampleRate,
                                             channels: 1, interleaved: false)!
    /// The processes the current tap covers; a meeting app can start more (a new call window, a browser tab).
    public private(set) var tappedProcesses: Set<AudioObjectID> = []

    /// `onSamples` is called on a private serial queue with 16 kHz mono chunks.
    public init(bundleIDPrefix: String, mute: Bool = false, onSamples: @escaping @Sendable ([Float]) -> Void) {
        self.bundleIDPrefix = bundleIDPrefix
        self.mute = mute
        self.onSamples = onSamples
    }

    deinit { stop() }

    public static func processes() -> [AudioProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        return CoreAudioProperty.array(system, kAudioHardwarePropertyProcessObjectList, AudioObjectID.self).map { id in
            let pid = CoreAudioProperty.value(id, kAudioProcessPropertyPID, pid_t(0)) ?? 0
            var process = AudioProcess(objectID: id, pid: pid,
                                       bundleID: CoreAudioProperty.string(id, kAudioProcessPropertyBundleID) ?? "",
                                       ownerBundleID: Responsibility.owner(of: pid).flatMap {
                                           NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
                                       },
                                       isOutputting: (CoreAudioProperty.value(id, kAudioProcessPropertyIsRunningOutput, UInt32(0)) ?? 0) != 0)
            process.isInputting = (CoreAudioProperty.value(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0) != 0
            if process.isInputting {
                process.inputDevices = CoreAudioProperty.array(id, kAudioProcessPropertyDevices, AudioDeviceID.self,
                                                               scope: kAudioObjectPropertyScopeInput)
            }
            return process
        }
    }

    /// Audio processes belonging to the app (its own bundle ID or a helper's, e.g. `com.google.Chrome.helper`).
    public func matchingProcesses() -> Set<AudioObjectID> {
        Set(Self.processes().filter { $0.belongs(to: bundleIDPrefix) }.map(\.objectID))
    }

    public func start() throws {
        let targets = matchingProcesses()
        guard !targets.isEmpty else { throw CaptureError.noAudioProcess(bundleIDPrefix) }
        stop()

        let description = CATapDescription(stereoMixdownOfProcesses: Array(targets))
        description.name = "Polylocal meeting mode"
        description.isPrivate = true
        description.muteBehavior = mute ? .mutedWhenTapped : .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "tap")

        guard var asbd = CoreAudioProperty.value(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription()),
              let format = AVAudioFormat(streamDescription: &asbd),
              let converter = AVAudioConverter(from: format, to: outputFormat) else {
            AudioHardwareDestroyProcessTap(tap)
            throw CaptureError.coreAudio("format", -1)
        }

        // A tap is read through a private aggregate device, clocked by the default output device.
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let output = CoreAudioProperty.value(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)),
              let outputUID = CoreAudioProperty.string(output, kAudioDevicePropertyDeviceUID) else {
            AudioHardwareDestroyProcessTap(tap)
            throw CaptureError.coreAudio("output device", -1)
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Polylocal meeting mode",
            kAudioAggregateDeviceUIDKey: "dev.polylocal.meeting.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        if let error = CaptureError.from(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "device") {
            AudioHardwareDestroyProcessTap(tap)
            throw error
        }

        lock.withLock {
            tapID = tap
            aggregateID = device
            self.converter = converter
            inputFormat = format
            tappedProcesses = targets
        }
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
            self?.deliver(input)
        }
        lock.withLock { procID = proc }
        try check(status, "io")
        try check(AudioDeviceStart(device, proc), "start")
    }

    public func stop() {
        let (tap, device, proc) = lock.withLock {
            defer {
                tapID = AudioObjectID(kAudioObjectUnknown); aggregateID = AudioObjectID(kAudioObjectUnknown)
                procID = nil; converter = nil; tappedProcesses = []
            }
            return (tapID, aggregateID, procID)
        }
        if device != kAudioObjectUnknown {
            AudioDeviceStop(device, proc)
            if let proc { AudioDeviceDestroyIOProcID(device, proc) }
            AudioHardwareDestroyAggregateDevice(device)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
    }

    private func deliver(_ input: UnsafePointer<AudioBufferList>) {
        guard let (converter, format) = lock.withLock({ () -> (AVAudioConverter, AVAudioFormat)? in
            guard let converter, let inputFormat else { return nil }
            return (converter, inputFormat)
        }),
            let source = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
            source.frameLength > 0 else { return }
        let capacity = AVAudioFrameCount(Double(source.frameLength) * outputFormat.sampleRate / format.sampleRate) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, converted.frameLength > 0, let channel = converted.floatChannelData?[0] else { return }
        onSamples(Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))))
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if let error = CaptureError.from(status, step) {
            stop()
            throw error
        }
    }
}

@available(macOS 14.2, *)
private extension AppAudioCapture.CaptureError {
    static func from(_ status: OSStatus, _ step: String) -> Self? {
        status == noErr ? nil : .coreAudio(step, status)
    }
}

/// macOS records which app is responsible for each helper process (what Activity Monitor and privacy
/// prompts use). The call is not in the public SDK, so it is looked up at runtime; without it, only
/// bundle IDs are matched and Safari's web audio is missed.
enum Responsibility {
    private typealias Function = @convention(c) (pid_t) -> pid_t
    private static let function: Function? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: Function.self) }

    static func owner(of pid: pid_t) -> pid_t? {
        guard pid > 0, let function else { return nil }
        let owner = function(pid)
        return owner > 0 && owner != pid ? owner : nil
    }
}

/// Small typed wrappers over AudioObjectGetPropertyData.
enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _: T.Type,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T] {
        var addr = address(selector)
        addr.mScope = scope
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var addr = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
