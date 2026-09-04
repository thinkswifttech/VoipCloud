package com.thinkswift.softphoneapp

import android.Manifest
import android.app.NotificationChannel
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.ContactsContract
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.content.ContextCompat

internal object SoftphoneWakeHandler {
    private const val TAG = "Softphone/PushWake"
    private const val CORE_START_DEBOUNCE_MS = 2_000L
    private var lastCoreStartAtMs = 0L
    // v2 is intentionally silent: Linphone owns the ringtone at an attenuated
    // level. Keeping sound on this channel would play a second full-volume tone.
    // v3 resets any persisted/downgraded v2 channel importance. Android keeps
    // notification-channel settings across `adb install -r`, and a channel
    // below HIGH will suppress a full-screen intent even when the app-level
    // USE_FULL_SCREEN_INTENT permission is granted.
    private const val INCOMING_CALL_CHANNEL_ID = "softphone_incoming_calls_v4"
    // Android requires the phone-call foreground service to keep publishing a
    // notification during a call. When our activity is visible, publish it on
    // a separate low-importance channel so it remains in the shade without
    // covering the in-app call controls with a heads-up notification.
    private const val FOREGROUND_CALL_CHANNEL_ID = "softphone_foreground_calls_v1"
    const val CALL_NOTIFICATION_ID = 7001
    private const val MESSAGE_CHANNEL_ID = "carrier_messages_v1"
    private const val MESSAGE_NOTIFICATION_BASE_ID = 8000
    private const val ACTION_CARRIER_MESSAGE = "com.thinkswift.softphoneapp.CARRIER_MESSAGE"
    const val ACTION_INCOMING_CALL_FULLSCREEN =
        "com.thinkswift.softphoneapp.call.INCOMING_FULLSCREEN"
    private const val REQUEST_CODE_OPEN = 7001
    private const val REQUEST_CODE_INCOMING_FULLSCREEN = 7010
    private const val REQUEST_CODE_ACCEPT = 7002
    private const val REQUEST_CODE_DECLINE = 7003
    private const val EXTRA_CALL_NOTIFICATION_REFRESH =
        "com.thinkswift.softphoneapp.extra.CALL_NOTIFICATION_REFRESH"

    fun startLinphoneCore(context: Context, reason: String) {
        val now = System.currentTimeMillis()
        if (now - lastCoreStartAtMs < CORE_START_DEBOUNCE_MS) {
            Log.d(TAG, "Skipping duplicate Linphone CoreService start for $reason")
            return
        }
        lastCoreStartAtMs = now

        val intent = Intent(context, VoipCloudCoreService::class.java).apply {
            putExtra("wake_reason", reason)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            Log.i(TAG, "Requested Linphone CoreService start for $reason")
        } catch (error: Throwable) {
            Log.e(TAG, "Failed to start Linphone CoreService for $reason", error)
        }
    }

    /**
     * Ask the phone-call foreground service to publish the current CallStyle
     * notification. Android 12+ rejects a CallStyle posted with notify() unless
     * it belongs to a foreground service, a user-initiated job, or carries a
     * full-screen intent. Keeping this path service-owned also prevents an
     * IllegalArgumentException from escaping a Linphone JNI callback.
     */
    fun refreshCallNotification(context: Context, reason: String) {
        val intent = Intent(context, VoipCloudCoreService::class.java).apply {
            putExtra("wake_reason", reason)
            putExtra(EXTRA_CALL_NOTIFICATION_REFRESH, true)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            Log.d(TAG, "Requested service-owned call notification for $reason")
        } catch (error: Throwable) {
            Log.e(TAG, "Could not start call notification service for $reason", error)
            postFullScreenFallbackIfAllowed(context)
        }
    }

    fun refreshCallNotificationIfActive(context: Context, reason: String) {
        val snapshot = AndroidCallCoordinator.snapshot()?.takeIf { !it.isTerminal } ?: return
        refreshCallNotification(context, "$reason:${snapshot.state.name.lowercase()}")
    }

    fun isCallNotificationRefresh(intent: Intent?): Boolean =
        intent?.getBooleanExtra(EXTRA_CALL_NOTIFICATION_REFRESH, false) == true

    private fun postFullScreenFallbackIfAllowed(context: Context) {
        val snapshot = AndroidCallCoordinator.snapshot()?.takeIf { !it.isTerminal } ?: return
        if (!isDeviceLockedOrScreenOff(context)) return
        val manager = context.getSystemService(NotificationManager::class.java)
        val canUseFsi = Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
            manager.canUseFullScreenIntent()
        if (!canUseFsi) return
        try {
            manager.notify(CALL_NOTIFICATION_ID, buildCallServiceNotification(context, snapshot))
            Log.w(TAG, "Used guarded full-screen call notification fallback")
        } catch (error: Throwable) {
            Log.e(TAG, "Full-screen call notification fallback failed", error)
        }
    }

    fun buildCallServiceNotification(
        context: Context,
        snapshot: AndroidCallCoordinator.Snapshot
    ): Notification {
        val manager = context.getSystemService(NotificationManager::class.java)
        ensureIncomingCallChannel(manager)
        ensureForegroundCallChannel(manager)
        val contentIntent = PendingIntent.getActivity(
            context,
            REQUEST_CODE_OPEN,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val person = Person.Builder().setName(snapshot.callerName).setImportant(true).build()
        val ringing = snapshot.direction == AndroidCallCoordinator.Direction.INCOMING &&
            snapshot.state in setOf(
                AndroidCallCoordinator.State.PUSH_RECEIVED,
                AndroidCallCoordinator.State.RINGING
            )
        val lockedOrScreenOff = isDeviceLockedOrScreenOff(context)
        val appOwnsVisibleCallSurface = SoftphoneAppState.isInForeground &&
            !lockedOrScreenOff
        val notificationChannelId = if (appOwnsVisibleCallSurface) {
            FOREGROUND_CALL_CHANNEL_ID
        } else {
            INCOMING_CALL_CHANNEL_ID
        }
        val notificationPriority = when {
            appOwnsVisibleCallSurface -> NotificationCompat.PRIORITY_LOW
            ringing -> NotificationCompat.PRIORITY_MAX
            else -> NotificationCompat.PRIORITY_HIGH
        }
        val builder = NotificationCompat.Builder(context, notificationChannelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(notificationPriority)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentIntent(contentIntent)
        if (appOwnsVisibleCallSurface) {
            builder
                .setSilent(true)
                .setOnlyAlertOnce(true)
        }
        if (ringing) {
            val answer = callActionPendingIntent(
                context, CallActionReceiver.ACTION_ANSWER, REQUEST_CODE_ACCEPT, snapshot.sessionId
            )
            val decline = callActionPendingIntent(
                context, CallActionReceiver.ACTION_DECLINE, REQUEST_CODE_DECLINE, snapshot.sessionId
            )
            builder.setStyle(NotificationCompat.CallStyle.forIncomingCall(person, decline, answer))
            val canUseFsi = Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
                manager.canUseFullScreenIntent()
            // The FCM service has already validated freshness, account and the
            // authoritative Call-ID before creating this snapshot. Launch the
            // Flutter call surface immediately: on cold starts Linphone can
            // receive the INVITE before its application listener observes the
            // initial state, while MainActivity resume performs an additional
            // SIP reconciliation. The coordinator timeout removes a placeholder
            // if the matching INVITE never becomes observable.
            val sipInviteMatched = !snapshot.sipCallId.isNullOrBlank()
            if (lockedOrScreenOff && canUseFsi) {
                builder.setFullScreenIntent(
                    PendingIntent.getActivity(
                        context,
                        incomingCallRequestCode(snapshot.sessionId),
                        incomingCallActivityIntent(context, snapshot),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    ),
                    true
                )
                Log.i(
                    TAG,
                    "Attached incoming-call full-screen intent " +
                        "sipMatched=$sipInviteMatched lockedOrScreenOff=true canUseFsi=true"
                )
            } else {
                Log.i(
                    TAG,
                    "Incoming-call full-screen intent not attached " +
                        "sipMatched=$sipInviteMatched " +
                        "lockedOrScreenOff=$lockedOrScreenOff canUseFsi=$canUseFsi"
                )
            }
        } else {
            val end = callActionPendingIntent(
                context, CallActionReceiver.ACTION_END, REQUEST_CODE_DECLINE, snapshot.sessionId
            )
            builder.setStyle(NotificationCompat.CallStyle.forOngoingCall(person, end))
        }
        return builder.build()
    }

    private fun incomingCallActivityIntent(
        context: Context,
        snapshot: AndroidCallCoordinator.Snapshot
    ): Intent = Intent(context, MainActivity::class.java).apply {
        action = ACTION_INCOMING_CALL_FULLSCREEN
        flags = Intent.FLAG_ACTIVITY_NEW_TASK or
            Intent.FLAG_ACTIVITY_SINGLE_TOP or
            Intent.FLAG_ACTIVITY_CLEAR_TOP
        putExtra("call_session_id", snapshot.sessionId)
    }

    // PendingIntent equality includes the request code but ignores extras. A
    // session-derived code keeps calls distinct without putting a native-only
    // URI into MainActivity, where Flutter could mistake it for a deep link.
    private fun incomingCallRequestCode(sessionId: String): Int =
        REQUEST_CODE_INCOMING_FULLSCREEN xor sessionId.hashCode()

    fun isIncomingCallFullScreenIntent(intent: Intent?): Boolean =
        intent?.action == ACTION_INCOMING_CALL_FULLSCREEN

    private fun isDeviceLockedOrScreenOff(context: Context): Boolean {
        val keyguard = context.getSystemService(KeyguardManager::class.java)
        val power = context.getSystemService(PowerManager::class.java)
        return keyguard?.isKeyguardLocked == true || power?.isInteractive == false
    }

    private fun callActionPendingIntent(
        context: Context,
        action: String,
        requestCode: Int,
        sessionId: String
    ): PendingIntent = PendingIntent.getBroadcast(
        context,
        requestCode xor sessionId.hashCode(),
        Intent(context, CallActionReceiver::class.java).apply {
            this.action = action
            putExtra(CallActionReceiver.EXTRA_CALL_SESSION_ID, sessionId)
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )

    fun clearIncomingCallNotification(context: Context) {
        // If 7001 is the active foreground-service notification Android will
        // ignore a plain cancel. Refreshing after the coordinator is terminal
        // atomically moves the service back to notification 1 and removes 7001.
        refreshCallNotification(context, "call_terminal")
        try {
            context.getSystemService(NotificationManager::class.java)
                .cancel(CALL_NOTIFICATION_ID)
        } catch (error: Throwable) {
            Log.e(TAG, "Failed to clear call notification", error)
        }
    }

    fun showCarrierMessageNotification(context: Context, data: Map<String, String>) {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(MESSAGE_CHANNEL_ID) == null
        ) {
            manager.createNotificationChannel(
                NotificationChannel(
                    MESSAGE_CHANNEL_ID,
                    "Messages",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "New carrier SMS and MMS notifications"
                    lockscreenVisibility = android.app.Notification.VISIBILITY_PRIVATE
                }
            )
        }
        val intent = Intent(context, MainActivity::class.java).apply {
            action = ACTION_CARRIER_MESSAGE
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("messaging_conversation_id", data["conversation_id"])
            putExtra("messaging_message_id", data["message_id"])
        }
        val requestCode = data["conversation_id"]?.hashCode() ?: MESSAGE_NOTIFICATION_BASE_ID
        val pendingIntent = PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val remoteNumber = firstNonBlank(
            data["remote_number"],
            data["from"],
            data["sender"]
        )
        val senderName = resolveContactName(context, remoteNumber)
            ?: remoteNumber.takeIf { it.isNotBlank() }
            ?: "New message"
        val preview = carrierMessagePreview(data)
        val sender = Person.Builder().setName(senderName).build()
        val messagingStyle = NotificationCompat.MessagingStyle(
            Person.Builder().setName("You").build()
        ).addMessage(
            preview,
            System.currentTimeMillis(),
            sender
        )
        val publicNotification = NotificationCompat.Builder(context, MESSAGE_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("New message")
            .setContentText("Open VoIPCloud to view it")
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .build()
        val notification = NotificationCompat.Builder(context, MESSAGE_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(senderName)
            .setContentText(preview)
            .setStyle(messagingStyle)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicNotification)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()
        manager.notify(requestCode, notification)
    }

    private fun carrierMessagePreview(data: Map<String, String>): String {
        val text = firstNonBlank(
            data["preview"],
            data["message_preview"],
            data["body_preview"]
        ).replace(Regex("\\s+"), " ").trim()
        if (text.isNotEmpty()) return text.take(120)

        val kind = firstNonBlank(data["channel"], data["message_type"])
            .lowercase()
        val hasMedia = data["has_media"]?.lowercase() in setOf("1", "true", "yes")
        return if (kind == "mms" || hasMedia) "Photo or attachment" else "New message"
    }

    private fun resolveContactName(context: Context, number: String?): String? {
        if (number.isNullOrBlank() ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return null
        }
        val uri = Uri.withAppendedPath(
            ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
            Uri.encode(number)
        )
        return try {
            context.contentResolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (!cursor.moveToFirst()) null else cursor.getString(0)?.trim()
            }?.takeIf { it.isNotEmpty() }
        } catch (error: SecurityException) {
            Log.w(TAG, "Contact lookup was unavailable for message notification")
            null
        }
    }

    private fun ensureIncomingCallChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val existing = manager.getNotificationChannel(INCOMING_CALL_CHANNEL_ID)
        if (existing != null) return
        val channel = NotificationChannel(
            INCOMING_CALL_CHANNEL_ID,
            "Incoming calls",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Incoming VoipCloud calls"
            lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
            setSound(null, null)
        }
        manager.createNotificationChannel(channel)
    }

    private fun ensureForegroundCallChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager.getNotificationChannel(FOREGROUND_CALL_CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                FOREGROUND_CALL_CHANNEL_ID,
                "Calls while app is open",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Silent call controls while VoipCloud is open"
                lockscreenVisibility = android.app.Notification.VISIBILITY_PRIVATE
                setSound(null, null)
                enableVibration(false)
                enableLights(false)
                setShowBadge(false)
            }
        )
    }

    private fun firstNonBlank(vararg values: String?): String {
        return values.firstOrNull { !it.isNullOrBlank() }?.trim().orEmpty()
    }

    fun isCarrierMessageIntent(intent: Intent?): Boolean {
        return intent?.action == ACTION_CARRIER_MESSAGE
    }

    fun carrierMessagePayload(intent: Intent?): Map<String, String>? {
        if (!isCarrierMessageIntent(intent)) return null
        val messageId = intent?.getStringExtra("messaging_message_id")?.trim().orEmpty()
        val conversationId = intent?.getStringExtra("messaging_conversation_id")?.trim().orEmpty()
        if (messageId.isEmpty() && conversationId.isEmpty()) return null
        return buildMap {
            if (messageId.isNotEmpty()) put("message_id", messageId)
            if (conversationId.isNotEmpty()) put("conversation_id", conversationId)
        }
    }

}
