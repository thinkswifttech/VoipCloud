import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/files/email_attachment_composer.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('voipcloud/windows_email_test');
  late Directory temporaryDirectory;
  MethodCall? call;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'voipcloud-email-log-test-',
    );
    call = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (value) async {
          call = value;
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await temporaryDirectory.delete(recursive: true);
  });

  test('writes the log and hands it to the Windows email composer', () async {
    final composer = EmailAttachmentComposer(
      channel: channel,
      isSupported: true,
      useWindowsEmailComposer: true,
      temporaryDirectory: () async => temporaryDirectory,
    );

    await composer.composeLog(fileName: 'sip-log.txt', content: 'SIP data');

    expect(call?.method, 'compose');
    final arguments = call?.arguments as Map<Object?, Object?>;
    final attachment = File(arguments['path']! as String);
    expect(await attachment.readAsString(), 'SIP data');
    expect(arguments['subject'], 'VoipCloud SIP logs');
    expect(arguments['body'], contains('attached'));
  });

  test('does not write a file on unsupported platforms', () async {
    final composer = EmailAttachmentComposer(
      channel: channel,
      isSupported: false,
      useWindowsEmailComposer: false,
      temporaryDirectory: () async => temporaryDirectory,
    );

    await expectLater(
      composer.composeLog(fileName: 'sip-log.txt', content: 'SIP data'),
      throwsUnsupportedError,
    );
    expect(call, isNull);
    expect(temporaryDirectory.listSync(), isEmpty);
  });

  test('rejects a file name that can escape the log directory', () async {
    final composer = EmailAttachmentComposer(
      channel: channel,
      isSupported: true,
      useWindowsEmailComposer: false,
      temporaryDirectory: () async => temporaryDirectory,
    );

    await expectLater(
      composer.composeLog(fileName: '../sip-log.txt', content: 'SIP data'),
      throwsArgumentError,
    );
    expect(call, isNull);
  });

  test('uses the native share sheet with a text attachment', () async {
    ShareParams? params;
    final composer = EmailAttachmentComposer(
      channel: channel,
      isSupported: true,
      useWindowsEmailComposer: false,
      temporaryDirectory: () async => temporaryDirectory,
      systemShare: (value) async {
        params = value;
        return const ShareResult('mail', ShareResultStatus.success);
      },
    );

    await composer.composeLog(fileName: 'sip-log.txt', content: 'SIP data');

    expect(call, isNull);
    expect(params?.subject, 'VoipCloud SIP logs');
    expect(params?.files, hasLength(1));
    expect(params?.files?.single.mimeType, 'text/plain');
    expect(params?.fileNameOverrides, ['sip-log.txt']);
    expect(await params?.files?.single.readAsString(), 'SIP data');
  });

  test(
    'falls back to the Windows share panel when email is unavailable',
    () async {
      ShareParams? params;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            throw PlatformException(
              code: 'email_compose_failed',
              message: 'No compatible email app.',
            );
          });
      final composer = EmailAttachmentComposer(
        channel: channel,
        isSupported: true,
        useWindowsEmailComposer: true,
        temporaryDirectory: () async => temporaryDirectory,
        systemShare: (value) async {
          params = value;
          return const ShareResult('outlook', ShareResultStatus.success);
        },
      );

      await composer.composeLog(fileName: 'sip-log.txt', content: 'SIP data');

      expect(params?.files, hasLength(1));
      expect(await params?.files?.single.readAsString(), 'SIP data');
    },
  );
}
