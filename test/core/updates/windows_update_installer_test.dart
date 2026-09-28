import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/updates/desktop_update.dart';
import 'package:phone_app/core/updates/windows_update_installer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  const channel = MethodChannel('voipcloud/windows_update_test');
  MethodCall? lastCall;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('voipcloud-update-test-');
    lastCall = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          lastCall = call;
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  DesktopRelease releaseFor(List<int> bytes) => DesktopRelease(
    version: '1.0.1',
    build: 33,
    downloadUri: Uri.parse(
      'https://updates.example.test/desktop/'
      'VoipCloud-1.0.1+33-windows-x64.msi',
    ),
    sha256: sha256.convert(bytes).toString(),
    releaseNotes: '',
  );

  test('verified cached installer is handed to native updater', () async {
    const bytes = [1, 2, 3, 4];
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      'VoipCloud-1.0.1+33-windows-x64.msi',
    );
    await file.writeAsBytes(bytes);

    await WindowsUpdateInstaller(
      channel: channel,
      cacheDirectory: directory,
      isWindows: true,
    ).install(releaseFor(bytes));

    expect(lastCall?.method, 'install');
    expect((lastCall?.arguments as Map)['path'], file.path);
    expect(
      (lastCall?.arguments as Map)['sha256'],
      sha256.convert(bytes).toString(),
    );
  });

  test('active call prevents installer handoff', () async {
    const bytes = [1, 2, 3, 4];
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      'VoipCloud-1.0.1+33-windows-x64.msi',
    );
    await file.writeAsBytes(bytes);

    await expectLater(
      WindowsUpdateInstaller(
        channel: channel,
        cacheDirectory: directory,
        isWindows: true,
      ).install(releaseFor(bytes), canInstall: () async => false),
      throwsStateError,
    );
    expect(lastCall, isNull);
  });

  test('downloaded installer is checked before native handoff', () async {
    const bytes = [1, 2, 3, 4];
    final dio = Dio()..httpClientAdapter = _BytesAdapter(bytes);
    await WindowsUpdateInstaller(
      dio: dio,
      channel: channel,
      cacheDirectory: directory,
      isWindows: true,
    ).install(releaseFor(bytes));

    expect(lastCall?.method, 'install');
    expect(
      await File(
        '${directory.path}${Platform.pathSeparator}'
        'VoipCloud-1.0.1+33-windows-x64.msi',
      ).readAsBytes(),
      bytes,
    );
  });

  test('checksum mismatch never reaches native installer', () async {
    final dio = Dio()..httpClientAdapter = _BytesAdapter(const [9, 9, 9]);
    await expectLater(
      WindowsUpdateInstaller(
        dio: dio,
        channel: channel,
        cacheDirectory: directory,
        isWindows: true,
      ).install(releaseFor(const [1, 2, 3])),
      throwsFormatException,
    );
    expect(lastCall, isNull);
    expect(directory.listSync(), isEmpty);
  });

  test('unexpected artifact name is rejected before download', () async {
    final original = releaseFor(const [1, 2, 3]);
    final release = DesktopRelease(
      version: original.version,
      build: original.build,
      downloadUri: Uri.parse(
        'https://updates.example.test/desktop/other.msi',
      ),
      sha256: original.sha256,
      releaseNotes: '',
    );
    await expectLater(
      WindowsUpdateInstaller(
        channel: channel,
        cacheDirectory: directory,
        isWindows: true,
      ).install(release),
      throwsFormatException,
    );
    expect(lastCall, isNull);
  });
}

class _BytesAdapter implements HttpClientAdapter {
  _BytesAdapter(this.bytes);

  final List<int> bytes;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes(bytes, 200);

  @override
  void close({bool force = false}) {}
}
