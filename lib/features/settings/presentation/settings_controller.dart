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
    this.themeMode = AppThemeMode.system,
  });

  final bool voipDebugLogsEnabled;
  final bool dndEnabled;
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
    AppThemeMode? themeMode,
  }) {
    return SettingsState(
      voipDebugLogsEnabled: voipDebugLogsEnabled ?? this.voipDebugLogsEnabled,
      dndEnabled: dndEnabled ?? this.dndEnabled,
      themeMode: themeMode ?? this.themeMode,
    );
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
    state = state.copyWith(dndEnabled: enabled);
    unawaited(
      ref
          .read(secureStorageProvider)
          .write(StorageKeys.appDndEnabled, enabled ? 'true' : 'false'),
    );
    // FreePBX *76 toggles DND server-side (same code for on and off).
    unawaited(ref.read(sipServiceProvider).syncPbxDndToggle());
    unawaited(_syncNativeDnd(enabled));
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
      final voipLogs = await storage.read(StorageKeys.appVoipDebugLogsEnabled);
      final enabledLogs = voipLogs == 'true';
      state = state.copyWith(
        themeMode: AppThemeModeCodec.parse(theme),
        dndEnabled: dnd == 'true',
        voipDebugLogsEnabled: enabledLogs,
      );
      if (enabledLogs) {
        await ref.read(sipLogStoreProvider).setEnabled(true);
      }
      await _syncNativeDnd(dnd == 'true');
    } catch (_) {
      // Keep defaults when secure storage is unavailable.
    }
  }

  Future<void> _syncNativeDnd(bool enabled) async {
    try {
      await const VoipPlatformChannel().setNativeDnd(enabled);
    } catch (_) {
      // Native cold-start DND is Android-only.
    }
  }
}
