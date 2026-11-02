import AVFoundation
import SystemIntegration

/// Plays audio into the hidden "Polylocal Voice" device, so it comes out of "Polylocal Microphone" in the
/// meeting app (meeting mode level 4). Everything is converted to the device's format (48 kHz mono).
@MainActor
final class VirtualMicrophoneOutput {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var converters: [AVAudioFormat: AVAudioConverter] = [:]

    func start() throws {
        guard let device = AudioDevices.device(uid: PolylocalMicrophone.voiceUID) else {
            throw AudioDeviceError.cannotSelect(-1)
        }
        try AudioDevices.select(device, for: engine.outputNode)
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: 1)!
        self.format = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        player.play()
    }

    func stop() {
        player.stop()
        engine.stop()
        converters = [:]
    }

    /// Queues `buffer` (any format); `completion` runs on the main actor once it has been played.
    func play(_ buffer: AVAudioPCMBuffer, completion: (@MainActor () -> Void)? = nil) {
        guard let converted = convert(buffer) else {
            completion?()
            return
        }
        player.scheduleBuffer(converted, completionCallbackType: .dataPlayedBack) { _ in
            guard let completion else { return }
            Task { @MainActor in completion() }
        }
    }

    /// Drops whatever is queued (the voice was interrupted).
    func flush() {
        player.stop()
        player.play()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let format, buffer.frameLength > 0 else { return nil }
        if buffer.format == format { return buffer }
        let converter = converters[buffer.format] ?? AVAudioConverter(from: buffer.format, to: format)
        guard let converter else { return nil }
        converters[buffer.format] = converter
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
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
        return error == nil ? output : nil
    }
}
