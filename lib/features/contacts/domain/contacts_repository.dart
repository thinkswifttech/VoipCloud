import 'contact.dart';

abstract class ContactsRepository {
  Future<List<Contact>> getContacts();

  Future<Contact> addContact({
    required String displayName,
    required String phoneNumber,
    String? extension,
  });

  Future<Contact> updateContact({
    required String id,
    required String displayName,
    required String phoneNumber,
    String? extension,
  });

  Future<void> deleteContact(String id);
}
