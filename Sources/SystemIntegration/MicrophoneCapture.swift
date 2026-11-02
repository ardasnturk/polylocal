import AVFoundation
import CoreAudio
import Foundation

/// The devices of the Polylocal Microphone driver (Driver/Driver.cpp), found by their fixed UIDs.
public enum PolylocalMicrophone {
    /// What meeting apps select as their microphone.
    public static let inputUID = "dev.polylocal.microphone.input"
    /// Hidden output: what Polylocal plays into it comes out of the microphone.
    public static let voiceUID = "dev.polylocal.microphone.voice"

    public static var isInstalled: Bool { AudioDevices.device(uid: voiceUID) != nil && AudioDevices.device(uid: inputUID) != nil }
}

public enum AudioDevices {
    /// Works for hidden devices too.
    public static func device(uid: String) -> AudioDeviceID? {
        var address = CoreAudioProperty.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    public static func uid(of device: AudioDeviceID) -> String? {
        CoreAudioProperty.string(device, kAudioDevicePropertyDeviceUID)
    }

    public static var defaultInput: AudioDeviceID? {
        CoreAudioProperty.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
                                AudioDeviceID(kAudioObjectUnknown))
            .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    /// The input devices with a built-in transport (the Mac's own microphone).
    public static var builtInInput: AudioDeviceID? {
        CoreAudioProperty.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, AudioDeviceID.self)
            .first { device in
                CoreAudioProperty.value(device, kAudioDevicePropertyTransportType, UInt32(0)) == kAudioDeviceTransportTypeBuiltIn
                    && hasInput(device)
            }
    }

    static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
            .contains { $0.mNumberChannels > 0 }
    }

    /// Points an AVAudioEngine's input or output node at a device without changing the system default.
    public static func select(_ device: AudioDeviceID, for node: AVAudioIONode) throws {
        guard let unit = node.audioUnit else { throw AudioDeviceError.noAudioUnit }
        var device = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { throw AudioDeviceError.cannotSelect(status) }
    }
}

public enum AudioDeviceError: LocalizedError {
    case noAudioUnit
    case cannotSelect(OSStatus)
    case noMicrophone

    public var errorDescription: String? {
        switch self {
        case .noAudioUnit, .cannotSelect: String(localized: "The audio device could not be opened.")
        case .noMicrophone: String(localized: "No microphone found.")
        }
    }
}

/// The user's real microphone, for meeting mode level 4: delivers 16 kHz mono for speech recognition, and the
/// original buffers for passing the voice through unchanged ("speak directly").
public final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let onSamples: @Sendable ([Float]) -> Void
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private var converter: AVAudioConverter?
    private let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    public init(onSamples: @escaping @Sendable ([Float]) -> Void, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.onSamples = onSamples
        self.onBuffer = onBuffer
    }

    deinit { stop() }

    /// The microphone to listen to: the system default, unless that is Polylocal's own (which would loop),
    /// then the built-in one.
    public static func preferredDevice() -> AudioDeviceID? {
        if let device = AudioDevices.defaultInput, AudioDevices.uid(of: device) != PolylocalMicrophone.inputUID {
            return device
        }
        return AudioDevices.builtInInput
    }

    public func start() throws {
        guard let device = Self.preferredDevice() else { throw AudioDeviceError.noMicrophone }
        let input = engine.inputNode
        try AudioDevices.select(device, for: input)
        let format = input.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: format, to: speechFormat)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.deliver(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        onBuffer(buffer)
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * speechFormat.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = output.floatChannelData?[0] else { return }
        onSamples(Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength))))
    }
}
