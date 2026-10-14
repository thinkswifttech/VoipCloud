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
  // Setup links and tokens never contain whitespace; a pasted link that was
  // wrapped across lines (or typed with a stray space) must still work.
  final trimmed = input.replaceAll(RegExp(r'\s+'), '');
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

/// Setup links must point at a host under this domain (any depth of
/// subdomain, never the domain itself). Build with
/// `--dart-define=PROVISIONING_ALLOWED_DOMAIN=` (empty) to allow any host,
/// for example against a local test server.
const provisioningAllowedDomain = String.fromEnvironment(
  'PROVISIONING_ALLOWED_DOMAIN',
  defaultValue: 'voipcloud.ca',
);

final RegExp _hostPattern = RegExp(
  r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$',
  caseSensitive: false,
);

/// Explains in plain words why [input] cannot be a setup link, or returns null
/// when it looks usable. This only checks the shape of the link on the device;
/// whether the server accepts it is reported after Activate.
String? provisioningInputProblem(
  String input, {
  String allowedDomain = provisioningAllowedDomain,
}) {
  final compact = input.replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty) {
    return 'Paste the setup link you were sent, or scan the QR code.';
  }
  final parsed = parseProvisioningInput(input);
  if (parsed == null) {
    if (compact.toLowerCase().startsWith('http://')) {
      return 'Setup links start with https://. Check the link you were sent.';
    }
    return "That doesn't look like a setup link. Paste the whole link you "
        'were sent, or scan the QR code.';
  }
  final uri = parsed.provisioningUri;
  if (uri == null) {
    return null;
  }
  if (!_hostPattern.hasMatch(uri.host)) {
    return "The web address in this link doesn't look right. Check it for "
        'typing mistakes, or scan the QR code instead.';
  }
  if (allowedDomain.isNotEmpty &&
      !uri.host.endsWith('.${allowedDomain.toLowerCase()}')) {
    return "This setup link isn't from VoipCloud. Check that you copied it "
        'correctly, or scan the QR code you were given.';
  }
  final hasPath = uri.pathSegments.any((segment) => segment.isNotEmpty);
  if (!hasPath && uri.query.isEmpty) {
    return 'This link looks incomplete. Make sure you copied all of it, or '
        'scan the QR code instead.';
  }
  return null;
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
