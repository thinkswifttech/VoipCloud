import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/config_providers.dart';

enum DesktopUpdatePlatform {
  windowsX64('windows-x64'),
  macosUniversal('macos-universal');

  const DesktopUpdatePlatform(this.manifestKey);

  final String manifestKey;

  static DesktopUpdatePlatform? get current {
    if (Platform.isWindows) return DesktopUpdatePlatform.windowsX64;
    if (Platform.isMacOS) return DesktopUpdatePlatform.macosUniversal;
    return null;
  }
}

class DesktopRelease {
  const DesktopRelease({
    required this.version,
    required this.build,
    required this.downloadUri,
    required this.sha256,
    required this.releaseNotes,
  });

  factory DesktopRelease.fromJson(
    Map<String, dynamic> json, {
    required Uri manifestUri,
  }) {
    final version = json['version'];
    final build = json['build'];
    final downloadUri = Uri.tryParse(json['url']?.toString() ?? '');
    final sha256 = json['sha256']?.toString().toLowerCase() ?? '';
    final releaseNotes = json['release_notes']?.toString() ?? '';

    if (version is! String || !_versionPattern.hasMatch(version)) {
      throw const FormatException('Invalid desktop release version.');
    }
    if (build is! int || build < 1) {
      throw const FormatException('Invalid desktop release build.');
    }
    if (downloadUri == null ||
        downloadUri.scheme != 'https' ||
        downloadUri.host != manifestUri.host ||
        downloadUri.hasFragment ||
        downloadUri.userInfo.isNotEmpty) {
      throw const FormatException('Untrusted desktop release URL.');
    }
    if (!_sha256Pattern.hasMatch(sha256)) {
      throw const FormatException('Invalid desktop release checksum.');
    }

    return DesktopRelease(
      version: version,
      build: build,
      downloadUri: downloadUri,
      sha256: sha256,
      releaseNotes: releaseNotes,
    );
  }

  final String version;
  final int build;
  final Uri downloadUri;
  final String sha256;
  final String releaseNotes;

  static final RegExp _versionPattern = RegExp(r'^\d+\.\d+\.\d+$');
  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
}

enum DesktopUpdateStatus { unsupported, notConfigured, upToDate, available }

class DesktopUpdateResult {
  const DesktopUpdateResult._(this.status, {this.release});

  const DesktopUpdateResult.unsupported()
    : this._(DesktopUpdateStatus.unsupported);
  const DesktopUpdateResult.notConfigured()
    : this._(DesktopUpdateStatus.notConfigured);
  const DesktopUpdateResult.upToDate() : this._(DesktopUpdateStatus.upToDate);
  const DesktopUpdateResult.available(DesktopRelease release)
    : this._(DesktopUpdateStatus.available, release: release);

  final DesktopUpdateStatus status;
  final DesktopRelease? release;
}

class DesktopUpdateService {
  DesktopUpdateService({
    required Uri? manifestUri,
    Dio? dio,
    Future<PackageInfo> Function()? packageInfoLoader,
    DesktopUpdatePlatform? platform,
  }) : _manifestUri = manifestUri,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 15),
               headers: const {Headers.acceptHeader: Headers.jsonContentType},
             ),
           ),
       _packageInfoLoader = packageInfoLoader ?? PackageInfo.fromPlatform,
       _platform = platform ?? DesktopUpdatePlatform.current;

  final Uri? _manifestUri;
  final Dio _dio;
  final Future<PackageInfo> Function() _packageInfoLoader;
  final DesktopUpdatePlatform? _platform;

  Future<DesktopUpdateResult> check() async {
    final platform = _platform;
    if (platform == null) return const DesktopUpdateResult.unsupported();

    final manifestUri = _manifestUri;
    if (manifestUri == null) return const DesktopUpdateResult.notConfigured();

    final response = await _dio.getUri<dynamic>(manifestUri);
    final json = response.data;
    if (json is! Map || json['schema_version'] != 1) {
      throw const FormatException('Unsupported desktop update manifest.');
    }
    final releases = json['releases'];
    final releaseJson = releases is Map ? releases[platform.manifestKey] : null;
    if (releaseJson is! Map) {
      throw const FormatException('Desktop release is missing.');
    }
    final release = DesktopRelease.fromJson(
      Map<String, dynamic>.from(releaseJson),
      manifestUri: manifestUri,
    );
    final current = await _packageInfoLoader();
    final currentBuild = int.tryParse(current.buildNumber);
    final hasUpdate = currentBuild != null
        ? release.build > currentBuild
        : _compareVersions(release.version, current.version) > 0;
    return hasUpdate
        ? DesktopUpdateResult.available(release)
        : const DesktopUpdateResult.upToDate();
  }

  static int _compareVersions(String left, String right) {
    final leftParts = left.split('.').map(int.parse).toList();
    final rightParts = right.split('.').map(int.tryParse).toList();
    for (var index = 0; index < 3; index++) {
      final rightPart = index < rightParts.length ? rightParts[index] ?? 0 : 0;
      final difference = leftParts[index] - rightPart;
      if (difference != 0) return difference;
    }
    return 0;
  }
}

final desktopUpdateServiceProvider = Provider<DesktopUpdateService>((ref) {
  final config = ref.watch(appConfigProvider);
  return DesktopUpdateService(manifestUri: config.desktopUpdateManifestUri);
});

final desktopUpdateProvider =
    AsyncNotifierProvider<DesktopUpdateController, DesktopUpdateResult>(
      DesktopUpdateController.new,
    );

class DesktopUpdateController extends AsyncNotifier<DesktopUpdateResult> {
  @override
  Future<DesktopUpdateResult> build() {
    // Watching this provider at application startup performs one quiet check.
    // Failures remain available to Settings without interrupting app startup.
    return ref.watch(desktopUpdateServiceProvider).check();
  }

  Future<void> check() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(desktopUpdateServiceProvider).check(),
    );
  }
}

final desktopUpdateLauncherProvider = Provider<Future<bool> Function(Uri)>((
  ref,
) {
  return (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
});
