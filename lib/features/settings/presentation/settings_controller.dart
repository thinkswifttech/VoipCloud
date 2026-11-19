import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/storage_providers.dart';
import '../../accounts/domain/account_line.dart';
import '../../sip/presentation/sip_log_providers.dart';
import '../../../voip/platform/voip_platform_channel.dart';
import '../application/pbx_dnd_monitor.dart';
import 'pbx_dnd_providers.dart';

class SettingsState {
  const SettingsState({
    this.voipDebugLogsEnabled = false,
    bool dndEnabled = false,
    this.dndScope = DndScope.thisDevice,
    this.themeMode = AppThemeMode.system,
    this.pbxDnd = const PbxDndState(),
    this.secondaryPbxDnd = const PbxDndState(),
    this.callingNetwork = CallingNetworkPreference.auto,
  }) : localDndEnabled = dndEnabled;

  final bool voipDebugLogsEnabled;
  final bool localDndEnabled;
  final PbxDndState pbxDnd;
  final PbxDndState secondaryPbxDnd;
  // Call handling only: the second account's PBX DND must not silence the first.
  bool get dndEnabled => localDndEnabled || pbxDnd.enabled == true;
  bool get selectedDndEnabled => dndScope == DndScope.thisDevice
      ? localDndEnabled
      : pbxDnd.enabled == true;
  final DndScope dndScope;
  final AppThemeMode themeMode;
  final CallingNetworkPreference callingNetwork;

  ThemeMode get materialThemeMode {
    return switch (themeMode) {
      AppThemeMode.system => ThemeMode.system,
      AppThemeMode.light => ThemeMode.light,
      AppThemeMode.dark => ThemeMode.dark,
    };
  }

  SettingsState copyWith({
    bool? voipDebugLogsEnabled,
    bool? dndEnabled,
    DndScope? dndScope,
    AppThemeMode? themeMode,
    PbxDndState? pbxDnd,
    PbxDndState? secondaryPbxDnd,
    CallingNetworkPreference? callingNetwork,
  }) {
    return SettingsState(
      voipDebugLogsEnabled: voipDebugLogsEnabled ?? this.voipDebugLogsEnabled,
      dndEnabled: dndEnabled ?? localDndEnabled,
      dndScope: dndScope ?? this.dndScope,
      themeMode: themeMode ?? this.themeMode,
      pbxDnd: pbxDnd ?? this.pbxDnd,
      secondaryPbxDnd: secondaryPbxDnd ?? this.secondaryPbxDnd,
      callingNetwork: callingNetwork ?? this.callingNetwork,
    );
  }
}

enum DndScope { thisDevice, allDevices }

extension DndScopeDetails on DndScope {
  String get label => switch (this) {
    DndScope.thisDevice => 'This device',
    DndScope.allDevices => 'All devices',
  };

  static DndScope parse(String? value, {required bool legacyDndEnabled}) {
    return switch (value) {
      'allDevices' => DndScope.allDevices,
      'thisDevice' => DndScope.thisDevice,
      // Before scope existed, enabling DND always toggled FreePBX. Preserve
      // that effective state so upgrading cannot strand PBX-wide DND on.
      _ when legacyDndEnabled => DndScope.allDevices,
      _ => DndScope.thisDevice,
    };
  }
}

/// Which connection calling traffic should use. Applies to mobile only.
enum CallingNetworkPreference { auto, wifi, cellular }

extension CallingNetworkPreferenceDetails on CallingNetworkPreference {
  String get label => switch (this) {
    CallingNetworkPreference.auto => 'Automatic',
    CallingNetworkPreference.wifi => 'Prefer Wi‑Fi',
    CallingNetworkPreference.cellular => 'Prefer mobile data',
  };

  static CallingNetworkPreference parse(String? value) {
    return switch (value) {
      'wifi' => CallingNetworkPreference.wifi,
      'cellular' => CallingNetworkPreference.cellular,
      _ => CallingNetworkPreference.auto,
    };
  }
}

enum AppThemeMode { system, light, dark }

extension AppThemeModeCodec on AppThemeMode {
  static AppThemeMode parse(String? value) {
    return switch (value) {
      'light' => AppThemeMode.light,
      'dark' => AppThemeMode.dark,
      _ => AppThemeMode.system,
    };
  }
}

final settingsControllerProvider =
    NotifierProvider<SettingsController, SettingsState>(SettingsController.new);

class SettingsController extends Notifier<SettingsState> {
  bool _localDndEdited = false;
  bool _scopeEdited = false;
  Future<void> _dndWrites = Future.value();

  void _persistDnd(String key, String value) {
    _dndWrites = _dndWrites.then((_) async {
      try {
        await ref.read(secureStorageProvider).write(key, value);
      } catch (_) {}
    });
  }

  @override
  SettingsState build() {
    ref.listen(pbxDndStateProvider, (_, next) {
      state = state.copyWith(pbxDnd: next);
    });
    ref.listen(secondaryPbxDndStateProvider, (_, next) {
      state = state.copyWith(secondaryPbxDnd: next);
    });
    unawaited(_restore());
    return SettingsState(
      pbxDnd: ref.read(pbxDndStateProvider),
      secondaryPbxDnd: ref.read(secondaryPbxDndStateProvider),
    );
  }

  /// Turns the PBX do-not-disturb of one account on or off (all its devices).
  void setPbxDndEnabled(AccountLine line, {required bool enabled}) {
    final monitor = ref.read(
      line == AccountLine.secondary
          ? secondaryPbxDndMonitorProvider
          : pbxDndMonitorProvider,
    );
    unawaited(monitor.setEnabled(enabled));
  }

  void setVoipDebugLogsEnabled({required bool enabled}) {
    state = state.copyWith(voipDebugLogsEnabled: enabled);
    unawaited(
      ref
          .read(secureStorageProvider)
          .write(
            StorageKeys.appVoipDebugLogsEnabled,
            enabled ? 'true' : 'false',
          ),
    );
    unawaited(ref.read(sipLogStoreProvider).setEnabled(enabled));
  }

  void setDndEnabled({required bool enabled}) {
    if (state.dndScope == DndScope.allDevices) {
      unawaited(ref.read(pbxDndMonitorProvider).setEnabled(enabled));
      return;
    }
    _localDndEdited = true;
    state = state.copyWith(dndEnabled: enabled);
    _persistDnd(StorageKeys.appLocalDndEnabled, enabled ? 'true' : 'false');
    unawaited(_syncNativeDnd(enabled));
  }

  void setDndScope(DndScope scope) {
    if (scope == state.dndScope) {
      return;
    }
    _scopeEdited = true;
    state = state.copyWith(dndScope: scope);
    _persistDnd(StorageKeys.appDndScope, scope.name);
  }

  /// Clears only this installation's DND preference during an app reset.
  ///
  /// Account-wide DND belongs to the extension and may still be enabled on
  /// the PBX, so resetting one device must never toggle that shared state.
  Future<void> resetDeviceDndForAppReset() async {
    _localDndEdited = true;
    _scopeEdited = true;
    state = state.copyWith(dndEnabled: false, dndScope: DndScope.thisDevice);

    // Publish an unmuted contact before SIP unregisters it. This also clears
    // the native preference used before Flutter starts after reprovisioning.
    await _syncNativeDnd(false);
    await _dndWrites;

    final storage = ref.read(secureStorageProvider);
    await storage.delete(StorageKeys.appLocalDndEnabled);
    await storage.delete(StorageKeys.appDndScope);
    await storage.delete(StorageKeys.appDndEnabled);
  }

  /// Saves the preference and hands it to the native layer, which applies it
  /// once no call is in progress. Does nothing in builds without the feature.
  void setCallingNetworkPreference(CallingNetworkPreference preference) {
    if (preference == state.callingNetwork) return;
    state = state.copyWith(callingNetwork: preference);
    unawaited(
      ref
          .read(secureStorageProvider)
          .write(StorageKeys.appCallingNetwork, preference.name),
    );
    unawaited(_syncNativeCallingNetwork(preference));
  }

  /// Returns this installation to Automatic during an app reset.
  Future<void> resetCallingNetworkForAppReset() async {
    final previous = state.callingNetwork;
    state = state.copyWith(callingNetwork: CallingNetworkPreference.auto);
    if (callingNetworkAvailable || previous != CallingNetworkPreference.auto) {
      await _syncNativeCallingNetwork(CallingNetworkPreference.auto);
    }
    await ref.read(secureStorageProvider).delete(StorageKeys.appCallingNetwork);
  }

  void setThemeMode(AppThemeMode themeMode) {
    state = state.copyWith(themeMode: themeMode);
    unawaited(
      ref
          .read(secureStorageProvider)
          .write(StorageKeys.appThemeMode, themeMode.name),
    );
  }

  Future<void> _restore() async {
    try {
      final storage = ref.read(secureStorageProvider);
      final theme = await storage.read(StorageKeys.appThemeMode);
      final dnd = await storage.read(StorageKeys.appDndEnabled);
      final dndEnabled = dnd == 'true';
      final dndScope = DndScopeDetails.parse(
        await storage.read(StorageKeys.appDndScope),
        legacyDndEnabled: dndEnabled,
      );
      final localStored = await storage.read(StorageKeys.appLocalDndEnabled);
      final localEnabled = localStored == null
          ? dndEnabled && dndScope == DndScope.thisDevice
          : localStored == 'true';
      final callingNetwork = CallingNetworkPreferenceDetails.parse(
        await storage.read(StorageKeys.appCallingNetwork),
      );
      final voipLogs = await storage.read(StorageKeys.appVoipDebugLogsEnabled);
      final enabledLogs = voipLogs == 'true';
      state = state.copyWith(
        themeMode: AppThemeModeCodec.parse(theme),
        dndEnabled: _localDndEdited ? state.localDndEnabled : localEnabled,
        dndScope: _scopeEdited ? state.dndScope : dndScope,
        voipDebugLogsEnabled: enabledLogs,
        callingNetwork: callingNetwork,
      );
      // Builds without the feature have nothing to apply, unless an earlier
      // build left a non-automatic choice that must now be switched off.
      if (callingNetworkAvailable ||
          callingNetwork != CallingNetworkPreference.auto) {
        await _syncNativeCallingNetwork(callingNetwork);
      }
      if (enabledLogs) {
        await ref.read(sipLogStoreProvider).setEnabled(true);
      }
      await _syncNativeDnd(state.localDndEnabled);
    } catch (_) {
      // Keep defaults when secure storage is unavailable.
    }
  }

  Future<void> _syncNativeCallingNetwork(
    CallingNetworkPreference preference,
  ) async {
    // Desktop has no native side for this; the iPhone one needs the patched SDK.
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await const VoipPlatformChannel().setCallingNetworkPreference(
        enabled: callingNetworkAvailable,
        preference: preference.name,
      );
    } catch (_) {
      // Platforms without the native hook keep the OS-managed connection.
    }
  }

  Future<void> _syncNativeDnd(bool enabled) async {
    try {
      await const VoipPlatformChannel().setNativeDnd(enabled);
    } catch (_) {
      // Unsupported platforms still enforce DND while Flutter is running.
    }
  }
}
