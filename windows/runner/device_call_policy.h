#pragma once
#include <string>
#include <sstream>
#include <algorithm>

inline std::string DeviceDndContactParameters(const char* original, bool enabled) {
  std::istringstream stream(original == nullptr ? "" : original);
  std::string part;
  std::string result;
  while (std::getline(stream, part, ';')) {
    auto key = part.substr(0, part.find('='));
    std::transform(key.begin(), key.end(), key.begin(), [](unsigned char c) {
      return c >= 'A' && c <= 'Z' ? static_cast<char>(c + ('a' - 'A')) : static_cast<char>(c);
    });
    if (part.empty() || key == "x-voipcloud-dnd") continue;
    if (!result.empty()) result += ';';
    result += part;
  }
  if (!result.empty()) result += ';';
  return result + "x-voipcloud-dnd=" + (enabled ? "1" : "0");
}
