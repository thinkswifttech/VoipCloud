#ifndef RUNNER_TASKBAR_PIN_BRIDGE_H_
#define RUNNER_TASKBAR_PIN_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

class TaskbarPinBridge {
 public:
  explicit TaskbarPinBridge(flutter::BinaryMessenger* messenger);
  ~TaskbarPinBridge();

  void OfferPin();

  TaskbarPinBridge(const TaskbarPinBridge&) = delete;
  TaskbarPinBridge& operator=(const TaskbarPinBridge&) = delete;

 private:
  bool CanRequestPin() const;
  void RequestPin(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<
      flutter::MethodChannel<flutter::EncodableValue>> method_channel_;
};

#endif  // RUNNER_TASKBAR_PIN_BRIDGE_H_
