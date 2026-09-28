#ifndef RUNNER_WINDOWS_EMAIL_BRIDGE_H_
#define RUNNER_WINDOWS_EMAIL_BRIDGE_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

class WindowsEmailBridge {
 public:
  WindowsEmailBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~WindowsEmailBridge();

 private:
  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_WINDOWS_EMAIL_BRIDGE_H_
