import 'dart:convert';

import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../domain/contact.dart';
import '../domain/contacts_repository.dart';

class LocalContactsRepository implements ContactsRepository {
  const LocalContactsRepository(this._storage);

  final SecureStorageService _storage;

  @override
  Future<List<Contact>> getContacts() async {
    final raw = await _storage.read(StorageKeys.appContacts);
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const [];
    }
    final contacts =
        decoded
            .whereType<Map>()
            .map((item) => Contact.fromJson(Map<String, dynamic>.from(item)))
            .where(
              (item) =>
                  item.displayName.isNotEmpty ||
                  item.phoneNumber.isNotEmpty ||
                  item.extension?.isNotEmpty == true,
            )
            .toList()
          ..sort(
            (a, b) => a.displayName.toLowerCase().compareTo(
              b.displayName.toLowerCase(),
            ),
          );
    return contacts;
  }

  @override
  Future<Contact> addContact({
    required String displayName,
    required String phoneNumber,
    String? extension,
  }) async {
    final normalized = _normalizeContactInput(
      displayName: displayName,
      phoneNumber: phoneNumber,
      extension: extension,
    );
    final existing = await getContacts();
    _ensureUnique(existing, normalized);
    final contact = Contact(
      id: 'contact-${DateTime.now().microsecondsSinceEpoch}',
      displayName: normalized.displayName,
      phoneNumber: normalized.phoneNumber,
      extension: normalized.extension,
    );
    final contacts = [contact, ...existing]..sort(_sortContacts);
    await _storage.write(
      StorageKeys.appContacts,
      jsonEncode(contacts.map((item) => item.toJson()).toList()),
    );
    return contact;
  }

  @override
  Future<Contact> updateContact({
    required String id,
    required String displayName,
    required String phoneNumber,
    String? extension,
  }) async {
    final normalized = _normalizeContactInput(
      displayName: displayName,
      phoneNumber: phoneNumber,
      extension: extension,
    );
    final contacts = await getContacts();
    final index = contacts.indexWhere((item) => item.id == id);
    if (index < 0) {
      throw ArgumentError('Contact was not found.');
    }
    _ensureUnique(contacts, normalized, ignoredId: id);
    final updated = Contact(
      id: id,
      displayName: normalized.displayName,
      phoneNumber: normalized.phoneNumber,
      extension: normalized.extension,
    );
    contacts[index] = updated;
    contacts.sort(_sortContacts);
    await _storage.write(
      StorageKeys.appContacts,
      jsonEncode(contacts.map((item) => item.toJson()).toList()),
    );
    return updated;
  }

  @override
  Future<void> deleteContact(String id) async {
    final contacts = await getContacts();
    final updated = contacts.where((item) => item.id != id).toList();
    await _storage.write(
      StorageKeys.appContacts,
      jsonEncode(updated.map((item) => item.toJson()).toList()),
    );
  }
}

typedef _NormalizedContactInput = ({
  String displayName,
  String phoneNumber,
  String? extension,
});

_NormalizedContactInput _normalizeContactInput({
  required String displayName,
  required String phoneNumber,
  String? extension,
}) {
  final name = displayName.trim();
  final number = phoneNumber.trim();
  final trimmedExtension = extension?.trim() ?? '';
  if (name.isEmpty || (number.isEmpty && trimmedExtension.isEmpty)) {
    throw ArgumentError('Contact name and a number or extension are required.');
  }
  return (
    displayName: name,
    phoneNumber: number,
    extension: trimmedExtension.isEmpty ? null : trimmedExtension,
  );
}

void _ensureUnique(
  List<Contact> contacts,
  _NormalizedContactInput input, {
  String? ignoredId,
}) {
  final number = input.phoneNumber.toLowerCase();
  final extension = input.extension?.toLowerCase() ?? '';
  final duplicate = contacts.any((contact) {
    if (contact.id == ignoredId) {
      return false;
    }
    final sameNumber =
        number.isNotEmpty && contact.phoneNumber.toLowerCase() == number;
    final sameExtension =
        extension.isNotEmpty && contact.extension?.toLowerCase() == extension;
    return sameNumber || sameExtension;
  });
  if (duplicate) {
    throw ArgumentError(
      'A contact with this phone number or extension already exists.',
    );
  }
}

int _sortContacts(Contact a, Contact b) {
  return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
}
