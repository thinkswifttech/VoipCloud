class DirectoryAccess {
  const DirectoryAccess({required this.endpoint, required this.token});

  factory DirectoryAccess.fromJson(Map<String, dynamic> json) {
    final rawEndpoint = '${json['endpoint'] ?? json['url'] ?? ''}'.trim();
    final endpoint = Uri.tryParse(rawEndpoint);
    final token = '${json['token'] ?? ''}'.trim();
    if (endpoint == null ||
        endpoint.scheme.toLowerCase() != 'https' ||
        endpoint.host.isEmpty ||
        token.isEmpty) {
      throw const FormatException('Invalid directory access configuration');
    }
    return DirectoryAccess(endpoint: endpoint, token: token);
  }

  final Uri endpoint;
  final String token;

  Map<String, dynamic> toJson() => {
    'endpoint': endpoint.toString(),
    'token': token,
  };
}
