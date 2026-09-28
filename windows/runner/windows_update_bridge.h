#ifndef RUNNER_WINDOWS_UPDATE_BRIDGE_H_
#define RUNNER_WINDOWS_UPDATE_BRIDGE_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

class WindowsUpdateBridge {
 public:
  WindowsUpdateBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~WindowsUpdateBridge();

 private:
  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif
