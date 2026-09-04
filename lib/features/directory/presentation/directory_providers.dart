import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    state = const AsyncLoading();
    state = await AsyncValue.guard(_load);
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
