#ifndef RUNNER_CLIPBOARD_IMAGE_BRIDGE_H_
#define RUNNER_CLIPBOARD_IMAGE_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>

#include <memory>

// Puts an image on the Windows clipboard so it can be pasted into another
// application. Channel: voipcloud/files, method: copyImage.
class ClipboardImageBridge {
 public:
  ClipboardImageBridge(flutter::BinaryMessenger* messenger, HWND owner);
  ~ClipboardImageBridge();

  ClipboardImageBridge(const ClipboardImageBridge&) = delete;
  ClipboardImageBridge& operator=(const ClipboardImageBridge&) = delete;

 private:
  HWND owner_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;
};

#endif  // RUNNER_CLIPBOARD_IMAGE_BRIDGE_H_
