package com.thinkswift.softphoneapp

import android.content.Context
import org.json.JSONObject

internal object SipCredentialStore {
    private const val PREFS_NAME = "softphone_sip_credentials"
    private const val KEY_PAYLOAD = "account_payload"

    fun save(context: Context, args: Map<*, *>) {
        val json = JSONObject()
        args.forEach { (key, value) ->
            if (key is String && value != null) {
                json.put(key, value)
            }
        }
        context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_PAYLOAD, json.toString())
            .apply()
    }

    fun load(context: Context): Map<String, Any?>? {
        val raw = context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_PAYLOAD, null)
            ?: return null
        val json = JSONObject(raw)
        val result = linkedMapOf<String, Any?>()
        json.keys().forEach { key ->
            result[key] = json.opt(key)
        }
        return result
    }

    fun clear(context: Context) {
        context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_PAYLOAD)
            // Logout must not return while a stale FCM wake can still observe
            // the previous SIP identity.
            .commit()
    }
}
