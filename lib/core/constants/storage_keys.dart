class StorageKeys {
  const StorageKeys._();

  static const appThemeMode = 'app.theme_mode';
  static const appDndEnabled = 'app.dnd_enabled';
  static const appDndScope = 'app.dnd_scope';
  static const appVoipDebugLogsEnabled = 'app.voip_debug_logs_enabled';

  static const appAccessToken = 'app.access_token';
  static const appRefreshToken = 'app.refresh_token';
  static const appUser = 'app.user';
  static const appService = 'app.service';
  static const appDevice = 'app.device';
  static const appProvisioning = 'app.provisioning';
  static const appSipConfig = 'app.sip_config';
  static const appDirectoryAccess = 'app.directory_access';
  static const appDeviceCredential = 'app.device_credential';
  static const appCarrierMessaging = 'app.carrier_messaging';
  static const appDeviceId = 'app.device_id';
  static const appPushTokenStatus = 'app.push_token_status';
  static const appCallHistory = 'app.call_history';
  static const appCallHistoryLastViewedAt = 'app.call_history_last_viewed_at';
  static const appQuickDial = 'app.quick_dial';
  static const appContacts = 'app.contacts';

  static const messagingAccessToken = 'messaging.access_token';
  static const messagingRefreshToken = 'messaging.refresh_token';
  static const messagingAccessExpiresAt = 'messaging.access_expires_at';
  static const messagingRefreshExpiresAt = 'messaging.refresh_expires_at';
  static const messagingSessionId = 'messaging.session_id';
  static const messagingInboxId = 'messaging.inbox_id';
  static const messagingLastSequence = 'messaging.last_sequence';
  static const messagingOutboxKey = 'messaging.outbox_key';
  static const messagingAttachmentCacheKey = 'messaging.attachment_cache_key';
  static const messagingDeletedConversations =
      'messaging.deleted_conversations';

  static const authAccessToken = 'auth.access_token';
  static const authRefreshToken = 'auth.refresh_token';
  static const authExpiresAt = 'auth.expires_at';
  static const authUserId = 'auth.user_id';
  static const authOrganizationId = 'auth.organization_id';
  static const authUserEmail = 'auth.user_email';
  static const authUserPhoneNumber = 'auth.user_phone_number';
  static const authUserDisplayName = 'auth.user_display_name';
  static const authUserRole = 'auth.user_role';
  static const authUserStatus = 'auth.user_status';
  static const authUserExtension = 'auth.user_extension';

  static const sipUsername = 'sip.username';
  static const sipAuthUsername = 'sip.auth_username';
  static const sipPassword = 'sip.password';
  static const sipDomain = 'sip.domain';
  static const sipProxyHost = 'sip.proxy_host';
  static const sipTransport = 'sip.transport';

  static const pushFcmToken = 'push.fcm_token';
  static const pushApnsToken = 'push.apns_token';
}
