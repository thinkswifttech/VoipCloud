class DeviceCredential {
  const DeviceCredential({required this.revokeEndpoint, required this.token});

  factory DeviceCredential.fromJson(Map<String, dynamic> json) {
    final rawEndpoint =
        '${json['revokeEndpoint'] ?? json['revoke_endpoint'] ?? ''}'.trim();
    final endpoint = Uri.tryParse(rawEndpoint);
    final token = '${json['token'] ?? ''}'.trim();
    if (endpoint == null ||
        endpoint.scheme.toLowerCase() != 'https' ||
        endpoint.host.isEmpty ||
        token.isEmpty) {
      throw const FormatException('Invalid device credential');
    }
    return DeviceCredential(revokeEndpoint: endpoint, token: token);
  }

  final Uri revokeEndpoint;
  final String token;

  Map<String, dynamic> toJson() => {
    'revokeEndpoint': revokeEndpoint.toString(),
    'token': token,
  };
}
