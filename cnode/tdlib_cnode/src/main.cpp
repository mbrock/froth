#include <ei.h>
#include <td/telegram/td_json_client.h>
#include <tgcalls/Instance.h>
#include <tgcalls/FakeAudioDeviceModule.h>
#include <tgcalls/StaticThreads.h>
#include <tgcalls/group/GroupInstanceCustomImpl.h>
#include <api/scoped_refptr.h>
#include <modules/audio_device/include/audio_device.h>

#include <chrono>
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstring>
#include <cctype>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <mutex>
#include <deque>
#include <unordered_map>
#include <vector>

#ifdef __linux__
#include <sys/prctl.h>
#include <signal.h>
#endif
#if defined(__linux__) || defined(__APPLE__)
#include <dlfcn.h>
#endif

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

namespace {

using TgcallsRegisterFunction = bool (*)();

struct TgcallsRegistrationState {
  std::string source = "none";
  bool attempted = false;
  bool ok = false;
  std::string plugin_path;
  std::string error;
};

#if defined(__GNUC__) || defined(__clang__)
extern "C" bool froth_tgcalls_register() __attribute__((weak));
#endif

struct Opts {
  std::string node;    // e.g. "tdlib_cnode@host"
  std::string cookie;  // must match BEAM node cookie
  std::string server = "tdlib";  // registered name this cnode serves
  int verbosity = -1;            // TDLib log verbosity; -1 means don't set
};

[[noreturn]] void usage(const char *argv0) {
  std::cerr
      << "Usage: " << argv0
      << " --node <name@host> --cookie <cookie> [--server <atom>] [--verbosity <n>]\n";
  std::exit(2);
}

std::string alive_name_from_node(const std::string &node) {
  auto at = node.find('@');
  if (at == std::string::npos) return node;
  return node.substr(0, at);
}

Opts parse_args(int argc, char **argv) {
  Opts o;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto need = [&](const char *flag) -> const char * {
      if (i + 1 >= argc) {
        std::cerr << "Missing value for " << flag << "\n";
        usage(argv[0]);
      }
      return argv[++i];
    };

    if (a == "--node") {
      o.node = need("--node");
    } else if (a == "--cookie") {
      o.cookie = need("--cookie");
    } else if (a == "--server") {
      o.server = need("--server");
    } else if (a == "--verbosity") {
      o.verbosity = std::stoi(need("--verbosity"));
    } else if (a == "-h" || a == "--help") {
      usage(argv[0]);
    } else {
      std::cerr << "Unknown argument: " << a << "\n";
      usage(argv[0]);
    }
  }

  if (o.node.empty() || o.cookie.empty()) {
    usage(argv[0]);
  }
  return o;
}

void td_set_verbosity(int verbosity) {
  if (verbosity < 0) return;

  std::string req =
      std::string("{\"@type\":\"setLogVerbosityLevel\",\"new_verbosity_level\":") +
      std::to_string(verbosity) + "}";
  (void)td_json_client_execute(nullptr, req.c_str());
}

std::string decode_binary(const char *buf, int *index) {
  int type = 0;
  int size = 0;
  if (ei_get_type(buf, index, &type, &size) != 0) {
    return {};
  }
  if (type != ERL_BINARY_EXT) {
    return {};
  }

  std::string out;
  out.resize(static_cast<size_t>(size));
  long actual = 0;
  if (ei_decode_binary(buf, index, out.data(), &actual) != 0) {
    return {};
  }
  out.resize(static_cast<size_t>(actual));
  return out;
}

std::optional<int> extract_client_id(const std::string &json) {
  static const std::string key = "\"@client_id\":";
  auto pos = json.find(key);
  if (pos == std::string::npos) {
    return std::nullopt;
  }

  pos += key.size();
  while (pos < json.size() &&
         std::isspace(static_cast<unsigned char>(json[static_cast<size_t>(pos)]))) {
    pos++;
  }

  const char *start = json.c_str() + static_cast<std::ptrdiff_t>(pos);
  char *end = nullptr;
  long value = std::strtol(start, &end, 10);
  if (start == end || value < INT_MIN || value > INT_MAX) {
    return std::nullopt;
  }

  return static_cast<int>(value);
}

int client_id_for_session(const std::string &session_id,
                          std::unordered_map<std::string, int> &session_to_client) {
  auto it = session_to_client.find(session_id);
  if (it != session_to_client.end()) {
    return it->second;
  }

  int client_id = td_create_client_id();
  session_to_client.emplace(session_id, client_id);
  return client_id;
}

void send_tdjson(int fd, const erlang_pid &to, const std::string &json) {
  ei_x_buff xb;
  ei_x_new_with_version(&xb);

  ei_x_encode_tuple_header(&xb, 2);
  ei_x_encode_atom(&xb, "tdjson");
  ei_x_encode_binary(&xb, json.data(), static_cast<int>(json.size()));

  // ei_send expects a non-const pointer.
  erlang_pid pid = to;
  (void)ei_send(fd, &pid, xb.buff, xb.index);

  ei_x_free(&xb);
}

std::string json_escape(const std::string &input) {
  std::string out;
  out.reserve(input.size());

  for (unsigned char c : input) {
    switch (c) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\b':
        out += "\\b";
        break;
      case '\f':
        out += "\\f";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (c < 0x20) {
          char buf[7] = {0};
          std::snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out.push_back(static_cast<char>(c));
        }
        break;
    }
  }

  return out;
}

TgcallsRegistrationState load_tgcalls_registration() {
  TgcallsRegistrationState state;

#if defined(__GNUC__) || defined(__clang__)
  if (froth_tgcalls_register != nullptr) {
    state.source = "linked";
    state.attempted = true;
    state.ok = froth_tgcalls_register();
    if (!state.ok) {
      state.error = "linked froth_tgcalls_register() returned false";
    }
    return state;
  }
#endif

  const char *plugin_env = std::getenv("FROTH_TGCALLS_PLUGIN");
  if (plugin_env == nullptr || plugin_env[0] == '\0') {
    state.error = "set FROTH_TGCALLS_PLUGIN to a registration plugin";
    return state;
  }

  state.source = "plugin";
  state.plugin_path = plugin_env;
  state.attempted = true;

#if defined(__linux__) || defined(__APPLE__)
  static void *plugin_handle = nullptr;
  plugin_handle = dlopen(plugin_env, RTLD_NOW | RTLD_GLOBAL);
  if (plugin_handle == nullptr) {
    const char *detail = dlerror();
    state.error = detail != nullptr ? detail : "dlopen failed";
    return state;
  }

  dlerror();
  void *symbol = dlsym(plugin_handle, "froth_tgcalls_register");
  const char *dlsym_error = dlerror();
  if (symbol == nullptr || dlsym_error != nullptr) {
    state.error = dlsym_error != nullptr ? dlsym_error : "missing froth_tgcalls_register symbol";
    return state;
  }

  const auto register_fn = reinterpret_cast<TgcallsRegisterFunction>(symbol);
  state.ok = register_fn();
  if (!state.ok) {
    state.error = "plugin froth_tgcalls_register() returned false";
  }
#else
  state.error = "dynamic plugin loading is unsupported on this platform";
#endif

  return state;
}

const TgcallsRegistrationState &tgcalls_registration_state() {
  static const TgcallsRegistrationState state = load_tgcalls_registration();
  return state;
}

std::string tgcalls_status_json() {
  const auto &registration = tgcalls_registration_state();
  const auto versions = tgcalls::Meta::Versions();
  const bool engine_available = !versions.empty();

  std::ostringstream out;
  out << "{\"linked\":true,\"engine_available\":" << (engine_available ? "true" : "false")
      << ",\"registered_versions\":[";

  for (size_t i = 0; i < versions.size(); i++) {
    if (i != 0) {
      out << ",";
    }
    out << "\"" << json_escape(versions[i]) << "\"";
  }

  out << "],\"max_layer\":" << tgcalls::Meta::MaxLayer()
      << ",\"registration_source\":\"" << json_escape(registration.source) << "\""
      << ",\"registration_attempted\":" << (registration.attempted ? "true" : "false")
      << ",\"registration_ok\":" << (registration.ok ? "true" : "false")
      << ",\"plugin_path\":\"" << json_escape(registration.plugin_path) << "\""
      << ",\"registration_error\":\"" << json_escape(registration.error) << "\"}";
  return out.str();
}

bool decode_bool_atom(const char *buf, int *index, bool &value) {
  char atom[MAXATOMLEN_UTF8] = {0};
  if (ei_decode_atom(buf, index, atom) != 0) {
    return false;
  }

  if (std::strcmp(atom, "true") == 0) {
    value = true;
    return true;
  }
  if (std::strcmp(atom, "false") == 0) {
    value = false;
    return true;
  }
  return false;
}

std::string base64_encode(const uint8_t *data, size_t size) {
  static constexpr char kAlphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

  std::string out;
  out.reserve(((size + 2) / 3) * 4);

  for (size_t i = 0; i < size; i += 3) {
    const uint32_t octet_a = data[i];
    const uint32_t octet_b = (i + 1 < size) ? data[i + 1] : 0;
    const uint32_t octet_c = (i + 2 < size) ? data[i + 2] : 0;
    const uint32_t triple = (octet_a << 16) | (octet_b << 8) | octet_c;

    out.push_back(kAlphabet[(triple >> 18) & 0x3F]);
    out.push_back(kAlphabet[(triple >> 12) & 0x3F]);
    out.push_back((i + 1 < size) ? kAlphabet[(triple >> 6) & 0x3F] : '=');
    out.push_back((i + 2 < size) ? kAlphabet[triple & 0x3F] : '=');
  }

  return out;
}

constexpr int kAudioSampleRateHz = 48000;
constexpr int kAudioFrameMs = 20;
constexpr size_t kAudioFrameBytes = static_cast<size_t>((kAudioSampleRateHz * kAudioFrameMs / 1000) * 2);

struct PcmPlaybackState {
  std::vector<uint8_t> pcm;
  size_t offset = 0;
  std::chrono::steady_clock::time_point next_emit = std::chrono::steady_clock::now();
};

struct CallAudioBridgeState {
  std::mutex mutex;
  std::deque<std::vector<uint8_t>> rendered_pcm_frames;
};

bool queue_audio_frame(const std::shared_ptr<CallAudioBridgeState> &bridge,
                       const tgcalls::AudioFrame &frame) {
  if (!bridge || frame.audio_samples == nullptr || frame.num_samples == 0 ||
      frame.bytes_per_sample == 0) {
    return false;
  }

  const size_t byte_count = frame.num_samples * frame.bytes_per_sample;
  if (byte_count == 0) {
    return false;
  }

  std::vector<uint8_t> pcm(byte_count);
  std::memcpy(pcm.data(), frame.audio_samples, byte_count);

  std::lock_guard<std::mutex> guard(bridge->mutex);
  bridge->rendered_pcm_frames.push_back(std::move(pcm));

  constexpr size_t kMaxQueuedFrames = 400;
  while (bridge->rendered_pcm_frames.size() > kMaxQueuedFrames) {
    bridge->rendered_pcm_frames.pop_front();
  }

  return true;
}

class QueueingRenderer final : public tgcalls::FakeAudioDeviceModule::Renderer {
 public:
  explicit QueueingRenderer(std::shared_ptr<CallAudioBridgeState> bridge)
      : bridge_(std::move(bridge)) {}

  bool Render(const tgcalls::AudioFrame &frame) override {
    queue_audio_frame(bridge_, frame);
    return true;
  }

 private:
  std::shared_ptr<CallAudioBridgeState> bridge_;
};

class SilenceRecorder final : public tgcalls::FakeAudioDeviceModule::Recorder {
 public:
  SilenceRecorder() : samples_(kAudioSampleRateHz / 100, 0) {}

  tgcalls::AudioFrame Record() override {
    tgcalls::AudioFrame frame{};
    frame.audio_samples = samples_.data();
    frame.num_samples = samples_.size();
    frame.bytes_per_sample = sizeof(int16_t);
    frame.num_channels = 1;
    frame.samples_per_sec = kAudioSampleRateHz;
    frame.elapsed_time_ms = 0;
    frame.ntp_time_ms = 0;
    return frame;
  }

 private:
  std::vector<int16_t> samples_;
};

using CallAudioSubscribers = std::unordered_map<int64_t, std::vector<erlang_pid>>;
using CallAudioPlaybacks = std::unordered_map<int64_t, PcmPlaybackState>;

struct ParsedRtcServer {
  int64_t id = 0;
  std::string ipv4;
  std::string ipv6;
  uint16_t port = 0;
  std::string login;
  std::string password;
  bool is_turn = false;
  bool is_tcp = false;
  std::string peer_tag;
};

struct TgCallRuntime {
  std::string session_id;
  std::string version;
  bool is_outgoing = false;
  std::unique_ptr<tgcalls::Instance> instance;
  std::shared_ptr<CallAudioBridgeState> audio_bridge;
};

using TgCallRuntimes = std::unordered_map<int64_t, TgCallRuntime>;

struct TgGroupCallRuntime {
  std::string session_id;
  std::unique_ptr<tgcalls::GroupInstanceInterface> instance;
  std::shared_ptr<CallAudioBridgeState> audio_bridge;
};

using TgGroupCallRuntimes = std::unordered_map<int64_t, TgGroupCallRuntime>;

struct PendingCallSignaling {
  std::string session_id;
  int64_t call_id = 0;
  std::vector<uint8_t> data;
};

struct PendingCallSignalingQueue {
  std::mutex mutex;
  std::vector<PendingCallSignaling> queue;
};

struct PendingGroupJoinPayload {
  int64_t group_call_id = 0;
  uint32_t audio_source_id = 0;
  std::string payload;
};

struct PendingGroupJoinPayloadQueue {
  std::mutex mutex;
  std::vector<PendingGroupJoinPayload> queue;
};

std::optional<int64_t> decode_int64(const char *buf, int *index) {
  long long value = 0;
  if (ei_decode_longlong(buf, index, &value) != 0) {
    return std::nullopt;
  }
  return static_cast<int64_t>(value);
}

bool decode_rtc_server_list(const char *buf, int *index, std::vector<ParsedRtcServer> &servers) {
  int list_arity = 0;
  if (ei_decode_list_header(buf, index, &list_arity) != 0) {
    return false;
  }

  servers.clear();
  if (list_arity == 0) {
    return true;
  }

  servers.reserve(static_cast<size_t>(list_arity));
  for (int i = 0; i < list_arity; i++) {
    int tuple_arity = 0;
    if (ei_decode_tuple_header(buf, index, &tuple_arity) != 0 || tuple_arity != 9) {
      return false;
    }

    ParsedRtcServer server;
    const auto id = decode_int64(buf, index);
    if (!id.has_value()) {
      return false;
    }
    server.id = *id;

    server.ipv4 = decode_binary(buf, index);
    server.ipv6 = decode_binary(buf, index);

    long long port = 0;
    if (ei_decode_longlong(buf, index, &port) != 0 || port < 0 || port > 65535) {
      return false;
    }
    server.port = static_cast<uint16_t>(port);

    server.login = decode_binary(buf, index);
    server.password = decode_binary(buf, index);
    if (!decode_bool_atom(buf, index, server.is_turn) ||
        !decode_bool_atom(buf, index, server.is_tcp)) {
      return false;
    }
    server.peer_tag = decode_binary(buf, index);

    servers.push_back(std::move(server));
  }

  int tail_arity = 0;
  if (ei_decode_list_header(buf, index, &tail_arity) != 0 || tail_arity != 0) {
    return false;
  }

  return true;
}

bool pid_equal(const erlang_pid &a, const erlang_pid &b) {
  return a.num == b.num && a.serial == b.serial && a.creation == b.creation &&
         std::strcmp(a.node, b.node) == 0;
}

void add_call_audio_subscriber(CallAudioSubscribers &subscribers, int64_t call_id,
                               const erlang_pid &pid) {
  auto &list = subscribers[call_id];
  const auto it = std::find_if(list.begin(), list.end(),
                               [&](const erlang_pid &candidate) { return pid_equal(candidate, pid); });
  if (it == list.end()) {
    list.push_back(pid);
  }
}

void remove_call_audio_subscriber(CallAudioSubscribers &subscribers, int64_t call_id,
                                  const erlang_pid &pid) {
  const auto map_it = subscribers.find(call_id);
  if (map_it == subscribers.end()) {
    return;
  }

  auto &list = map_it->second;
  list.erase(std::remove_if(list.begin(), list.end(),
                            [&](const erlang_pid &candidate) { return pid_equal(candidate, pid); }),
             list.end());

  if (list.empty()) {
    subscribers.erase(map_it);
  }
}

void send_call_audio(int fd, const erlang_pid &to, int64_t call_id, const uint8_t *data, size_t size) {
  ei_x_buff xb;
  ei_x_new_with_version(&xb);

  ei_x_encode_tuple_header(&xb, 3);
  ei_x_encode_atom(&xb, "call_audio");
  ei_x_encode_longlong(&xb, static_cast<long long>(call_id));
  ei_x_encode_binary(&xb, data, static_cast<int>(size));

  erlang_pid pid = to;
  (void)ei_send(fd, &pid, xb.buff, xb.index);

  ei_x_free(&xb);
}

void send_call_media_event(int fd, const erlang_pid &to, int64_t call_id, const char *event) {
  ei_x_buff xb;
  ei_x_new_with_version(&xb);

  ei_x_encode_tuple_header(&xb, 3);
  ei_x_encode_atom(&xb, "call_media_event");
  ei_x_encode_longlong(&xb, static_cast<long long>(call_id));
  ei_x_encode_atom(&xb, event);

  erlang_pid pid = to;
  (void)ei_send(fd, &pid, xb.buff, xb.index);

  ei_x_free(&xb);
}

void send_call_media_error(int fd, const erlang_pid &to, int64_t call_id, const std::string &error) {
  ei_x_buff xb;
  ei_x_new_with_version(&xb);

  ei_x_encode_tuple_header(&xb, 3);
  ei_x_encode_atom(&xb, "call_media_error");
  ei_x_encode_longlong(&xb, static_cast<long long>(call_id));
  ei_x_encode_binary(&xb, error.data(), static_cast<int>(error.size()));

  erlang_pid pid = to;
  (void)ei_send(fd, &pid, xb.buff, xb.index);

  ei_x_free(&xb);
}

void send_group_call_join_payload(int fd,
                                  const erlang_pid &to,
                                  int64_t group_call_id,
                                  uint32_t audio_source_id,
                                  const std::string &payload) {
  ei_x_buff xb;
  ei_x_new_with_version(&xb);

  ei_x_encode_tuple_header(&xb, 4);
  ei_x_encode_atom(&xb, "group_call_join_payload");
  ei_x_encode_longlong(&xb, static_cast<long long>(group_call_id));
  ei_x_encode_long(&xb, static_cast<long>(audio_source_id));
  ei_x_encode_binary(&xb, payload.data(), static_cast<int>(payload.size()));

  erlang_pid pid = to;
  (void)ei_send(fd, &pid, xb.buff, xb.index);

  ei_x_free(&xb);
}

void broadcast_call_media_event(int fd, const CallAudioSubscribers &subscribers, int64_t call_id,
                                const char *event) {
  const auto it = subscribers.find(call_id);
  if (it == subscribers.end()) {
    return;
  }
  for (const auto &pid : it->second) {
    send_call_media_event(fd, pid, call_id, event);
  }
}

void broadcast_call_media_error(int fd, const CallAudioSubscribers &subscribers, int64_t call_id,
                                const std::string &error) {
  const auto it = subscribers.find(call_id);
  if (it == subscribers.end()) {
    return;
  }
  for (const auto &pid : it->second) {
    send_call_media_error(fd, pid, call_id, error);
  }
}

void stop_tgcalls_runtime(TgCallRuntimes &runtimes, int64_t call_id) {
  const auto it = runtimes.find(call_id);
  if (it == runtimes.end()) {
    return;
  }

  if (it->second.instance) {
    it->second.instance->stop([](tgcalls::FinalState) {});
  }

  runtimes.erase(it);
}

void stop_tgcalls_group_runtime(TgGroupCallRuntimes &runtimes, int64_t group_call_id) {
  const auto it = runtimes.find(group_call_id);
  if (it == runtimes.end()) {
    return;
  }

  if (it->second.instance) {
    it->second.instance->stop([] {});
  }

  runtimes.erase(it);
}

bool start_tgcalls_runtime(TgCallRuntimes &runtimes,
                           PendingCallSignalingQueue &pending_signaling,
                           int64_t call_id,
                           const std::string &session_id,
                           const std::string &version,
                           bool is_outgoing,
                           bool allow_p2p,
                           const std::string &encryption_key,
                           const std::vector<ParsedRtcServer> &parsed_servers,
                           const std::string &custom_parameters,
                           std::string &error) {
  if (session_id.empty()) {
    error = "missing session_id";
    return false;
  }
  if (version.empty()) {
    error = "missing tgcalls version";
    return false;
  }
  if (encryption_key.size() != tgcalls::EncryptionKey::kSize) {
    error = "encryption_key must be 256 bytes";
    return false;
  }
  if (tgcalls::Meta::Versions().empty()) {
    const auto &registration = tgcalls_registration_state();
    if (!registration.error.empty()) {
      error = "no tgcalls implementations registered (" + registration.error + ")";
    } else {
      error = "no tgcalls implementations registered";
    }
    return false;
  }

  std::vector<tgcalls::Endpoint> endpoints;
  std::vector<tgcalls::RtcServer> rtc_servers;

  endpoints.reserve(parsed_servers.size());
  rtc_servers.reserve(parsed_servers.size());
  for (const auto &parsed : parsed_servers) {
    if (!parsed.peer_tag.empty()) {
      if (parsed.peer_tag.size() != 16) {
        error = "peer_tag must be 16 bytes when provided";
        return false;
      }

      tgcalls::Endpoint endpoint;
      endpoint.endpointId = parsed.id;
      endpoint.host.ipv4 = parsed.ipv4;
      endpoint.host.ipv6 = parsed.ipv6;
      endpoint.port = parsed.port;
      endpoint.type = parsed.is_tcp ? tgcalls::EndpointType::TcpRelay
                                    : tgcalls::EndpointType::UdpRelay;
      std::memcpy(endpoint.peerTag, parsed.peer_tag.data(), 16);
      endpoints.push_back(std::move(endpoint));
    }

    std::string host = parsed.ipv4;
    if (host.empty()) {
      host = parsed.ipv6;
    }

    if (!host.empty()) {
      tgcalls::RtcServer server;
      server.id = static_cast<uint8_t>(parsed.id & 0xFF);
      server.host = host;
      server.port = parsed.port;
      server.login = parsed.login;
      server.password = parsed.password;
      server.isTurn = parsed.is_turn;
      server.isTcp = parsed.is_tcp;
      rtc_servers.push_back(std::move(server));
    }
  }

  auto key_bytes = std::make_shared<std::array<uint8_t, tgcalls::EncryptionKey::kSize>>();
  std::memcpy(key_bytes->data(), encryption_key.data(), key_bytes->size());
  tgcalls::EncryptionKey key(key_bytes, is_outgoing);

  tgcalls::Config config;
  config.initializationTimeout = 30.0;
  config.receiveTimeout = 20.0;
  config.enableP2P = allow_p2p;
  config.allowTCP = true;
  config.enableNS = true;
  config.enableAGC = true;
  config.maxApiLayer = std::max(tgcalls::Meta::MaxLayer(), 92);
  config.customParameters = custom_parameters;

  auto signaling_emitted = [call_id, session_id, &pending_signaling](const std::vector<uint8_t> &data) {
    PendingCallSignaling entry;
    entry.session_id = session_id;
    entry.call_id = call_id;
    entry.data = data;

    std::lock_guard<std::mutex> guard(pending_signaling.mutex);
    pending_signaling.queue.push_back(std::move(entry));
  };

  auto audio_bridge = std::make_shared<CallAudioBridgeState>();
  auto create_audio_device_module =
      [audio_bridge](webrtc::TaskQueueFactory *task_queue_factory)
          -> webrtc::scoped_refptr<webrtc::AudioDeviceModule> {
    auto renderer = std::make_shared<QueueingRenderer>(audio_bridge);
    auto recorder = std::make_shared<SilenceRecorder>();

    tgcalls::FakeAudioDeviceModule::Options options;
    options.samples_per_sec = static_cast<uint32_t>(kAudioSampleRateHz);
    options.num_channels = 1;

    auto creator =
        tgcalls::FakeAudioDeviceModule::Creator(std::move(renderer), std::move(recorder), options);
    return creator(task_queue_factory);
  };

  tgcalls::Descriptor descriptor{
      version,
      config,
      tgcalls::PersistentState{},
      std::move(endpoints),
      std::unique_ptr<tgcalls::Proxy>{},
      std::move(rtc_servers),
      tgcalls::NetworkType::WiFi,
      key,
      tgcalls::MediaDevicesConfig{},
      std::shared_ptr<tgcalls::VideoCaptureInterface>{},
      [](tgcalls::State) {},
      [](int) {},
      [](float) {},
      [](bool) {},
      [](tgcalls::AudioState, tgcalls::VideoState) {},
      [](float) {},
      std::move(signaling_emitted),
      std::move(create_audio_device_module),
      nullptr,
      "",
      "",
      nullptr
  };

  auto instance = tgcalls::Meta::Create(version, std::move(descriptor));
  if (!instance) {
    error = "failed to create tgcalls instance for version " + version;
    return false;
  }

  TgCallRuntime runtime;
  runtime.session_id = session_id;
  runtime.version = version;
  runtime.is_outgoing = is_outgoing;
  runtime.audio_bridge = std::move(audio_bridge);
  runtime.instance = std::move(instance);

  runtimes[call_id] = std::move(runtime);
  return true;
}

bool start_tgcalls_group_runtime(TgGroupCallRuntimes &runtimes,
                                 PendingGroupJoinPayloadQueue &pending_join_payloads,
                                 int64_t group_call_id,
                                 const std::string &session_id,
                                 std::string &error) {
  if (session_id.empty()) {
    error = "missing session_id";
    return false;
  }

  auto audio_bridge = std::make_shared<CallAudioBridgeState>();
  auto create_audio_device_module =
      [audio_bridge](webrtc::TaskQueueFactory *task_queue_factory)
          -> webrtc::scoped_refptr<webrtc::AudioDeviceModule> {
    auto renderer = std::make_shared<QueueingRenderer>(audio_bridge);
    auto recorder = std::make_shared<SilenceRecorder>();

    tgcalls::FakeAudioDeviceModule::Options options;
    options.samples_per_sec = static_cast<uint32_t>(kAudioSampleRateHz);
    options.num_channels = 1;

    auto creator =
        tgcalls::FakeAudioDeviceModule::Creator(std::move(renderer), std::move(recorder), options);
    return creator(task_queue_factory);
  };

  tgcalls::GroupConfig config;
  config.need_log = false;

  tgcalls::GroupInstanceDescriptor descriptor;
  descriptor.threads = tgcalls::StaticThreads::getThreads();
  descriptor.config = config;
  descriptor.networkStateUpdated = [](tgcalls::GroupNetworkState) {};
  descriptor.signalBarsUpdated = [](int) {};
  descriptor.audioLevelsUpdated = [](const tgcalls::GroupLevelsUpdate &) {};
  descriptor.onAudioFrame = [audio_bridge](uint32_t, const tgcalls::AudioFrame &frame) {
    queue_audio_frame(audio_bridge, frame);
  };
  descriptor.ssrcActivityUpdated = [](const tgcalls::GroupActivitiesUpdate &) {};
  descriptor.useDummyChannel = true;
  descriptor.disableIncomingChannels = false;
  descriptor.createAudioDeviceModule = std::move(create_audio_device_module);
  descriptor.disableOutgoingAudioProcessing = true;
  descriptor.disableAudioInput = true;

  auto instance = std::make_unique<tgcalls::GroupInstanceCustomImpl>(std::move(descriptor));
  if (!instance) {
    error = "failed to create group call runtime";
    return false;
  }

  instance->setConnectionMode(tgcalls::GroupConnectionMode::GroupConnectionModeRtc, false, false);
  instance->emitJoinPayload([group_call_id, &pending_join_payloads](const tgcalls::GroupJoinPayload &payload) {
    PendingGroupJoinPayload entry;
    entry.group_call_id = group_call_id;
    entry.audio_source_id = payload.audioSsrc;
    entry.payload = payload.json;

    std::lock_guard<std::mutex> guard(pending_join_payloads.mutex);
    pending_join_payloads.queue.push_back(std::move(entry));
  });

  TgGroupCallRuntime runtime;
  runtime.session_id = session_id;
  runtime.audio_bridge = std::move(audio_bridge);
  runtime.instance = std::move(instance);
  runtimes[group_call_id] = std::move(runtime);

  return true;
}

void flush_pending_signaling(PendingCallSignalingQueue &pending_signaling,
                             const std::unordered_map<std::string, int> &session_to_client,
                             CallAudioSubscribers &subscribers,
                             int fd) {
  std::vector<PendingCallSignaling> batch;
  {
    std::lock_guard<std::mutex> guard(pending_signaling.mutex);
    if (pending_signaling.queue.empty()) {
      return;
    }
    batch.swap(pending_signaling.queue);
  }

  for (const auto &entry : batch) {
    const auto it = session_to_client.find(entry.session_id);
    if (it == session_to_client.end()) {
      broadcast_call_media_error(fd, subscribers, entry.call_id, "session for outgoing signaling is not initialized");
      continue;
    }

    const auto payload = base64_encode(entry.data.data(), entry.data.size());
    std::ostringstream request;
    request << "{\"@type\":\"sendCallSignalingData\",\"call_id\":" << entry.call_id
            << ",\"data\":\"" << payload << "\"}";
    td_send(it->second, request.str().c_str());
    broadcast_call_media_event(fd, subscribers, entry.call_id, "signaling_sent");
  }
}

void flush_pending_group_join_payloads(PendingGroupJoinPayloadQueue &pending_join_payloads,
                                       CallAudioSubscribers &subscribers,
                                       int fd) {
  std::vector<PendingGroupJoinPayload> batch;
  {
    std::lock_guard<std::mutex> guard(pending_join_payloads.mutex);
    if (pending_join_payloads.queue.empty()) {
      return;
    }
    batch.swap(pending_join_payloads.queue);
  }

  for (const auto &entry : batch) {
    const auto sub_it = subscribers.find(entry.group_call_id);
    if (sub_it == subscribers.end()) {
      continue;
    }

    for (const auto &pid : sub_it->second) {
      send_group_call_join_payload(fd, pid, entry.group_call_id, entry.audio_source_id, entry.payload);
    }
  }
}

uint16_t read_u16_le(const uint8_t *p) {
  return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
}

uint32_t read_u32_le(const uint8_t *p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

std::optional<std::vector<uint8_t>> read_file_bytes(const std::string &path) {
  std::ifstream input(path, std::ios::binary | std::ios::ate);
  if (!input.is_open()) {
    return std::nullopt;
  }

  const auto end = input.tellg();
  if (end <= 0) {
    return std::vector<uint8_t>{};
  }

  std::vector<uint8_t> bytes(static_cast<size_t>(end));
  input.seekg(0, std::ios::beg);
  if (!input.read(reinterpret_cast<char *>(bytes.data()), static_cast<std::streamsize>(bytes.size()))) {
    return std::nullopt;
  }

  return bytes;
}

bool parse_wav_pcm16_mono_48k(const std::vector<uint8_t> &wav, std::vector<uint8_t> &pcm,
                              std::string &error) {
  if (wav.size() < 44 || std::memcmp(wav.data(), "RIFF", 4) != 0 ||
      std::memcmp(wav.data() + 8, "WAVE", 4) != 0) {
    error = "unsupported wav header";
    return false;
  }

  bool found_fmt = false;
  bool found_data = false;
  uint16_t audio_format = 0;
  uint16_t channels = 0;
  uint16_t bits_per_sample = 0;
  uint32_t sample_rate = 0;
  size_t data_offset = 0;
  size_t data_size = 0;

  size_t pos = 12;
  while (pos + 8 <= wav.size()) {
    const uint8_t *chunk = wav.data() + pos;
    const uint32_t chunk_size = read_u32_le(chunk + 4);
    const size_t chunk_data_pos = pos + 8;
    const size_t chunk_end = chunk_data_pos + static_cast<size_t>(chunk_size);
    if (chunk_end > wav.size()) {
      error = "invalid wav chunk size";
      return false;
    }

    if (std::memcmp(chunk, "fmt ", 4) == 0 && chunk_size >= 16) {
      found_fmt = true;
      audio_format = read_u16_le(wav.data() + chunk_data_pos + 0);
      channels = read_u16_le(wav.data() + chunk_data_pos + 2);
      sample_rate = read_u32_le(wav.data() + chunk_data_pos + 4);
      bits_per_sample = read_u16_le(wav.data() + chunk_data_pos + 14);
    } else if (std::memcmp(chunk, "data", 4) == 0) {
      found_data = true;
      data_offset = chunk_data_pos;
      data_size = static_cast<size_t>(chunk_size);
    }

    pos = chunk_end + (chunk_size % 2);
  }

  if (!found_fmt || !found_data) {
    error = "missing wav fmt/data chunk";
    return false;
  }
  if (audio_format != 1 || channels != 1 || sample_rate != kAudioSampleRateHz || bits_per_sample != 16) {
    error = "wav must be PCM16 mono 48k";
    return false;
  }
  if (data_offset + data_size > wav.size()) {
    error = "invalid wav data bounds";
    return false;
  }

  pcm.assign(wav.begin() + static_cast<std::ptrdiff_t>(data_offset),
             wav.begin() + static_cast<std::ptrdiff_t>(data_offset + data_size));
  if (pcm.size() % 2 != 0) {
    pcm.pop_back();
  }
  if (pcm.empty()) {
    error = "wav payload empty";
    return false;
  }

  return true;
}

bool load_pcm_audio_file(const std::string &path, std::vector<uint8_t> &pcm, std::string &error) {
  const auto bytes = read_file_bytes(path);
  if (!bytes.has_value()) {
    error = "failed to read file";
    return false;
  }
  if (bytes->empty()) {
    error = "audio file empty";
    return false;
  }

  if (bytes->size() >= 12 && std::memcmp(bytes->data(), "RIFF", 4) == 0 &&
      std::memcmp(bytes->data() + 8, "WAVE", 4) == 0) {
    return parse_wav_pcm16_mono_48k(*bytes, pcm, error);
  }

  pcm = *bytes;
  if (pcm.size() % 2 != 0) {
    pcm.pop_back();
  }
  if (pcm.empty()) {
    error = "raw pcm payload empty";
    return false;
  }

  return true;
}

void process_pcm_playbacks(int fd,
                           CallAudioSubscribers &subscribers,
                           CallAudioPlaybacks &playbacks,
                           TgCallRuntimes &tgcalls_runtimes,
                           TgGroupCallRuntimes &tgcalls_group_runtimes) {
  for (auto it = playbacks.begin(); it != playbacks.end();) {
    const int64_t call_id = it->first;
    auto &playback = it->second;

    auto now = std::chrono::steady_clock::now();
    while (playback.offset < playback.pcm.size() && playback.next_emit <= now) {
      const size_t remaining = playback.pcm.size() - playback.offset;
      const size_t frame_size = std::min(kAudioFrameBytes, remaining);

      const auto runtime_it = tgcalls_runtimes.find(call_id);
      const bool private_runtime_active =
          runtime_it != tgcalls_runtimes.end() && runtime_it->second.instance;
      const auto group_runtime_it = tgcalls_group_runtimes.find(call_id);
      const bool group_runtime_active =
          group_runtime_it != tgcalls_group_runtimes.end() && group_runtime_it->second.instance;
      const bool runtime_active = private_runtime_active || group_runtime_active;
      const auto sub_it = subscribers.find(call_id);
      // Keep legacy local playback echo only when tgcalls runtime is absent.
      if (sub_it != subscribers.end() && !runtime_active) {
        const uint8_t *frame_data = playback.pcm.data() + playback.offset;
        for (const auto &pid : sub_it->second) {
          send_call_audio(fd, pid, call_id, frame_data, frame_size);
        }
      }

      if (private_runtime_active || group_runtime_active) {
        const uint8_t *frame_data = playback.pcm.data() + playback.offset;
        std::vector<uint8_t> samples(frame_data, frame_data + frame_size);
        if (private_runtime_active) {
          runtime_it->second.instance->addExternalAudioSamples(std::move(samples));
        } else {
          group_runtime_it->second.instance->addExternalAudioSamples(std::move(samples));
        }
      }

      playback.offset += frame_size;
      playback.next_emit += std::chrono::milliseconds(kAudioFrameMs);
      now = std::chrono::steady_clock::now();
    }

    if (playback.offset >= playback.pcm.size()) {
      const auto sub_it = subscribers.find(call_id);
      if (sub_it != subscribers.end()) {
        for (const auto &pid : sub_it->second) {
          send_call_media_event(fd, pid, call_id, "playback_finished");
        }
      }
      it = playbacks.erase(it);
    } else {
      ++it;
    }
  }
}

void flush_runtime_audio_bridge(int fd,
                                CallAudioSubscribers &subscribers,
                                int64_t call_id,
                                const std::shared_ptr<CallAudioBridgeState> &audio_bridge) {
  if (!audio_bridge) {
    return;
  }

  std::deque<std::vector<uint8_t>> queued;
  {
    std::lock_guard<std::mutex> guard(audio_bridge->mutex);
    if (audio_bridge->rendered_pcm_frames.empty()) {
      return;
    }
    queued.swap(audio_bridge->rendered_pcm_frames);
  }

  const auto sub_it = subscribers.find(call_id);
  if (sub_it == subscribers.end()) {
    return;
  }

  for (const auto &frame : queued) {
    if (frame.empty()) {
      continue;
    }
    for (const auto &pid : sub_it->second) {
      send_call_audio(fd, pid, call_id, frame.data(), frame.size());
    }
  }
}

void flush_tgcalls_rendered_audio(int fd,
                                  CallAudioSubscribers &subscribers,
                                  TgCallRuntimes &tgcalls_runtimes,
                                  TgGroupCallRuntimes &tgcalls_group_runtimes) {
  for (auto &entry : tgcalls_runtimes) {
    flush_runtime_audio_bridge(fd, subscribers, entry.first, entry.second.audio_bridge);
  }

  for (auto &entry : tgcalls_group_runtimes) {
    flush_runtime_audio_bridge(fd, subscribers, entry.first, entry.second.audio_bridge);
  }
}

void send_tgcalls_status(int fd, const erlang_pid &to) {
  const auto json = tgcalls_status_json();
  ei_x_buff xb;
  ei_x_new_with_version(&xb);

  ei_x_encode_tuple_header(&xb, 2);
  ei_x_encode_atom(&xb, "tgcalls_status");
  ei_x_encode_binary(&xb, json.data(), static_cast<int>(json.size()));

  // ei_send expects a non-const pointer.
  erlang_pid pid = to;
  (void)ei_send(fd, &pid, xb.buff, xb.index);

  ei_x_free(&xb);
}

void log_tgcalls_status() {
  std::cerr << "[tdlib_cnode] tgcalls core linked status=" << tgcalls_status_json() << "\n";
}

}  // namespace

int main(int argc, char **argv) {
  const Opts opts = parse_args(argc, argv);

#ifdef __linux__
  // Die when parent process exits — prevents orphaned cnodes that hold
  // stale epmd registrations and block new instances from starting.
  prctl(PR_SET_PDEATHSIG, SIGTERM);
  // Check if parent already died between fork and prctl
  if (getppid() == 1) {
    std::cerr << "[tdlib_cnode] parent already dead, exiting\n";
    return 1;
  }
#endif

  if (ei_init() != 0) {
    std::cerr << "ei_init failed\n";
    return 1;
  }

  log_tgcalls_status();

  td_set_verbosity(opts.verbosity);

  ei_cnode ec;
  // Important: ei_connect_init expects *alive name* (without "@host") for epmd
  // registration. Passing a full nodename would register the wrong epmd entry
  // and BEAM nodes won't be able to connect.
  std::string alive = alive_name_from_node(opts.node);
  if (ei_connect_init(&ec, alive.c_str(), opts.cookie.c_str(), 0) < 0) {
    std::cerr << "ei_connect_init failed (alive=" << alive << ")\n";
    return 1;
  }

  int port = 0;
  int lfd = ei_listen(&ec, &port, 5);
  if (lfd < 0) {
    std::cerr << "ei_listen failed\n";
    return 1;
  }

  if (ei_publish(&ec, port) < 0) {
    std::cerr << "ei_publish failed (is epmd running?)\n";
    return 1;
  }

  std::cerr << "[tdlib_cnode] up node=" << ei_thisnodename(&ec) << " server=" << opts.server
            << " port=" << port << "\n";

  std::unordered_map<std::string, int> session_to_client;
  std::unordered_map<int, erlang_pid> client_to_dest;
  CallAudioSubscribers call_audio_subscribers;
  CallAudioPlaybacks call_audio_playbacks;
  TgCallRuntimes tgcalls_runtimes;
  TgGroupCallRuntimes tgcalls_group_runtimes;
  PendingCallSignalingQueue pending_signaling;
  PendingGroupJoinPayloadQueue pending_group_join_payloads;

  for (;;) {
    ErlConnect con;
    int fd = ei_accept(&ec, lfd, &con);
    if (fd < 0) {
      std::this_thread::sleep_for(std::chrono::milliseconds(200));
      continue;
    }

    std::cerr << "[tdlib_cnode] accepted connection from " << con.nodename << "\n";

    ei_x_buff x;
    ei_x_new(&x);
    bool running = true;

    while (running) {
      // Receive 1 message (with timeout), then drain any TDLib output.
      erlang_msg msg;
      int r = ei_xreceive_msg_tmo(fd, &msg, &x, 50);

      if (r == ERL_ERROR) {
        // With timeouts, erl_interface may surface EAGAIN/EWOULDBLOCK here.
        // Treat that as "no message yet" instead of dropping the connection.
        if (errno == 0 || errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
          // no-op
        } else {
          std::cerr << "[tdlib_cnode] connection error, reconnecting (r=" << r << " errno=" << errno
                    << " " << std::strerror(errno) << ")\n";
          running = false;
        }
      } else if (r == ERL_MSG) {
        if (msg.msgtype == ERL_REG_SEND) {
          if (std::strcmp(msg.toname, opts.server.c_str()) != 0) {
            // Ignore messages not intended for our server name.
          } else {
            int idx = 0;
            int ver = 0;
            int arity = 0;
            if (ei_decode_version(x.buff, &idx, &ver) == 0 &&
                ei_decode_tuple_header(x.buff, &idx, &arity) == 0 && arity >= 1) {
              char tag[MAXATOMLEN_UTF8] = {0};
              if (ei_decode_atom(x.buff, &idx, tag) == 0) {
                if (std::strcmp(tag, "init") == 0 && arity == 2) {
                  // Backward compatibility with previous protocol:
                  // {:init, pid} initializes the "default" session.
                  const std::string session_id = "default";
                  erlang_pid pid;
                  if (ei_decode_pid(x.buff, &idx, &pid) == 0) {
                    int client_id = client_id_for_session(session_id, session_to_client);
                    client_to_dest[client_id] = pid;
                    std::cerr << "[tdlib_cnode] init session=" << session_id
                              << " client_id=" << client_id << "\n";
                  }
                } else if (std::strcmp(tag, "init") == 0 && arity == 3) {
                  std::string session_id = decode_binary(x.buff, &idx);
                  erlang_pid pid;
                  if (!session_id.empty() && ei_decode_pid(x.buff, &idx, &pid) == 0) {
                    int client_id = client_id_for_session(session_id, session_to_client);
                    client_to_dest[client_id] = pid;
                    std::cerr << "[tdlib_cnode] init session=" << session_id
                              << " client_id=" << client_id << "\n";
                  }
                } else if (std::strcmp(tag, "send") == 0 && arity == 2) {
                  // Backward compatibility with previous protocol:
                  // {:send, json} targets the "default" session.
                  std::string json = decode_binary(x.buff, &idx);
                  if (!json.empty()) {
                    const std::string session_id = "default";
                    int client_id = client_id_for_session(session_id, session_to_client);
                    td_send(client_id, json.c_str());
                  }
                } else if (std::strcmp(tag, "send") == 0 && arity == 3) {
                  std::string session_id = decode_binary(x.buff, &idx);
                  std::string json = decode_binary(x.buff, &idx);
                  if (!session_id.empty() && !json.empty()) {
                    int client_id = client_id_for_session(session_id, session_to_client);
                    // Don't overwrite client_to_dest here — the destination pid
                    // is set by {:init, session_id, pid} and should stay as the
                    // session process, not the Cnode GenServer that relays sends.
                    td_send(client_id, json.c_str());
                  }
                } else if (std::strcmp(tag, "stop_session") == 0 && arity == 2) {
                  std::string session_id = decode_binary(x.buff, &idx);
                  if (!session_id.empty()) {
                    auto it = session_to_client.find(session_id);
                    if (it != session_to_client.end()) {
                      td_send(it->second, "{\"@type\":\"close\"}");
                      client_to_dest.erase(it->second);
                      session_to_client.erase(it);
                    }

                    for (auto call_it = tgcalls_runtimes.begin();
                         call_it != tgcalls_runtimes.end();) {
                      if (call_it->second.session_id == session_id) {
                        if (call_it->second.instance) {
                          call_it->second.instance->stop([](tgcalls::FinalState) {});
                        }
                        call_audio_playbacks.erase(call_it->first);
                        call_audio_subscribers.erase(call_it->first);
                        call_it = tgcalls_runtimes.erase(call_it);
                      } else {
                        ++call_it;
                      }
                    }

                    for (auto group_it = tgcalls_group_runtimes.begin();
                         group_it != tgcalls_group_runtimes.end();) {
                      if (group_it->second.session_id == session_id) {
                        if (group_it->second.instance) {
                          group_it->second.instance->stop([] {});
                        }
                        call_audio_playbacks.erase(group_it->first);
                        call_audio_subscribers.erase(group_it->first);
                        group_it = tgcalls_group_runtimes.erase(group_it);
                      } else {
                        ++group_it;
                      }
                    }
                  }
                } else if (std::strcmp(tag, "tgcalls_status") == 0 && arity == 2) {
                  erlang_pid pid;
                  if (ei_decode_pid(x.buff, &idx, &pid) == 0) {
                    send_tgcalls_status(fd, pid);
                  }
                } else if ((std::strcmp(tag, "start_private_media") == 0 ||
                            std::strcmp(tag, "subscribe_call_audio") == 0) &&
                           arity == 3) {
                  auto call_id = decode_int64(x.buff, &idx);
                  erlang_pid pid;
                  if (call_id.has_value() && ei_decode_pid(x.buff, &idx, &pid) == 0) {
                    add_call_audio_subscriber(call_audio_subscribers, *call_id, pid);
                    send_call_media_event(fd, pid, *call_id, "subscribed");
                  }
                } else if (std::strcmp(tag, "unsubscribe_call_audio") == 0 && arity == 3) {
                  auto call_id = decode_int64(x.buff, &idx);
                  erlang_pid pid;
                  if (call_id.has_value() && ei_decode_pid(x.buff, &idx, &pid) == 0) {
                    remove_call_audio_subscriber(call_audio_subscribers, *call_id, pid);
                    send_call_media_event(fd, pid, *call_id, "unsubscribed");
                  }
                } else if (std::strcmp(tag, "start_tgcalls_call") == 0 && arity == 10) {
                  auto call_id = decode_int64(x.buff, &idx);
                  std::string session_id = decode_binary(x.buff, &idx);
                  std::string version = decode_binary(x.buff, &idx);
                  bool is_outgoing = false;
                  bool allow_p2p = false;
                  bool decoded_outgoing = decode_bool_atom(x.buff, &idx, is_outgoing);
                  bool decoded_p2p = decode_bool_atom(x.buff, &idx, allow_p2p);
                  std::string encryption_key = decode_binary(x.buff, &idx);
                  std::vector<ParsedRtcServer> rtc_servers;
                  bool decoded_servers = decode_rtc_server_list(x.buff, &idx, rtc_servers);
                  std::string custom_parameters = decode_binary(x.buff, &idx);
                  erlang_pid pid;
                  bool decoded_pid = (ei_decode_pid(x.buff, &idx, &pid) == 0);

                  if (call_id.has_value() && decoded_outgoing && decoded_p2p &&
                      decoded_servers && decoded_pid) {
                    add_call_audio_subscriber(call_audio_subscribers, *call_id, pid);
                    stop_tgcalls_runtime(tgcalls_runtimes, *call_id);
                    stop_tgcalls_group_runtime(tgcalls_group_runtimes, *call_id);

                    std::string error;
                    if (start_tgcalls_runtime(tgcalls_runtimes,
                                              pending_signaling,
                                              *call_id,
                                              session_id,
                                              version,
                                              is_outgoing,
                                              allow_p2p,
                                              encryption_key,
                                              rtc_servers,
                                              custom_parameters,
                                              error)) {
                      send_call_media_event(fd, pid, *call_id, "tgcalls_started");
                    } else {
                      send_call_media_error(fd, pid, *call_id, error);
                    }
                  }
                } else if (std::strcmp(tag, "stop_tgcalls_call") == 0 && arity == 2) {
                  auto call_id = decode_int64(x.buff, &idx);
                  if (call_id.has_value()) {
                    stop_tgcalls_runtime(tgcalls_runtimes, *call_id);
                    broadcast_call_media_event(fd, call_audio_subscribers, *call_id, "tgcalls_stopped");
                  }
                } else if (std::strcmp(tag, "start_tgcalls_group_call") == 0 && arity == 4) {
                  auto group_call_id = decode_int64(x.buff, &idx);
                  std::string session_id = decode_binary(x.buff, &idx);
                  erlang_pid pid;
                  bool decoded_pid = (ei_decode_pid(x.buff, &idx, &pid) == 0);

                  if (group_call_id.has_value() && decoded_pid) {
                    add_call_audio_subscriber(call_audio_subscribers, *group_call_id, pid);
                    stop_tgcalls_group_runtime(tgcalls_group_runtimes, *group_call_id);
                    stop_tgcalls_runtime(tgcalls_runtimes, *group_call_id);

                    std::string error;
                    if (start_tgcalls_group_runtime(tgcalls_group_runtimes,
                                                   pending_group_join_payloads,
                                                   *group_call_id,
                                                   session_id,
                                                   error)) {
                      send_call_media_event(fd, pid, *group_call_id, "tgcalls_group_started");
                    } else {
                      send_call_media_error(fd, pid, *group_call_id, error);
                    }
                  }
                } else if (std::strcmp(tag, "set_tgcalls_group_join_response") == 0 && arity == 3) {
                  auto group_call_id = decode_int64(x.buff, &idx);
                  std::string payload = decode_binary(x.buff, &idx);
                  if (group_call_id.has_value()) {
                    const auto group_it = tgcalls_group_runtimes.find(*group_call_id);
                    if (group_it == tgcalls_group_runtimes.end() || !group_it->second.instance) {
                      broadcast_call_media_error(
                          fd, call_audio_subscribers, *group_call_id, "group tgcalls runtime is not started");
                    } else {
                      group_it->second.instance->setJoinResponsePayload(payload);
                      broadcast_call_media_event(fd,
                                                 call_audio_subscribers,
                                                 *group_call_id,
                                                 "tgcalls_group_join_response_set");
                    }
                  }
                } else if (std::strcmp(tag, "stop_tgcalls_group_call") == 0 && arity == 2) {
                  auto group_call_id = decode_int64(x.buff, &idx);
                  if (group_call_id.has_value()) {
                    stop_tgcalls_group_runtime(tgcalls_group_runtimes, *group_call_id);
                    broadcast_call_media_event(fd, call_audio_subscribers, *group_call_id, "tgcalls_group_stopped");
                  }
                } else if (std::strcmp(tag, "receive_tgcalls_signaling_data") == 0 && arity == 3) {
                  auto call_id = decode_int64(x.buff, &idx);
                  std::string data = decode_binary(x.buff, &idx);
                  if (call_id.has_value()) {
                    const auto runtime_it = tgcalls_runtimes.find(*call_id);
                    if (runtime_it == tgcalls_runtimes.end() || !runtime_it->second.instance) {
                      broadcast_call_media_error(fd, call_audio_subscribers, *call_id, "tgcalls runtime is not started");
                    } else {
                      runtime_it->second.instance->receiveSignalingData(
                          std::vector<uint8_t>(data.begin(), data.end()));
                    }
                  }
                } else if (std::strcmp(tag, "stop_private_media") == 0 && arity == 2) {
                  auto call_id = decode_int64(x.buff, &idx);
                  if (call_id.has_value()) {
                    call_audio_playbacks.erase(*call_id);
                    stop_tgcalls_runtime(tgcalls_runtimes, *call_id);
                    stop_tgcalls_group_runtime(tgcalls_group_runtimes, *call_id);
                    broadcast_call_media_event(fd, call_audio_subscribers, *call_id, "stopped");
                    call_audio_subscribers.erase(*call_id);
                  }
                } else if (std::strcmp(tag, "feed_pcm_frame") == 0 && arity == 3) {
                  auto call_id = decode_int64(x.buff, &idx);
                  std::string frame = decode_binary(x.buff, &idx);
                  if (call_id.has_value() && !frame.empty()) {
                    if (frame.size() % 2 != 0) {
                      frame.pop_back();
                    }

                    if (frame.empty()) {
                      broadcast_call_media_error(
                          fd, call_audio_subscribers, *call_id, "pcm frame payload empty");
                      continue;
                    }

                    const auto runtime_it = tgcalls_runtimes.find(*call_id);
                    const bool private_runtime_active =
                        runtime_it != tgcalls_runtimes.end() && runtime_it->second.instance;
                    const auto group_runtime_it = tgcalls_group_runtimes.find(*call_id);
                    const bool group_runtime_active =
                        group_runtime_it != tgcalls_group_runtimes.end() && group_runtime_it->second.instance;
                    const bool runtime_active = private_runtime_active || group_runtime_active;
                    const auto sub_it = call_audio_subscribers.find(*call_id);

                    // Keep fallback local echo only when tgcalls runtime is absent.
                    if (sub_it != call_audio_subscribers.end() && !runtime_active) {
                      for (const auto &pid : sub_it->second) {
                        send_call_audio(fd, pid, *call_id, reinterpret_cast<const uint8_t *>(frame.data()),
                                        frame.size());
                      }
                    }

                    if (private_runtime_active || group_runtime_active) {
                      std::vector<uint8_t> samples(frame.begin(), frame.end());
                      if (private_runtime_active) {
                        runtime_it->second.instance->addExternalAudioSamples(std::move(samples));
                      } else {
                        group_runtime_it->second.instance->addExternalAudioSamples(std::move(samples));
                      }
                    }
                  }
                } else if (std::strcmp(tag, "feed_pcm_file") == 0 && arity == 3) {
                  auto call_id = decode_int64(x.buff, &idx);
                  std::string path = decode_binary(x.buff, &idx);
                  if (call_id.has_value() && !path.empty()) {
                    std::vector<uint8_t> pcm;
                    std::string error;
                    const auto sub_it = call_audio_subscribers.find(*call_id);
                    if (load_pcm_audio_file(path, pcm, error)) {
                      auto &playback = call_audio_playbacks[*call_id];
                      playback.pcm = std::move(pcm);
                      playback.offset = 0;
                      playback.next_emit = std::chrono::steady_clock::now();

                      if (sub_it != call_audio_subscribers.end()) {
                        for (const auto &pid : sub_it->second) {
                          send_call_media_event(fd, pid, *call_id, "playback_started");
                        }
                      }
                    } else if (sub_it != call_audio_subscribers.end()) {
                      for (const auto &pid : sub_it->second) {
                        send_call_media_error(fd, pid, *call_id, error);
                      }
                    }
                  }
                } else if (std::strcmp(tag, "stop") == 0) {
                  running = false;
                }
              }
            }
          }
        }
      }

      // Drain TDLib outputs without blocking.
      for (;;) {
        const char *out = td_receive(0.0);
        if (!out) break;

        std::string json(out);
        auto client_id = extract_client_id(json);
        if (!client_id) {
          continue;
        }

        auto it = client_to_dest.find(*client_id);
        if (it != client_to_dest.end()) {
          send_tdjson(fd, it->second, json);
        }
      }

      flush_pending_signaling(
          pending_signaling, session_to_client, call_audio_subscribers, fd);

      flush_pending_group_join_payloads(
          pending_group_join_payloads, call_audio_subscribers, fd);

      process_pcm_playbacks(
          fd, call_audio_subscribers, call_audio_playbacks, tgcalls_runtimes, tgcalls_group_runtimes);

      flush_tgcalls_rendered_audio(
          fd, call_audio_subscribers, tgcalls_runtimes, tgcalls_group_runtimes);
    }

    ei_x_free(&x);
    ei_close_connection(fd);
  }

  // Unreachable.
  return 0;
}
