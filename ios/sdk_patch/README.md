# Linphone SDK patch: pin sockets to a network interface (iPhone)

This folder holds the changes VoipCloud makes to the Linphone SDK (linphone-sdk **5.5.19**, the version the iPhone app is built with) and the script that builds the patched SDK. The Linphone SDK is licensed under the GNU Affero General Public License v3 (AGPL-3.0); these files are the modified source and build instructions that go with the iPhone app. All original copyright and licence notices in the SDK files are kept unchanged.

## What the change does
The stock SDK has no way to choose the network its sockets use. This adds one setting, "bound interface", applied with `IP_BOUND_IF` / `IPV6_BOUND_IF` to every socket created after it is set. `0` means no pinning (the default, identical to the stock behaviour). The app uses it for its "Calling network" setting (Auto, Wi-Fi, Mobile data).

## The patches
Each patch applies to the plain `<module>` folder of the linphone-sdk 5.5.19 tree (commit `8e1ec723a2091854e3f6c19790fd64cbb7667539`, see `BASES.txt`).

| Patch | Change |
|---|---|
| `bctoolbox-bound-interface.patch` | New public API in `vconnect.h`: `bctbx_set_bound_interface(index)`, `bctbx_get_bound_interface()`, `bctbx_socket_apply_bound_interface(sock, family)`. `bctbx_socket()` applies it to each new socket and **fails closed** (closes the socket and returns -1) if the OS refuses, so traffic never leaves through the wrong network. The local-address probe in `port.c` now uses `bctbx_socket()`. A "Bound interface" test is added to the Utils suite. |
| `ortp-bound-interface.patch` | RTP/RTCP sockets (`rtpsession_inet.c`) use `bctbx_socket()`: the audio path. |
| `belle-sip-bound-interface.patch` | The embedded DNS resolver (`dns/dns.c`) uses `bctbx_socket()`. |
| `mediastreamer2-bound-interface.patch` | TURN-over-TCP (`turn_tcp.cpp`, the outgoing socket only) and the MTU probe (`src/base/mtu.c`). |
| `liblinphone-bound-interface.patch` | The STUN client socket (`nat/stun-client.cpp`). |

The same five patches, applied to the 5.5.19 tree, are published as a source branch (see "Source" below).

## Build
On a Mac with Xcode (15 or later), cmake (3.22 or later), ninja, python3, git and about 30 GB of free disk:

```
./build_patched_sdk.sh fetch      # get the 5.5.19 source
./build_patched_sdk.sh verify     # check that the patches apply (changes nothing)
./build_patched_sdk.sh patched    # apply the patches and build (arm64, video off)
./build_patched_sdk.sh package    # zip the xcframeworks and print their checksums
```
Settings (environment variables): `WORK` is the work folder (default `$HOME/linphone-sdk-build`); `BUNDLES` is an optional folder of local git bundles for building without network access.

The generated Swift package is `build-ios/linphone-sdk-swift-ios` inside `WORK/linphone-sdk`. The iPhone Xcode project (`ios/Runner.xcodeproj`) references it as a local Swift package at `relativePath = ../../../linphone-sdk-build/linphone-sdk/build-ios/linphone-sdk-swift-ios`, so set `WORK` to a folder named `linphone-sdk-build` located next to the repository's `App Development` folder (or edit that path in Xcode). Every framework in the generated `Package.swift` is a local `binaryTarget` pointing at `XCFrameworks/<name>.xcframework.zip`. `SHIPPED-SDK-CHECKSUMS.txt` lists the SHA-256 of the zips used for the released iPhone build and the verified source state.

## Apply by hand
```
cd <linphone-sdk tree>; git apply --directory=<module> <path>/<module>-bound-interface.patch
```

## Known limits
- On iPhone the SDK resolves names with Apple's DNS service by default, which ignores the pinned sockets. The app therefore sets custom DNS servers (`core.dnsServersApp`) while a network is pinned and clears them when it is not.
- Only `IPV6_BOUND_IF` is set on IPv6 sockets; IPv4-mapped traffic on such sockets should be checked on a device.
- `mediastreamer2/src/otherfilters/msudp.c` (a test filter) still calls `socket()`; it is not patched on purpose.
- The setting is a plain volatile unsigned integer, written rarely from one thread.
- Existing sockets keep their interface. Changing the interface needs the stack to drop and recreate its transports (the app toggles `core.networkReachable`). A live call's audio socket cannot move: the app ends the call when its network is lost.

## Source
The patched source tree is published as branch/tag `5.5.19-voipcloud1` of the VoipCloud fork of linphone-sdk (see `FORK.md` for the address and the list of changes). Upstream: https://gitlab.linphone.org/BC/public/linphone-sdk
