import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_exception.dart';
import '../domain/directory_access.dart';
import '../domain/directory_entry.dart';

final directoryRepositoryProvider = Provider<DirectoryRepository>((ref) {
  return DirectoryRepository();
});

class DirectoryRepository {
  DirectoryRepository({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 15),
            ),
          );

  final Dio _dio;

  Future<List<DirectoryEntry>> fetchDirectory(DirectoryAccess? access) async {
    if (access == null) {
      throw const AppException(
        message: 'Directory access was not provisioned',
        userMessage: 'Re-register the app to enable the company directory.',
      );
    }
    try {
      final response = await _dio.getUri<Object?>(
        access.endpoint,
        options: Options(
          responseType: ResponseType.json,
          headers: {'Authorization': 'Bearer ${access.token}'},
        ),
      );
      return parseDirectoryResponse(response.data);
    } on DioException catch (error) {
      throw AppException(
        message: 'Directory request failed: ${error.type.name}',
        userMessage: 'The company directory is temporarily unavailable.',
      );
    }
  }

  Future<void> revoke(DirectoryAccess access) async {
    try {
      await _dio.deleteUri<void>(
        access.endpoint,
        options: Options(headers: {'Authorization': 'Bearer ${access.token}'}),
      );
    } on DioException {
      // Local reset must complete even when the server is unreachable.
    }
  }
}

List<DirectoryEntry> parseDirectoryResponse(Object? body) {
  final raw = body is Map ? body['contacts'] : body;
  if (raw is! List) {
    throw const FormatException('Invalid directory response');
  }
  final parsed = raw
      .whereType<Map>()
      .map((item) => DirectoryEntry.fromJson(Map<String, dynamic>.from(item)))
      .toList(growable: false);

  // Some gateway versions flatten every <Telephone> element into a separate
  // JSON contact. Restore the source DirectoryEntry grouping so one person is
  // rendered once and exposes all of their dial targets in the number sheet.
  final grouped = <String, List<DirectoryEntry>>{};
  for (final entry in parsed) {
    grouped.putIfAbsent(_contactKey(entry), () => []).add(entry);
  }
  return grouped.values.map(_mergeContacts).toList(growable: false);
}

String _contactKey(DirectoryEntry entry) {
  final teams = entry.teams.map(_normalizedIdentityPart).toList()..sort();
  return [
    entry.telephoneKind.name,
    _normalizedIdentityPart(entry.displayName),
    _normalizedIdentityPart(entry.company),
    teams.join('\u0001'),
  ].join('\u0000');
}

String _normalizedIdentityPart(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

DirectoryEntry _mergeContacts(List<DirectoryEntry> contacts) {
  final first = contacts.first;
  final seen = <String>{};
  final numbers = <String>[
    for (final contact in contacts)
      for (final number in contact.numbers)
        if (seen.add(number.trim())) number.trim(),
  ];
  final seenTeams = <String>{};
  final teams = <String>[
    for (final contact in contacts)
      for (final team in contact.teams)
        if (team.trim().isNotEmpty && seenTeams.add(team.trim().toLowerCase()))
          team.trim(),
  ];

  // For company entries, make a PBX-style short extension the primary dial
  // target even if the gateway happened to return a public number first.
  if (first.isCompany) {
    numbers.sort((left, right) {
      final leftIsExtension = RegExp(r'^\d{2,8}$').hasMatch(left);
      final rightIsExtension = RegExp(r'^\d{2,8}$').hasMatch(right);
      if (leftIsExtension == rightIsExtension) return 0;
      return leftIsExtension ? -1 : 1;
    });
  }

  return DirectoryEntry(
    id: first.id,
    displayName: first.displayName,
    numbers: numbers,
    company: first.company,
    teams: teams,
    telephoneKind: first.telephoneKind,
    presence: _mergedPresence(contacts),
    deviceRegistered: _mergedRegistration(contacts),
  );
}

bool? _mergedRegistration(List<DirectoryEntry> contacts) {
  final states = contacts
      .map((entry) => entry.deviceRegistered)
      .whereType<bool>()
      .toSet();
  if (states.contains(true)) return true;
  if (states.contains(false)) return false;
  return null;
}

DirectoryPresence _mergedPresence(List<DirectoryEntry> contacts) {
  final states = contacts.map((entry) => entry.presence).toSet();
  for (final state in const [
    DirectoryPresence.ringing,
    DirectoryPresence.busy,
    DirectoryPresence.available,
    DirectoryPresence.unregistered,
  ]) {
    if (states.contains(state)) return state;
  }
  return DirectoryPresence.unknown;
}
