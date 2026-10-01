#ifndef RUNNER_STARTUP_DIRECTORY_H_
#define RUNNER_STARTUP_DIRECTORY_H_

#include <windows.h>

#include <string>
#include <vector>

// MSI, the Windows Run key, and update helpers can inherit an unrelated working
// directory. Some native SDK dependencies still resolve resources relative to
// it, even when Flutter and Linphone's top-level resource paths are absolute.
// Establish a stable directory before any engine, plugin, or SDK is initialized.
inline bool UseExecutableWorkingDirectory() {
  std::vector<wchar_t> path(512);
  for (;;) {
    const DWORD length = GetModuleFileNameW(
        nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (length == 0) return false;
    if (length < path.size()) {
      std::wstring directory(path.data(), length);
      const auto separator = directory.find_last_of(L"\\/");
      if (separator == std::wstring::npos) return false;
      directory.resize(separator + 1);
      return SetCurrentDirectoryW(directory.c_str()) != FALSE;
    }
    if (path.size() >= 32768) return false;
    path.resize(path.size() * 2);
  }
}

#endif  // RUNNER_STARTUP_DIRECTORY_H_
