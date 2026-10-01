#include "../startup_directory.h"

#include <filesystem>
#include <iostream>

int wmain() {
  wchar_t system_directory[MAX_PATH] = {};
  if (!GetSystemDirectoryW(system_directory, MAX_PATH) ||
      !SetCurrentDirectoryW(system_directory)) return 1;
  if (!UseExecutableWorkingDirectory()) return 2;

  std::vector<wchar_t> executable(32768);
  const DWORD length = GetModuleFileNameW(
      nullptr, executable.data(), static_cast<DWORD>(executable.size()));
  if (!length || length >= executable.size()) return 3;
  const auto expected =
      std::filesystem::path(std::wstring(executable.data(), length)).parent_path();
  if (!std::filesystem::equivalent(std::filesystem::current_path(), expected)) {
    return 4;
  }
  // Repeated initialization must be harmless.
  if (!UseExecutableWorkingDirectory()) return 5;
  std::cout << "Installer/system-directory startup regression passed.\n";
  return 0;
}
