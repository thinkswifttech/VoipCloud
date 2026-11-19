import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/logging/app_logger.dart';

import '../../accounts/domain/account_line.dart';
import '../../accounts/presentation/accounts_controller.dart';
import '../data/directory_repository.dart';
import '../domain/directory_access.dart';
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
    await _cacheNames(access, entries, 'primary');
    return entries;
  }
}

Future<void> _cacheNames(
  DirectoryAccess? access,
  List<DirectoryEntry> entries,
  String line,
) async {
  try {
    await const VoipPlatformChannel().updateDirectoryCache(
      tenantKey: access?.endpoint.host ?? 'local',
      line: line,
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
}

/// The second account's company directory. It belongs to another phone
/// system, so it is loaded and cached separately from the primary one; an
/// account without a directory simply has none.
final secondaryDirectoryProvider =
    AsyncNotifierProvider<SecondaryDirectoryController, List<DirectoryEntry>>(
      SecondaryDirectoryController.new,
    );

class SecondaryDirectoryController extends AsyncNotifier<List<DirectoryEntry>> {
  @override
  Future<List<DirectoryEntry>> build() => _load();

  Future<void> refresh() async {
    final previous = state;
    final result = await AsyncValue.guard(_load);
    if (result.hasError && previous.hasValue) {
      AppLogger.warning(
        'Second directory refresh failed; retaining last known entries',
      );
      return;
    }
    state = result;
  }

  Future<List<DirectoryEntry>> _load() async {
    final access = ref
        .watch(accountsControllerProvider)
        .value
        ?.secondary
        ?.directoryAccess;
    if (access == null) return const [];
    final entries = await ref
        .read(directoryRepositoryProvider)
        .fetchDirectory(access);
    await _cacheNames(access, entries, 'secondary');
    return entries;
  }
}

/// The directory of one account's phone system.
final directoryForLineProvider =
    Provider.family<AsyncValue<List<DirectoryEntry>>, AccountLine>((ref, line) {
      return line == AccountLine.secondary
          ? ref.watch(secondaryDirectoryProvider)
          : ref.watch(directoryProvider);
    });

/// Which account's directory the Directory screen is showing. Only matters
/// with two accounts.
final selectedDirectoryLineProvider =
    NotifierProvider<SelectedDirectoryLine, AccountLine>(
      SelectedDirectoryLine.new,
    );

class SelectedDirectoryLine extends Notifier<AccountLine> {
  @override
  AccountLine build() => AccountLine.primary;

  void select(AccountLine line) => state = line;
}
