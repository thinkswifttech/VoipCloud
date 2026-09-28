#include "windows_update_bridge.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <string>
#include <vector>

namespace {
using flutter::EncodableValue;
constexpr UINT kQuitCommand = 41002;

std::wstring FromUtf8(const std::string& value) {
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.c_str(), -1, nullptr, 0);
  if (length <= 0) return {};
  std::wstring result(length, L'\0');
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.c_str(), -1,
                           result.data(), length)) return {};
  result.pop_back();
  return result;
}

std::wstring Quote(const std::wstring& value) {
  // Paths supplied here are filesystem paths, not arbitrary shell commands.
  return L"\"" + value + L"\"";
}

std::wstring ModulePath() {
  std::vector<wchar_t> buffer(32768);
  const DWORD length = GetModuleFileNameW(nullptr, buffer.data(),
                                          static_cast<DWORD>(buffer.size()));
  if (length == 0 || length >= static_cast<DWORD>(buffer.size())) return {};
  return std::wstring(buffer.data(), length);
}

bool ValidDigest(const std::string& digest) {
  return digest.size() == 64 && std::all_of(digest.begin(), digest.end(),
      [](char c) { return (c >= '0' && c <= '9') ||
                           (c >= 'a' && c <= 'f'); });
}

bool StartHelper(const std::wstring& msi, const std::string& digest,
                 std::string* error) {
  const auto app = ModulePath();
  const auto separator = app.find_last_of(L"\\/");
  if (separator == std::wstring::npos) {
    *error = "Cannot locate the installed application.";
    return false;
  }
  const auto source = app.substr(0, separator + 1) + L"VoipCloudUpdater.exe";
  const DWORD source_attributes = GetFileAttributesW(source.c_str());
  if (source_attributes == INVALID_FILE_ATTRIBUTES ||
      (source_attributes & FILE_ATTRIBUTE_DIRECTORY)) {
    *error = "The update helper is not installed. Please install this update manually.";
    return false;
  }
  const DWORD msi_attributes = GetFileAttributesW(msi.c_str());
  if (msi_attributes == INVALID_FILE_ATTRIBUTES ||
      (msi_attributes & FILE_ATTRIBUTE_DIRECTORY)) {
    *error = "The downloaded installer is missing.";
    return false;
  }

  std::vector<wchar_t> temp(MAX_PATH + 1);
  const DWORD temp_length = GetTempPathW(static_cast<DWORD>(temp.size()),
                                        temp.data());
  if (temp_length == 0 || temp_length >= static_cast<DWORD>(temp.size())) {
    *error = "Cannot prepare a temporary update location.";
    return false;
  }
  const std::wstring directory = std::wstring(temp.data()) +
                                  L"ThinkSwift\\VoipCloud\\updates\\";
  const std::wstring first = std::wstring(temp.data()) + L"ThinkSwift";
  const std::wstring second = first + L"\\VoipCloud";
  if ((!CreateDirectoryW(first.c_str(), nullptr) &&
       GetLastError() != ERROR_ALREADY_EXISTS) ||
      (!CreateDirectoryW(second.c_str(), nullptr) &&
       GetLastError() != ERROR_ALREADY_EXISTS) ||
      (!CreateDirectoryW(directory.c_str(), nullptr) &&
       GetLastError() != ERROR_ALREADY_EXISTS)) {
    *error = "Cannot prepare a temporary update location.";
    return false;
  }
  const std::wstring helper = directory + L"VoipCloudUpdater-" +
      std::to_wstring(GetCurrentProcessId()) + L"-" +
      std::to_wstring(GetTickCount64()) + L".exe";
  if (!CopyFileW(source.c_str(), helper.c_str(), TRUE)) {
    *error = "Cannot stage the update helper.";
    return false;
  }

  const std::wstring command = Quote(helper) + L" " +
      std::to_wstring(GetCurrentProcessId()) + L" " + Quote(msi) + L" " +
      FromUtf8(digest) + L" " + Quote(app);
  std::vector<wchar_t> mutable_command(command.begin(), command.end());
  mutable_command.push_back(L'\0');
  STARTUPINFOW startup{sizeof(startup)};
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(helper.c_str(), mutable_command.data(), nullptr,
                      nullptr, FALSE, 0, nullptr, directory.c_str(),
                      &startup, &process)) {
    DeleteFileW(helper.c_str());
    *error = "Cannot start the update helper.";
    return false;
  }
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  return true;
}
}  // namespace

WindowsUpdateBridge::WindowsUpdateBridge(flutter::BinaryMessenger* messenger,
                                         HWND window) : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "voipcloud/windows_update",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() != "install") {
          result->NotImplemented();
          return;
        }
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args) {
          result->Error("invalid_update", "Update details are missing.");
          return;
        }
        const auto path = args->find(EncodableValue("path"));
        const auto hash = args->find(EncodableValue("sha256"));
        if (path == args->end() || hash == args->end() ||
            !std::holds_alternative<std::string>(path->second) ||
            !std::holds_alternative<std::string>(hash->second)) {
          result->Error("invalid_update", "Update details are invalid.");
          return;
        }
        const auto& digest = std::get<std::string>(hash->second);
        const auto msi = FromUtf8(std::get<std::string>(path->second));
        if (!ValidDigest(digest) || msi.empty() ||
            msi.find(L'\"') != std::wstring::npos ||
            msi.size() < 4 || msi.substr(msi.size() - 4) != L".msi") {
          result->Error("invalid_update", "Update details are invalid.");
          return;
        }
        std::string error;
        if (!StartHelper(msi, digest, &error)) {
          result->Error("update_start_failed", error);
          return;
        }
        result->Success();
        PostMessageW(window_, WM_COMMAND, MAKEWPARAM(kQuitCommand, 0), 0);
      });
}

WindowsUpdateBridge::~WindowsUpdateBridge() = default;
