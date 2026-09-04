import '../../../core/errors/app_exception.dart';
import '../../../core/network/app_client.dart';
import '../domain/contact.dart';
import '../domain/contacts_repository.dart';

class ApiContactsRepository implements ContactsRepository {
  const ApiContactsRepository(this._client);

  final AppClient _client;

  @override
  Future<Contact> addContact({
    required String displayName,
    required String phoneNumber,
    String? extension,
  }) async {
    final response = await _client.post<Map<String, dynamic>>(
      '/api/v1/admin/users',
      data: {
        'displayName': displayName,
        'phoneNumber': phoneNumber,
        'extension': extension,
      },
    );
    final data = response.data;
    if (data == null) {
      throw const ApiException(
        statusCode: null,
        message: 'Missing added contact response',
      );
    }
    return _contactFromJson(data);
  }

  @override
  Future<Contact> updateContact({
    required String id,
    required String displayName,
    required String phoneNumber,
    String? extension,
  }) async {
    final response = await _client.put<Map<String, dynamic>>(
      '/api/v1/admin/users/$id',
      data: {
        'displayName': displayName,
        'phoneNumber': phoneNumber,
        'extension': extension,
      },
    );
    final data = response.data;
    if (data == null) {
      throw const ApiException(
        statusCode: null,
        message: 'Missing updated contact response',
      );
    }
    return _contactFromJson(data);
  }

  @override
  Future<void> deleteContact(String id) async {
    await _client.delete<void>('/api/v1/admin/users/$id');
  }

  @override
  Future<List<Contact>> getContacts() async {
    try {
      final response = await _client.get<Map<String, dynamic>>(
        '/api/v1/admin/users',
        queryParameters: const {
          'page': 0,
          'size': 100,
          'sort': 'displayName,asc',
        },
      );
      final content = response.data?['content'];
      if (content is! List) {
        return const [];
      }
      return content
          .whereType<Map>()
          .map((item) => _contactFromJson(Map<String, dynamic>.from(item)))
          .toList(growable: false);
    } on ApiException catch (error) {
      if (error.statusCode == 403) {
        return const [];
      }
      rethrow;
    }
  }

  Contact _contactFromJson(Map<String, dynamic> json) {
    final phoneNumber = _stringOrNull(json['phoneNumber']) ?? '';
    final extension = _stringOrNull(json['extension'])?.trim();
    return Contact(
      id: _requiredString(json, 'id'),
      displayName: _requiredString(json, 'displayName'),
      phoneNumber: phoneNumber,
      extension: extension == null || extension.isEmpty ? null : extension,
    );
  }

  String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    throw ApiException(statusCode: null, message: 'Missing "$key"');
  }

  String? _stringOrNull(Object? value) => value == null ? null : '$value';
}
