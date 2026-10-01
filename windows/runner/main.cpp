#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "startup_directory.h"
#include "utils.h"

namespace {
constexpr wchar_t kSingleInstanceMutexName[] =
    L"Local\\ThinkSwift.VoipCloud.SingleInstance."
    L"8D72D853-EE12-4E7E-A33C-9C1777F99F35";
constexpr wchar_t kActivateExistingMessageName[] =
    L"ThinkSwift.VoipCloud.ActivateExisting.v1";

bool ActivateExistingInstance(bool offer_taskbar_pin) {
  const UINT activation_message =
      RegisterWindowMessage(kActivateExistingMessageName);
  if (activation_message == 0) return false;

  // An installer launch can overlap the existing process's startup. Wait for
  // its window and confirm that it actually handled the activation request;
  // merely finding the window does not mean it was ready to restore itself.
  const ULONGLONG deadline = GetTickCount64() + 10000;
  do {
    HWND existing = FindWindow(kFlutterWindowClassName, L"VoipCloud");
    if (existing != nullptr) {
      DWORD process_id = 0;
      GetWindowThreadProcessId(existing, &process_id);
      if (process_id != 0) {
        AllowSetForegroundWindow(process_id);
      }
      DWORD_PTR handled = 0;
      if (SendMessageTimeout(existing, activation_message,
                             offer_taskbar_pin ? 1 : 0, 0,
                             SMTO_ABORTIFHUNG | SMTO_BLOCK, 250,
                             &handled) != 0 &&
          handled == 1) {
        return true;
      }
    }
    Sleep(50);
  } while (GetTickCount64() < deadline);
  return false;
}
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const bool offer_taskbar_pin =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--offer-taskbar-pin") != command_line_arguments.end();
  const bool start_hidden =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--background") != command_line_arguments.end();

  if (!UseExecutableWorkingDirectory()) {
    OutputDebugStringW(L"VoipCloud: unable to establish startup directory.\n");
    if (!start_hidden) {
      MessageBoxW(nullptr,
                  L"VoipCloud could not access its installation folder. "
                  L"Please repair or reinstall the application.",
                  L"VoipCloud could not start", MB_OK | MB_ICONERROR);
    }
    return EXIT_FAILURE;
  }

  HANDLE single_instance_mutex =
      CreateMutex(nullptr, TRUE, kSingleInstanceMutexName);
  const DWORD mutex_error = GetLastError();
  if (single_instance_mutex == nullptr) {
    return EXIT_FAILURE;
  }
  if (mutex_error == ERROR_ALREADY_EXISTS) {
    // A sign-in launch should never interrupt an instance the user already
    // opened. Interactive launches still restore the existing tray process.
    if (!start_hidden) {
      const bool activated = ActivateExistingInstance(offer_taskbar_pin);
      CloseHandle(single_instance_mutex);
      return activated ? EXIT_SUCCESS : EXIT_FAILURE;
    }
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

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, start_hidden);
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
