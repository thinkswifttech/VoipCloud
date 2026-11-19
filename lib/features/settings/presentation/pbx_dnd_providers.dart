import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../voip/platform/voip_platform_channel.dart';
import '../../accounts/domain/account_line.dart';
import '../../session/presentation/session_controller.dart';
import '../../sip/presentation/sip_log_providers.dart';
import '../application/pbx_dnd_monitor.dart';

PbxDndMonitor _monitorFor(Ref ref, AccountLine line) {
  const platform = VoipPlatformChannel();
  final monitor = PbxDndMonitor(
    events: platform.presenceEvents(),
    start: (extension, id) =>
        platform.startPbxDndSubscription(extension, id, accountId: line.wire),
    stop: () => platform.stopDndDiagnostic(accountId: line.wire),
    toggle: () => ref
        .read(sipServiceProvider)
        .syncPbxDndToggle(requireImmediate: true, line: line),
    canToggle: () => ref.read(sipServiceProvider).liveCalls.isEmpty,
    diagnostic: (message) => ref.read(sipLogStoreProvider).info(message),
  );
  ref.onDispose(monitor.dispose);
  return monitor;
}

final pbxDndMonitorProvider = Provider<PbxDndMonitor>(
  (ref) => _monitorFor(ref, AccountLine.primary),
);

/// The second account's own PBX do-not-disturb (its extension, its phone system).
final secondaryPbxDndMonitorProvider = Provider<PbxDndMonitor>(
  (ref) => _monitorFor(ref, AccountLine.secondary),
);

final pbxDndStateProvider = NotifierProvider<PbxDndStateNotifier, PbxDndState>(
  PbxDndStateNotifier.new,
);

final secondaryPbxDndStateProvider =
    NotifierProvider<PbxDndStateNotifier, PbxDndState>(
      () => PbxDndStateNotifier(secondary: true),
    );

class PbxDndStateNotifier extends Notifier<PbxDndState> {
  PbxDndStateNotifier({this.secondary = false});

  final bool secondary;

  @override
  PbxDndState build() {
    final monitor = ref.read(
      secondary ? secondaryPbxDndMonitorProvider : pbxDndMonitorProvider,
    );
    void update() {
      state = monitor.state;
    }

    monitor.addListener(update);
    ref.onDispose(() => monitor.removeListener(update));
    return monitor.state;
  }
}
