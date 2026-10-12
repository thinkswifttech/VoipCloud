#include "clipboard_image_bridge.h"

#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

constexpr UINT kMaxPixels = 64u * 1024u * 1024u;

struct DecodedImage {
  UINT width = 0;
  UINT height = 0;
  std::vector<uint8_t> bgra;  // top-down, 4 bytes per pixel
};

bool DecodeImage(const std::vector<uint8_t>& bytes, DecodedImage* out) {
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&factory)))) {
    return false;
  }
  ComPtr<IWICStream> stream;
  if (FAILED(factory->CreateStream(&stream)) ||
      FAILED(stream->InitializeFromMemory(
          const_cast<BYTE*>(bytes.data()), static_cast<DWORD>(bytes.size())))) {
    return false;
  }
  ComPtr<IWICBitmapDecoder> decoder;
  if (FAILED(factory->CreateDecoderFromStream(
          stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder))) {
    return false;
  }
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(decoder->GetFrame(0, &frame))) return false;
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeCustom))) {
    return false;
  }
  UINT width = 0;
  UINT height = 0;
  if (FAILED(converter->GetSize(&width, &height)) || width == 0 ||
      height == 0 || width > kMaxPixels / height) {
    return false;
  }
  out->width = width;
  out->height = height;
  out->bgra.resize(static_cast<size_t>(width) * height * 4);
  return SUCCEEDED(converter->CopyPixels(
      nullptr, width * 4, static_cast<UINT>(out->bgra.size()),
      out->bgra.data()));
}

HGLOBAL BuildDibV5(const DecodedImage& image) {
  const size_t pixel_bytes = image.bgra.size();
  const size_t total = sizeof(BITMAPV5HEADER) + pixel_bytes;
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, total);
  if (!memory) return nullptr;
  auto* base = static_cast<uint8_t*>(GlobalLock(memory));
  if (!base) {
    GlobalFree(memory);
    return nullptr;
  }
  auto* header = reinterpret_cast<BITMAPV5HEADER*>(base);
  std::memset(header, 0, sizeof(BITMAPV5HEADER));
  header->bV5Size = sizeof(BITMAPV5HEADER);
  header->bV5Width = static_cast<LONG>(image.width);
  header->bV5Height = static_cast<LONG>(image.height);  // bottom-up
  header->bV5Planes = 1;
  header->bV5BitCount = 32;
  header->bV5Compression = BI_BITFIELDS;
  header->bV5SizeImage = static_cast<DWORD>(pixel_bytes);
  header->bV5RedMask = 0x00FF0000;
  header->bV5GreenMask = 0x0000FF00;
  header->bV5BlueMask = 0x000000FF;
  header->bV5AlphaMask = 0xFF000000;
  header->bV5CSType = LCS_sRGB;
  header->bV5Intent = LCS_GM_IMAGES;
  uint8_t* pixels = base + sizeof(BITMAPV5HEADER);
  const size_t stride = static_cast<size_t>(image.width) * 4;
  for (UINT row = 0; row < image.height; ++row) {
    std::memcpy(pixels + row * stride,
                image.bgra.data() + (image.height - 1 - row) * stride, stride);
  }
  GlobalUnlock(memory);
  return memory;
}

HGLOBAL CopyBytes(const std::vector<uint8_t>& bytes) {
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
  if (!memory) return nullptr;
  void* target = GlobalLock(memory);
  if (!target) {
    GlobalFree(memory);
    return nullptr;
  }
  std::memcpy(target, bytes.data(), bytes.size());
  GlobalUnlock(memory);
  return memory;
}

bool OpenClipboardWithRetry(HWND owner) {
  for (int attempt = 0; attempt < 10; ++attempt) {
    if (OpenClipboard(owner)) return true;
    Sleep(20);
  }
  return false;
}

std::string CopyImage(HWND owner, const std::vector<uint8_t>& bytes,
                      bool is_png) {
  DecodedImage image;
  if (!DecodeImage(bytes, &image)) return "The image could not be read.";
  HGLOBAL dib = BuildDibV5(image);
  if (!dib) return "Not enough memory to copy the image.";
  HGLOBAL png = nullptr;
  const UINT png_format = RegisterClipboardFormatW(L"PNG");
  if (is_png && png_format != 0) png = CopyBytes(bytes);

  if (!OpenClipboardWithRetry(owner)) {
    GlobalFree(dib);
    if (png) GlobalFree(png);
    return "The clipboard is in use by another application.";
  }
  EmptyClipboard();
  const bool ok = SetClipboardData(CF_DIBV5, dib) != nullptr;
  if (ok) {
    dib = nullptr;  // owned by the clipboard now
    if (png && SetClipboardData(png_format, png) != nullptr) png = nullptr;
  }
  CloseClipboard();
  if (dib) GlobalFree(dib);
  if (png) GlobalFree(png);
  return ok ? std::string() : "The image could not be placed on the clipboard.";
}
}  // namespace

ClipboardImageBridge::ClipboardImageBridge(flutter::BinaryMessenger* messenger,
                                           HWND owner)
    : owner_(owner) {
  method_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "voipcloud/files",
      &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() != "copyImage") {
          result->NotImplemented();
          return;
        }
        const auto* arguments = std::get_if<EncodableMap>(call.arguments());
        const std::vector<uint8_t>* bytes = nullptr;
        std::string mime_type;
        if (arguments) {
          auto it = arguments->find(EncodableValue("bytes"));
          if (it != arguments->end()) {
            bytes = std::get_if<std::vector<uint8_t>>(&it->second);
          }
          it = arguments->find(EncodableValue("mimeType"));
          if (it != arguments->end()) {
            if (const auto* text = std::get_if<std::string>(&it->second)) {
              mime_type = *text;
            }
          }
        }
        if (!bytes || bytes->empty()) {
          result->Error("INVALID_ARGS", "An image is required.");
          return;
        }
        std::transform(mime_type.begin(), mime_type.end(), mime_type.begin(),
                       [](unsigned char c) { return std::tolower(c); });
        const std::string error =
            CopyImage(owner_, *bytes, mime_type == "image/png");
        if (!error.empty()) {
          result->Error("COPY_FAILED", error);
          return;
        }
        result->Success(EncodableValue(true));
      });
}

ClipboardImageBridge::~ClipboardImageBridge() = default;
