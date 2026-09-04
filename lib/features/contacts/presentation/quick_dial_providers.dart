import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/storage_providers.dart';
import '../data/local_quick_dial_repository.dart';
import '../domain/quick_dial_entry.dart';

final quickDialRepositoryProvider = Provider<LocalQuickDialRepository>((ref) {
  return LocalQuickDialRepository(ref.watch(secureStorageProvider));
});

final quickDialProvider =
    AsyncNotifierProvider<QuickDialController, List<QuickDialEntry>>(
      QuickDialController.new,
    );

class QuickDialDuplicateException implements Exception {
  const QuickDialDuplicateException(this.number);

  final String number;

  @override
  String toString() => 'Quick dial already contains $number';
}

class QuickDialController extends AsyncNotifier<List<QuickDialEntry>> {
  @override
  Future<List<QuickDialEntry>> build() {
    return ref.watch(quickDialRepositoryProvider).getEntries();
  }

  Future<QuickDialEntry> add({
    required String displayName,
    required String number,
    required QuickDialSource source,
    String? sourceId,
    Uint8List? photoBytes,
  }) async {
    final normalizedNumber = _normalizeNumber(number);
    if (normalizedNumber.isEmpty) {
      throw ArgumentError('Number is required');
    }
    final name = displayName.trim();
    if (name.isEmpty) {
      throw ArgumentError('Display name is required');
    }

    final current = [...(state.asData?.value ?? await future)];
    if (_hasNumber(current, normalizedNumber)) {
      throw QuickDialDuplicateException(normalizedNumber);
    }

    final entry = QuickDialEntry(
      id: 'qd-${DateTime.now().microsecondsSinceEpoch}',
      displayName: name,
      number: normalizedNumber,
      source: source,
      sourceId: sourceId,
      photoBytes: photoBytes,
      createdAt: DateTime.now(),
    );
    final next = [...current, entry];
    await ref.read(quickDialRepositoryProvider).saveEntries(next);
    state = AsyncData(next);
    return entry;
  }

  Future<QuickDialEntry> updateEntry({
    required String id,
    required String displayName,
    required String number,
    Uint8List? photoBytes,
    bool clearPhoto = false,
  }) async {
    final normalizedNumber = _normalizeNumber(number);
    if (normalizedNumber.isEmpty) {
      throw ArgumentError('Number is required');
    }
    final name = displayName.trim();
    if (name.isEmpty) {
      throw ArgumentError('Display name is required');
    }

    final current = [...(state.asData?.value ?? await future)];
    final index = current.indexWhere((entry) => entry.id == id);
    if (index < 0) {
      throw StateError('Quick dial entry not found');
    }
    if (current[index].source == QuickDialSource.directory) {
      throw StateError('Directory Quick Dial entries cannot be edited');
    }
    if (_hasNumber(current, normalizedNumber, excludingId: id)) {
      throw QuickDialDuplicateException(normalizedNumber);
    }

    final updated = current[index].copyWith(
      displayName: name,
      number: normalizedNumber,
      photoBytes: photoBytes,
      clearPhoto: clearPhoto,
    );
    current[index] = updated;
    await ref.read(quickDialRepositoryProvider).saveEntries(current);
    state = AsyncData(current);
    return updated;
  }

  Future<void> remove(String id) async {
    final current = [...(state.asData?.value ?? await future)];
    final next = current.where((entry) => entry.id != id).toList();
    await ref.read(quickDialRepositoryProvider).saveEntries(next);
    state = AsyncData(next);
  }

  /// Imports entries, skipping numbers that already exist.
  /// Returns how many were added and how many were skipped as duplicates.
  Future<({int added, int skipped})> importEntries(
    List<QuickDialEntry> incoming,
  ) async {
    if (incoming.isEmpty) {
      return (added: 0, skipped: 0);
    }

    final current = [...(state.asData?.value ?? await future)];
    final existingNumbers = {
      for (final entry in current) _normalizeNumber(entry.number),
    };

    var added = 0;
    var skipped = 0;
    final next = [...current];
    final stamp = DateTime.now().microsecondsSinceEpoch;

    for (var i = 0; i < incoming.length; i++) {
      final candidate = incoming[i];
      final number = _normalizeNumber(candidate.number);
      final name = candidate.displayName.trim();
      if (number.isEmpty || name.isEmpty) {
        skipped += 1;
        continue;
      }
      if (existingNumbers.contains(number)) {
        skipped += 1;
        continue;
      }
      existingNumbers.add(number);
      next.add(
        QuickDialEntry(
          id: 'qd-import-$stamp-$i',
          displayName: name,
          number: number,
          source: candidate.source,
          sourceId: candidate.sourceId,
          photoBytes: candidate.photoBytes,
          createdAt: DateTime.now().add(Duration(microseconds: i)),
        ),
      );
      added += 1;
    }

    if (added > 0) {
      final saved = await ref
          .read(quickDialRepositoryProvider)
          .saveEntries(next);
      state = AsyncData(saved);
    }
    return (added: added, skipped: skipped);
  }

  Future<void> clear() async {
    await ref.read(quickDialRepositoryProvider).clear();
    state = const AsyncData([]);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(quickDialRepositoryProvider).getEntries(),
    );
  }

  bool _hasNumber(
    List<QuickDialEntry> entries,
    String number, {
    String? excludingId,
  }) {
    return entries.any(
      (entry) =>
          entry.id != excludingId && _normalizeNumber(entry.number) == number,
    );
  }

  String _normalizeNumber(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), '');
  }
}
