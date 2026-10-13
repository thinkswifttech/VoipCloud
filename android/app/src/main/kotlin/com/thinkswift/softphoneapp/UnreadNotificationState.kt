package com.thinkswift.softphoneapp

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Remembers that the user swiped the "unread activity" notification away, so a
 * later refresh of the same count does not bring it back. It returns only when
 * there is more unread activity than when it was dismissed.
 */
internal object UnreadNotificationState {
    private const val PREFS = "voipcloud_unread_notification"
    private const val KEY_DISMISSED_COUNT = "dismissed_count"

    fun dismissedCount(context: Context): Int =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getInt(KEY_DISMISSED_COUNT, 0)

    fun setDismissedCount(context: Context, count: Int) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putInt(KEY_DISMISSED_COUNT, count.coerceAtLeast(0))
            .apply()
    }

    /** Whether a notification for [count] unread items should be shown. */
    fun shouldShow(context: Context, count: Int): Boolean {
        val dismissed = dismissedCount(context)
        if (count < dismissed) {
            // Some items were read since the dismissal: new activity after this
            // point must be able to bring the notification back.
            setDismissedCount(context, count)
            return false
        }
        return count > dismissed
    }
}

internal class UnreadNotificationDismissedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val count = intent.getIntExtra(EXTRA_COUNT, 0)
        UnreadNotificationState.setDismissedCount(context, count)
    }

    companion object {
        const val ACTION_DISMISSED =
            "com.thinkswift.softphoneapp.unread.DISMISSED"
        const val EXTRA_COUNT = "count"
    }
}
