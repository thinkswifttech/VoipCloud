import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/storage_providers.dart';
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
  }) : localDndEnabled = dndEnabled;

  final bool voipDebugLogsEnabled;
  final bool localDndEnabled;
  final PbxDndState pbxDnd;
  bool get dndEnabled => localDndEnabled || pbxDnd.enabled == true;
  bool get selectedDndEnabled => dndScope == DndScope.thisDevice
      ? localDndEnabled
      : pbxDnd.enabled == true;
  final DndScope dndScope;
  final AppThemeMode themeMode;

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
  }) {
    return SettingsState(
      voipDebugLogsEnabled: voipDebugLogsEnabled ?? this.voipDebugLogsEnabled,
      dndEnabled: dndEnabled ?? localDndEnabled,
      dndScope: dndScope ?? this.dndScope,
      themeMode: themeMode ?? this.themeMode,
      pbxDnd: pbxDnd ?? this.pbxDnd,
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
    unawaited(_restore());
    return SettingsState(pbxDnd: ref.read(pbxDndStateProvider));
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
      final voipLogs = await storage.read(StorageKeys.appVoipDebugLogsEnabled);
      final enabledLogs = voipLogs == 'true';
      state = state.copyWith(
        themeMode: AppThemeModeCodec.parse(theme),
        dndEnabled: _localDndEdited ? state.localDndEnabled : localEnabled,
        dndScope: _scopeEdited ? state.dndScope : dndScope,
        voipDebugLogsEnabled: enabledLogs,
      );
      if (enabledLogs) {
        await ref.read(sipLogStoreProvider).setEnabled(true);
      }
      await _syncNativeDnd(state.localDndEnabled);
    } catch (_) {
      // Keep defaults when secure storage is unavailable.
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
