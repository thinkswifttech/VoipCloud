#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {
constexpr wchar_t kSingleInstanceMutexName[] =
    L"Local\\ThinkSwift.VoipCloud.SingleInstance."
    L"8D72D853-EE12-4E7E-A33C-9C1777F99F35";
constexpr wchar_t kActivateExistingMessageName[] =
    L"ThinkSwift.VoipCloud.ActivateExisting.v1";

bool ActivateExistingInstance() {
  const UINT activation_message =
      RegisterWindowMessage(kActivateExistingMessageName);
  if (activation_message == 0) return false;

  // The first process may own the mutex just before its top-level window is
  // created. Retry briefly so rapid Start-menu clicks still activate that
  // process instead of appearing to do nothing.
  for (int attempt = 0; attempt < 40; ++attempt) {
    HWND existing = FindWindow(kFlutterWindowClassName, L"VoipCloud");
    if (existing != nullptr) {
      DWORD process_id = 0;
      GetWindowThreadProcessId(existing, &process_id);
      if (process_id != 0) {
        AllowSetForegroundWindow(process_id);
      }
      DWORD_PTR ignored = 0;
      SendMessageTimeout(existing, activation_message, 0, 0,
                         SMTO_ABORTIFHUNG | SMTO_BLOCK, 1000, &ignored);
      return true;
    }
    Sleep(50);
  }
  return false;
}
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE single_instance_mutex =
      CreateMutex(nullptr, TRUE, kSingleInstanceMutexName);
  const DWORD mutex_error = GetLastError();
  if (single_instance_mutex == nullptr) {
    return EXIT_FAILURE;
  }
  if (mutex_error == ERROR_ALREADY_EXISTS) {
    ActivateExistingInstance();
    CloseHandle(single_instance_mutex);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"VoipCloud", origin, size)) {
    CloseHandle(single_instance_mutex);
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ReleaseMutex(single_instance_mutex);
  CloseHandle(single_instance_mutex);
  return EXIT_SUCCESS;
}
