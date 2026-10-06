#include "../audio_device_preference.h"
#include <cassert>
#include <iostream>

int main() {
  int default_device = 0, active_device = 0, active_updates = 0;
  auto apply = [&](bool active, bool accept_default, bool accept_active) {
    return ApplyAudioDevicePreference(active,
        [&] { if (accept_default) default_device = 2; },
        [&] { ++active_updates; if (accept_active) active_device = 2; },
        [&] { return default_device == 2; },
        [&] { return active_device == 2; });
  };
  assert(apply(false, true, false));
  assert(default_device == 2 && active_updates == 0);
  default_device = 0;
  assert(apply(true, true, true));
  assert(default_device == 2 && active_device == 2 && active_updates == 1);
  default_device = active_device = active_updates = 0;
  assert(!apply(true, false, true));
  assert(active_updates == 0); // Never move the call if setting its default failed.
  assert(!apply(true, true, false)); // Never falsely confirm a rejected active device.
  assert(active_updates == 1);
  default_device = 0;
  assert(!apply(false, false, true));
  std::cout << "Audio device preference: 5 cases passed\n";
}
