package com.thinkswift.softphoneapp

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

internal class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val expectedSessionId = intent.getStringExtra(EXTRA_CALL_SESSION_ID)
        if (!AndroidCallCoordinator.isCurrentSession(expectedSessionId)) {
            Log.i("VoIPCloud/Telecom", "Ignored stale call notification action")
            return
        }
        when (intent.action) {
            ACTION_ANSWER -> AndroidCallCoordinator.answerFromApp(context)
            ACTION_DECLINE -> AndroidCallCoordinator.rejectFromApp(context)
            ACTION_END -> AndroidCallCoordinator.endFromApp(context)
            ACTION_MUTE -> AndroidCallCoordinator.setMuted(
                context,
                intent.getBooleanExtra(EXTRA_ENABLED, true)
            )
            ACTION_ENDPOINT -> intent.getStringExtra(EXTRA_ENDPOINT_ID)?.let { id ->
                AndroidCallCoordinator.requestEndpoint(id) { }
            }
        }
    }

    companion object {
        const val ACTION_ANSWER = "com.thinkswift.softphoneapp.call.ANSWER"
        const val ACTION_DECLINE = "com.thinkswift.softphoneapp.call.DECLINE"
        const val ACTION_END = "com.thinkswift.softphoneapp.call.END"
        const val ACTION_MUTE = "com.thinkswift.softphoneapp.call.MUTE"
        const val ACTION_ENDPOINT = "com.thinkswift.softphoneapp.call.ENDPOINT"
        const val EXTRA_ENABLED = "enabled"
        const val EXTRA_ENDPOINT_ID = "endpoint_id"
        const val EXTRA_CALL_SESSION_ID = "call_session_id"
    }
}
