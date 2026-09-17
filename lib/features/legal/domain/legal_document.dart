class LegalDocument {
  const LegalDocument({
    required this.documentId,
    required this.version,
    required this.effectiveAt,
    required this.title,
    required this.sha256,
    required this.body,
  });

  final String documentId;
  final String version;
  final String effectiveAt;
  final String title;
  final String sha256;
  final String body;
}
