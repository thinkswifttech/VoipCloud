import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as native;

import '../domain/contact.dart';
import '../domain/contact_number_eligibility.dart';

class ContactsAccessException implements Exception {
  const ContactsAccessException({required this.canOpenSettings});

  final bool canOpenSettings;
}

class UnsupportedContactsPlatformException implements Exception {
  const UnsupportedContactsPlatformException();
}

bool isDeviceContactsSupported({bool? web, TargetPlatform? platform}) {
  if (web ?? kIsWeb) return false;
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux ||
    TargetPlatform.fuchsia => false,
  };
}

class DeviceContactsRepository {
  const DeviceContactsRepository();

  bool get isSupported => isDeviceContactsSupported();

  Stream<void> get changes => isSupported
      ? native.FlutterContacts.onDatabaseChange.map<void>((_) {})
      : const Stream<void>.empty();

  Future<List<Contact>> getContactSummaries({int? limit}) async {
    await _ensureReadPermission();
    // Keep the first paint light: skip photos here and hydrate thumbnails
    // asynchronously after the list is on screen.
    final contacts = await native.FlutterContacts.getAll(
      properties: const {
        native.ContactProperty.name,
        native.ContactProperty.phone,
        native.ContactProperty.organization,
      },
      limit: limit,
    );
    return [
      for (final contact in contacts)
        _mapSummary(contact, canCommunicate: false),
    ]..sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );
  }

  Future<List<Contact>> enrichCommunicationEligibility(
    List<Contact> contacts,
  ) async {
    final numberLists = contacts
        .map(
          (contact) => contact.dialablePhones
              .map((phone) => phone.number)
              .toList(growable: false),
        )
        .toList(growable: false);
    final eligibility = await compute(_contactNumbersEligibility, numberLists);
    return [
      for (var index = 0; index < contacts.length; index++)
        contacts[index].copyWith(canCommunicate: eligibility[index]),
    ];
  }

  Future<List<Contact>> enrichPhotos(
    List<Contact> contacts, {
    Iterable<String>? onlyIds,
  }) async {
    if (contacts.isEmpty) return contacts;
    final idFilter = onlyIds?.toSet();
    final targets = [
      for (final contact in contacts)
        if (contact.photo == null &&
            contact.id.isNotEmpty &&
            (idFilter == null || idFilter.contains(contact.id)))
          contact.id,
    ];
    if (targets.isEmpty) return contacts;

    await _ensureReadPermission();
    final photosById = <String, Uint8List>{};
    const batchSize = 100;
    for (var start = 0; start < targets.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, targets.length);
      final batch = targets.sublist(start, end);
      final withPhotos = await native.FlutterContacts.getAll(
        properties: const {native.ContactProperty.photoThumbnail},
        filter: native.ContactFilter.ids(batch),
      );
      for (final contact in withPhotos) {
        final id = contact.id ?? '';
        final thumbnail = contact.photo?.thumbnail;
        if (id.isNotEmpty && thumbnail != null) {
          photosById[id] = thumbnail;
        }
      }
    }
    if (photosById.isEmpty) return contacts;
    return [
      for (final contact in contacts)
        photosById.containsKey(contact.id)
            ? contact.copyWith(photo: photosById[contact.id])
            : contact,
    ];
  }

  Future<List<Contact>> getContacts({int? limit}) async {
    final contacts = await getContactSummaries(limit: limit);
    final withEligibility = await enrichCommunicationEligibility(contacts);
    return enrichPhotos(withEligibility);
  }

  Future<Contact?> getContact(String id) async {
    await _ensureReadPermission();
    final contact = await native.FlutterContacts.get(
      id,
      properties: {
        ...native.ContactProperties.allProperties,
        native.ContactProperty.photoFullRes,
        native.ContactProperty.photoThumbnail,
      },
    );
    return contact == null ? null : _mapContact(contact);
  }

  Future<String?> openNativeContactCreator({
    String? displayName,
    String? phoneNumber,
  }) async {
    _ensureMobilePlatform();
    final normalizedName = displayName?.trim() ?? '';
    final normalizedNumber = phoneNumber?.trim() ?? '';
    final nameParts = normalizedName
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    final prefill = normalizedName.isEmpty && normalizedNumber.isEmpty
        ? null
        : native.Contact(
            displayName: normalizedName.isEmpty ? null : normalizedName,
            name: nameParts.isEmpty
                ? null
                : native.Name(
                    first: nameParts.first,
                    last: nameParts.length > 1
                        ? nameParts.sublist(1).join(' ')
                        : null,
                  ),
            phones: normalizedNumber.isEmpty
                ? const []
                : [native.Phone(number: normalizedNumber, isPrimary: true)],
          );
    return native.FlutterContacts.native.showCreator(contact: prefill);
  }

  Future<String?> openNativeContactEditor(String id) async {
    _ensureMobilePlatform();
    return native.FlutterContacts.native.showEditor(id);
  }

  Future<void> openSettings() =>
      native.FlutterContacts.permissions.openSettings();

  Future<void> _ensureReadPermission() async {
    _ensureMobilePlatform();
    var status = await native.FlutterContacts.permissions.check(
      native.PermissionType.read,
    );
    if (status == native.PermissionStatus.notDetermined ||
        status == native.PermissionStatus.denied) {
      status = await native.FlutterContacts.permissions.request(
        native.PermissionType.read,
      );
    }
    if (status == native.PermissionStatus.granted ||
        status == native.PermissionStatus.limited) {
      return;
    }
    throw ContactsAccessException(
      canOpenSettings:
          status == native.PermissionStatus.permanentlyDenied ||
          status == native.PermissionStatus.restricted,
    );
  }

  void _ensureMobilePlatform() {
    if (!isSupported) {
      throw const UnsupportedContactsPlatformException();
    }
  }

  Contact _mapSummary(native.Contact contact, {bool? canCommunicate}) {
    final phones = _mapPhones(contact.phones);
    final primaryPhone = _primaryPhone(contact.phones);
    final company = contact.organizations
        .map((organization) => organization.name?.trim() ?? '')
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    return Contact(
      id: contact.id ?? '',
      displayName: _displayName(contact),
      phoneNumber: primaryPhone,
      // List rows use thumbnails only (hydrated via enrichPhotos).
      photo: contact.photo?.thumbnail,
      company: company.isEmpty ? null : company,
      firstName: _nullable(contact.name?.first),
      lastName: _nullable(contact.name?.last),
      canCommunicate:
          canCommunicate ??
          phones.any((phone) => isUsOrCanadianNumber(phone.number)),
      phones: phones,
    );
  }

  Contact _mapContact(native.Contact contact) {
    final summary = _mapSummary(contact);
    return Contact(
      id: summary.id,
      displayName: summary.displayName,
      phoneNumber: summary.phoneNumber,
      // Details prefer full-resolution when available.
      photo: contact.photo?.fullSize ?? contact.photo?.thumbnail,
      company: summary.company,
      firstName: summary.firstName,
      lastName: summary.lastName,
      canCommunicate: summary.canCommunicate,
      phones: summary.phones,
      details: [
        _section('Name', _nameItems(contact.name)),
        _section(
          'Phone numbers',
          _mapPhones(
            contact.phones,
          ).map((phone) => _item(phone.label, phone.number)).toList(),
        ),
        _section(
          'Email addresses',
          contact.emails
              .map((email) => _item(_label(email.label), email.address))
              .toList(),
        ),
        _section(
          'Addresses',
          contact.addresses
              .map(
                (address) => _item(
                  _label(address.label),
                  address.formatted ??
                      _join([
                        address.street,
                        address.city,
                        address.state,
                        address.postalCode,
                        address.country,
                      ]),
                ),
              )
              .toList(),
        ),
        _section(
          'Work',
          contact.organizations.expand(_organizationItems).toList(),
        ),
        _section(
          'Websites',
          contact.websites
              .map((website) => _item(_label(website.label), website.url))
              .toList(),
        ),
        _section(
          'Social profiles',
          contact.socialMedias
              .map((social) => _item(_label(social.label), social.username))
              .toList(),
        ),
        _section(
          'Dates',
          contact.events.map((event) {
            final year = event.year == null ? '' : '${event.year}-';
            final month = event.month.toString().padLeft(2, '0');
            final day = event.day.toString().padLeft(2, '0');
            return _item(_label(event.label), '$year$month-$day');
          }).toList(),
        ),
        _section(
          'Relationships',
          contact.relations
              .map((relation) => _item(_label(relation.label), relation.name))
              .toList(),
        ),
        _section(
          'Notes',
          contact.notes.map((note) => _item('Note', note.note)).toList(),
        ),
      ].where((section) => section.items.isNotEmpty).toList(),
    );
  }

  List<ContactDetailItem> _nameItems(native.Name? name) {
    if (name == null) return const [];
    return [
      _item('Prefix', name.prefix ?? ''),
      _item('First name', name.first ?? ''),
      _item('Middle name', name.middle ?? ''),
      _item('Last name', name.last ?? ''),
      _item('Suffix', name.suffix ?? ''),
      _item('Nickname', name.nickname ?? ''),
      _item('Phonetic first name', name.phoneticFirst ?? ''),
      _item('Phonetic middle name', name.phoneticMiddle ?? ''),
      _item('Phonetic last name', name.phoneticLast ?? ''),
    ].where((item) => item.value.isNotEmpty).toList();
  }

  Iterable<ContactDetailItem> _organizationItems(
    native.Organization organization,
  ) => [
    _item('Company', organization.name ?? ''),
    _item('Job title', organization.jobTitle ?? ''),
    _item('Department', organization.departmentName ?? ''),
    _item('Office', organization.officeLocation ?? ''),
    _item('Role', organization.jobDescription ?? ''),
  ].where((item) => item.value.isNotEmpty);

  ContactDetailSection _section(String title, List<ContactDetailItem> items) =>
      ContactDetailSection(
        title: title,
        items: items.where((item) => item.value.trim().isNotEmpty).toList(),
      );

  ContactDetailItem _item(String label, String value) =>
      ContactDetailItem(label: label, value: value.trim());

  String _displayName(native.Contact contact) {
    final displayName = contact.displayName?.trim() ?? '';
    if (displayName.isNotEmpty) return displayName;
    final number = _primaryPhone(contact.phones);
    return number.isEmpty ? 'Unnamed contact' : number;
  }

  String _primaryPhone(List<native.Phone> phones) {
    if (phones.isEmpty) return '';
    return phones
        .firstWhere(
          (phone) => phone.isPrimary == true,
          orElse: () => phones.first,
        )
        .number
        .trim();
  }

  List<ContactPhone> _mapPhones(List<native.Phone> phones) {
    final seen = <String>{};
    final mapped = <ContactPhone>[];
    for (final phone in phones) {
      final number = phone.number.trim();
      if (number.isEmpty || !seen.add(number)) {
        continue;
      }
      mapped.add(ContactPhone(number: number, label: _label(phone.label)));
    }
    return mapped;
  }

  String _label<T extends Enum>(native.Label<T> label) {
    final custom = label.customLabel?.trim() ?? '';
    if (custom.isNotEmpty) return custom;
    final words = label.label.name.replaceAllMapped(
      RegExp(r'([a-z])([A-Z])'),
      (match) => '${match.group(1)} ${match.group(2)}',
    );
    return '${words[0].toUpperCase()}${words.substring(1)}';
  }

  String _join(List<String?> values) => values
      .map((value) => value?.trim() ?? '')
      .where((value) => value.isNotEmpty)
      .join(', ');

  String? _nullable(String? value) {
    final text = value?.trim() ?? '';
    return text.isEmpty ? null : text;
  }
}

List<bool> _contactNumbersEligibility(List<List<String>> numberLists) {
  return [for (final numbers in numberLists) numbers.any(isUsOrCanadianNumber)];
}
