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
        LoadSymbol<LinphoneCall* …14880 tokens truncated… && c <= '9';
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
