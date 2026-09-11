#include "linphone_windows_bridge.h"

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <shellapi.h>

#include <atomic>
#include <algorithm>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <variant>

namespace {

#define VOIPCLOUD_STRINGIFY_VALUE(value) #value
#define VOIPCLOUD_STRINGIFY(value) VOIPCLOUD_STRINGIFY_VALUE(value)

constexpr UINT kLinphoneBridgeEventMessage = WM_APP + 0x5C1;
constexpr UINT kLinphoneIterateMessage = WM_APP + 0x5C2;
constexpr UINT kVoipCloudTrayIconId = 1;
constexpr wchar_t kVoipCloudRegistryPath[] =
    L"Software\\ThinkSwift\\VoipCloud";
constexpr wchar_t kDeviceDndRegistryValue[] = L"DeviceDndEnabled";
constexpr char kVoipCloudVersion[] =
    VOIPCLOUD_STRINGIFY(FLUTTER_VERSION_MAJOR) "."
    VOIPCLOUD_STRINGIFY(FLUTTER_VERSION_MINOR) "."
    VOIPCLOUD_STRINGIFY(FLUTTER_VERSION_PATCH);

bool LoadDeviceDndEnabled() {
  DWORD enabled = 0;
  DWORD size = sizeof(enabled);
  const LSTATUS status = RegGetValueW(
      HKEY_CURRENT_USER, kVoipCloudRegistryPath, kDeviceDndRegistryValue,
      RRF_RT_REG_DWORD, nullptr, &enabled, &size);
  return status == ERROR_SUCCESS && enabled != 0;
}

bool SaveDeviceDndEnabled(bool enabled) {
  HKEY key = nullptr;
  const LSTATUS create_status = RegCreateKeyExW(
      HKEY_CURRENT_USER, kVoipCloudRegistryPath, 0, nullptr,
      REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &key, nullptr);
  if (create_status != ERROR_SUCCESS || key == nullptr) {
    return false;
  }
  const DWORD value = enabled ? 1 : 0;
  const LSTATUS write_status = RegSetValueExW(
      key, kDeviceDndRegistryValue, 0, REG_DWORD,
      reinterpret_cast<const BYTE*>(&value), sizeof(value));
  RegCloseKey(key);
  return write_status == ERROR_SUCCESS;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return {};
  }
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) {
    return {};
  }
  std::wstring converted(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), converted.data(), length);
  return converted;
}

void TraceNative(const std::string& message) {
  wchar_t local_app_data[MAX_PATH] = {};
  const auto length = GetEnvironmentVariableW(
      L"LOCALAPPDATA", local_app_data, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return;
  }
  std::wstring trace_path(local_app_data, length);
  trace_path.append(L"\\ThinkSwift");
  CreateDirectoryW(trace_path.c_str(), nullptr);
  trace_path.append(L"\\VoipCloud");
  CreateDirectoryW(trace_path.c_str(), nullptr);
  trace_path.append(L"\\logs");
  CreateDirectoryW(trace_path.c_str(), nullptr);
  trace_path.append(L"\\voipcloud_linphone_trace.log");

  HANDLE file = CreateFileW(trace_path.c_str(), FILE_APPEND_DATA,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  SYSTEMTIME now{};
  GetLocalTime(&now);
  std::ostringstream timestamped;
  timestamped << now.wYear << '-' << now.wMonth << '-' << now.wDay << ' '
              << now.wHour << ':' << now.wMinute << ':' << now.wSecond << '.'
              << now.wMilliseconds << ' ' << message << "\r\n";
  const std::string line = timestamped.str();
  DWORD written = 0;
  WriteFile(file, line.data(), static_cast<DWORD>(line.size()), &written,
            nullptr);
  FlushFileBuffers(file);
  CloseHandle(file);
  OutputDebugStringA(line.c_str());
}

std::string ExecutableDirectoryUtf8() {
  wchar_t executable_path[MAX_PATH] = {};
  const auto length = GetModuleFileNameW(nullptr, executable_path, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return std::string();
  }

  std::wstring directory(executable_path, length);
  const auto separator = directory.find_last_of(L"\\/");
  if (separator == std::wstring::npos) {
    return std::string();
  }
  directory.resize(separator);

  const int utf8_length = WideCharToMultiByte(
      CP_UTF8, 0, directory.c_str(), static_cast<int>(directory.size()),
      nullptr, 0, nullptr, nullptr);
  if (utf8_length <= 0) {
    return std::string();
  }
  std::string utf8_directory(static_cast<size_t>(utf8_length), '\0');
  WideCharToMultiByte(CP_UTF8, 0, directory.c_str(),
                      static_cast<int>(directory.size()),
                      utf8_directory.data(), utf8_length, nullptr, nullptr);
  return utf8_directory;
}

using EncodableMap = flutter::EncodableMap;
using EncodableValue = flutter::EncodableValue;
using MethodCall = flutter::MethodCall<EncodableValue>;
using MethodResult = flutter::MethodResult<EncodableValue>;
using EventSink = flutter::EventSink<EncodableValue>;

struct LinphoneFactory;
struct LinphoneCore;
struct LinphoneCoreCbs;
struct LinphoneProxyConfig;
struct LinphoneAuthInfo;
struct LinphoneAddress;
struct LinphoneAccountParams;
struct LinphoneAccount;
struct LinphoneCallParams;
struct LinphoneCall;
struct LinphoneEvent;
struct LinphoneContent;
struct LinphoneErrorInfo;
struct LinphoneAudioDevice;
struct LinphoneCallStats;
struct LinphoneCallParams;
struct LinphonePayloadType;
struct BctbxList {
  BctbxList* next;
  BctbxList* previous;
  void* data;
};

using RegistrationCallback =
    void (*)(LinphoneCore*, LinphoneProxyConfig*, int, const char*);
using CallStateCallback =
    void (*)(LinphoneCore*, LinphoneCall*, int, const char*);
using NotifyReceivedCallback =
    void (*)(LinphoneCore*, LinphoneEvent*, const char*, const LinphoneContent*);
using SubscriptionStateCallback =
    void (*)(LinphoneCore*, LinphoneEvent*, int);

std::string PointerId(const void* value) {
  std::ostringstream stream;
  stream << "win-" << reinterpret_cast<std::uintptr_t>(value);
  return stream.str();
}

std::string StringArg(const EncodableMap& args, const char* key) {
  const auto found = args.find(EncodableValue(std::string(key)));
  if (found == args.end()) {
    return std::string();
  }
  if (const auto* value = std::get_if<std::string>(&found->second)) {
    return *value;
  }
  return std::string();
}

bool BoolArg(const EncodableMap& args, const char* key) {
  const auto found = args.find(EncodableValue(std::string(key)));
  if (found == args.end()) {
    return false;
  }
  if (const auto* value = std::get_if<bool>(&found->second)) {
    return *value;
  }
  return false;
}

std::vector<std::string> StringListArg(const EncodableMap& args,
                                       const char* key) {
  std::vector<std::string> values;
  const auto found = args.find(EncodableValue(std::string(key)));
  if (found == args.end()) {
    return values;
  }
  const auto* list = std::get_if<flutter::EncodableList>(&found->second);
  if (list == nullptr) {
    return values;
  }
  for (const auto& item : *list) {
    if (const auto* value = std::get_if<std::string>(&item)) {
      values.push_back(*value);
    }
  }
  return values;
}

std::string SubscriptionStateName(int state) {
  switch (state) {
    case 0:
      return "none";
    case 1:
      return "incoming";
    case 2:
      return "progress";
    case 3:
      return "pending";
    case 4:
      return "active";
    case 5:
      return "terminated";
    case 6:
      return "error";
    default:
      return "unknown";
  }
}

const EncodableMap& ArgsMap(const MethodCall& call) {
  static const EncodableMap kEmpty;
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  return args == nullptr ? kEmpty : *args;
}

std::string NormalizeSipAddress(const std::string& value) {
  if (value.rfind("sip:", 0) == 0 || value.rfind("sips:", 0) == 0) {
    return value;
  }
  return "sip:" + value;
}

std::string NormalizeDestination(const std::string& destination,
                                 const std::string& domain) {
  if (destination.rfind("sip:", 0) == 0 ||
      destination.rfind("sips:", 0) == 0) {
    return destination;
  }
  if (destination.find('@') != std::string::npos) {
    return "sip:" + destination;
  }
  return "sip:" + destination + "@" + domain;
}

int TransportType(const std::string& value) {
  if (value == "tls" || value == "TLS") {
    return 2;
  }
  if (value == "tcp" || value == "TCP") {
    return 1;
  }
  return 0;
}

std::string RegistrationStatus(int state) {
  switch (state) {
    case 1:
      return "registering";
    case 2:
      return "registered";
    case 3:
      return "unregistered";
    case 4:
      return "failed";
    default:
      return "unregistered";
  }
}

std::string CallStatus(int state) {
  switch (state) {
    case 1:
    case 2:
    case 17:
      return "ringing";
    case 3:
    case 4:
    case 5:
    case 6:
      return "dialing";
    case 7:
    case 8:
      return "active";
    case 9:
    case 10:
    case 15:
      return "held";
    case 13:
      return "failed";
    case 14:
    case 19:
      return "ended";
    default:
      return "connecting";
  }
}

class StreamHandler : public flutter::StreamHandler<EncodableValue> {
 public:
  explicit StreamHandler(std::unique_ptr<EventSink>* sink) : sink_(sink) {}

 protected:
  std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> OnListenInternal(
      const EncodableValue* arguments,
      std::unique_ptr<EventSink>&& events) override {
    *sink_ = std::move(events);
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> OnCancelInternal(
      const EncodableValue* arguments) override {
    sink_->reset();
    return nullptr;
  }

 private:
  std::unique_ptr<EventSink>* sink_;
};

class LinphoneApi {
 public:
  ~LinphoneApi() {
    if (module_ != nullptr) {
      FreeLibrary(module_);
    }
  }

  bool Load() {
    TraceNative("LinphoneApi.Load enter");
    if (module_ != nullptr) {
      TraceNative("LinphoneApi.Load already loaded");
      return true;
    }

    module_ = LoadLibraryW(L"linphone.dll");
    if (module_ == nullptr) {
      module_ = LoadLibraryW(L"liblinphone.dll");
    }
    if (module_ == nullptr) {
      wchar_t configured_path[MAX_PATH] = {};
      const auto length = GetEnvironmentVariableW(
          L"LINPHONE_WINDOWS_DLL", configured_path, MAX_PATH);
      if (length > 0 && length < MAX_PATH) {
        module_ = LoadLibraryW(configured_path);
      }
    }
    if (module_ == nullptr) {
      TraceNative("LinphoneApi.Load DLL not found");
      return false;
    }
    TraceNative("LinphoneApi.Load DLL loaded");

    linphone_factory_get = LoadSymbol<LinphoneFactory* (*)()>(
        "linphone_factory_get");
    linphone_factory_set_top_resources_dir =
        LoadSymbol<void (*)(LinphoneFactory*, const char*)>(
            "linphone_factory_set_top_resources_dir");
    linphone_factory_create_core_3 =
        LoadSymbol<LinphoneCore* (*)(LinphoneFactory*, const char*, const char*,
                                     void*)>(
            "linphone_factory_create_core_3");
    linphone_core_start = LoadSymbol<int (*)(LinphoneCore*)>(
        "linphone_core_start");
    linphone_core_set_user_agent =
        LoadSymbol<void (*)(LinphoneCore*, const char*, const char*)>(
            "linphone_core_set_user_agent");
    linphone_core_set_root_ca =
        LoadSymbol<void (*)(LinphoneCore*, const char*)>(
            "linphone_core_set_root_ca");
    linphone_core_stop = LoadSymbol<void (*)(LinphoneCore*)>(
        "linphone_core_stop");
    linphone_core_unref = LoadSymbol<void (*)(LinphoneCore*)>(
        "linphone_core_unref");
    linphone_core_iterate = LoadSymbol<void (*)(LinphoneCore*)>(
        "linphone_core_iterate");
    linphone_factory_create_core_cbs =
        LoadSymbol<LinphoneCoreCbs* (*)(LinphoneFactory*)>(
            "linphone_factory_create_core_cbs");
    linphone_core_cbs_set_registration_state_changed =
        LoadSymbol<void (*)(LinphoneCoreCbs*, RegistrationCallback)>(
            "linphone_core_cbs_set_registration_state_changed");
    linphone_core_cbs_set_call_state_changed =
        LoadSymbol<void (*)(LinphoneCoreCbs*, CallStateCallback)>(
            "linphone_core_cbs_set_call_state_changed");
    linphone_core_cbs_set_notify_received =
        LoadSymbol<void (*)(LinphoneCoreCbs*, NotifyReceivedCallback)>(
            "linphone_core_cbs_set_notify_received");
    linphone_core_cbs_set_subscription_state_changed =
        LoadSymbol<void (*)(LinphoneCoreCbs*, SubscriptionStateCallback)>(
            "linphone_core_cbs_set_subscription_state_changed");
    linphone_core_add_callbacks =
        LoadSymbol<void (*)(LinphoneCore*, LinphoneCoreCbs*)>(
            "linphone_core_add_callbacks");
    linphone_auth_info_new =
        LoadSymbol<LinphoneAuthInfo* (*)(const char*, const char*, const char*,
                                         const char*, const char*,
                                         const char*)>(
            "linphone_auth_info_new");
    linphone_auth_info_new_for_algorithm =
        LoadSymbol<LinphoneAuthInfo* (*)(const char*, const char*, const char*,
                                         const char*, const char*, const char*,
                                         const char*)>(
            "linphone_auth_info_new_for_algorithm");
    linphone_core_add_auth_info =
        LoadSymbol<void (*)(LinphoneCore*, LinphoneAuthInfo*)>(
            "linphone_core_add_auth_info");
    linphone_core_clear_all_auth_info =
        LoadSymbol<void (*)(LinphoneCore*)>("linphone_core_clear_all_auth_info");
    linphone_core_clear_accounts =
        LoadSymbol<void (*)(LinphoneCore*)>("linphone_core_clear_accounts");
    linphone_factory_create_address =
        LoadSymbol<LinphoneAddress* (*)(LinphoneFactory*, const char*)>(
            "linphone_factory_create_address");
    linphone_address_set_transport =
        LoadSymbol<void (*)(LinphoneAddress*, int)>(
            "linphone_address_set_transport");
    linphone_address_set_display_name =
        LoadSymbol<int (*)(LinphoneAddress*, const char*)>(
            "linphone_address_set_display_name");
    linphone_address_as_string_uri_only =
        LoadSymbol<char* (*)(const LinphoneAddress*)>(
            "linphone_address_as_string_uri_only");
    linphone_address_get_display_name =
        LoadSymbol<const char* (*)(const LinphoneAddress*)>(
            "linphone_address_get_display_name");
    linphone_address_get_username =
        LoadSymbol<const char* (*)(const LinphoneAddress*)>(
            "linphone_address_get_username");
    linphone_address_unref = LoadSymbol<void (*)(LinphoneAddress*)>(
        "linphone_address_unref");
    linphone_core_create_account_params =
        LoadSymbol<LinphoneAccountParams* (*)(LinphoneCore*)>(
            "linphone_core_create_account_params");
    linphone_account_params_set_identity_address =
        LoadSymbol<int (*)(LinphoneAccountParams*, const LinphoneAddress*)>(
            "linphone_account_params_set_identity_address");
    linphone_account_params_set_server_address =
        LoadSymbol<int (*)(LinphoneAccountParams*, const LinphoneAddress*)>(
            "linphone_account_params_set_server_address");
    linphone_account_params_enable_register =
        LoadSymbol<void (*)(LinphoneAccountParams*, int)>(
            "linphone_account_params_enable_register");
    linphone_account_params_enable_outbound_proxy =
        LoadSymbol<void (*)(LinphoneAccountParams*, int)>(
            "linphone_account_params_enable_outbound_proxy");
    linphone_account_params_unref =
        LoadSymbol<void (*)(LinphoneAccountParams*)>(
            "linphone_account_params_unref");
    linphone_core_create_account =
        LoadSymbol<LinphoneAccount* (*)(LinphoneCore*, LinphoneAccountParams*)>(
            "linphone_core_create_account");
    linphone_core_add_account =
        LoadSymbol<int (*)(LinphoneCore*, LinphoneAccount*)>(
            "linphone_core_add_account");
    linphone_core_set_default_account =
        LoadSymbol<void (*)(LinphoneCore*, LinphoneAccount*)>(
            "linphone_core_set_default_account");
    linphone_account_get_params =
        LoadSymbol<const LinphoneAccountParams* (*)(LinphoneAccount*)>(
            "linphone_account_get_params");
    linphone_account_params_clone =
        LoadSymbol<LinphoneAccountParams* (*)(const LinphoneAccountParams*)>(
            "linphone_account_params_clone");
    linphone_account_set_params =
        LoadSymbol<int (*)(LinphoneAccount*, LinphoneAccountParams*)>(
            "linphone_account_set_params");
    linphone_account_refresh_register =
        LoadSymbol<void (*)(LinphoneAccount*)>(
            "linphone_account_refresh_register");
    linphone_account_get_error_info =
        LoadSymbol<const LinphoneErrorInfo* (*)(LinphoneAccount*)>(
            "linphone_account_get_error_info");
    linphone_error_info_get_reason =
        LoadSymbol<int (*)(const LinphoneErrorInfo*)>(
            "linphone_error_info_get_reason");
    linphone_error_info_get_protocol_code =
        LoadSymbol<int (*)(const LinphoneErrorInfo*)>(
            "linphone_error_info_get_protocol_code");
    linphone_error_info_get_phrase =
        LoadSymbol<const char* (*)(const LinphoneErrorInfo*)>(
            "linphone_error_info_get_phrase");
    linphone_core_refresh_registers =
        LoadSymbol<void (*)(LinphoneCore*)>("linphone_core_refresh_registers");
    linphone_core_create_subscribe =
        LoadSymbol<LinphoneEvent* (*)(LinphoneCore*, const LinphoneAddress*,
                                      const char*, int)>(
            "linphone_core_create_subscribe");
    linphone_event_add_custom_header =
        LoadSymbol<void (*)(LinphoneEvent*, const char*, const char*)>(
            "linphone_event_add_custom_header");
    linphone_event_send_subscribe =
        LoadSymbol<int (*)(LinphoneEvent*, const LinphoneContent*)>(
            "linphone_event_send_subscribe");
    linphone_event_terminate = LoadSymbol<void (*)(LinphoneEvent*)>(
        "linphone_event_terminate");
    linphone_event_unref = LoadSymbol<void (*)(LinphoneEvent*)>(
        "linphone_event_unref");
    linphone_content_get_utf8_text =
        LoadSymbol<const char* (*)(const LinphoneContent*)>(
            "linphone_content_get_utf8_text");
    linphone_content_get_type =
        LoadSymbol<const char* (*)(const LinphoneContent*)>(
            "linphone_content_get_type");
    linphone_content_get_subtype =
        LoadSymbol<const char* (*)(const LinphoneContent*)>(
            "linphone_content_get_subtype");
    linphone_core_create_call_params =
        LoadSymbol<LinphoneCallParams* (*)(LinphoneCore*, LinphoneCall*)>(
            "linphone_core_create_call_params");
    linphone_call_params_enable_video =
        LoadSymbol<void (*)(LinphoneCallParams*, int)>(
            "linphone_call_params_enable_video");
    linphone_call_params_unref = LoadSymbol<void (*)(LinphoneCallParams*)>(
        "linphone_call_params_unref");
    linphone_core_invite_address_with_params =
        LoadSymbol<LinphoneCall* (*)(LinphoneCore*, const LinphoneAddress*,
                                     const LinphoneCallParams*)>(
            "linphone_core_invite_address_with_params");
    linphone_core_invite_address =
        LoadSymbol<LinphoneCall* (*)(LinphoneCore*, const LinphoneAddress*)>(
            "linphone_core_invite_address");
    linphone_core_get_current_call =
        LoadSymbol<LinphoneCall* (*)(LinphoneCore*)>(
            "linphone_core_get_current_call");
    linphone_call_accept = LoadSymbol<int (*)(LinphoneCall*)>(
        "linphone_call_accept");
    linphone_call_decline = LoadSymbol<int (*)(LinphoneCall*, int)>(
        "linphone_call_decline");
    linphone_call_terminate = LoadSymbol<int (*)(LinphoneCall*)>(
        "linphone_call_terminate");
    linphone_call_pause = LoadSymbol<int (*)(LinphoneCall*)>(
        "linphone_call_pause");
    linphone_call_resume = LoadSymbol<int (*)(LinphoneCall*)>(
        "linphone_call_resume");
    linphone_call_send_dtmf = LoadSymbol<int (*)(LinphoneCall*, char)>(
        "linphone_call_send_dtmf");
    linphone_call_get_remote_address =
        LoadSymbol<const LinphoneAddress* (*)(const LinphoneCall*)>(
            "linphone_call_get_remote_address");
    linphone_call_get_state =
        LoadSymbol<int (*)(const LinphoneCall*)>("linphone_call_get_state");
    linphone_call_get_dir = LoadSymbol<int (*)(const LinphoneCall*)>(
        "linphone_call_get_dir");
    linphone_core_set_mic_enabled = LoadSymbol<void (*)(LinphoneCore*, int)>(
        "linphone_core_set_mic_enabled");
    linphone_core_enable_mic = LoadSymbol<void (*)(LinphoneCore*, int)>(
        "linphone_core_enable_mic");
    linphone_core_get_sound_devices =
        LoadSymbol<const char* const* (*)(LinphoneCore*)>(
            "linphone_core_get_sound_devices");
    linphone_core_get_playback_device =
        LoadSymbol<const char* (*)(LinphoneCore*)>(
            "linphone_core_get_playback_device");
    linphone_core_set_playback_device =
        LoadSymbol<int (*)(LinphoneCore*, const char*)>(
            "linphone_core_set_playback_device");
    linphone_core_set_capture_device =
        LoadSymbol<int (*)(LinphoneCore*, const char*)>(
            "linphone_core_set_capture_device");
    linphone_core_sound_device_can_capture =
        LoadSymbol<int (*)(LinphoneCore*, const char*)>(
            "linphone_core_sound_device_can_capture");
    linphone_core_get_extended_audio_devices =
        LoadSymbol<BctbxList* (*)(const LinphoneCore*)>(
            "linphone_core_get_extended_audio_devices");
    linphone_core_get_output_audio_device =
        LoadSymbol<const LinphoneAudioDevice* (*)(const LinphoneCore*)>(
            "linphone_core_get_output_audio_device");
    linphone_core_set_output_audio_device =
        LoadSymbol<void (*)(LinphoneCore*, LinphoneAudioDevice*)>(
            "linphone_core_set_output_audio_device");
    linphone_core_set_input_audio_device =
        LoadSymbol<void (*)(LinphoneCore*, LinphoneAudioDevice*)>(
            "linphone_core_set_input_audio_device");
    linphone_audio_device_get_id =
        LoadSymbol<const char* (*)(const LinphoneAudioDevice*)>(
            "linphone_audio_device_get_id");
    linphone_audio_device_get_device_name =
        LoadSymbol<const char* (*)(const LinphoneAudioDevice*)>(
            "linphone_audio_device_get_device_name");
    linphone_audio_device_get_capabilities =
        LoadSymbol<int (*)(const LinphoneAudioDevice*)>(
            "linphone_audio_device_get_capabilities");
    linphone_audio_device_get_type =
        LoadSymbol<int (*)(const LinphoneAudioDevice*)>(
            "linphone_audio_device_get_type");
    linphone_call_set_output_audio_device =
        LoadSymbol<void (*)(LinphoneCall*, LinphoneAudioDevice*)>(
            "linphone_call_set_output_audio_device");
    linphone_call_set_input_audio_device =
        LoadSymbol<void (*)(LinphoneCall*, LinphoneAudioDevice*)>(
            "linphone_call_set_input_audio_device");
    linphone_call_get_current_quality =
        LoadSymbol<float (*)(const LinphoneCall*)>(
            "linphone_call_get_current_quality");
    linphone_call_get_average_quality =
        LoadSymbol<float (*)(const LinphoneCall*)>(
            "linphone_call_get_average_quality");
    linphone_call_get_duration = LoadSymbol<int (*)(const LinphoneCall*)>(
        "linphone_call_get_duration");
    linphone_call_get_audio_stats =
        LoadSymbol<LinphoneCallStats* (*)(LinphoneCall*)>(
            "linphone_call_get_audio_stats");
    linphone_call_stats_get_round_trip_delay =
        LoadSymbol<float (*)(const LinphoneCallStats*)>(
            "linphone_call_stats_get_round_trip_delay");
    linphone_call_stats_get_jitter_buffer_size_ms =
        LoadSymbol<float (*)(const LinphoneCallStats*)>(
            "linphone_call_stats_get_jitter_buffer_size_ms");
    linphone_call_stats_get_receiver_loss_rate =
        LoadSymbol<float (*)(const LinphoneCallStats*)>(
            "linphone_call_stats_get_receiver_loss_rate");
    linphone_call_stats_get_sender_loss_rate =
        LoadSymbol<float (*)(const LinphoneCallStats*)>(
            "linphone_call_stats_get_sender_loss_rate");
    linphone_call_stats_get_local_loss_rate =
        LoadSymbol<float (*)(const LinphoneCallStats*)>(
            "linphone_call_stats_get_local_loss_rate");
    linphone_call_stats_get_download_bandwidth =
        LoadSymbol<float (*)(const LinphoneCallStats*)>(
            "linphone_call_stats_get_download_bandwidth");
    linphone_call_stats_get_upload_bandwidth =
        LoadSymbol<float (*)(const LinphoneCallStats*)>(
            "linphone_call_stats_get_upload_bandwidth");
    linphone_call_stats_unref = LoadSymbol<void (*)(LinphoneCallStats*)>(
        "linphone_call_stats_unref");
    bctbx_free = LoadSymbol<void (*)(void*)>("bctbx_free");
    bctbx_list_free = LoadSymbol<void (*)(BctbxList*)>("bctbx_list_free");
    if (bctbx_list_free == nullptr) {
      const auto bctoolbox = GetModuleHandleW(L"bctoolbox.dll");
      if (bctoolbox != nullptr) {
        bctbx_list_free = reinterpret_cast<void (*)(BctbxList*)>(
            GetProcAddress(bctoolbox, "bctbx_list_free"));
      }
    }

    const bool required_symbols_loaded = linphone_factory_get != nullptr &&
           linphone_factory_set_top_resources_dir != nullptr &&
           linphone_factory_create_core_3 != nullptr &&
           linphone_core_start != nullptr && linphone_core_stop != nullptr &&
           linphone_core_unref != nullptr &&
           linphone_factory_create_address != nullptr &&
           linphone_auth_info_new != nullptr &&
           linphone_core_create_account_params != nullptr &&
           linphone_core_create_account != nullptr &&
           linphone_core_add_account != nullptr;
    TraceNative(required_symbols_loaded
                    ? "LinphoneApi.Load required symbols loaded"
                    : "LinphoneApi.Load required symbol missing");
    return required_symbols_loaded;
  }

  std::string CopyString(char* value) const {
    if (value == nullptr) {
      return std::string();
    }
    std::string copied(value);
    if (bctbx_free != nullptr) {
      bctbx_free(value);
    }
    return copied;
  }

  LinphoneFactory* (*linphone_factory_get)() = nullptr;
  void (*linphone_factory_set_top_resources_dir)(LinphoneFactory*,
                                                  const char*) = nullptr;
  LinphoneCore* (*linphone_factory_create_core_3)(
      LinphoneFactory*, const char*, const char*, void*) = nullptr;
  int (*linphone_core_start)(LinphoneCore*) = nullptr;
  void (*linphone_core_set_user_agent)(LinphoneCore*, const char*,
                                        const char*) = nullptr;
  void (*linphone_core_set_root_ca)(LinphoneCore*, const char*) = nullptr;
  void (*linphone_core_stop)(LinphoneCore*) = nullptr;
  void (*linphone_core_unref)(LinphoneCore*) = nullptr;
  void (*linphone_core_iterate)(LinphoneCore*) = nullptr;
  LinphoneCoreCbs* (*linphone_factory_create_core_cbs)(LinphoneFactory*) =
      nullptr;
  void (*linphone_core_cbs_set_registration_state_changed)(
      LinphoneCoreCbs*, RegistrationCallback) = nullptr;
  void (*linphone_core_cbs_set_call_state_changed)(LinphoneCoreCbs*,
                                                   CallStateCallback) = nullptr;
  void (*linphone_core_cbs_set_notify_received)(LinphoneCoreCbs*,
                                                NotifyReceivedCallback) =
      nullptr;
  void (*linphone_core_cbs_set_subscription_state_changed)(
      LinphoneCoreCbs*, SubscriptionStateCallback) = nullptr;
  void (*linphone_core_add_callbacks)(LinphoneCore*, LinphoneCoreCbs*) =
      nullptr;
  LinphoneAuthInfo* (*linphone_auth_info_new)(
      const char*, const char*, const char*, const char*, const char*,
      const char*) = nullptr;
  LinphoneAuthInfo* (*linphone_auth_info_new_for_algorithm)(
      const char*, const char*, const char*, const char*, const char*,
      const char*, const char*) = nullptr;
  void (*linphone_core_add_auth_info)(LinphoneCore*, LinphoneAuthInfo*) =
      nullptr;
  void (*linphone_core_clear_all_auth_info)(LinphoneCore*) = nullptr;
  void (*linphone_core_clear_accounts)(LinphoneCore*) = nullptr;
  LinphoneAddress* (*linphone_factory_create_address)(LinphoneFactory*,
                                                      const char*) = nullptr;
  void (*linphone_address_set_transport)(LinphoneAddress*, int) = nullptr;
  int (*linphone_address_set_display_name)(LinphoneAddress*, const char*) =
      nullptr;
  char* (*linphone_address_as_string_uri_only)(const LinphoneAddress*) =
      nullptr;
  const char* (*linphone_address_get_display_name)(const LinphoneAddress*) =
      nullptr;
  const char* (*linphone_address_get_username)(const LinphoneAddress*) =
      nullptr;
  void (*linphone_address_unref)(LinphoneAddress*) = nullptr;
  LinphoneAccountParams* (*linphone_core_create_account_params)(
      LinphoneCore*) = nullptr;
  int (*linphone_account_params_set_identity_address)(
      LinphoneAccountParams*, const LinphoneAddress*) = nullptr;
  int (*linphone_account_params_set_server_address)(
      LinphoneAccountParams*, const LinphoneAddress*) = nullptr;
  void (*linphone_account_params_enable_register)(LinphoneAccountParams*, int) =
      nullptr;
  void (*linphone_account_params_enable_outbound_proxy)(
      LinphoneAccountParams*, int) = nullptr;
  void (*linphone_account_params_unref)(LinphoneAccountParams*) = nullptr;
  LinphoneAccount* (*linphone_core_create_account)(LinphoneCore*,
                                                   LinphoneAccountParams*) =
      nullptr;
  int (*linphone_core_add_account)(LinphoneCore*, LinphoneAccount*) = nullptr;
  void (*linphone_core_set_default_account)(LinphoneCore*, LinphoneAccount*) =
      nullptr;
  const LinphoneAccountParams* (*linphone_account_get_params)(
      LinphoneAccount*) = nullptr;
  LinphoneAccountParams* (*linphone_account_params_clone)(
      const LinphoneAccountParams*) = nullptr;
  int (*linphone_account_set_params)(LinphoneAccount*, LinphoneAccountParams*) =
      nullptr;
  void (*linphone_account_refresh_register)(LinphoneAccount*) = nullptr;
  const LinphoneErrorInfo* (*linphone_account_get_error_info)(
      LinphoneAccount*) = nullptr;
  int (*linphone_error_info_get_reason)(const LinphoneErrorInfo*) = nullptr;
  int (*linphone_error_info_get_protocol_code)(const LinphoneErrorInfo*) =
      nullptr;
  const char* (*linphone_error_info_get_phrase)(const LinphoneErrorInfo*) =
      nullptr;
  void (*linphone_core_refresh_registers)(LinphoneCore*) = nullptr;
  LinphoneEvent* (*linphone_core_create_subscribe)(
      LinphoneCore*, const LinphoneAddress*, const char*, int) = nullptr;
  void (*linphone_event_add_custom_header)(LinphoneEvent*, const char*,
                                           const char*) = nullptr;
  int (*linphone_event_send_subscribe)(LinphoneEvent*,
                                       const LinphoneContent*) = nullptr;
  void (*linphone_event_terminate)(LinphoneEvent*) = nullptr;
  void (*linphone_event_unref)(LinphoneEvent*) = nullptr;
  const char* (*linphone_content_get_utf8_text)(const LinphoneContent*) =
      nullptr;
  const char* (*linphone_content_get_type)(const LinphoneContent*) = nullptr;
  const char* (*linphone_content_get_subtype)(const LinphoneContent*) = nullptr;
  LinphoneCallParams* (*linphone_core_create_call_params)(LinphoneCore*,
                                                          LinphoneCall*) =
      nullptr;
  void (*linphone_call_params_enable_video)(LinphoneCallParams*, int) = nullptr;
  void (*linphone_call_params_unref)(LinphoneCallParams*) = nullptr;
  LinphoneCall* (*linphone_core_invite_address_with_params)(
      LinphoneCore*, const LinphoneAddress*, const LinphoneCallParams*) =
      nullptr;
  LinphoneCall* (*linphone_core_invite_address)(LinphoneCore*,
                                                const LinphoneAddress*) =
      nullptr;
  LinphoneCall* (*linphone_core_get_current_call)(LinphoneCore*) = nullptr;
  int (*linphone_call_accept)(LinphoneCall*) = nullptr;
  int (*linphone_call_decline)(LinphoneCall*, int) = nullptr;
  int (*linphone_call_terminate)(LinphoneCall*) = nullptr;
  int (*linphone_call_pause)(LinphoneCall*) = nullptr;
  int (*linphone_call_resume)(LinphoneCall*) = nullptr;
  int (*linphone_call_send_dtmf)(LinphoneCall*, char) = nullptr;
  const LinphoneAddress* (*linphone_call_get_remote_address)(
      const LinphoneCall*) = nullptr;
  int (*linphone_call_get_state)(const LinphoneCall*) = nullptr;
  int (*linphone_call_get_dir)(const LinphoneCall*) = nullptr;
  void (*linphone_core_set_mic_enabled)(LinphoneCore*, int) = nullptr;
  void (*linphone_core_enable_mic)(LinphoneCore*, int) = nullptr;
  const char* const* (*linphone_core_get_sound_devices)(LinphoneCore*) = nullptr;
  const char* (*linphone_core_get_playback_device)(LinphoneCore*) = nullptr;
  int (*linphone_core_set_playback_device)(LinphoneCore*, const char*) = nullptr;
  int (*linphone_core_set_capture_device)(LinphoneCore*, const char*) = nullptr;
  int (*linphone_core_sound_device_can_capture)(LinphoneCore*, const char*) =
      nullptr;
  BctbxList* (*linphone_core_get_extended_audio_devices)(
      const LinphoneCore*) = nullptr;
  const LinphoneAudioDevice* (*linphone_core_get_output_audio_device)(
      const LinphoneCore*) = nullptr;
  void (*linphone_core_set_output_audio_device)(LinphoneCore*,
                                                 LinphoneAudioDevice*) = nullptr;
  void (*linphone_core_set_input_audio_device)(LinphoneCore*,
                                                LinphoneAudioDevice*) = nullptr;
  const char* (*linphone_audio_device_get_id)(const LinphoneAudioDevice*) =
      nullptr;
  const char* (*linphone_audio_device_get_device_name)(
      const LinphoneAudioDevice*) = nullptr;
  int (*linphone_audio_device_get_capabilities)(const LinphoneAudioDevice*) =
      nullptr;
  int (*linphone_audio_device_get_type)(const LinphoneAudioDevice*) = nullptr;
  void (*linphone_call_set_output_audio_device)(LinphoneCall*,
                                                 LinphoneAudioDevice*) = nullptr;
  void (*linphone_call_set_input_audio_device)(LinphoneCall*,
                                                LinphoneAudioDevice*) = nullptr;
  float (*linphone_call_get_current_quality)(const LinphoneCall*) = nullptr;
  float (*linphone_call_get_average_quality)(const LinphoneCall*) = nullptr;
  int (*linphone_call_get_duration)(const LinphoneCall*) = nullptr;
  LinphoneCallStats* (*linphone_call_get_audio_stats)(LinphoneCall*) = nullptr;
  float (*linphone_call_stats_get_round_trip_delay)(
      const LinphoneCallStats*) = nullptr;
  float (*linphone_call_stats_get_jitter_buffer_size_ms)(
      const LinphoneCallStats*) = nullptr;
  float (*linphone_call_stats_get_receiver_loss_rate)(
      const LinphoneCallStats*) = nullptr;
  float (*linphone_call_stats_get_sender_loss_rate)(
      const LinphoneCallStats*) = nullptr;
  float (*linphone_call_stats_get_local_loss_rate)(
      const LinphoneCallStats*) = nullptr;
  float (*linphone_call_stats_get_download_bandwidth)(
      const LinphoneCallStats*) = nullptr;
  float (*linphone_call_stats_get_upload_bandwidth)(
      const LinphoneCallStats*) = nullptr;
  void (*linphone_call_stats_unref)(LinphoneCallStats*) = nullptr;
  void (*bctbx_free)(void*) = nullptr;
  void (*bctbx_list_free)(BctbxList*) = nullptr;

 private:
  template <typename T>
  T LoadSymbol(const char* name) {
    return reinterpret_cast<T>(GetProcAddress(module_, name));
  }

  HMODULE module_ = nullptr;
};

}  // namespace

class LinphoneWindowsBridge::Impl {
 public:
  Impl(flutter::BinaryMessenger* messenger, LinphoneWindowsBridge* owner)
      : owner_(owner), device_dnd_enabled_(LoadDeviceDndEnabled()) {
    auto codec = &flutter::StandardMethodCodec::GetInstance();

    method_channel_ =
        std::make_unique<flutter::MethodChannel<EncodableValue>>(
            messenger, "voipcloud/linphone", codec);
    method_channel_->SetMethodCallHandler(
        [this](const MethodCall& call,
               std::unique_ptr<MethodResult> result) {
          HandleMethodCall(call, std::move(result));
        });

    registration_channel_ =
        std::make_unique<flutter::EventChannel<EncodableValue>>(
            messenger, "voipcloud/linphone/registration", codec);
    registration_channel_->SetStreamHandler(
        std::make_unique<StreamHandler>(&registration_sink_));

    call_channel_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
        messenger, "voipcloud/linphone/calls", codec);
    call_channel_->SetStreamHandler(std::make_unique<StreamHandler>(&call_sink_));

    message_channel_ =
        std::make_unique<flutter::EventChannel<EncodableValue>>(
            messenger, "voipcloud/linphone/messages", codec);
    message_channel_->SetStreamHandler(
        std::make_unique<StreamHandler>(&message_sink_));

    presence_channel_ =
        std::make_unique<flutter::EventChannel<EncodableValue>>(
            messenger, "voipcloud/linphone/presence", codec);
    presence_channel_->SetStreamHandler(
        std::make_unique<StreamHandler>(&presence_sink_));
  }

  ~Impl() { Dispose(); }

  void SendEvent(const std::string& stream, const EncodableMap& payload) {
    if (stream == "registration" && registration_sink_) {
      registration_sink_->Success(EncodableValue(payload));
    } else if (stream == "calls" && call_sink_) {
      call_sink_->Success(EncodableValue(payload));
    } else if (stream == "messages" && message_sink_) {
      message_sink_->Success(EncodableValue(payload));
    } else if (stream == "presence" && presence_sink_) {
      presence_sink_->Success(EncodableValue(payload));
    }
  }

  void Iterate() {
    std::lock_guard<std::mutex> lock(core_mutex_);
    if (core_ != nullptr && api_.linphone_core_iterate != nullptr) {
      const bool trace_this_iteration = !first_iterate_completed_;
      if (trace_this_iteration) {
        TraceNative("Linphone iterate first call begin");
      }
      api_.linphone_core_iterate(core_);
      if (trace_this_iteration) {
        first_iterate_completed_ = true;
        TraceNative("Linphone iterate first call complete");
      }
    }
  }

 private:
  static Impl* active_impl_;

  void HandleMethodCall(const MethodCall& call,
                        std::unique_ptr<MethodResult> result) {
    const auto& method = call.method_name();
    TraceNative("Method " + method);
    if (method == "initialize") {
      Initialize(std::move(result));
    } else if (method == "configureAccount") {
      ConfigureAccount(ArgsMap(call), std::move(result));
    } else if (method == "register") {
      UpdateRegistration(true, std::move(result));
    } else if (method == "syncCurrentCall") {
      SyncCurrentCall(std::move(result));
    } else if (method == "hasActiveCall") {
      HasActiveCall(std::move(result));
    } else if (method == "setNativeDnd") {
      SetNativeDnd(BoolArg(ArgsMap(call), "enabled"), std::move(result));
    } else if (method == "enterBackground" || method == "enterForeground") {
      result->Success();
    } else if (method == "unregister") {
      UpdateRegistration(false, std::move(result));
    } else if (method == "purgeAccount") {
      PurgeAccount(std::move(result));
    } else if (method == "makeCall") {
      MakeCall(StringArg(ArgsMap(call), "destination"), std::move(result));
    } else if (method == "acceptCall") {
      AcceptCall(std::move(result));
    } else if (method == "rejectCall") {
      DeclineCall(std::move(result));
    } else if (method == "endCall") {
      WithCall(&LinphoneApi::linphone_call_terminate, std::move(result));
    } else if (method == "hold") {
      WithCall(&LinphoneApi::linphone_call_pause, std::move(result));
    } else if (method == "resume") {
      WithCall(&LinphoneApi::linphone_call_resume, std::move(result));
    } else if (method == "mute") {
      SetMuted(BoolArg(ArgsMap(call), "enabled"), std::move(result));
    } else if (method == "setSpeaker" || method == "setBluetooth") {
      const bool enabled = BoolArg(ArgsMap(call), "enabled");
      const std::string route = method == "setBluetooth"
                                    ? (enabled ? "bluetooth" : "speaker")
                                    : (enabled ? "speaker" : "streaming");
      SetAudioRoute(route,
                    std::string(), std::move(result));
    } else if (method == "ensureBluetoothPermission") {
      result->Success(EncodableValue(true));
    } else if (method == "getAudioRoutes") {
      GetAudioRoutes(std::move(result));
    } else if (method == "getCallQuality") {
      GetCallQuality(std::move(result));
    } else if (method == "setAudioRoute") {
      SetAudioRoute(StringArg(ArgsMap(call), "route"),
                    StringArg(ArgsMap(call), "endpointId"),
                    std::move(result));
    } else if (method == "sendDtmf") {
      SendDtmf(StringArg(ArgsMap(call), "value"), std::move(result));
    } else if (method == "sendMessage") {
      result->Error("LINPHONE_UNSUPPORTED",
                    "Windows SIP messaging is not implemented yet.");
    } else if (method == "startPresenceSubscriptions") {
      StartPresenceSubscriptions(
          StringListArg(ArgsMap(call), "extensions"), std::move(result));
    } else if (method == "stopPresenceSubscriptions") {
      StopPresenceSubscriptions();
      result->Success();
    } else if (method == "dispose") {
      Dispose();
      result->Success();
    } else {
      result->NotImplemented();
    }
  }

  bool EnsureReady(MethodResult* result) {
    TraceNative("EnsureReady enter");
    if (!api_.Load()) {
      result->Error("LINPHONE_NOT_LINKED",
                    "Windows liblinphone DLL was not found. Put linphone.dll "
                    "or liblinphone.dll beside ThinkSwift.exe, add it to PATH, "
                    "or set LINPHONE_WINDOWS_DLL.");
      return false;
    }
    if (core_ == nullptr) {
      TraceNative("EnsureReady factory get begin");
      LinphoneFactory* factory = api_.linphone_factory_get();
      TraceNative(factory != nullptr ? "EnsureReady factory get complete"
                                     : "EnsureReady factory is null");
      if (factory == nullptr) {
        result->Error("LINPHONE_ERROR", "Unable to obtain Linphone factory.");
        return false;
      }
      const std::string resources_directory = ExecutableDirectoryUtf8();
      if (resources_directory.empty()) {
        result->Error("LINPHONE_ERROR",
                      "Unable to locate Linphone runtime resources.");
        return false;
      }
      TraceNative("EnsureReady set resources directory begin");
      api_.linphone_factory_set_top_resources_dir(
          factory, resources_directory.c_str());
      TraceNative("EnsureReady set resources directory complete");
      TraceNative("EnsureReady create core begin");
      core_ = api_.linphone_factory_create_core_3(factory, nullptr, nullptr,
                                                  nullptr);
      TraceNative(core_ != nullptr ? "EnsureReady create core complete"
                                   : "EnsureReady create core returned null");
      if (core_ == nullptr) {
        result->Error("LINPHONE_ERROR", "Unable to create Linphone core.");
        return false;
      }
      if (api_.linphone_core_set_user_agent != nullptr) {
        api_.linphone_core_set_user_agent(core_, "VoIPCloud-Windows",
                                          kVoipCloudVersion);
        TraceNative("EnsureReady desktop user agent configured");
      }
      if (api_.linphone_core_set_root_ca != nullptr) {
        const std::string root_ca_path =
            resources_directory + "\\share\\linphone\\rootca.pem";
        TraceNative("EnsureReady set root CA begin");
        api_.linphone_core_set_root_ca(core_, root_ca_path.c_str());
        TraceNative("EnsureReady set root CA complete");
      }
      active_impl_ = this;
      if (api_.linphone_factory_create_core_cbs != nullptr &&
          api_.linphone_core_cbs_set_registration_state_changed != nullptr &&
          api_.linphone_core_cbs_set_call_state_changed != nullptr &&
          api_.linphone_core_add_callbacks != nullptr) {
        TraceNative("EnsureReady create callbacks begin");
        callbacks_ = api_.linphone_factory_create_core_cbs(factory);
        TraceNative(callbacks_ != nullptr
                        ? "EnsureReady create callbacks complete"
                        : "EnsureReady create callbacks returned null");
        if (callbacks_ == nullptr) {
          result->Error("LINPHONE_ERROR", "Unable to create Linphone callbacks.");
          return false;
        }
        api_.linphone_core_cbs_set_registration_state_changed(
            callbacks_, &Impl::OnRegistrationChanged);
        api_.linphone_core_cbs_set_call_state_changed(callbacks_,
                                                      &Impl::OnCallChanged);
        if (api_.linphone_core_cbs_set_notify_received != nullptr) {
          api_.linphone_core_cbs_set_notify_received(callbacks_,
                                                      &Impl::OnNotifyReceived);
        }
        if (api_.linphone_core_cbs_set_subscription_state_changed != nullptr) {
          api_.linphone_core_cbs_set_subscription_state_changed(
              callbacks_, &Impl::OnSubscriptionStateChanged);
        }
        TraceNative("EnsureReady add callbacks begin");
        api_.linphone_core_add_callbacks(core_, callbacks_);
        TraceNative("EnsureReady add callbacks complete");
      }
      TraceNative("EnsureReady core start begin");
      if (api_.linphone_core_start(core_) != 0) {
        result->Error("LINPHONE_ERROR", "Unable to start Linphone core.");
        return false;
      }
      TraceNative("EnsureReady core start complete");
      StartIterateLoop();
      TraceNative("EnsureReady iterate scheduling started");
      owner_->EnqueueEvent(
          "registration",
          EncodableMap{{EncodableValue("status"),
                        EncodableValue(std::string("unregistered"))},
                       {EncodableValue("message"), EncodableValue()}});
    }
    TraceNative("EnsureReady complete");
    return true;
  }

  void Initialize(std::unique_ptr<MethodResult> result) {
    std::lock_guard<std::mutex> lock(core_mutex_);
    if (!EnsureReady(result.get())) {
      return;
    }
    result->Success();
  }

  void ConfigureAccount(const EncodableMap& args,
                        std::unique_ptr<MethodResult> result) {
    TraceNative("ConfigureAccount enter");
    std::lock_guard<std::mutex> lock(core_mutex_);
    if (!EnsureReady(result.get())) {
      return;
    }

    sip_domain_ = StringArg(args, "domain");
    const auto username = StringArg(args, "sipUsername");
    const auto auth_username_arg = StringArg(args, "authUsername");
    const auto auth_username =
        auth_username_arg.empty() ? username : auth_username_arg;
    const auto password = StringArg(args, "password");
    const auto ha1 = StringArg(args, "ha1");
    const auto algorithm = StringArg(args, "algorithm");
    const auto realm_arg = StringArg(args, "realm");
    const auto realm = realm_arg.empty() ? sip_domain_ : realm_arg;
    const auto auth_domain_arg = StringArg(args, "authDomain");
    const auto auth_domain =
        auth_domain_arg.empty() ? realm : auth_domain_arg;
    const auto registrar_arg = StringArg(args, "registrar");
    const auto registrar = registrar_arg.empty() ? sip_domain_ : registrar_arg;
    const auto outbound_proxy = StringArg(args, "outboundProxy");
    const auto display_name = StringArg(args, "displayName");
    const auto transport = TransportType(StringArg(args, "transport"));

    StopPresenceSubscriptionsLocked();

    if (username.empty() || sip_domain_.empty() || registrar.empty()) {
      result->Error("LINPHONE_ERROR", "SIP account is missing username/domain.");
      return;
    }

    if (api_.linphone_core_clear_accounts != nullptr) {
      TraceNative("ConfigureAccount clear accounts begin");
      api_.linphone_core_clear_accounts(core_);
      TraceNative("ConfigureAccount clear accounts complete");
    }
    if (api_.linphone_core_clear_all_auth_info != nullptr) {
      TraceNative("ConfigureAccount clear auth begin");
      api_.linphone_core_clear_all_auth_info(core_);
      TraceNative("ConfigureAccount clear auth complete");
    }

    TraceNative("ConfigureAccount create auth begin");
    LinphoneAuthInfo* auth_info = nullptr;
    if (!algorithm.empty() &&
        api_.linphone_auth_info_new_for_algorithm != nullptr) {
      auth_info = api_.linphone_auth_info_new_for_algorithm(
          auth_username.c_str(), username.c_str(),
          password.empty() ? nullptr : password.c_str(),
          ha1.empty() ? nullptr : ha1.c_str(), realm.c_str(),
          auth_domain.c_str(), algorithm.c_str());
    } else {
      auth_info = api_.linphone_auth_info_new(
          auth_username.c_str(), username.c_str(),
          password.empty() ? nullptr : password.c_str(),
          ha1.empty() ? nullptr : ha1.c_str(), realm.c_str(),
          auth_domain.c_str());
    }
    TraceNative(auth_info != nullptr ? "ConfigureAccount create auth complete"
                                     : "ConfigureAccount create auth returned null");
    if (auth_info != nullptr && api_.linphone_core_add_auth_info != nullptr) {
      TraceNative("ConfigureAccount add auth begin");
      api_.linphone_core_add_auth_info(core_, auth_info);
      TraceNative("ConfigureAccount add auth complete");
    }

    const auto identity_uri = "sip:" + username + "@" + sip_domain_;
    TraceNative("ConfigureAccount identity address begin");
    LinphoneAddress* identity =
        api_.linphone_factory_create_address(api_.linphone_factory_get(),
                                             identity_uri.c_str());
    TraceNative(identity != nullptr
                    ? "ConfigureAccount identity address complete"
                    : "ConfigureAccount identity address returned null");
    if (identity == nullptr) {
      result->Error("LINPHONE_ERROR", "SIP identity address is invalid.");
      return;
    }
    if (!display_name.empty() && api_.linphone_address_set_display_name) {
      api_.linphone_address_set_display_name(identity, display_name.c_str());
    }
    const auto server_uri =
        NormalizeSipAddress(outbound_proxy.empty() ? registrar : outbound_proxy);
    TraceNative("ConfigureAccount server address begin");
    LinphoneAddress* server =
        api_.linphone_factory_create_address(api_.linphone_factory_get(),
                                             server_uri.c_str());
    TraceNative(server != nullptr
                    ? "ConfigureAccount server address complete"
                    : "ConfigureAccount server address returned null");
    if (server == nullptr) {
      if (api_.linphone_address_unref != nullptr) {
        api_.linphone_address_unref(identity);
      }
      result->Error("LINPHONE_ERROR", "SIP registrar address is invalid.");
      return;
    }
    if (api_.linphone_address_set_transport != nullptr) {
      api_.linphone_address_set_transport(server, transport);
    }

    TraceNative("ConfigureAccount create params begin");
    LinphoneAccountParams* params =
        api_.linphone_core_create_account_params(core_);
    TraceNative(params != nullptr ? "ConfigureAccount create params complete"
                                  : "ConfigureAccount create params returned null");
    if (params == nullptr) {
      if (api_.linphone_address_unref != nullptr) {
        api_.linphone_address_unref(identity);
        api_.linphone_address_unref(server);
      }
      result->Error("LINPHONE_ERROR", "Unable to create SIP account parameters.");
      return;
    }
    if (api_.linphone_account_params_set_identity_address != nullptr) {
      api_.linphone_account_params_set_identity_address(params, identity);
    }
    if (api_.linphone_account_params_set_server_address != nullptr) {
      api_.linphone_account_params_set_server_address(params, server);
    }
    if (api_.linphone_account_params_enable_outbound_proxy != nullptr) {
      api_.linphone_account_params_enable_outbound_proxy(
          params, outbound_proxy.empty() ? 0 : 1);
    }
    if (api_.linphone_account_params_enable_register != nullptr) {
      api_.linphone_account_params_enable_register(params, 1);
    }

    TraceNative("ConfigureAccount create account begin");
    account_ = api_.linphone_core_create_account(core_, params);
    TraceNative(account_ != nullptr ? "ConfigureAccount create account complete"
                                    : "ConfigureAccount create account returned null");
    if (account_ == nullptr) {
      result->Error("LINPHONE_ERROR", "Unable to create SIP account.");
      return;
    }
    TraceNative("ConfigureAccount add account begin");
    api_.linphone_core_add_account(core_, account_);
    TraceNative("ConfigureAccount add account complete");
    if (api_.linphone_core_set_default_account != nullptr) {
      api_.linphone_core_set_default_account(core_, account_);
    }
    if (api_.linphone_address_unref != nullptr) {
      api_.linphone_address_unref(identity);
      api_.linphone_address_unref(server);
    }
    if (api_.linphone_account_params_unref != nullptr) {
      api_.linphone_account_params_unref(params);
    }

    owner_->EnqueueEvent(
        "registration",
        EncodableMap{{EncodableValue("status"),
                      EncodableValue(std::string("configuring"))},
                     {EncodableValue("message"),
                      EncodableValue(std::string("SIP account configured"))}});
    result->Success();
    TraceNative("ConfigureAccount complete");
  }

  void UpdateRegistration(bool enabled, std::unique_ptr<MethodResult> result) {
    std::lock_guard<std::mutex> lock(core_mutex_);
    if (!EnsureReady(result.get())) {
      return;
    }
    if (!enabled) {
      StopPresenceSubscriptionsLocked();
    }
    if (account_ != nullptr && api_.linphone_account_get_params != nullptr &&
        api_.linphone_account_params_clone != nullptr &&
        api_.linphone_account_set_params != nullptr &&
        api_.linphone_account_params_enable_register != nullptr) {
      const auto* current_params = api_.linphone_account_get_params(account_);
      LinphoneAccountParams* params =
          api_.linphone_account_params_clone(current_params);
      api_.linphone_account_params_enable_register(params, enabled ? 1 : 0);
      api_.linphone_account_set_params(account_, params);
      if (api_.linphone_account_params_unref != nullptr) {
        api_.linphone_account_params_unref(params);
      }
      if (api_.linphone_account_refresh_register != nullptr) {
        api_.linphone_account_refresh_register(account_);
      }
    } else if (api_.linphone_core_refresh_registers != nullptr) {
      api_.linphone_core_refresh_registers(core_);
    }
    result->Success();
  }

  void HasActiveCall(std::unique_ptr<MethodResult> result) {
    std::lock_guard<std::mutex> lock(core_mutex_);
    result->Success(EncodableValue(core_ != nullptr && CurrentCall() != nullptr));
  }

  void SyncCurrentCall(std::unique_ptr<MethodResult> result) {
    std::lock_guard<std::mutex> lock(core_mutex_);
    if (!EnsureReady(result.get())) {
      return;
    }
    LinphoneCall* call = CurrentCall();
    if (call == nullptr) {
      active_call_ = nullptr;
      EncodableMap payload{{EncodableValue("status"),
                            EncodableValue(std::string("none"))}};
      result->Success(EncodableValue(payload));
    } else {
      const int state = api_.linphone_call_get_state != nullptr
                            ? api_.linphone_call_get_state(call)
                            : 0;
      auto payload = BuildCallPayload(call, state);
      result->Success(EncodableValue(payload));
    }
  }

  void SetNativeDnd(bool enabled, std::unique_ptr<MethodResult> result) {
    std::lock_guard<std::mutex> lock(core_mutex_);
    if (!SaveDeviceDndEnabled(enabled)) {
      result->Error("DND_PERSISTENCE_ERROR",
                    "Unable to persist the device DND setting.");
      return;
    }
    device_dnd_enabled_ = enabled;
    if (enabled) {
      LinphoneCall* call = CurrentCall();
      const int state = call != nullptr && api_.linphone_call_get_state != nullptr
                            ? api_.linphone_call_get_state(call)
                            : -1;
      const bool incoming =
          call != nullptr && api_.linphone_call_get_dir != nullptr &&
          api_.linphone_call_get_dir(call) == 1;
      if (incoming && CallStatus(state) == "ringing" &&
          api_.linphone_call_decline != nullptr) {
        dnd_declined_incoming_call_ = call;
        api_.linphone_call_decline(call, 3);
        notified_incoming_call_ = nullptr;
        owner_->ClearIncomingCallNotification();
      }
    }
    result->Success();
  }

  void AcceptCall(std::unique_ptr<MethodResult> result) {
    std::lock_guard<std::mutex> lock(core_mutex_);
    if (!EnsureReady(result.get())) {
      return;
    }
    LinphoneCall* call = CurrentCall();
    const int state = call != nullptr && api_.linphone_call_get_state != nullptr
                          ? api_.linphone_call_get_state(call)
                          : -1;
    if (call == nullptr || (state != 1 && state != 2 && state != 17)) {
      result->Error("CALL_ENDED", "This incoming call has already ended.");
      return;
    }
    if (api_.linphone_call_accept == nullptr ||
        api_.linphone_call_accept(call) != 0) {
      result->Error("LINPHONE_ERROR", "Unable to accept incoming call.");
      return;
    }
    result->Success();
  }

  void MakeCall(const std::string& destination,
                std::unique_ptr<MethodResult> result) {
    TraceNative("Outgoing call request received");
    std::lock_guard<std::mutex> lock(core_mutex_);
    if (!EnsureReady(result.get())) {
      return;
    }
    if (destination.empty()) {
      result->Error("LINPHONE_ERROR", "Missing call destination.");
      return;
    }
    const auto uri = NormalizeDestination(destination, sip_domain_);
    LinphoneAddress* address =
        api_.linphone_factory_create_address(api_.linphone_factory_get(),
                                             uri.c_str());
    if (address == nullptr) {
      result->Error("LINPHONE_ERROR", "Invalid call destination.");
      return;
    }
    LinphoneCallParams* params = nullptr;
    if (api_.linphone_core_create_call_params != nullptr) {
      params = api_.linphone_core_create_call_params(core_, nullptr);
      if (params != nullptr && api_.linphone_call_params_enable_video != nullptr) {
        api_.linphone_call_params_enable_video(params, 0);
      }
    }
    LinphoneCall* call = nullptr;
    if (params != nullptr &&
        api_.linphone_core_invite_address_with_params != nullptr) {
      call = api_.linphone_core_invite_address_with_params(core_, address,
                                                           params);
    }
    if (call == nullptr && api_.linphone_core_invite_address != nullptr) {
      call = api_.linphone_core_invite_address(core_, address);
    }
    if (api_.linphone_call_params_unref != nullptr && params != nullptr) {
      api_.linphone_call_params_unref(params);
    }
    if (api_.linphone_address_unref != nullptr) {
      api_.linphone_address_unref(address);
    }
    if (call == nullptr) {
      result->Error("LINPHONE_ERROR", "Unable to start call.");
      return;
    }
    active_call_ = call;
    EmitCall(call, 3);
    TraceNative("Outgoing call accepted by Linphone id=" + PointerId(call));
    result->Success();
  }

  void WithCall(int (*LinphoneApi::*operation)(LinphoneCall*),
                std::unique_ptr<MethodResult> result) {
    std::lock_guard<std::mutex> lock(core_mutex_);
    if (!EnsureReady(result.get())) {
      return;
    }
    LinphoneCall* call = CurrentCall();
    auto function = api_.*operation;
    if (call != nullptr && function != nullptr) {
      function(call);
    }
    result->Success();
  }

  void DeclineCall(std::unique_ptr<MethodResult> result) {
    std::lock_guard<std::mutex> lock(core_mutex_);
    if (!EnsureReady(result.get())) {
      return;
    }
    LinphoneCall* call = CurrentCall();
    if (call != nullptr && api_.linphone_call_decline != nullptr) {
      api_.linphone_call_decline(call, 3);
    }
    result->Success();
  }

  void SetMuted(bool enabled, std::unique_ptr<MethodResult> result) {
    std::lock_guard<std::mutex> lock(core_mutex_);
    if (!EnsureReady(result.get())) {
      return;
    }
    if (api_.linphone_core_set_mic_enabled != nullptr) {
      api_.linphone_core_set_mic_enabled(core_, enabled ? 0 : 1);
    } else if (api_.linphone_core_enable_mic != nullptr) {
      api_.linphone_core_enable_mic(core_, enabled ? 0 : 1);
    }
    result->Success();
  }

  static std::string AudioRouteForDevice(const std::string& device) {
    std::string normalized = device;
    std::transform(normalized.begin(), normalized.end(), normalized.begin(),
                   [](unsigned char value) {
                     return static_cast<char>(std::tolower(value));
                   });
    if (normalized.find("bluetooth") != std::string::npos ||
        normalized.find("airpods") != std::string::npos) {
      return "bluetooth";
    }
    if (normalized.find("headphone") != std::string::npos ||
        normalized.find("headset") != std::string::npos ||
        normalized.find("usb") != std::string::npos) {
      return "wired";
    }
    if (normalized.find("speaker") != std::string::npos) {
      return "speaker";
    }
    return "streaming";
  }

  static std::string AudioRouteForType(int type,
                                       const std::string& fallback_name) {
    switch (type) {
      case 2:  // Earpiece
      case 6:  // Telephony
        return "earpiece";
      case 3:  // Speaker
        return "speaker";
      case 4:   // Bluetooth
      case 5:   // Bluetooth A2DP
      case 11:  // Hearing aid
        return "bluetooth";
      case 8:   // Generic USB
      case 9:   // Headset
      case 10:  // Headphones
        return "wired";
      default:
        return AudioRouteForDevice(fallback_name);
    }
  }

  struct AudioEndpoint {
    LinphoneAudioDevice* device = nullptr;
    std::string id;
    std::string label;
    std::string route;
    int capabilities = 0;
    bool selected = false;
  };

  std::vector<AudioEndpoint> ModernAudioEndpoints() const {
    std::vector<AudioEndpoint> endpoints;
    if (core_ == nullptr ||
        api_.linphone_core_get_extended_audio_devices == nullptr ||
        api_.linphone_audio_device_get_id == nullptr ||
        api_.linphone_audio_device_get_device_name == nullptr ||
        api_.linphone_audio_device_get_capabilities == nullptr) {
      return endpoints;
    }
    const LinphoneAudioDevice* active =
        api_.linphone_core_get_output_audio_device == nullptr
            ? nullptr
            : api_.linphone_core_get_output_audio_device(core_);
    BctbxList* devices =
        api_.linphone_core_get_extended_audio_devices(core_);
    for (auto* item = devices; item != nullptr; item = item->next) {
      auto* device = static_cast<LinphoneAudioDevice*>(item->data);
      if (device == nullptr) {
        continue;
      }
      const int capabilities =
          api_.linphone_audio_device_get_capabilities(device);
      constexpr int kCanPlay = 1 << 1;
      if ((capabilities & kCanPlay) == 0) {
        continue;
      }
      const char* raw_id = api_.linphone_audio_device_get_id(device);
      const char* raw_name =
          api_.linphone_audio_device_get_device_name(device);
      std::string id = raw_id == nullptr ? "" : raw_id;
      std::string label = raw_name == nullptr ? id : raw_name;
      if (id.empty()) {
        id = label;
      }
      if (id.empty()) {
        continue;
      }
      const int type = api_.linphone_audio_device_get_type == nullptr
                           ? 0
                           : api_.linphone_audio_device_get_type(device);
      endpoints.push_back(AudioEndpoint{
          device,
          id,
          label.empty() ? id : label,
          AudioRouteForType(type, label),
          capabilities,
          active == device,
      });
    }
    if (devices != nullptr && api_.bctbx_list_free != nullptr) {
      api_.bctbx_list_free(devices);
    }
    return endpoints;
  }

  std::vector<std::string> AudioDevices() const {
    std::vector<std::string> devices;
    if (core_ == nullptr || api_.linphone_core_get_sound_devices == nullptr) {
      return devices;
    }
    const char* const* values = api_.linphone_core_get_sound_devices(core_);
    if (values == nullptr) {
      return devices;
    }
    for (size_t index = 0; index < 64 && values[index] != nullptr; ++index) {
      const std::string device(values[index]);
      if (!device.empty() &&
          std::find(devices.begin(), devices.end(), device) == devices.end()) {
        devices.push_back(device);
      }
    }
    return devices;
  }

  flutter::EncodableList AudioEndpointPayload() const {
    flutter::EncodableList payload;
    const auto modern = ModernAudioEndpoints();
    if (!modern.empty()) {
      for (const auto& endpoint : modern) {
        payload.emplace_back(EncodableMap{
            {EncodableValue("id"),
             EncodableValue("windows:" + endpoint.id)},
            {EncodableValue("route"), EncodableValue(endpoint.route)},
            {EncodableValue("label"), EncodableValue(endpoint.label)},
            {EncodableValue("available"), EncodableValue(true)},
            {EncodableValue("selected"), EncodableValue(endpoint.selected)},
        });
      }
      return payload;
    }
    const char* active_value =
        api_.linphone_core_get_playback_device == nullptr
            ? nullptr
            : api_.linphone_core_get_playback_device(core_);
    const std::string active = active_value == nullptr ? "" : active_value;
    for (const auto& device : AudioDevices()) {
      payload.emplace_back(EncodableMap{
          {EncodableValue("id"), EncodableValue("windows:" + device)},
          {EncodableValue("route"), EncodableValue(AudioRouteForDevice(device))},
          {EncodableValue("label"), EncodableValue(device)},
          {EncodableValue("available"), EncodableValue(true)},
          {EncodableValue("selected"), EncodableValue(device == active)},
      });
    }
    return payload;
  }

  std::string CurrentAudioRoute() const {
    for (const auto& endpoint : ModernAudioEndpoints()) {
      if (endpoint.selected) {
        return endpoint.route;
      }
    }
    const char* active = api_.linphone_core_get_playback_device == nullptr
                             ? nullptr
                             : api_.linphone_core_get_playback_device(core_);
    return AudioRouteForDevice(active == nullptr ? "" : active);
  }

  void GetAudioRoutes(std::unique_ptr<MethodResult> result) {
    std::lock_guard<std::mutex> lock(core_mutex_);
    if (!EnsureReady(result.get())) {
      return;
    }
    auto endpoints = AudioEndpointPayload();
    TraceNative("Audio routes enumerated count=" +
                std::to_string(endpoints.size()));
    result->Success(EncodableValue(endpoints));
  }

  void GetCallQuality(std::unique_ptr<MethodResult> result) {
    std::lock_guard<std::mutex> lock(core_mutex_);
    if (!EnsureReady(result.get())) {
      return;
    }
    LinphoneCall* call = CurrentCall();
    if (call == nullptr) {
      result->Error("CALL_ENDED", "There is no active call.");
      return;
    }
    EncodableMap quality{
        {EncodableValue("callId"), EncodableValue(PointerId(call))},
        {EncodableValue("audioRoute"), EncodableValue(CurrentAudioRoute())},
    };
    if (api_.linphone_call_get_current_quality != nullptr) {
      quality.emplace(EncodableValue("currentQuality"),
                      EncodableValue(static_cast<double>(
                          api_.linphone_call_get_current_quality(call))));
    }
    if (api_.linphone_call_get_average_quality != nullptr) {
      quality.emplace(EncodableValue("averageQuality"),
                      EncodableValue(static_cast<double>(
                          api_.linphone_call_get_average_quality(call))));
    }
    if (api_.linphone_call_get_duration != nullptr) {
      quality.emplace(EncodableValue("durationSeconds"),
                      EncodableValue(api_.linphone_call_get_duration(call)));
    }
    const LinphoneAddress* remote =
        api_.linphone_call_get_remote_address == nullptr
            ? nullptr
            : api_.linphone_call_get_remote_address(call);
    if (remote != nullptr &&
        api_.linphone_address_as_string_uri_only != nullptr) {
      quality.emplace(
          EncodableValue("remoteUri"),
          EncodableValue(api_.CopyString(
              api_.linphone_address_as_string_uri_only(remote))));
    }
    LinphoneCallStats* stats =
        api_.linphone_call_get_audio_stats == nullptr
            ? nullptr
            : api_.linphone_call_get_audio_stats(call);
    if (stats != nullptr) {
      if (api_.linphone_call_stats_get_round_trip_delay != nullptr) {
        quality.emplace(
            EncodableValue("roundTripMs"),
            EncodableValue(static_cast<double>(
                api_.linphone_call_stats_get_round_trip_delay(stats) * 1000)));
      }
      if (api_.linphone_call_stats_get_jitter_buffer_size_ms != nullptr) {
        quality.emplace(
            EncodableValue("jitterBufferMs"),
            EncodableValue(static_cast<double>(
                api_.linphone_call_stats_get_jitter_buffer_size_ms(stats))));
      }
      if (api_.linphone_call_stats_get_receiver_loss_rate != nullptr) {
        quality.emplace(
            EncodableValue("receiverLossPercent"),
            EncodableValue(static_cast<double>(
                api_.linphone_call_stats_get_receiver_loss_rate(stats))));
      }
      if (api_.linphone_call_stats_get_sender_loss_rate != nullptr) {
        quality.emplace(
            EncodableValue("senderLossPercent"),
            EncodableValue(static_cast<double>(
                api_.linphone_call_stats_get_sender_loss_rate(stats))));
      }
      if (api_.linphone_call_stats_get_local_loss_rate != nullptr) {
        quality.emplace(
            EncodableValue("localLossPercent"),
            EncodableValue(static_cast<double>(
                api_.linphone_call_stats_get_local_loss_rate(stats))));
      }
      if (api_.linphone_call_stats_get_download_bandwidth != nullptr) {
        quality.emplace(
            EncodableValue("downloadKbps"),
            EncodableValue(static_cast<double>(
                api_.linphone_call_stats_get_download_bandwidth(stats))));
      }
      if (api_.linphone_call_stats_get_upload_bandwidth != nullptr) {
        quality.emplace(
            EncodableValue("uploadKbps"),
            EncodableValue(static_cast<double>(
                api_.linphone_call_stats_get_upload_bandwidth(stats))));
      }
      if (api_.linphone_call_stats_unref != nullptr) {
        api_.linphone_call_stats_unref(stats);
      }
    }
    TraceNative("Call quality snapshot id=" + PointerId(call) +
                " fields=" + std::to_string(quality.size()));
    result->Success(EncodableValue(quality));
  }

  void SetAudioRoute(const std::string& route,
                     const std::string& endpoint_id,
                     std::unique_ptr<MethodResult> result) {
    std::lock_guard<std::mutex> lock(core_mutex_);
    if (!EnsureReady(result.get())) {
      return;
    }
    const auto modern = ModernAudioEndpoints();
    if (!modern.empty()) {
      std::string requested = endpoint_id;
      constexpr char kPrefix[] = "windows:";
      if (requested.rfind(kPrefix, 0) == 0) {
        requested.erase(0, sizeof(kPrefix) - 1);
      }
      auto selected = std::find_if(
          modern.begin(), modern.end(),
          [&requested](const AudioEndpoint& endpoint) {
            return !requested.empty() && endpoint.id == requested;
          });
      if (selected == modern.end()) {
        selected = std::find_if(
            modern.begin(), modern.end(),
            [&route](const AudioEndpoint& endpoint) {
              return endpoint.route == route;
            });
      }
      if (selected == modern.end()) {
        result->Error("AUDIO_ROUTE",
                      "The selected Windows audio device is unavailable.");
        return;
      }
      LinphoneCall* call = CurrentCall();
      if (call != nullptr &&
          api_.linphone_call_set_output_audio_device != nullptr) {
        api_.linphone_call_set_output_audio_device(call, selected->device);
      } else if (api_.linphone_core_set_output_audio_device != nullptr) {
        api_.linphone_core_set_output_audio_device(core_, selected->device);
      }
      constexpr int kCanRecord = 1 << 0;
      if ((selected->capabilities & kCanRecord) != 0) {
        if (call != nullptr &&
            api_.linphone_call_set_input_audio_device != nullptr) {
          api_.linphone_call_set_input_audio_device(call, selected->device);
        } else if (api_.linphone_core_set_input_audio_device != nullptr) {
          api_.linphone_core_set_input_audio_device(core_, selected->device);
        }
      }
      TraceNative("Audio route selected route=" + selected->route);
      result->Success(EncodableValue(selected->route));
      return;
    }
    const auto devices = AudioDevices();
    std::string requested = endpoint_id;
    constexpr char kPrefix[] = "windows:";
    if (requested.rfind(kPrefix, 0) == 0) {
      requested.erase(0, sizeof(kPrefix) - 1);
    }
    auto selected = std::find(devices.begin(), devices.end(), requested);
    if (selected == devices.end()) {
      selected = std::find_if(devices.begin(), devices.end(),
                              [&route](const std::string& device) {
                                return AudioRouteForDevice(device) == route;
                              });
    }
    if (selected == devices.end() ||
        api_.linphone_core_set_playback_device == nullptr) {
      result->Error("AUDIO_ROUTE",
                    "The selected Windows audio device is unavailable.");
      return;
    }
    if (api_.linphone_core_set_playback_device(core_, selected->c_str()) != 0) {
      result->Error("AUDIO_ROUTE",
                    "Windows could not activate the selected audio device.");
      return;
    }
    // A Bluetooth or USB headset is one logical user choice. Pair its capture
    // side with playback when the SDK reports that the selected device can
    // record, avoiding speaker audio with an unrelated laptop microphone.
    if (api_.linphone_core_set_capture_device != nullptr &&
        api_.linphone_core_sound_device_can_capture != nullptr &&
        api_.linphone_core_sound_device_can_capture(core_, selected->c_str()) != 0 &&
        api_.linphone_core_set_capture_device(core_, selected->c_str()) != 0) {
      result->Error("AUDIO_ROUTE",
                    "Windows activated playback but could not activate the "
                    "matching microphone.");
      return;
    }
    result->Success(EncodableValue(AudioRouteForDevice(*selected)));
  }

  void SendDtmf(const std::string& value, std::unique_ptr<MethodResult> result) {
    std::lock_guard<std::mutex> lock(core_mutex_);
    if (!EnsureReady(result.get())) {
      return;
    }
    LinphoneCall* call = CurrentCall();
    if (call != nullptr && !value.empty() &&
        api_.linphone_call_send_dtmf != nullptr) {
      api_.linphone_call_send_dtmf(call, value.front());
    }
    result->Success();
  }

  void PurgeAccount(std::unique_ptr<MethodResult> result) {
    std::lock_guard<std::mutex> lock(core_mutex_);
    if (core_ == nullptr) {
      account_ = nullptr;
      sip_domain_.clear();
      result->Success();
      return;
    }
    StopPresenceSubscriptionsLocked();
    if (api_.linphone_core_clear_accounts != nullptr) {
      api_.linphone_core_clear_accounts(core_);
    }
    if (api_.linphone_core_clear_all_auth_info != nullptr) {
      api_.linphone_core_clear_all_auth_info(core_);
    }
    account_ = nullptr;
    sip_domain_.clear();
    TraceNative("Purged logged-out SIP account");
    result->Success();
  }

  void StartPresenceSubscriptions(
      std::vector<std::string> extensions,
      std::unique_ptr<MethodResult> result) {
    std::lock_guard<std::mutex> lock(core_mutex_);
    if (!EnsureReady(result.get())) {
      return;
    }
    if (api_.linphone_core_create_subscribe == nullptr ||
        api_.linphone_event_send_subscribe == nullptr ||
        api_.linphone_event_terminate == nullptr ||
        api_.linphone_core_cbs_set_notify_received == nullptr ||
        api_.linphone_core_cbs_set_subscription_state_changed == nullptr) {
      result->Error(
          "LINPHONE_UNSUPPORTED",
          "This Windows Linphone runtime does not support BLF subscriptions.");
      return;
    }

    StopPresenceSubscriptionsLocked();
    for (auto& extension : extensions) {
      extension.erase(
          extension.begin(),
          std::find_if(extension.begin(), extension.end(), [](unsigned char c) {
            return !std::isspace(c);
          }));
      extension.erase(
          std::find_if(extension.rbegin(), extension.rend(),
                       [](unsigned char c) { return !std::isspace(c); })
              .base(),
          extension.end());
    }
    extensions.erase(
        std::remove_if(
            extensions.begin(), extensions.end(), [](const std::string& value) {
              return value.size() < 2 || value.size() > 8 ||
                     !std::all_of(value.begin(), value.end(), [](char c) {
                       return c >= '0' && c <= '9';
                     });
            }),
        extensions.end());
    std::sort(extensions.begin(), extensions.end());
    extensions.erase(std::unique(extensions.begin(), extensions.end()),
                     extensions.end());
    if (extensions.size() > 250) {
      extensions.resize(250);
    }

    LinphoneFactory* factory = api_.linphone_factory_get();
    for (const auto& extension : extensions) {
      const std::pair<const char*, const char*> packages[] = {
          {"dialog", "application/dialog-info+xml"},
          {"presence", "application/pidf+xml"}};
      for (const auto& package : packages) {
      const std::string destination =
          NormalizeDestination(extension, sip_domain_);
      LinphoneAddress* address =
          api_.linphone_factory_create_address(factory, destination.c_str());
      if (address == nullptr) {
        EmitPresenceSubscription(extension, package.first, "error");
        continue;
      }
      LinphoneEvent* event = api_.linphone_core_create_subscribe(
          core_, address, package.first, 300);
      if (api_.linphone_address_unref != nullptr) {
        api_.linphone_address_unref(address);
      }
      if (event == nullptr) {
        EmitPresenceSubscription(extension, package.first, "error");
        continue;
      }
      if (api_.linphone_event_add_custom_header != nullptr) {
        api_.linphone_event_add_custom_header(
            event, "Accept", package.second);
      }
      presence_subscriptions_[event] = {extension, package.first};
      if (api_.linphone_event_send_subscribe(event, nullptr) != 0) {
        presence_subscriptions_.erase(event);
        api_.linphone_event_terminate(event);
        if (api_.linphone_event_unref != nullptr) {
          api_.linphone_event_unref(event);
        }
        EmitPresenceSubscription(extension, package.first, "error");
      }
      }
    }
    result->Success();
  }

  void StopPresenceSubscriptions() {
    std::lock_guard<std::mutex> lock(core_mutex_);
    StopPresenceSubscriptionsLocked();
  }

  void StopPresenceSubscriptionsLocked() {
    std::vector<LinphoneEvent*> subscriptions;
    subscriptions.reserve(presence_subscriptions_.size());
    for (const auto& entry : presence_subscriptions_) {
      subscriptions.push_back(entry.first);
    }
    presence_subscriptions_.clear();
    for (LinphoneEvent* event : subscriptions) {
      if (api_.linphone_event_terminate != nullptr) {
        api_.linphone_event_terminate(event);
      }
      if (api_.linphone_event_unref != nullptr) {
        api_.linphone_event_unref(event);
      }
    }
  }

  void EmitPresenceSubscription(const std::string& extension,
                                const std::string& event_package,
                                const std::string& state) {
    owner_->EnqueueEvent(
        "presence",
        EncodableMap{{EncodableValue("kind"),
                      EncodableValue(std::string("subscription"))},
                     {EncodableValue("extension"), EncodableValue(extension)},
                     {EncodableValue("event"), EncodableValue(event_package)},
                     {EncodableValue("state"), EncodableValue(state)}});
  }

  LinphoneCall* CurrentCall() {
    if (api_.linphone_core_get_current_call != nullptr) {
      LinphoneCall* call = api_.linphone_core_get_current_call(core_);
      if (call != nullptr && !IsTerminalCall(call)) {
        return call;
      }
    }
    return active_call_ != nullptr && !IsTerminalCall(active_call_)
               ? active_call_
               : nullptr;
  }

  bool IsTerminalCall(const LinphoneCall* call) const {
    if (call == nullptr) {
      return true;
    }
    if (api_.linphone_call_get_state == nullptr) {
      return false;
    }
    const int state = api_.linphone_call_get_state(call);
    return state == 13 || state == 14 || state == 19;
  }

  void Dispose() {
    TraceNative("Dispose enter");
    iterate_running_ = false;
    if (iterate_thread_.joinable()) {
      iterate_thread_.join();
    }
    std::lock_guard<std::mutex> lock(core_mutex_);
    StopPresenceSubscriptionsLocked();
    if (core_ != nullptr) {
      TraceNative("Dispose core stop begin");
      api_.linphone_core_stop(core_);
      TraceNative("Dispose core stop complete");
      api_.linphone_core_unref(core_);
      TraceNative("Dispose core unref complete");
      core_ = nullptr;
    }
    callbacks_ = nullptr;
    account_ = nullptr;
    active_call_ = nullptr;
    if (active_impl_ == this) {
      active_impl_ = nullptr;
    }
    TraceNative("Dispose complete");
  }

  void StartIterateLoop() {
    if (api_.linphone_core_iterate == nullptr || iterate_running_) {
      return;
    }
    iterate_running_ = true;
    iterate_thread_ = std::thread([this]() {
      while (iterate_running_) {
        if (owner_->window_ != nullptr) {
          PostMessage(owner_->window_, kLinphoneIterateMessage, 0, 0);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
      }
    });
  }

  static void OnRegistrationChanged(LinphoneCore* core,
                                    LinphoneProxyConfig* config,
                                    int state,
                                    const char* message) {
    if (active_impl_ != nullptr) {
      std::string registration_message = message == nullptr
                                             ? std::string()
                                             : std::string(message);
      if (state == 4) {
        registration_message = active_impl_->RegistrationFailureDetails(
            registration_message);
      }
      active_impl_->owner_->EnqueueEvent(
          "registration",
          EncodableMap{{EncodableValue("status"),
                        EncodableValue(RegistrationStatus(state))},
                       {EncodableValue("message"),
                        registration_message.empty()
                            ? EncodableValue()
                            : EncodableValue(registration_message)}});
    }
  }

  std::string RegistrationFailureDetails(const std::string& fallback) {
    if (account_ == nullptr || api_.linphone_account_get_error_info == nullptr) {
      return fallback;
    }
    const LinphoneErrorInfo* error_info =
        api_.linphone_account_get_error_info(account_);
    if (error_info == nullptr) {
      return fallback;
    }
    std::ostringstream details;
    if (!fallback.empty()) {
      details << fallback;
    } else {
      details << "SIP registration failed";
    }
    if (api_.linphone_error_info_get_reason != nullptr) {
      details << " (reason "
              << api_.linphone_error_info_get_reason(error_info);
      if (api_.linphone_error_info_get_protocol_code != nullptr) {
        const int code =
            api_.linphone_error_info_get_protocol_code(error_info);
        if (code > 0) {
          details << ", SIP " << code;
        }
      }
      details << ")";
    }
    if (api_.linphone_error_info_get_phrase != nullptr) {
      const char* phrase = api_.linphone_error_info_get_phrase(error_info);
      if (phrase != nullptr && phrase[0] != '\0' && fallback != phrase) {
        details << ": " << phrase;
      }
    }
    TraceNative("Registration failed with detailed SDK error");
    return details.str();
  }

  static void OnCallChanged(LinphoneCore* core,
                            LinphoneCall* call,
                            int state,
                            const char* message) {
    if (active_impl_ != nullptr) {
      active_impl_->EmitCall(call, state);
    }
  }

  static void OnNotifyReceived(LinphoneCore* core,
                               LinphoneEvent* event,
                               const char* notified_event,
                               const LinphoneContent* body) {
    if (active_impl_ == nullptr || event == nullptr ||
        notified_event == nullptr) {
      return;
    }
    const auto found = active_impl_->presence_subscriptions_.find(event);
    if (found == active_impl_->presence_subscriptions_.end()) {
      return;
    }
    if (found->second.second != notified_event) {
      return;
    }
    std::string body_text;
    std::string content_type;
    if (body != nullptr) {
      if (active_impl_->api_.linphone_content_get_utf8_text != nullptr) {
        const char* text =
            active_impl_->api_.linphone_content_get_utf8_text(body);
        if (text != nullptr) {
          body_text = text;
        }
      }
      if (active_impl_->api_.linphone_content_get_type != nullptr) {
        const char* type = active_impl_->api_.linphone_content_get_type(body);
        if (type != nullptr) {
          content_type = type;
        }
      }
      if (active_impl_->api_.linphone_content_get_subtype != nullptr) {
        const char* subtype =
            active_impl_->api_.linphone_content_get_subtype(body);
        if (subtype != nullptr) {
          content_type += "/" + std::string(subtype);
        }
      }
    }
    active_impl_->owner_->EnqueueEvent(
        "presence",
        EncodableMap{{EncodableValue("kind"),
                      EncodableValue(std::string("notify"))},
                     {EncodableValue("extension"),
                      EncodableValue(found->second.first)},
                     {EncodableValue("event"),
                      EncodableValue(found->second.second)},
                     {EncodableValue("contentType"),
                      EncodableValue(content_type)},
                     {EncodableValue("body"), EncodableValue(body_text)}});
  }

  static void OnSubscriptionStateChanged(LinphoneCore* core,
                                         LinphoneEvent* event,
                                         int state) {
    if (active_impl_ == nullptr || event == nullptr) {
      return;
    }
    const auto found = active_impl_->presence_subscriptions_.find(event);
    if (found == active_impl_->presence_subscriptions_.end()) {
      return;
    }
    active_impl_->EmitPresenceSubscription(
        found->second.first,
        found->second.second,
        SubscriptionStateName(state));
  }

  EncodableMap BuildCallPayload(LinphoneCall* call, int state) {
    if (call == nullptr) {
      return {{EncodableValue("status"),
               EncodableValue(std::string("none"))}};
    }
    const bool terminal = state == 13 || state == 14 || state == 19;
    active_call_ = terminal ? nullptr : call;
    std::string remote_uri;
    std::string remote_name;
    const LinphoneAddress* remote_address = nullptr;
    if (api_.linphone_call_get_remote_address != nullptr) {
      remote_address = api_.linphone_call_get_remote_address(call);
    }
    if (remote_address != nullptr) {
      if (api_.linphone_address_as_string_uri_only != nullptr) {
        remote_uri = api_.CopyString(
            api_.linphone_address_as_string_uri_only(remote_address));
      }
      if (api_.linphone_address_get_display_name != nullptr) {
        const char* display_name =
            api_.linphone_address_get_display_name(remote_address);
        if (display_name != nullptr) {
          remote_name = display_name;
        }
      }
      if (remote_name.empty() && api_.linphone_address_get_username != nullptr) {
        const char* username = api_.linphone_address_get_username(remote_address);
        if (username != nullptr) {
          remote_name = username;
        }
      }
    }
    const std::string direction =
        api_.linphone_call_get_dir != nullptr &&
                api_.linphone_call_get_dir(call) == 1
            ? "incoming"
            : "outgoing";
    auto audio_endpoints = AudioEndpointPayload();
    const std::string audio_route = CurrentAudioRoute();
    std::string current_endpoint_id;
    for (const auto& endpoint_value : audio_endpoints) {
      const auto* endpoint = std::get_if<EncodableMap>(&endpoint_value);
      if (endpoint == nullptr) {
        continue;
      }
      const auto selected = endpoint->find(EncodableValue("selected"));
      const auto id = endpoint->find(EncodableValue("id"));
      if (selected != endpoint->end() && id != endpoint->end() &&
          std::get_if<bool>(&selected->second) != nullptr &&
          *std::get_if<bool>(&selected->second)) {
        if (const auto* value = std::get_if<std::string>(&id->second)) {
          current_endpoint_id = *value;
        }
        break;
      }
    }
    const auto call_status = CallStatus(state);
    TraceNative("Call state id=" + PointerId(call) +
                " direction=" + direction +
                " state=" + std::to_string(state) +
                " status=" + call_status);
    if (direction == "incoming" && call_status == "ringing") {
      if (device_dnd_enabled_) {
        owner_->ClearIncomingCallNotification();
        if (dnd_declined_incoming_call_ != call &&
            api_.linphone_call_decline != nullptr) {
          dnd_declined_incoming_call_ = call;
          TraceNative("Declining incoming call for device DND id=" +
                      PointerId(call));
          api_.linphone_call_decline(call, 3);
        }
      } else if (notified_incoming_call_ != call) {
        notified_incoming_call_ = call;
        owner_->ShowIncomingCallNotification(
            remote_name.empty() ? remote_uri : remote_name);
      }
    } else if (terminal || call_status == "active") {
      notified_incoming_call_ = nullptr;
      dnd_declined_incoming_call_ = nullptr;
      owner_->ClearIncomingCallNotification();
    }
    return EncodableMap{{EncodableValue("id"), EncodableValue(PointerId(call))},
                     {EncodableValue("remoteUri"), EncodableValue(remote_uri)},
                     {EncodableValue("remoteDisplayName"),
                      EncodableValue(remote_name)},
                     {EncodableValue("direction"),
                      EncodableValue(direction)},
                     {EncodableValue("status"), EncodableValue(call_status)},
                     {EncodableValue("isMuted"), EncodableValue(false)},
                     {EncodableValue("isSpeakerEnabled"),
                      EncodableValue(audio_route == "speaker")},
                     {EncodableValue("audioRoute"),
                      EncodableValue(audio_route)},
                     {EncodableValue("currentEndpointId"),
                      current_endpoint_id.empty()
                          ? EncodableValue()
                          : EncodableValue(current_endpoint_id)},
                     {EncodableValue("availableEndpoints"),
                      EncodableValue(audio_endpoints)}};
  }

  void EmitCall(LinphoneCall* call, int state) {
    if (call == nullptr) {
      return;
    }
    owner_->EnqueueEvent("calls", BuildCallPayload(call, state));
  }

  LinphoneWindowsBridge* owner_;
  LinphoneApi api_;
  LinphoneCore* core_ = nullptr;
  LinphoneCoreCbs* callbacks_ = nullptr;
  LinphoneAccount* account_ = nullptr;
  LinphoneCall* active_call_ = nullptr;
  LinphoneCall* notified_incoming_call_ = nullptr;
  LinphoneCall* dnd_declined_incoming_call_ = nullptr;
  std::unordered_map<LinphoneEvent*,
                     std::pair<std::string, std::string>>
      presence_subscriptions_;
  std::string sip_domain_;
  std::mutex core_mutex_;
  bool first_iterate_completed_ = false;
  bool device_dnd_enabled_ = false;
  std::atomic<bool> iterate_running_{false};
  std::thread iterate_thread_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> method_channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> registration_channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> call_channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> message_channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> presence_channel_;
  std::unique_ptr<EventSink> registration_sink_;
  std::unique_ptr<EventSink> call_sink_;
  std::unique_ptr<EventSink> message_sink_;
  std::unique_ptr<EventSink> presence_sink_;
};

LinphoneWindowsBridge::Impl* LinphoneWindowsBridge::Impl::active_impl_ =
    nullptr;

LinphoneWindowsBridge::LinphoneWindowsBridge(flutter::BinaryMessenger* messenger,
                                             HWND window)
    : window_(window), impl_(std::make_unique<Impl>(messenger, this)) {}

LinphoneWindowsBridge::~LinphoneWindowsBridge() = default;

bool LinphoneWindowsBridge::ProcessWindowMessage(UINT message) {
  if (message == kLinphoneBridgeEventMessage) {
    DrainPendingEvents();
    return true;
  }
  if (message == kLinphoneIterateMessage) {
    impl_->Iterate();
    return true;
  }
  return false;
}

void LinphoneWindowsBridge::EnqueueEvent(std::string stream,
                                         EncodableMap payload) {
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    pending_events_.push_back(PendingEvent{std::move(stream), std::move(payload)});
  }
  if (window_ != nullptr) {
    PostMessage(window_, kLinphoneBridgeEventMessage, 0, 0);
  }
}

void LinphoneWindowsBridge::DrainPendingEvents() {
  std::vector<PendingEvent> events;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    events.swap(pending_events_);
  }
  for (const auto& event : events) {
    impl_->SendEvent(event.stream, event.payload);
  }
}

void LinphoneWindowsBridge::ShowIncomingCallNotification(
    const std::string& caller) {
  if (window_ == nullptr) {
    return;
  }

  // The SIP core remains alive while the main window is hidden in the tray.
  // A taskbar flash or legacy balloon alone is not a reliable call surface:
  // restore the existing Flutter window so its incoming-call route can render.
  const bool was_hidden = !IsWindowVisible(window_) || IsIconic(window_);
  if (was_hidden) {
    ShowWindow(window_, SW_RESTORE);
    SetWindowPos(window_, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
    SetForegroundWindow(window_);
    TraceNative("Incoming call restored desktop window");
  }

  FLASHWINFO flash{};
  flash.cbSize = sizeof(flash);
  flash.hwnd = window_;
  flash.dwFlags = FLASHW_TRAY | FLASHW_TIMERNOFG;
  FlashWindowEx(&flash);

  NOTIFYICONDATA notification{};
  notification.cbSize = sizeof(notification);
  notification.hWnd = window_;
  notification.uID = kVoipCloudTrayIconId;
  notification.uFlags = NIF_INFO;
  // Do not use NIIF_RESPECT_QUIET_TIME for a real-time incoming call. Windows
  // discards (rather than queues) balloons suppressed by that flag.
  notification.dwInfoFlags = NIIF_USER | NIIF_LARGE_ICON;
  wcscpy_s(notification.szInfoTitle, L"Incoming VoipCloud call");
  const auto caller_wide = Utf8ToWide(caller);
  wcsncpy_s(notification.szInfo, caller_wide.c_str(), _TRUNCATE);
  const bool notification_posted =
      Shell_NotifyIcon(NIM_MODIFY, &notification) == TRUE;
  TraceNative(notification_posted
                  ? "Incoming call tray fallback posted"
                  : "Incoming call tray fallback unavailable");
}

void LinphoneWindowsBridge::ClearIncomingCallNotification() {
  if (window_ == nullptr) {
    return;
  }
  FLASHWINFO flash{};
  flash.cbSize = sizeof(flash);
  flash.hwnd = window_;
  flash.dwFlags = FLASHW_STOP;
  FlashWindowEx(&flash);

  // Clear a balloon immediately on CANCEL/decline/answer so stale incoming
  // call presentation cannot outlive the authoritative Linphone call.
  NOTIFYICONDATA notification{};
  notification.cbSize = sizeof(notification);
  notification.hWnd = window_;
  notification.uID = kVoipCloudTrayIconId;
  notification.uFlags = NIF_INFO;
  notification.szInfo[0] = L'\0';
  notification.szInfoTitle[0] = L'\0';
  Shell_NotifyIcon(NIM_MODIFY, &notification);
}
