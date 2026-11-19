import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/config_providers.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/storage/storage_providers.dart';
import '../../directory/data/directory_repository.dart';
import '../../messages/domain/carrier_messaging_config.dart';
import '../../session/data/device_credential_repository.dart';
import '../../session/domain/app_session.dart';
import '../../session/presentation/session_controller.dart';
import '../../sip/domain/sip_config.dart';
import '../../sip/domain/sip_registration_state.dart';
import '../../sip/domain/sip_routing.dart';
import '../data/accounts_repository.dart';
import '../domain/account_models.dart';

final accountsRepositoryProvider = Provider<AccountsRepository>((ref) {
  return AccountsRepository(ref.watch(secureStorageProvider));
});

class AccountsState {
  const AccountsState({this.secondary, this.prefs = const AccountsPrefs()});

  final SecondaryAccount? secondary;
  final AccountsPrefs prefs;

  /// All dual-account features key off this: with one account the app looks
  /// and behaves exactly as before.
  bool get hasSecondary => secondary != null;

  AccountsState copyWith({
    SecondaryAccount? secondary,
    bool clearSecondary = false,
    AccountsPrefs? prefs,
  }) {
    return AccountsState(
      secondary: clearSecondary ? null : secondary ?? this.secondary,
      prefs: prefs ?? this.prefs,
    );
  }
}

final accountsControllerProvider =
    AsyncNotifierProvider<AccountsController, AccountsState>(
      AccountsController.new,
    );

/// True once a second account exists (and the feature is available).
final hasSecondaryAccountProvider = Provider<bool>((ref) {
  return ref.watch(accountsControllerProvider).value?.hasSecondary ?? false;
});

final secondaryRegistrationStateProvider = StreamProvider<SipRegistrationState>(
  (ref) {
    final service = ref.watch(sipServiceProvider);
    return Stream<SipRegistrationState>.multi((controller) {
      controller.add(service.getSecondaryRegistrationState());
      final subscription = service.secondaryRegistrationStateStream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.onCancel = subscription.cancel;
    });
  },
);

class AccountsController extends AsyncNotifier<AccountsState> {
  AccountsRepository get _repository => ref.read(accountsRepositoryProvider);

  @override
  Future<AccountsState> build() async {
    final prefs = await _repository.readPrefs();
    final secondary = await _repository.readSecondary();
    if (!multiAccountAvailable) {
      // A build without the feature must not keep ringing a second account
      // that an earlier build added; the saved data stays for a later build.
      if (secondary != null) {
        try {
          await ref.read(sipServiceProvider).removeSecondary();
        } catch (_) {
          // Platforms without native support have nothing to remove.
        }
      }
      return const AccountsState();
    }
    return AccountsState(secondary: secondary, prefs: prefs);
  }

  Future<AccountsState> _current() async => state.value ?? await future;

  /// Validates a freshly provisioned session and keeps it as the second
  /// account. Throws a friendly [AppException] when it cannot be added.
  Future<void> addSecondary(AppSession session) async {
    final current = await _current();
    if (current.hasSecondary) {
      throw const AppException(
        message: 'A second account already exists',
        userMessage:
            'You already have two accounts. Remove the second one first.',
      );
    }
    final sip = session.sipConfig;
    if (sip == null || !sip.hasCredentials || !session.canRegisterSip) {
      throw const AppException(
        message: 'Second account is not usable',
        userMessage:
            "This account can't make calls yet. Ask your administrator to check it.",
      );
    }
    final primary = ref.read(sessionControllerProvider).value?.sipConfig;
    if (primary != null &&
        primary.sipIdentity.toLowerCase() == sip.sipIdentity.toLowerCase()) {
      throw const AppException(
        message: 'Second account duplicates the primary',
        userMessage: 'That account is already set up on this phone.',
      );
    }
    final account = SecondaryAccount(
      sipConfig: sip,
      directoryAccess: session.directoryAccess,
      deviceCredential: session.deviceCredential,
      carrierMessaging: session.carrierMessaging,
    );
    await _repository.writeSecondary(account);
    state = AsyncData(current.copyWith(secondary: account));
    await syncSecondary();
  }

  /// Hands the second account to the native layer and registers it. Safe to
  /// call again at any time (startup, after the primary account is synced).
  Future<void> syncSecondary() async {
    final account = (await _current()).secondary;
    if (!multiAccountAvailable || account == null) return;
    try {
      final routed = alignSipRouting(
        account.sipConfig,
        ref.read(appConfigProvider).sipProxyHost,
      );
      final push = await ref.read(sipPushTokenServiceProvider).getPushConfig();
      final config = push == null ? routed : routed.copyWith(pushConfig: push);
      final service = ref.read(sipServiceProvider);
      await service.configureSecondary(config);
      await service.register();
    } catch (error, stackTrace) {
      // The primary account must keep working whatever happens here.
      AppLogger.error(
        'Second account could not be started',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> removeSecondary() async {
    final current = await _current();
    final account = current.secondary;
    if (account == null) return;
    await _revokeCredentials(account);
    try {
      await ref.read(sipServiceProvider).removeSecondary();
    } catch (error, stackTrace) {
      AppLogger.error(
        'Second account could not be removed natively',
        error: error,
        stackTrace: stackTrace,
      );
    }
    await _repository.clearSecondary();
    var prefs = current.prefs;
    // Nothing is left to ask about, and no line must point at a removed one.
    prefs = prefs
        .withDefaultOutgoing(DefaultOutgoingLine.ask)
        .withAppearance(AccountLine.secondary, const AccountAppearance());
    await _repository.writePrefs(prefs);
    state = AsyncData(AccountsState(prefs: prefs));
  }

  /// Keeps the carrier-messaging assignment the messaging server reported for
  /// the second account (it is discovered after activation).
  Future<void> setSecondaryMessagingConfig(
    CarrierMessagingConfig config,
  ) async {
    final current = await _current();
    final account = current.secondary;
    if (account == null) return;
    final updated = SecondaryAccount(
      sipConfig: account.sipConfig,
      directoryAccess: account.directoryAccess,
      deviceCredential: account.deviceCredential,
      carrierMessaging: config,
    );
    await _repository.writeSecondary(updated);
    state = AsyncData(current.copyWith(secondary: updated));
  }

  Future<void> setDefaultOutgoing(DefaultOutgoingLine value) async {
    final current = await _current();
    final prefs = current.prefs.withDefaultOutgoing(value);
    await _repository.writePrefs(prefs);
    state = AsyncData(current.copyWith(prefs: prefs));
  }

  /// [label] null keeps the name; an empty one resets it to the default.
  Future<void> setAppearance(
    AccountLine line, {
    String? label,
    int? colorValue,
  }) async {
    final current = await _current();
    final updated = current.prefs
        .appearance(line)
        .copyWith(label: label, colorValue: colorValue);
    final prefs = current.prefs.withAppearance(line, updated);
    await _repository.writePrefs(prefs);
    state = AsyncData(current.copyWith(prefs: prefs));
  }

  /// App reset: revoke the second account's credentials and forget it. The
  /// native side is purged by the primary reset that follows.
  Future<void> resetForAppReset() async {
    final account = (await _current()).secondary;
    if (account != null) await _revokeCredentials(account);
    await _repository.clearAll();
    state = const AsyncData(AccountsState());
  }

  Future<void> _revokeCredentials(SecondaryAccount account) async {
    final credential = account.deviceCredential;
    if (credential != null) {
      try {
        await ref.read(deviceCredentialRepositoryProvider).revoke(credential);
      } catch (error, stackTrace) {
        AppLogger.error(
          'Second account device credential was not revoked',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    final directory = account.directoryAccess;
    if (directory != null) {
      try {
        await ref.read(directoryRepositoryProvider).revoke(directory);
      } catch (error, stackTrace) {
        AppLogger.error(
          'Second account directory token was not revoked',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }
}

/// What the UI needs to draw one line.
class LineInfo {
  const LineInfo({
    required this.line,
    required this.label,
    required this.colorValue,
    required this.config,
  });

  final AccountLine line;
  final String label;
  final int colorValue;
  final SipConfig? config;

  /// Just the extension ("210"), for compact places; the label when unknown.
  String get shortLabel {
    final extension = config?.extension.trim() ?? '';
    return extension.isEmpty ? label : extension;
  }
}

/// The lines to show, primary first. Only the primary one until a second
/// account exists.
final accountLinesProvider = Provider<List<LineInfo>>((ref) {
  final accounts = ref.watch(accountsControllerProvider).value;
  final prefs = accounts?.prefs ?? const AccountsPrefs();
  final primary = ref.watch(sessionControllerProvider).value?.sipConfig;
  final lines = <LineInfo>[
    LineInfo(
      line: AccountLine.primary,
      label: prefs.label(AccountLine.primary, primary),
      colorValue: prefs.colorValue(AccountLine.primary),
      config: primary,
    ),
  ];
  final secondary = accounts?.secondary;
  if (secondary != null) {
    lines.add(
      LineInfo(
        line: AccountLine.secondary,
        label: prefs.label(AccountLine.secondary, secondary.sipConfig),
        colorValue: prefs.colorValue(AccountLine.secondary),
        config: secondary.sipConfig,
      ),
    );
  }
  return lines;
});
