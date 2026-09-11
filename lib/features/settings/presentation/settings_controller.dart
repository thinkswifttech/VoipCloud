import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/storage_providers.dart';
import '../../session/presentation/session_controller.dart';
import '../../sip/presentation/sip_log_providers.dart';
import '../../../voip/platform/voip_platform_channel.dart';

class SettingsState {
  const SettingsState({
    this.voipDebugLogsEnabled = false,
    this.dndEnabled = false,
    this.dndScope = DndScope.thisDevice,
    this.themeMode = AppThemeMode.system,
  });

  final bool voipDebugLogsEnabled;
  final bool dndEnabled;
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
  }) {
    return SettingsState(
      voipDebugLogsEnabled: voipDebugLogsEnabled ?? this.voipDebugLogsEnabled,
      dndEnabled: dndEnabled ?? this.dndEnabled,
      dndScope: dndScope ?? this.dndScope,
      themeMode: themeMode ?? this.themeMode,
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

bool isPbxDndEnabled(SettingsState value) =>
    value.dndEnabled && value.dndScope == DndScope.allDevices;

bool shouldTogglePbxDnd(SettingsState previous, SettingsState next) =>
    isPbxDndEnabled(previous) != isPbxDndEnabled(next);

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
  @override
  SettingsState build() {
    unawaited(_restore());
    return const SettingsState();
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
    final previous = state;
    state = state.copyWith(dndEnabled: enabled);
    unawaited(
      ref
          .read(secureStorageProvider)
          .write(StorageKeys.appDndEnabled, enabled ? 'true' : 'false'),
    );
    _syncPbxDndIfChanged(previous);
    unawaited(_syncNativeDnd(enabled));
  }

  void setDndScope(DndScope scope) {
    if (scope == state.dndScope) {
      return;
    }
    final previous = state;
    state = state.copyWith(dndScope: scope);
    unawaited(
      ref
          .read(secureStorageProvider)
          .write(StorageKeys.appDndScope, scope.name),
    );
    _syncPbxDndIfChanged(previous);
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
      final voipLogs = await storage.read(StorageKeys.appVoipDebugLogsEnabled);
      final enabledLogs = voipLogs == 'true';
      state = state.copyWith(
        themeMode: AppThemeModeCodec.parse(theme),
        dndEnabled: dndEnabled,
        dndScope: dndScope,
        voipDebugLogsEnabled: enabledLogs,
      );
      if (enabledLogs) {
        await ref.read(sipLogStoreProvider).setEnabled(true);
      }
      await _syncNativeDnd(dndEnabled);
    } catch (_) {
      // Keep defaults when secure storage is unavailable.
    }
  }

  void _syncPbxDndIfChanged(SettingsState previous) {
    if (!shouldTogglePbxDnd(previous, state)) {
      return;
    }
    // FreePBX *76 toggles extension-wide DND (same code for on and off).
    unawaited(ref.read(sipServiceProvider).syncPbxDndToggle());
  }

  Future<void> _syncNativeDnd(bool enabled) async {
    try {
      await const VoipPlatformChannel().setNativeDnd(enabled);
    } catch (_) {
      // Unsupported platforms still enforce DND while Flutter is running.
    }
  }
}
