import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../voip/platform/voip_platform_channel.dart';
import '../../session/presentation/session_controller.dart';
import '../application/pbx_dnd_monitor.dart';

final pbxDndMonitorProvider = Provider<PbxDndMonitor>((ref) {
  const platform = VoipPlatformChannel();
  final monitor = PbxDndMonitor(
    events: platform.presenceEvents(),
    start: platform.startPbxDndSubscription,
    stop: platform.stopDndDiagnostic,
    toggle: () =>
        ref.read(sipServiceProvider).syncPbxDndToggle(requireImmediate: true),
    canToggle: () => ref.read(sipServiceProvider).liveCalls.isEmpty,
  );
  ref.onDispose(monitor.dispose);
  return monitor;
});

final pbxDndStateProvider = NotifierProvider<PbxDndStateNotifier, PbxDndState>(
  PbxDndStateNotifier.new,
);

class PbxDndStateNotifier extends Notifier<PbxDndState> {
  @override
  PbxDndState build() {
    final monitor = ref.read(pbxDndMonitorProvider);
    void update() {
      state = monitor.state;
    }

    monitor.addListener(update);
    ref.onDispose(() => monitor.removeListener(update));
    return monitor.state;
  }
}
