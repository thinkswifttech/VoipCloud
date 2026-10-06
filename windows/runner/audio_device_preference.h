#pragma once

// SDK defaults control future calls; active-device setters control existing
// calls. Confirm both before persisting or reporting success to the UI.
template <typename SetDefault, typename SetActive, typename VerifyDefault,
          typename VerifyActive>
bool ApplyAudioDevicePreference(bool has_active_call, SetDefault set_default,
                                SetActive set_active, VerifyDefault verify_default,
                                VerifyActive verify_active) {
  set_default();
  if (!verify_default()) return false;
  if (has_active_call) {
    set_active();
    if (!verify_active()) return false;
  }
  return true;
}
