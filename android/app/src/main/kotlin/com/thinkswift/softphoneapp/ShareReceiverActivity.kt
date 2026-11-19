package com.thinkswift.softphoneapp

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Entry for other apps' share sheets. It hands the share to the running
 * MainActivity (NEW_TASK finds the app's existing task) rather than letting
 * MainActivity start as a second copy inside the sharing app's task.
 */
class ShareReceiverActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (ShareIntentReader.isShare(intent)) {
            startActivity(
                Intent(intent).apply {
                    setClass(this@ShareReceiverActivity, MainActivity::class.java)
                    // The share sheet adds MULTIPLE_TASK, which would always start a new task.
                    flags = 0
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                }
            )
        }
        finish()
    }
}
