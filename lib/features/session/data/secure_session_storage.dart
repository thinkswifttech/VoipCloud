import 'dart:convert';

import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../../sip/domain/sip_config.dart';
import '../../directory/domain/directory_access.dart';
import '../../messages/domain/carrier_messaging_config.dart';
import '../domain/app_session.dart';
import '../domain/current_user.dart';
import '../domain/device_status.dart';
import '../domain/device_credential.dart';
import '../domain/provisioning_reference.dart';
import '../domain/service_account.dart';

class SecureSessionStorage {
  const SecureSessionStorage(this._storage);

  final SecureStorageService _storage;

  Future<AppSession?> readSession() async {
    final accessToken = await _storage.read(StorageKeys.appAccessToken);
    final userJson = await _readJson(StorageKeys.appUser);
    final serviceJson = await _readJson(StorageKeys.appService);
    final deviceJson = await _readJson(StorageKeys.appDevice);
    final provisioningJson = await _readJson(StorageKeys.appProvisioning);

    final sipJson = await _readJson(StorageKeys.appSipConfig);
    final directoryJson = await _readJson(StorageKeys.appDirectoryAccess);
    final deviceCredentialJson = await _readJson(
      StorageKeys.appDeviceCredential,
    );
    final carrierMessagingJson = await _readJson(
      StorageKeys.appCarrierMessaging,
    );
    if ((accessToken == null || userJson == null || serviceJson == null) &&
        sipJson == null) {
      return null;
    }

    final refreshToken = await _storage.read(StorageKeys.appRefreshToken);
    final sipConfig = sipJson == null ? null : SipConfig.fromJson(sipJson);
    return AppSession(
      accessToken: accessToken ?? '',
      refreshToken: refreshToken,
      user: userJson == null
          ? CurrentUser(
              id: sipConfig?.sipIdentity ?? 'local-device',
              fullName: sipConfig?.displayName ?? 'Softphone User',
              status: UserStatus.active,
            )
          : CurrentUser.fromJson(userJson),
      service: serviceJson == null
          ? const ServiceAccount(serviceStatus: ServiceStatus.active)
          : ServiceAccount.fromJson(serviceJson),
      device: deviceJson == null
          ? DeviceStatus(
              provisioningStatus: sipConfig == null
                  ? DeviceProvisioningStatus.unknown
                  : DeviceProvisioningStatus.provisioned,
              sessionStatus: sipConfig == null
                  ? DeviceSessionStatus.unknown
                  : DeviceSessionStatus.active,
              revoked: false,
              sipIdentity: sipConfig?.sipIdentity,
            )
          : DeviceStatus.fromJson(deviceJson),
      provisioning: provisioningJson == null
          ? ProvisioningReference(
              source: sipConfig == null ? null : 'FLEXIAPI',
              status: sipConfig == null
                  ? DeviceProvisioningStatus.unknown
                  : DeviceProvisioningStatus.provisioned,
              sipIdentity: sipConfig?.sipIdentity,
              displayName: sipConfig?.displayName,
            )
          : ProvisioningReference.fromJson(provisioningJson),
      sipConfig: sipConfig,
      directoryAccess: directoryJson == null
          ? null
          : DirectoryAccess.fromJson(directoryJson),
      deviceCredential: deviceCredentialJson == null
          ? null
          : DeviceCredential.fromJson(deviceCredentialJson),
      carrierMessaging: carrierMessagingJson == null
          ? null
          : CarrierMessagingConfig.fromJson(carrierMessagingJson),
    );
  }

  Future<void> writeSession(AppSession session) async {
    await _writeOptional(StorageKeys.appAccessToken, session.accessToken);
    await _writeOptional(StorageKeys.appRefreshToken, session.refreshToken);
    await _writeJson(StorageKeys.appUser, session.user.toJson());
    await _writeJson(StorageKeys.appService, session.service.toJson());
    await _writeJson(StorageKeys.appDevice, session.device.toJson());
    await _writeJson(
      StorageKeys.appProvisioning,
      session.provisioning.toJson(),
    );
    if (session.sipConfig == null || session.service.blocksSip) {
      await _storage.delete(StorageKeys.appSipConfig);
    } else {
      await _writeJson(StorageKeys.appSipConfig, session.sipConfig!.toJson());
    }
    if (session.directoryAccess == null || session.service.blocksSip) {
      await _storage.delete(StorageKeys.appDirectoryAccess);
    } else {
      await _writeJson(
        StorageKeys.appDirectoryAccess,
        session.directoryAccess!.toJson(),
      );
    }
    if (session.deviceCredential == null || session.service.blocksSip) {
      await _storage.delete(StorageKeys.appDeviceCredential);
    } else {
      await _writeJson(
        StorageKeys.appDeviceCredential,
        session.deviceCredential!.toJson(),
      );
    }
    if (session.carrierMessaging == null) {
      await _storage.delete(StorageKeys.appCarrierMessaging);
    } else {
      await _writeJson(
        StorageKeys.appCarrierMessaging,
        session.carrierMessaging!.toJson(),
      );
    }
  }

  Future<void> updateConfig({
    required CurrentUser user,
    required ServiceAccount service,
    required DeviceStatus device,
    required ProvisioningReference provisioning,
    required SipConfig? sipConfig,
    CarrierMessagingConfig? carrierMessaging,
  }) async {
    await _writeJson(StorageKeys.appUser, user.toJson());
    await _writeJson(StorageKeys.appService, service.toJson());
    await _writeJson(StorageKeys.appDevice, device.toJson());
    await _writeJson(StorageKeys.appProvisioning, provisioning.toJson());
    if (sipConfig == null || service.blocksSip) {
      await _storage.delete(StorageKeys.appSipConfig);
    } else {
      await _writeJson(StorageKeys.appSipConfig, sipConfig.toJson());
    }
    if (carrierMessaging == null) {
      await _storage.delete(StorageKeys.appCarrierMessaging);
    } else {
      await _writeJson(
        StorageKeys.appCarrierMessaging,
        carrierMessaging.toJson(),
      );
    }
  }

  Future<void> clearSession() async {
    await _storage.delete(StorageKeys.appAccessToken);
    await _storage.delete(StorageKeys.appRefreshToken);
    await _storage.delete(StorageKeys.appUser);
    await _storage.delete(StorageKeys.appService);
    await _storage.delete(StorageKeys.appDevice);
    await _storage.delete(StorageKeys.appProvisioning);
    await _storage.delete(StorageKeys.appSipConfig);
    await _storage.delete(StorageKeys.appDirectoryAccess);
    await _storage.delete(StorageKeys.appDeviceCredential);
    await _storage.delete(StorageKeys.appCarrierMessaging);
    await _storage.delete(StorageKeys.appPushTokenStatus);
    await _clearMessagingSession();
    await _clearLegacyAuth();
  }

  Future<void> _clearMessagingSession() async {
    await _storage.delete(StorageKeys.messagingAccessToken);
    await _storage.delete(StorageKeys.messagingRefreshToken);
    await _storage.delete(StorageKeys.messagingAccessExpiresAt);
    await _storage.delete(StorageKeys.messagingRefreshExpiresAt);
    await _storage.delete(StorageKeys.messagingSessionId);
    await _storage.delete(StorageKeys.messagingInboxId);
    await _storage.delete(StorageKeys.messagingLastSequence);
  }

  Future<void> _writeOptional(String key, String? value) {
    if (value == null || value.isEmpty) {
      return _storage.delete(key);
    }
    return _storage.write(key, value);
  }

  Future<void> _writeJson(String key, Map<String, dynamic> value) {
    return _storage.write(key, jsonEncode(value));
  }

  Future<Map<String, dynamic>?> _readJson(String key) async {
    final raw = await _storage.read(key);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    return null;
  }

  Future<void> _clearLegacyAuth() async {
    await _storage.delete(StorageKeys.authAccessToken);
    await _storage.delete(StorageKeys.authRefreshToken);
    await _storage.delete(StorageKeys.authExpiresAt);
    await _storage.delete(StorageKeys.authUserId);
    await _storage.delete(StorageKeys.authOrganizationId);
    await _storage.delete(StorageKeys.authUserEmail);
    await _storage.delete(StorageKeys.authUserPhoneNumber);
    await _storage.delete(StorageKeys.authUserDisplayName);
    await _storage.delete(StorageKeys.authUserRole);
    await _storage.delete(StorageKeys.authUserStatus);
    await _storage.delete(StorageKeys.authUserExtension);
  }
}
