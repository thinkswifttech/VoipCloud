#include "windows_email_bridge.h"

#include <MAPI.h>
#include <MapiUnicodeHelp.h>
#include <flutter/standard_method_codec.h>

#include <string>

namespace {
using flutter::EncodableValue;

std::wstring FromUtf8(const std::string& value) {
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.c_str(), -1, nullptr, 0);
  if (length <= 0) return {};
  std::wstring result(length, L'\0');
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.c_str(), -1,
                           result.data(), length)) {
    return {};
  }
  result.pop_back();
  return result;
}

const std::string* StringArgument(const flutter::EncodableMap& arguments,
                                  const char* name) {
  const auto item = arguments.find(EncodableValue(name));
  if (item == arguments.end()) return nullptr;
  return std::get_if<std::string>(&item->second);
}

std::wstring FileNameFromPath(const std::wstring& path) {
  const auto separator = path.find_last_of(L"\\/");
  return separator == std::wstring::npos ? path : path.substr(separator + 1);
}
}  // namespace

WindowsEmailBridge::WindowsEmailBridge(flutter::BinaryMessenger* messenger,
                                       HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "voipcloud/windows_email",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() != "compose") {
          result->NotImplemented();
          return;
        }
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_email", "Email details are missing.");
          return;
        }
        const auto* path_argument = StringArgument(*arguments, "path");
        const auto* subject_argument = StringArgument(*arguments, "subject");
        const auto* body_argument = StringArgument(*arguments, "body");
        if (path_argument == nullptr || subject_argument == nullptr ||
            body_argument == nullptr) {
          result->Error("invalid_email", "Email details are invalid.");
          return;
        }

        auto path = FromUtf8(*path_argument);
        auto subject = FromUtf8(*subject_argument);
        auto body = FromUtf8(*body_argument);
        const DWORD attributes = GetFileAttributesW(path.c_str());
        if (path.empty() || subject.empty() ||
            attributes == INVALID_FILE_ATTRIBUTES ||
            (attributes & FILE_ATTRIBUTE_DIRECTORY)) {
          result->Error("invalid_attachment",
                        "The exported SIP log could not be attached.");
          return;
        }

        auto file_name = FileNameFromPath(path);
        MapiFileDescW attachment{};
        attachment.nPosition = static_cast<ULONG>(-1);
        attachment.lpszPathName = path.data();
        attachment.lpszFileName = file_name.data();

        MapiMessageW message{};
        message.lpszSubject = subject.data();
        message.lpszNoteText = body.data();
        message.nFileCount = 1;
        message.lpFiles = &attachment;

        const ULONG status = MAPISendMailHelper(
            0, reinterpret_cast<ULONG_PTR>(window_), &message,
            MAPI_LOGON_UI | MAPI_DIALOG, 0);
        if (status == SUCCESS_SUCCESS || status == MAPI_USER_ABORT) {
          result->Success();
          return;
        }
        const std::string detail =
            status == MAPI_E_LOGIN_FAILURE
                ? "No compatible default desktop email app is configured."
                : "The default email app could not create a message with the "
                  "SIP log attached. (MAPI code " +
                      std::to_string(status) + ")";
        result->Error("email_compose_failed", detail);
      });
}

WindowsEmailBridge::~WindowsEmailBridge() = default;
