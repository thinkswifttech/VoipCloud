class ProvisioningInput {
  const ProvisioningInput({
    required this.rawValue,
    this.backendToken,
    this.provisioningUri,
  });

  final String rawValue;
  final String? backendToken;
  final Uri? provisioningUri;

  bool get hasUsableValue => rawValue.trim().isNotEmpty;
}

ProvisioningInput? parseProvisioningInput(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.scheme == 'voipcloud' && uri.host == 'provision') {
    final token = uri.queryParameters['token']?.trim();
    final url = uri.queryParameters['url']?.trim();
    final provisioningUri = url == null ? null : Uri.tryParse(url);
    final backendToken = _backendTokenFromUri(uri);
    if ((token == null || token.isEmpty) && backendToken == null) {
      return null;
    }
    return ProvisioningInput(
      rawValue: token == null || token.isEmpty ? backendToken! : token,
      backendToken: backendToken,
      provisioningUri: _isHttpsProvisioningUri(provisioningUri)
          ? provisioningUri
          : null,
    );
  }

  if (_isHttpsProvisioningUri(uri)) {
    final httpsUri = uri!;
    return ProvisioningInput(
      rawValue: trimmed,
      backendToken: _backendTokenFromUri(httpsUri),
      provisioningUri: httpsUri,
    );
  }

  if (trimmed.contains('://') || (uri?.hasScheme ?? false)) {
    return null;
  }

  return ProvisioningInput(rawValue: trimmed, backendToken: trimmed);
}

bool isProvisioningActivationInput(String input) {
  return parseProvisioningInput(input) != null;
}

bool _isHttpsProvisioningUri(Uri? uri) {
  if (uri == null || uri.scheme != 'https') {
    return false;
  }
  return uri.host.isNotEmpty;
}

String? _backendTokenFromUri(Uri uri) {
  for (final key in const [
    'appSessionToken',
    'app_session_token',
    'backendToken',
    'backend_token',
    'appToken',
    'app_token',
  ]) {
    final value = uri.queryParameters[key]?.trim();
    if (value != null && value.isNotEmpty) {
      return value;
    }
  }
  return null;
}
