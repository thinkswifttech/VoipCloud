// DRAFT - written on Windows, never compiled or run.
//
// The real CallingNetworkBinder: asks our patched bctoolbox (ios/sdk_patch) to pin every socket the
// Linphone SDK creates from now on to one network interface (IP_BOUND_IF / IPV6_BOUND_IF).
//
// The functions are looked up at run time with dlsym instead of being declared with @_silgen_name.
// A direct declaration would break the link when the app is built with the stock SDK; with dlsym the
// same code runs against both: the stock SDK simply does not have the symbol, so `isSupported` is
// false and the manager keeps behaving like Auto ("unsupported"), exactly as before.

import Darwin
import Foundation
import Network

final class BoundInterfaceBinder: CallingNetworkBinder {
  private typealias SetBoundInterface = @convention(c) (UInt32) -> Void
  private typealias GetBoundInterface = @convention(c) () -> UInt32

  private let setBoundInterface: SetBoundInterface?
  private let getBoundInterface: GetBoundInterface?
  private let onPinChanged: ((Bool) -> Void)?

  /// `onPinChanged(true)` runs after sockets are pinned to an interface, `false` after pinning is removed.
  init(onPinChanged: ((Bool) -> Void)? = nil) {
    self.onPinChanged = onPinChanged
    // RTLD_DEFAULT: search the main program and every framework already loaded.
    let handle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    if let set = dlsym(handle, "bctbx_set_bound_interface"),
      let get = dlsym(handle, "bctbx_get_bound_interface")
    {
      setBoundInterface = unsafeBitCast(set, to: SetBoundInterface.self)
      getBoundInterface = unsafeBitCast(get, to: GetBoundInterface.self)
    } else {
      setBoundInterface = nil
      getBoundInterface = nil
    }
  }

  /// True only when this build of the app links the patched SDK.
  var isSupported: Bool { setBoundInterface != nil && getBoundInterface != nil }

  /// Pins sockets created from now on to `interface` (nil = system routing). Returns true only when the
  /// SDK confirms the new value. The caller must still make the SDK recreate its transports.
  func bind(to interface: NWInterface?) -> Bool {
    guard let set = setBoundInterface, let get = getBoundInterface else { return false }
    var index: UInt32 = 0
    if let interface {
      index = if_nametoindex(interface.name)
      // The interface vanished between the path update and now: refuse rather than guess.
      guard index != 0 else { return false }
    }
    set(index)
    guard get() == index else { return false }
    onPinChanged?(index != 0)
    return true
  }
}
