package com.thinkswift.softphoneapp

import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class SoftphoneFirebaseMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        if (message.data["kind"] == "carrier_message") {
            Log.i(
                "Softphone/FCM",
                "Received carrier message invalidation dataKeys=${message.data.keys.joinToString(",")}"
            )
            if (!SoftphoneAppState.isInForeground) {
                SoftphoneWakeHandler.showCarrierMessageNotification(this, message.data)
            }
            return
        }
        if (SipCredentialStore.load(this) == null) {
            Log.i(
                "Softphone/FCM",
                "Ignored stale call push because no SIP account is configured"
            )
            return
        }
        Log.i(
            "Softphone/FCM",
            "Received push from=${message.from ?: "unknown"} " +
                "priority=${priorityName(message.priority)} " +
                "originalPriority=${priorityName(message.originalPriority)} " +
                "ttl=${message.ttl}s dataKeys=${message.data.keys.joinToString(",")}"
        )
        val ageMs = (System.currentTimeMillis() - message.sentTime).coerceAtLeast(0L)
        if (message.ttl > 0 && ageMs > message.ttl * 1_000L) {
            Log.w("Softphone/FCM", "Ignored expired call push ageMs=$ageMs ttl=${message.ttl}s")
            return
        }
        if (message.priority != RemoteMessage.PRIORITY_HIGH) {
            // Do not discard an otherwise fresh call: FCM can downgrade high
            // priority when an app repeatedly fails to show user-visible UI.
            Log.w("Softphone/FCM", "Call push was delivered without HIGH priority")
        }
        val event = (message.data["event"] ?: message.data["kind"]).orEmpty()
        if (event in setOf("call_cancelled", "call_canceled", "call_ended", "cancel")) {
            if (!AndroidCallCoordinator.onCallCancelled(this, message.data)) {
                Log.i("Softphone/FCM", "Ignored unmatched call cancellation push")
            }
            return
        }
        if (event.isNotBlank() && event !in setOf("incoming_call", "call", "incoming")) {
            Log.w("Softphone/FCM", "Ignored unsupported push event=$event")
            return
        }
        val schemaVersion = message.data["schema_version"]?.trim().orEmpty()
        if (schemaVersion.isNotEmpty() && schemaVersion != SUPPORTED_CALL_SCHEMA_VERSION) {
            Log.w("Softphone/FCM", "Unsupported call push schema; waking SIP only")
            SoftphoneWakeHandler.startLinphoneCore(this, "unsupported_call_schema")
            return
        }
        // Request the foreground service before contacts, Telecom registration,
        // or any other cold-start work. OnePlus/Oppo may kill a newly-created
        // FCM process if it has not promoted itself quickly enough.
        SoftphoneWakeHandler.startLinphoneCore(this, "fcm_push")
        if (CallerIdentityStore.isDnd(this)) {
            AndroidCallCoordinator.rejectIncomingPushWithoutUi(message.data)
            return
        }
        AndroidCallCoordinator.onIncomingPush(this, message.data)
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        if (SipCredentialStore.load(this) == null) {
            Log.i("Softphone/FCM", "FCM token refreshed with no configured SIP account")
            return
        }
        // Token rotation can happen while Flutter is not running. Persist and
        // re-REGISTER natively so Flexisip never keeps routing to an old token.
        SoftphoneWakeHandler.startLinphoneCore(this, "fcm-token-refresh")
        LinphoneBridgeAccessor.updateFcmPushToken(this, token)
        Log.i("Softphone/FCM", "FCM token refreshed; native SIP re-registration requested")
    }

    private fun priorityName(priority: Int): String {
        return when (priority) {
            RemoteMessage.PRIORITY_HIGH -> "high"
            RemoteMessage.PRIORITY_NORMAL -> "normal"
            else -> "unknown($priority)"
        }
    }

    private companion object {
        const val SUPPORTED_CALL_SCHEMA_VERSION = "1"
    }
}
