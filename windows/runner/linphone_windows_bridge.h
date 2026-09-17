#ifndef RUNNER_LINPHONE_WINDOWS_BRIDGE_H_
#define RUNNER_LINPHONE_WINDOWS_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <windows.h>

#include <memory>
#include <mutex>
#include <string>
#include <vector>

class LinphoneWindowsBridge {
 public:
  LinphoneWindowsBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~LinphoneWindowsBridge();

  LinphoneWindowsBridge(const LinphoneWindowsBridge&) = delete;
  LinphoneWindowsBridge& operator=(const LinphoneWindowsBridge&) = delete;

  bool ProcessWindowMessage(UINT message);

 private:
  struct PendingEvent {
    std::string stream;
    flutter::EncodableMap payload;
  };

  class Impl;

  HWND window_ = nullptr;
  std::unique_ptr<Impl> impl_;
  std::mutex pending_mutex_;
  std::vector<PendingEvent> pending_events_;

  void EnqueueEvent(std::string stream, flutter::EncodableMap payload);
  void DrainPendingEvents();
  void ShowIncomingCallNotification(const std::string& caller);
  void ClearIncomingCallNotification();
  void SetAppBadgeCount(int count);
};

#endif  // RUNNER_LINPHONE_WINDOWS_BRIDGE_H_
