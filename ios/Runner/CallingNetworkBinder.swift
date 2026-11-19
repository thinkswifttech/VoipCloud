// DRAFT - written on Windows, never compiled or run.
//
// The one piece the stock Linphone SDK does not give us on iPhone: forcing its
// sockets (DNS, SIP TCP/TLS, RTP/RTCP, STUN/TURN) onto a chosen interface.
// Apple's supported way for plain sockets is setsockopt IP_BOUND_IF /
// IPV6_BOUND_IF with an interface index, which has to be applied where the SDK
// creates each socket. That needs the SDK patch scoped in the Mac spike.
//
// Until then the manager runs with UnsupportedCallingNetworkBinder: the
// preference is stored, but routing stays system-managed (like Auto) and the
// status says "unsupported". Nothing here pretends to control the call.

import Foundation
import Network

protocol CallingNetworkBinder {
  /// True only when the SDK build can really pin its sockets to an interface.
  var isSupported: Bool { get }

  /// Pins all SDK traffic created from now on to `interface`; nil returns to
  /// system routing. Returns true only when the binding was applied.
  /// Sockets already created keep the interface they were created with, so the
  /// implementation must also make the SDK recreate its transports (the Android
  /// lesson: a pinned socket cannot move).
  func bind(to interface: NWInterface?) -> Bool
}

final class UnsupportedCallingNetworkBinder: CallingNetworkBinder {
  var isSupported: Bool { false }
  func bind(to interface: NWInterface?) -> Bool { false }
}
