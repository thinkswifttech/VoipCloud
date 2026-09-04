#include "flutter_window.h"

#include <shellapi.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {
constexpr UINT kTrayIconMessage = WM_APP + 0x31;
constexpr UINT kTrayIconId = 1;
constexpr UINT kOpenCommand = 41001;
constexpr UINT kQuitCommand = 41002;
constexpr wchar_t kActivateExistingMessageName[] =
    L"ThinkSwift.VoipCloud.ActivateExisting.v1";

UINT ActivateExistingMessage() {
  static const UINT message = RegisterWindowMessage(kActivateExistingMessageName);
  return message;
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  linphone_bridge_ = std::make_unique<LinphoneWindowsBridge>(
      flutter_controller_->engine()->messenger(), GetHandle());
  taskbar_pin_bridge_ = std::make_unique<TaskbarPinBridge>(
      flutter_controller_->engine()->messenger());
  AddTrayIcon();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  taskbar_pin_bridge_ = nullptr;
  linphone_bridge_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == ActivateExistingMessage()) {
    ShowAndActivate();
    return 1;
  }

  // These private messages drive Linphone iteration and deliver queued SIP
  // events to Dart. Handle them before Flutter's generic window procedure so
  // no engine/plugin handler can consume them first.
  if (linphone_bridge_ && linphone_bridge_->ProcessWindowMessage(message)) {
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }
  switch (message) {
    case WM_CLOSE:
      if (!quitting_) {
        // Keep the Linphone core and SIP registration alive in the tray.
        ShowWindow(hwnd, SW_HIDE);
        return 0;
      }
      break;
    case WM_COMMAND:
      switch (LOWORD(wparam)) {
        case kOpenCommand:
          ShowAndActivate();
          return 0;
        case kQuitCommand:
          quitting_ = true;
          DestroyWindow(hwnd);
          return 0;
      }
      break;
    case kTrayIconMessage:
      switch (LOWORD(lparam)) {
        case WM_LBUTTONDBLCLK:
        case NIN_BALLOONUSERCLICK:
          ShowAndActivate();
          return 0;
        case WM_RBUTTONUP:
        case WM_CONTEXTMENU:
          ShowTrayMenu();
          return 0;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::AddTrayIcon() {
  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(tray_icon_);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = kTrayIconId;
  tray_icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  tray_icon_.uCallbackMessage = kTrayIconMessage;
  tray_icon_.hIcon =
      LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(tray_icon_.szTip, L"VoipCloud - running for incoming calls");
  tray_icon_added_ = Shell_NotifyIcon(NIM_ADD, &tray_icon_) == TRUE;
  if (tray_icon_added_) {
    tray_icon_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIcon(NIM_SETVERSION, &tray_icon_);
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) return;
  Shell_NotifyIcon(NIM_DELETE, &tray_icon_);
  tray_icon_added_ = false;
}

void FlutterWindow::ShowAndActivate() {
  const auto window = GetHandle();
  if (window == nullptr) return;
  ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
  BringWindowToTop(window);
  SetForegroundWindow(window);
  SetFocus(window);
}

void FlutterWindow::ShowTrayMenu() {
  POINT cursor{};
  GetCursorPos(&cursor);
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return;
  AppendMenu(menu, MF_STRING, kOpenCommand, L"Open VoipCloud");
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(menu, MF_STRING, kQuitCommand, L"Quit");
  SetForegroundWindow(GetHandle());
  TrackPopupMenu(menu, TPM_BOTTOMALIGN | TPM_LEFTALIGN | TPM_RIGHTBUTTON,
                 cursor.x, cursor.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu);
}
