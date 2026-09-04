import 'dart:typed_data';

class ContactPhone {
  const ContactPhone({required this.number, this.label = 'Phone'});

  final String number;
  final String label;
}

class Contact {
  const Contact({
    required this.id,
    required this.displayName,
    required this.phoneNumber,
    this.extension,
    this.photo,
    this.company,
    this.firstName,
    this.lastName,
    this.canCommunicate = false,
    this.phones = const [],
    this.details = const [],
  });

  final String id;
  final String displayName;
  final String phoneNumber;
  final String? extension;
  final Uint8List? photo;
  final String? company;
  final String? firstName;
  final String? lastName;
  final bool canCommunicate;
  final List<ContactPhone> phones;
  final List<ContactDetailSection> details;

  List<ContactPhone> get dialablePhones {
    if (phones.isNotEmpty) {
      return phones
          .where((phone) => phone.number.trim().isNotEmpty)
          .toList(growable: false);
    }
    final primary = phoneNumber.trim();
    if (primary.isEmpty) {
      return const [];
    }
    return [ContactPhone(number: primary)];
  }

  Contact copyWith({
    bool? canCommunicate,
    Uint8List? photo,
    bool clearPhoto = false,
    List<ContactPhone>? phones,
    String? displayName,
    String? phoneNumber,
    String? company,
    String? firstName,
    String? lastName,
    List<ContactDetailSection>? details,
  }) {
    return Contact(
      id: id,
      displayName: displayName ?? this.displayName,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      extension: extension,
      photo: clearPhoto ? null : photo ?? this.photo,
      company: company ?? this.company,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      canCommunicate: canCommunicate ?? this.canCommunicate,
      phones: phones ?? this.phones,
      details: details ?? this.details,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'displayName': displayName,
      'phoneNumber': phoneNumber,
      'extension': extension,
      'company': company,
      'firstName': firstName,
      'lastName': lastName,
      'canCommunicate': canCommunicate,
    };
  }

  factory Contact.fromJson(Map<String, dynamic> json) {
    return Contact(
      id: _string(
        json['id'],
        fallback: 'contact-${DateTime.now().microsecondsSinceEpoch}',
      ),
      displayName: _string(json['displayName']),
      phoneNumber: _string(json['phoneNumber']),
      extension: _nullableString(json['extension']),
      company: _nullableString(json['company']),
      firstName: _nullableString(json['firstName']),
      lastName: _nullableString(json['lastName']),
      canCommunicate: json['canCommunicate'] == true,
    );
  }
}

class ContactDetailSection {
  const ContactDetailSection({required this.title, required this.items});

  final String title;
  final List<ContactDetailItem> items;
}

class ContactDetailItem {
  const ContactDetailItem({required this.label, required this.value});

  final String label;
  final String value;
}

String _string(Object? value, {String fallback = ''}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

String? _nullableString(Object? value) {
  final text = _string(value);
  return text.isEmpty ? null : text;
}
