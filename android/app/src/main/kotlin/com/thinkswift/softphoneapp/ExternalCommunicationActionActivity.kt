package com.thinkswift.softphoneapp

import android.app.Activity
import android.content.Intent
import android.os.Bundle

abstract class ExternalCommunicationActionActivity : Activity() {
    protected abstract val voipCloudAction: String

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val selectedText = intent
            ?.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)
            ?.toString()
            .orEmpty()

        if (selectedText.isNotBlank()) {
            startActivity(
                Intent(this, MainActivity::class.java).apply {
                    action = voipCloudAction
                    putExtra(MainActivity.EXTRA_EXTERNAL_DESTINATION, selectedText)
                    addFlags(
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP
                    )
                }
            )
        }
        finish()
    }
}

class CallSelectedTextActivity : ExternalCommunicationActionActivity() {
    override val voipCloudAction = MainActivity.ACTION_EXTERNAL_CALL
}

class MessageSelectedTextActivity : ExternalCommunicationActionActivity() {
    override val voipCloudAction = MainActivity.ACTION_EXTERNAL_MESSAGE
}
