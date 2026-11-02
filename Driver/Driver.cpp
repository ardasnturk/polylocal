// Polylocal Microphone: a virtual audio device for meeting mode level 4 ("speak the translation").
//
// Two devices share one ring buffer inside coreaudiod:
//   - "Polylocal Microphone" (input, visible): what meeting apps select as their microphone.
//   - "Polylocal Voice" (output, hidden): Polylocal plays the translated voice (and, between phrases,
//     the user's real microphone) into it by UID. Hidden, so it never shows up as a speaker.
// No IPC and no files: whatever is played into the voice device comes out of the microphone.
//
// Built with libASPL (MIT, https://github.com/gavv/libASPL). See scripts/build-mic-driver.sh.

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <algorithm>
#include <atomic>
#include <cstring>

namespace {

constexpr UInt32 SampleRate = 48000;
constexpr UInt32 ChannelCount = 1;

// One second of mono audio. The writer (voice device) and the reader (microphone) run on
// separate clocks of the same rate, so the fill level stays small; the extra room absorbs
// scheduling jitter.
constexpr UInt32 Capacity = SampleRate;
// More buffered than this means the reader fell behind (or started late): skip ahead so the
// meeting does not hear the voice with a growing delay.
constexpr UInt32 MaxLatency = SampleRate / 10;

// Single producer (voice device I/O thread), single consumer (microphone I/O thread).
class RingBuffer
{
public:
    void Write(const Float32* samples, UInt32 count)
    {
        UInt64 write = write_.load(std::memory_order_relaxed);
        for (UInt32 n = 0; n < count; n++) {
            buffer_[(write + n) % Capacity] = samples[n];
        }
        write_.store(write + count, std::memory_order_release);
    }

    void Read(Float32* samples, UInt32 count)
    {
        UInt64 write = write_.load(std::memory_order_acquire);
        UInt64 read = read_.load(std::memory_order_relaxed);
        if (write - read > MaxLatency) {
            read = write - std::min<UInt64>(write, count);
        }
        UInt32 available = UInt32(std::min<UInt64>(write - read, count));
        for (UInt32 n = 0; n < available; n++) {
            samples[n] = buffer_[(read + n) % Capacity];
        }
        // Nothing playing: silence, not the last samples again.
        std::memset(samples + available, 0, (count - available) * sizeof(Float32));
        read_.store(read + available, std::memory_order_release);
    }

    void Reset()
    {
        read_.store(write_.load(std::memory_order_acquire), std::memory_order_release);
    }

private:
    Float32 buffer_[Capacity] = {};
    std::atomic<UInt64> write_{0};
    std::atomic<UInt64> read_{0};
};

RingBuffer ring;

class VoiceHandler : public aspl::ControlRequestHandler, public aspl::IORequestHandler
{
public:
    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        const void* bytes,
        UInt32 bytesCount) override
    {
        ring.Write(static_cast<const Float32*>(bytes), bytesCount / sizeof(Float32));
    }
};

class MicrophoneHandler : public aspl::ControlRequestHandler, public aspl::IORequestHandler
{
public:
    OSStatus OnStartIO() override
    {
        // Do not replay what was played while nobody listened.
        ring.Reset();
        return kAudioHardwareNoError;
    }

    void OnReadClientInput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        void* bytes,
        UInt32 bytesCount) override
    {
        ring.Read(static_cast<Float32*>(bytes), bytesCount / sizeof(Float32));
    }
};

aspl::StreamParameters StreamParams(aspl::Direction direction)
{
    aspl::StreamParameters params;
    params.Direction = direction;
    params.Format = {
        .mSampleRate = SampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 4 * ChannelCount,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 4 * ChannelCount,
        .mChannelsPerFrame = ChannelCount,
        .mBitsPerChannel = 32,
    };
    return params;
}

std::shared_ptr<aspl::Device> MakeDevice(const std::shared_ptr<aspl::Context>& context,
    const char* name,
    const char* uid,
    aspl::Direction direction)
{
    aspl::DeviceParameters params;
    params.Name = name;
    params.Manufacturer = "Polylocal";
    params.DeviceUID = uid;
    params.ModelUID = "dev.polylocal.microphone";
    params.SampleRate = SampleRate;
    params.ChannelCount = ChannelCount;
    // Never take over the system's default devices.
    params.CanBeDefault = false;
    params.CanBeDefaultForSystemSounds = false;

    auto device = std::make_shared<aspl::Device>(context, params);
    device->AddStreamAsync(StreamParams(direction));
    return device;
}

std::shared_ptr<aspl::Driver> CreateDriver()
{
    auto context = std::make_shared<aspl::Context>(std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop));

    auto microphone = MakeDevice(context, "Polylocal Microphone", "dev.polylocal.microphone.input", aspl::Direction::Input);
    auto microphoneHandler = std::make_shared<MicrophoneHandler>();
    microphone->SetControlHandler(microphoneHandler);
    microphone->SetIOHandler(microphoneHandler);

    auto voice = MakeDevice(context, "Polylocal Voice", "dev.polylocal.microphone.voice", aspl::Direction::Output);
    voice->SetIsHidden(true);
    auto voiceHandler = std::make_shared<VoiceHandler>();
    voice->SetControlHandler(voiceHandler);
    voice->SetIOHandler(voiceHandler);

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(microphone);
    plugin->AddDevice(voice);

    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

extern "C" void* PolylocalMicrophoneEntryPoint(CFAllocatorRef allocator, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }
    static std::shared_ptr<aspl::Driver> driver = CreateDriver();
    return driver->GetReference();
}
