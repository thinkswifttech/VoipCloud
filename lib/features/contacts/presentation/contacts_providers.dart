import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/storage_providers.dart';
import '../data/device_contacts_repository.dart';
import '../data/local_contacts_repository.dart';
import '../domain/contact.dart';
import '../domain/contacts_repository.dart';

final contactsRepositoryProvider = Provider<ContactsRepository>((ref) {
  return LocalContactsRepository(ref.watch(secureStorageProvider));
});

final deviceContactsRepositoryProvider = Provider<DeviceContactsRepository>(
  (_) => const DeviceContactsRepository(),
);

final contactsProvider =
    AsyncNotifierProvider<ContactsController, List<Contact>>(
      ContactsController.new,
    );

class ContactsController extends AsyncNotifier<List<Contact>> {
  Timer? _changesDebounce;
  var _generation = 0;
  var _disposed = false;

  @override
  Future<List<Contact>> build() async {
    final repository = ref.watch(deviceContactsRepositoryProvider);
    final subscription = repository.changes.listen((_) {
      _changesDebounce?.cancel();
      _changesDebounce = Timer(
        const Duration(milliseconds: 400),
        () => unawaited(refresh()),
      );
    });
    ref.onDispose(() {
      _disposed = true;
      _changesDebounce?.cancel();
      unawaited(subscription.cancel());
    });
    final generation = ++_generation;
    // Full lightweight list first so the alphabet index is complete. Photos and
    // eligibility hydrate afterward so the first paint is not blocked.
    final contacts = await repository.getContactSummaries();
    Timer.run(() => unawaited(_enrich(contacts, generation)));
    return contacts;
  }

  Future<String?> addContact({
    String? displayName,
    String? phoneNumber,
    String? extension,
  }) async {
    final createdId = await ref
        .read(deviceContactsRepositoryProvider)
        .openNativeContactCreator(
          displayName: displayName,
          phoneNumber: phoneNumber,
        );
    if (createdId != null) await refresh();
    return createdId;
  }

  Future<Contact> updateContact({
    required String id,
    required String displayName,
    required String phoneNumber,
    String? extension,
  }) async {
    final contact = await ref
        .read(contactsRepositoryProvider)
        .updateContact(
          id: id,
          displayName: displayName,
          phoneNumber: phoneNumber,
          extension: extension,
        );
    final current = state.asData?.value ?? const <Contact>[];
    state = AsyncData(
      [contact, ...current.where((item) => item.id != contact.id)]..sort(
        (a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
      ),
    );
    return contact;
  }

  Future<void> deleteContact(String id) async {
    await ref.read(contactsRepositoryProvider).deleteContact(id);
    final current = state.asData?.value ?? const <Contact>[];
    state = AsyncData(current.where((item) => item.id != id).toList());
  }

  Future<void> refresh() async {
    final generation = ++_generation;
    final repository = ref.read(deviceContactsRepositoryProvider);
    try {
      final contacts = await repository.getContactSummaries();
      if (_disposed || generation != _generation) return;
      state = AsyncData(contacts);
      await _enrich(contacts, generation);
    } catch (error, stackTrace) {
      if (_disposed || generation != _generation) return;
      state = AsyncError(error, stackTrace);
    }
  }

  Future<void> _enrich(List<Contact> contacts, int generation) async {
    try {
      final withEligibility = await ref
          .read(deviceContactsRepositoryProvider)
          .enrichCommunicationEligibility(contacts);
      if (_disposed || generation != _generation) return;
      state = AsyncData(withEligibility);

      final withPhotos = await ref
          .read(deviceContactsRepositoryProvider)
          .enrichPhotos(withEligibility);
      if (_disposed || generation != _generation) return;
      state = AsyncData(withPhotos);
    } catch (_) {
      // The lightweight contact list remains usable even if optional number
      // classification or photo hydration fails.
    }
  }

  Future<Contact?> getContact(String id) =>
      ref.read(deviceContactsRepositoryProvider).getContact(id);

  Future<String?> editContact(String id) async {
    final result = await ref
        .read(deviceContactsRepositoryProvider)
        .openNativeContactEditor(id);
    // Always refresh after the editor closes so list/details reflect edits.
    await refresh();
    return result;
  }

  Future<void> openSettings() =>
      ref.read(deviceContactsRepositoryProvider).openSettings();
}
