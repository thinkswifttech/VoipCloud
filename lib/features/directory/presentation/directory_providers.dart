import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/logging/app_logger.dart';

import '../data/directory_repository.dart';
import '../domain/directory_entry.dart';
import '../../session/presentation/session_controller.dart';
import '../../../voip/platform/voip_platform_channel.dart';

final directoryProvider =
    AsyncNotifierProvider<DirectoryController, List<DirectoryEntry>>(
      DirectoryController.new,
    );

class DirectoryController extends AsyncNotifier<List<DirectoryEntry>> {
  @override
  Future<List<DirectoryEntry>> build() => _load();

  Future<void> refresh() async {
    final previous = state;
    final result = await AsyncValue.guard(_load);
    // Refresh in place: never transiently publish an empty desired BLF set.
    if (result.hasError && previous.hasValue) {
      AppLogger.warning(
        'Directory refresh failed; retaining last known entries',
      );
      return;
    }
    state = result;
  }

  Future<List<DirectoryEntry>> _load() async {
    final access = ref.watch(sessionControllerProvider).value?.directoryAccess;
    final entries = await ref
        .read(directoryRepositoryProvider)
        .fetchDirectory(access);
    try {
      await const VoipPlatformChannel().updateDirectoryCache(
        tenantKey: access?.endpoint.host ?? 'local',
        entries: [
          for (final entry in entries)
            <String, Object?>{
              'name': entry.displayName,
              'numbers': entry.numbers,
            },
        ],
      );
    } catch (_) {
      // Native cold-start identity caching is best-effort and non-blocking.
    }
    return entries;
  }
}
