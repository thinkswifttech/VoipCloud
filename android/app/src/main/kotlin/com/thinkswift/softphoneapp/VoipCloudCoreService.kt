package com.thinkswift.softphoneapp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.linphone.core.tools.service.CoreService

class VoipCloudCoreService : CoreService() {
    private val handler = Handler(Looper.getMainLooper())
    private var notificationState = StandbyState.REGISTERING
    private var settleNotBeforeMs = 0L
    private var foregroundNotificationId = SERVICE_NOTIFICATION_ID

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val reason = intent?.getStringExtra("wake_reason") ?: "service-start"
        if (SoftphoneWakeHandler.isCallNotificationRefresh(intent)) {
            showForegroundServiceNotification(isVideoCall = false)
            if (!mIsInForegroundMode) {
                Log.e(TAG, "Stopping service because call notification promotion failed for $reason")
                stopSelf(startId)
            }
            return START_NOT_STICKY
        }
        notificationState = StandbyState.REGISTERING
        settleNotBeforeMs = SystemClock.elapsedRealtime() + wakeGracePeriodMs(reason)
        showForegroundServiceNotification(isVideoCall = false)
        if (!mIsInForegroundMode) {
            Log.e(TAG, "Stopping service because foreground promotion failed for $reason")
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val startResult = super.onStartCommand(intent, flags, startId)
        LinphoneBridgeAccessor.wakeFromPush(applicationContext, reason)
        scheduleStandbyTransition(startId)
        return if (startResult == START_STICKY) START_NOT_STICKY else startResult
    }

    override fun hideForegroundServiceNotification() {
        // Linphone calls this when its last call ends. Briefly expose the final
        // transition, then remove the service notification entirely.
        beginDeregisteringTransition()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        Log.i(TAG, "Task removed; refreshing the push registration before sleeping")
        notificationState = StandbyState.REGISTERING
        settleNotBeforeMs = SystemClock.elapsedRealtime() + BACKGROUND_GRACE_MS
        showForegroundServiceNotification(isVideoCall = false)
        LinphoneBridgeAccessor.wakeFromPush(applicationContext, "task-removed")
        scheduleStandbyTransition()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    override fun createServiceNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = NotificationManagerCompat.from(this)
        // Drop the SDK default channel so Settings no longer shows "Linphone Core Service".
        manager.deleteNotificationChannel(LINPHONE_DEFAULT_CHANNEL_ID)

        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = CHANNEL_DESCRIPTION
            enableVibration(false)
            enableLights(false)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    override fun createServiceNotification() {
        val title = serviceNotificationTitle()
        mServiceNotification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(null)
            .setSmallIcon(applicationInfo.icon)
            .setAutoCancel(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .setWhen(System.currentTimeMillis())
            .setShowWhen(false)
            .setOngoing(true)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun serviceNotificationTitle(): String {
        val extension = loggedInExtension()
        val status = when (notificationState) {
            StandbyState.REGISTERING -> "Registering"
            StandbyState.PUSH -> "Push"
            StandbyState.DEREGISTERING -> "Deregistering"
        }
        return if (extension.isNullOrBlank()) status else "$extension - $status"
    }

    private fun loggedInExtension(): String? {
        val fromCore = LinphoneBridgeAccessor.sipExtension(applicationContext)
        if (!fromCore.isNullOrBlank()) return fromCore
        val saved = SipCredentialStore.load(applicationContext) ?: return null
        val username = saved["sipUsername"] as? String
        return username?.trim()?.takeIf { it.isNotEmpty() }
    }

    override fun showForegroundServiceNotification(isVideoCall: Boolean) {
        // Rebuild each time so the title tracks the logged-in extension.
        val callSnapshot = AndroidCallCoordinator.snapshot()?.takeIf { !it.isTerminal }
        if (callSnapshot == null) {
            createServiceNotification()
        } else {
            mServiceNotification = SoftphoneWakeHandler.buildCallServiceNotification(
                applicationContext,
                callSnapshot
            )
        }
        val notification = mServiceNotification ?: return
        val notificationId = if (callSnapshot == null) {
            SERVICE_NOTIFICATION_ID
        } else {
            SoftphoneWakeHandler.CALL_NOTIFICATION_ID
        }
        val previousId = foregroundNotificationId
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    notificationId,
                    notification,
                    foregroundServiceTypes(isVideoCall)
                )
            } else {
                @Suppress("DEPRECATION")
                startForeground(notificationId, notification)
            }
            foregroundNotificationId = notificationId
            if (previousId != notificationId) {
                getSystemService(NotificationManager::class.java).cancel(previousId)
            }
            mIsInForegroundMode = true
        } catch (error: Throwable) {
            Log.e(TAG, "Failed to start foreground service", error)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                try {
                    startForeground(
                        notificationId,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                    )
                    mIsInForegroundMode = true
                } catch (fallback: Throwable) {
                    Log.e(TAG, "Phone-call-only foreground fallback failed", fallback)
                    stopSelf()
                }
            } else {
                stopSelf()
            }
        }
    }

    private fun foregroundServiceTypes(isVideoCall: Boolean): Int {
        var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
        if (isVideoCall && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        }
        return types
    }

    private fun scheduleStandbyTransition(startId: Int? = null) {
        handler.removeCallbacksAndMessages(null)
        val check = object : Runnable {
            override fun run() {
                if (SoftphoneAppState.isInForeground &&
                    !LinphoneBridgeAccessor.hasActiveCall(applicationContext)
                ) {
                    removeStandbyNotification(startId)
                    return
                }
                if (LinphoneBridgeAccessor.hasActiveCall(applicationContext)) {
                    // A cold-start INVITE can be accepted by liblinphone between
                    // Core.start() returning and the app listener becoming fully
                    // observable. Reconcile the SDK call here as a second,
                    // idempotent path so the coordinator can attach the
                    // full-screen intent and Telecom controls immediately.
                    LinphoneBridgeAccessor.reconcileCurrentCall(
                        applicationContext,
                        "service-active-call"
                    )
                    // CoreService owns the foreground lifetime while a call exists.
                    if (notificationState != StandbyState.PUSH) {
                        notificationState = StandbyState.PUSH
                        showForegroundServiceNotification(isVideoCall = false)
                    }
                    return
                }
                val now = SystemClock.elapsedRealtime()
                if (now < settleNotBeforeMs ||
                    !LinphoneBridgeAccessor.isRegistered(applicationContext)
                ) {
                    if (now < settleNotBeforeMs + REGISTRATION_TIMEOUT_MS) {
                        handler.postDelayed(this, REGISTRATION_POLL_MS)
                    } else {
                        beginDeregisteringTransition(startId)
                    }
                    return
                }
                notificationState = StandbyState.PUSH
                showForegroundServiceNotification(isVideoCall = false)
                handler.postDelayed(
                    { beginDeregisteringTransition(startId) },
                    PUSH_VISIBLE_MS
                )
            }
        }
        handler.post(check)
    }

    private fun beginDeregisteringTransition(startId: Int? = null) {
        handler.removeCallbacksAndMessages(null)
        if (LinphoneBridgeAccessor.hasActiveCall(applicationContext)) return
        notificationState = StandbyState.DEREGISTERING
        showForegroundServiceNotification(isVideoCall = false)
        handler.postDelayed(
            { removeStandbyNotification(startId) },
            DEREGISTERING_VISIBLE_MS
        )
    }

    private fun removeStandbyNotification(startId: Int? = null) {
        if (LinphoneBridgeAccessor.hasActiveCall(applicationContext)) {
            notificationState = StandbyState.PUSH
            showForegroundServiceNotification(isVideoCall = false)
            return
        }
        super.hideForegroundServiceNotification()
        mIsInForegroundMode = false
        if (startId == null) stopSelf() else stopSelf(startId)
        Log.i(TAG, "Push registration refreshed; foreground notification removed")
    }

    private fun wakeGracePeriodMs(reason: String): Long {
        return if (reason.contains("push", ignoreCase = true)) {
            INCOMING_PUSH_GRACE_MS
        } else {
            BACKGROUND_GRACE_MS
        }
    }

    private enum class StandbyState {
        REGISTERING,
        PUSH,
        DEREGISTERING
    }

    private companion object {
        const val TAG = "VoIPCloud/Linphone"
        const val SERVICE_NOTIFICATION_ID = 1
        const val LINPHONE_DEFAULT_CHANNEL_ID =
            "org_linphone_core_service_notification_channel"
        const val CHANNEL_ID = "voipcloud_core_service"
        const val CHANNEL_NAME = "VoipCloud service"
        const val CHANNEL_DESCRIPTION =
            "Shows push registration transitions and active call status"
        const val REGISTRATION_POLL_MS = 250L
        const val BACKGROUND_GRACE_MS = 500L
        const val INCOMING_PUSH_GRACE_MS = 8_000L
        const val REGISTRATION_TIMEOUT_MS = 10_000L
        const val PUSH_VISIBLE_MS = 1_500L
        const val DEREGISTERING_VISIBLE_MS = 750L
    }
}
