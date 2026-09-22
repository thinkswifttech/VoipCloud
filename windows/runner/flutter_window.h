#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>
#include <shellapi.h>

#include "win32_window.h"
#include "linphone_windows_bridge.h"
#include "taskbar_pin_bridge.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project,
                         bool start_hidden = false);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void RestoreWindowBounds();
  void SaveWindowBounds();
  void AddTrayIcon();
  void RemoveTrayIcon();
  void ShowAndActivate();
  void ShowTrayMenu();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<LinphoneWindowsBridge> linphone_bridge_;
  std::unique_ptr<TaskbarPinBridge> taskbar_pin_bridge_;
  NOTIFYICONDATA tray_icon_{};
  bool tray_icon_added_ = false;
  bool quitting_ = false;
  bool start_hidden_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
