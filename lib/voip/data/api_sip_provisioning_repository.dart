import '../../core/config/sip_transport.dart';
import '../../core/errors/app_exception.dart';
import '../../core/network/app_client.dart';
import '../domain/sip_account.dart';
import '../domain/sip_provisioning_repository.dart';

class ApiSipProvisioningRepository implements SipProvisioningRepository {
  const ApiSipProvisioningRepository(this._client);

  final AppClient _client;

  @override
  Future<SipAccount?> getSipAccount() async {
    try {
      final response = await _client.get<Map<String, dynamic>>(
        '/api/v1/sip/account',
      );
      final data = response.data;
      if (data == null || data['enabled'] == false) {
        return null;
      }
      return SipAccount(
        username: _requiredString(data, 'sipUsername'),
        authUsername: _stringOrNull(data['sipAuthUsername']),
        password: _stringOrNull(data['sipPassword']),
        domain: _requiredString(data, 'sipDomain'),
        proxyHost: _requiredString(data, 'proxyHost'),
        transport: SipTransport.parse(_stringOrNull(data['transport']) ?? ''),
        extension: _stringOrNull(data['sipUsername']),
        stunServer: _stringOrNull(data['stunServer']),
      );
    } on ApiException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 403) {
        return null;
      }
      rethrow;
    }
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
