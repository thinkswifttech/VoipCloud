#include <windows.h>
#include <bcrypt.h>
#include <shellapi.h>

#include <array>
#include <cstdint>
#include <cwctype>
#include <string>

namespace {
constexpr LONGLONG kMaximumInstallerBytes = 128LL * 1024 * 1024;

bool MatchesSha256(const wchar_t* path, const wchar_t* expected) {
  if (wcslen(expected) != 64) return false;
  HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size{};
  bool valid = GetFileSizeEx(file, &size) && size.QuadPart > 0 &&
               size.QuadPart <= kMaximumInstallerBytes;
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  std::array<UCHAR, 32> digest{};
  if (valid) valid = BCryptOpenAlgorithmProvider(&algorithm,
      BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0;
  if (valid) valid = BCryptCreateHash(algorithm, &hash, nullptr, 0,
                                      nullptr, 0, 0) >= 0;
  std::array<UCHAR, 65536> buffer{};
  while (valid) {
    DWORD count = 0;
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()),
                  &count, nullptr)) {
      valid = false;
      break;
    }
    if (count == 0) break;
    valid = BCryptHashData(hash, buffer.data(), count, 0) >= 0;
  }
  if (valid) valid = BCryptFinishHash(hash, digest.data(),
                                      static_cast<ULONG>(digest.size()), 0) >= 0;
  if (hash) BCryptDestroyHash(hash);
  if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
  CloseHandle(file);
  if (!valid) return false;
  constexpr wchar_t digits[] = L"0123456789abcdef";
  for (size_t i = 0; i < digest.size(); ++i) {
    if (towlower(expected[i * 2]) != digits[digest[i] >> 4] ||
        towlower(expected[i * 2 + 1]) != digits[digest[i] & 0x0f]) {
      return false;
    }
  }
  return true;
}

void ReopenApp(const wchar_t* app) {
  ShellExecuteW(nullptr, L"open", app, nullptr, nullptr, SW_SHOWNORMAL);
}

bool WaitForAppExit(DWORD pid) {
  HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, pid);
  if (!process) return GetLastError() == ERROR_INVALID_PARAMETER;
  const DWORD wait = WaitForSingleObject(process, 120000);
  CloseHandle(process);
  return wait == WAIT_OBJECT_0;
}

std::wstring SystemMsiexec() {
  std::array<wchar_t, MAX_PATH + 1> directory{};
  const UINT length = GetSystemDirectoryW(directory.data(),
                                          static_cast<UINT>(directory.size()));
  if (length == 0 || length >= static_cast<UINT>(directory.size())) return {};
  return std::wstring(directory.data(), length) + L"\\msiexec.exe";
}

bool Install(const wchar_t* msi, const wchar_t* log, DWORD* exit_code) {
  const auto msiexec = SystemMsiexec();
  if (msiexec.empty()) return false;
  const std::wstring parameters =
      std::wstring(L"/i \"") + msi + L"\" /passive /norestart /L*V \"" +
      log + L"\"";
  SHELLEXECUTEINFOW execute{};
  execute.cbSize = sizeof(execute);
  execute.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI;
  execute.lpVerb = L"runas";
  execute.lpFile = msiexec.c_str();
  execute.lpParameters = parameters.c_str();
  execute.nShow = SW_SHOWNORMAL;
  if (!ShellExecuteExW(&execute)) return false;
  const DWORD wait = WaitForSingleObject(execute.hProcess, INFINITE);
  const bool completed = wait == WAIT_OBJECT_0 &&
                         GetExitCodeProcess(execute.hProcess, exit_code);
  CloseHandle(execute.hProcess);
  return completed;
}

void ShowError(const wchar_t* message) {
  MessageBoxW(nullptr, message, L"VoipCloud update", MB_OK | MB_ICONERROR);
}
}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, wchar_t*, int) {
  int argc = 0;
  wchar_t** args = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!args || argc != 5) {
    if (args) LocalFree(args);
    return 1;
  }
  wchar_t* end = nullptr;
  const unsigned long pid = wcstoul(args[1], &end, 10);
  if (!pid || !end || *end != L'\0') {
    LocalFree(args);
    return 1;
  }
  const std::wstring msi(args[2]);
  const std::wstring digest(args[3]);
  const std::wstring app(args[4]);
  const std::wstring log = msi + L".install.log";
  LocalFree(args);

  if (!WaitForAppExit(static_cast<DWORD>(pid))) {
    ShowError(L"VoipCloud did not close. The update was not installed.");
    return 2;
  }
  if (!MatchesSha256(msi.c_str(), digest.c_str())) {
    ShowError(L"The update file did not pass verification. It was not installed.");
    ReopenApp(app.c_str());
    return 3;
  }
  DWORD exit_code = 0;
  if (!Install(msi.c_str(), log.c_str(), &exit_code)) {
    ShowError(L"Windows could not start the installer. VoipCloud will reopen.");
    ReopenApp(app.c_str());
    return 4;
  }
  if (exit_code != ERROR_SUCCESS && exit_code != ERROR_SUCCESS_REBOOT_REQUIRED) {
    const std::wstring message = L"Windows could not install the update (code " +
        std::to_wstring(exit_code) + L"). VoipCloud will reopen.\n\n" +
        L"Installer log: " + log;
    ShowError(message.c_str());
    ReopenApp(app.c_str());
    return 5;
  }
  ReopenApp(app.c_str());
  if (exit_code == ERROR_SUCCESS_REBOOT_REQUIRED) {
    MessageBoxW(nullptr,
                L"The update was installed. Windows needs a restart to finish it.",
                L"VoipCloud update", MB_OK | MB_ICONINFORMATION);
  }
  return 0;
}
