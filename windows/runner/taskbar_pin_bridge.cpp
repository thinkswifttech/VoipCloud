#include "taskbar_pin_bridge.h"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.UI.Shell.h>
#include <winrt/base.h>

#include <utility>

namespace {
using flutter::EncodableValue;
using TaskbarManager = winrt::Windows::UI::Shell::TaskbarManager;
using DesktopSupport =
    winrt::Windows::UI::Shell::ITaskbarManagerDesktopAppSupportStatics;

bool HasDesktopTaskbarSupport() {
  return static_cast<bool>(
      winrt::try_get_activation_factory<TaskbarManager, DesktopSupport>());
}

winrt::fire_and_forget RequestPinAsync(
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  try {
    const auto manager = TaskbarManager::GetDefault();
    if (!manager || !manager.IsSupported() || !manager.IsPinningAllowed()) {
      result->Success(EncodableValue(false));
      co_return;
    }

    const bool pinned = co_await manager.RequestPinCurrentAppAsync();
    result->Success(EncodableValue(pinned));
  } catch (const winrt::hresult_error& error) {
    result->Error("taskbar_pin_failed", winrt::to_string(error.message()));
  } catch (...) {
    result->Error("taskbar_pin_failed",
                  "Windows could not complete the taskbar pin request.");
  }
}
}  // namespace

TaskbarPinBridge::TaskbarPinBridge(flutter::BinaryMessenger* messenger) {
  method_channel_ =
      std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "voipcloud/windows_taskbar",
          &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() == "canRequestPin") {
          result->Success(EncodableValue(CanRequestPin()));
          return;
        }
        if (call.method_name() == "requestPin") {
          RequestPin(std::move(result));
          return;
        }
        result->NotImplemented();
      });
}

TaskbarPinBridge::~TaskbarPinBridge() = default;

void TaskbarPinBridge::OfferPin() {
  method_channel_->InvokeMethod("offerPin", nullptr);
}

bool TaskbarPinBridge::CanRequestPin() const {
  try {
    if (!HasDesktopTaskbarSupport()) return false;
    const auto manager = TaskbarManager::GetDefault();
    return manager && manager.IsSupported() && manager.IsPinningAllowed();
  } catch (...) {
    return false;
  }
}

void TaskbarPinBridge::RequestPin(
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (!CanRequestPin()) {
    result->Success(EncodableValue(false));
    return;
  }
  RequestPinAsync(std::move(result));
}
