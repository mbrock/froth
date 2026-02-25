#include <memory>
#include <cstring>
#include <vector>

#include "api/video_codecs/video_decoder.h"
#include "api/video_codecs/video_decoder_factory.h"
#include "api/video_codecs/video_encoder.h"
#include "api/video_codecs/video_encoder_factory.h"
#include "api/video_codecs/builtin_video_decoder_factory.h"
#include "api/video_codecs/builtin_video_encoder_factory.h"
#include "modules/audio_device/include/audio_device.h"
#include "modules/audio_device/include/audio_device_data_observer.h"
#include "modules/video_coding/h265_vps_sps_pps_tracker.h"
#include "tgcalls/FakeAudioDeviceModule.h"
#include "rnnoise.h"

namespace {
class NullRenderer final : public tgcalls::FakeAudioDeviceModule::Renderer {
 public:
  bool Render(const tgcalls::AudioFrame &) override { return true; }
};

class NullRecorder final : public tgcalls::FakeAudioDeviceModule::Recorder {
 public:
  tgcalls::AudioFrame Record() override { return {}; }
};

class NullVideoEncoder final : public webrtc::VideoEncoder {
 public:
  int32_t RegisterEncodeCompleteCallback(
      webrtc::EncodedImageCallback *callback) override {
    callback_ = callback;
    return 0;
  }

  int32_t Release() override {
    callback_ = nullptr;
    return 0;
  }

  int32_t Encode(const webrtc::VideoFrame &,
                 const std::vector<webrtc::VideoFrameType> *) override {
    return 0;
  }

  void SetRates(const RateControlParameters &) override {}

  EncoderInfo GetEncoderInfo() const override {
    EncoderInfo info;
    info.implementation_name = "froth-null-video-encoder";
    info.has_trusted_rate_controller = true;
    return info;
  }

 private:
  webrtc::EncodedImageCallback *callback_ = nullptr;
};

class NullVideoDecoder final : public webrtc::VideoDecoder {
 public:
  bool Configure(const Settings &) override { return true; }

  int32_t Decode(const webrtc::EncodedImage &, int64_t) override {
    return 0;
  }

  int32_t RegisterDecodeCompleteCallback(
      webrtc::DecodedImageCallback *callback) override {
    callback_ = callback;
    return 0;
  }

  int32_t Release() override {
    callback_ = nullptr;
    return 0;
  }

  DecoderInfo GetDecoderInfo() const override {
    DecoderInfo info;
    info.implementation_name = "froth-null-video-decoder";
    return info;
  }

 private:
  webrtc::DecodedImageCallback *callback_ = nullptr;
};

class NullVideoEncoderFactory final : public webrtc::VideoEncoderFactory {
 public:
  std::vector<webrtc::SdpVideoFormat> GetSupportedFormats() const override {
    return {webrtc::SdpVideoFormat("VP8")};
  }

  std::unique_ptr<webrtc::VideoEncoder> CreateVideoEncoder(
      const webrtc::SdpVideoFormat &) override {
    return std::make_unique<NullVideoEncoder>();
  }
};

class NullVideoDecoderFactory final : public webrtc::VideoDecoderFactory {
 public:
  std::vector<webrtc::SdpVideoFormat> GetSupportedFormats() const override {
    return {webrtc::SdpVideoFormat("VP8")};
  }

  std::unique_ptr<webrtc::VideoDecoder> CreateVideoDecoder(
      const webrtc::SdpVideoFormat &) override {
    return std::make_unique<NullVideoDecoder>();
  }
};
}  // namespace

namespace webrtc {
std::unique_ptr<VideoEncoderFactory> CreateBuiltinVideoEncoderFactory() {
  return std::make_unique<NullVideoEncoderFactory>();
}

std::unique_ptr<VideoDecoderFactory> CreateBuiltinVideoDecoderFactory() {
  return std::make_unique<NullVideoDecoderFactory>();
}

rtc::scoped_refptr<AudioDeviceModule> AudioDeviceModule::Create(
    AudioLayer,
    TaskQueueFactory *task_queue_factory) {
  auto renderer = std::make_shared<NullRenderer>();
  auto recorder = std::make_shared<NullRecorder>();
  auto creator = tgcalls::FakeAudioDeviceModule::Creator(
      std::move(renderer),
      std::move(recorder),
      tgcalls::FakeAudioDeviceModule::Options{});
  return creator(task_queue_factory);
}

rtc::scoped_refptr<AudioDeviceModule> CreateAudioDeviceWithDataObserver(
    rtc::scoped_refptr<AudioDeviceModule> audio_device_module,
    std::unique_ptr<AudioDeviceDataObserver>) {
  return audio_device_module;
}
}  // namespace webrtc

namespace webrtc::video_coding {
H265VpsSpsPpsTracker::FixedBitstream H265VpsSpsPpsTracker::CopyAndFixBitstream(
    rtc::ArrayView<const uint8_t> bitstream,
    RTPVideoHeader *) {
  FixedBitstream fixed;
  fixed.action = kInsert;
  fixed.bitstream = rtc::CopyOnWriteBuffer(bitstream.data(), bitstream.size());
  return fixed;
}

void H265VpsSpsPpsTracker::InsertVpsSpsPpsNalus(const std::vector<uint8_t> &,
                                                const std::vector<uint8_t> &,
                                                const std::vector<uint8_t> &) {}
}  // namespace webrtc::video_coding

namespace {
struct DummyDenoiseState {
  int unused = 0;
};
}  // namespace

extern "C" {
int rnnoise_get_frame_size(void) { return 480; }

DenoiseState *rnnoise_create(RNNModel *) {
  return reinterpret_cast<DenoiseState *>(new DummyDenoiseState{});
}

void rnnoise_destroy(DenoiseState *st) {
  delete reinterpret_cast<DummyDenoiseState *>(st);
}

float rnnoise_process_frame(DenoiseState *, float *out, const float *in) {
  if (out != nullptr && in != nullptr) {
    std::memcpy(out, in, sizeof(float) * 480);
  }
  return 0.0f;
}
}
