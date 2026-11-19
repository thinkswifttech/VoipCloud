package com.thinkswift.softphoneapp

import android.content.Context
import org.json.JSONObject

/**
 * Saved SIP credentials, restored when a push wakes the app before Flutter
 * runs. The primary account keeps its original key; the optional second
 * account lives beside it and never overwrites it.
 */
internal object SipCredentialStore {
    private const val PREFS_NAME = "softphone_sip_credentials"
    private const val KEY_PAYLOAD = "account_payload"
    private const val KEY_SECONDARY_PAYLOAD = "secondary_account_payload"

    fun save(context: Context, args: Map<*, *>) = write(context, KEY_PAYLOAD, args)

    fun load(context: Context): Map<String, Any?>? = read(context, KEY_PAYLOAD)

    fun saveSecondary(context: Context, args: Map<*, *>) =
        write(context, KEY_SECONDARY_PAYLOAD, args)

    fun loadSecondary(context: Context): Map<String, Any?>? =
        read(context, KEY_SECONDARY_PAYLOAD)

    fun clearSecondary(context: Context) {
        context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_SECONDARY_PAYLOAD)
            .commit()
    }

    fun clear(context: Context) {
        context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_PAYLOAD)
            .remove(KEY_SECONDARY_PAYLOAD)
            // Logout must not return while a stale FCM wake can still observe
            // the previous SIP identity.
            .commit()
    }

    private fun write(context: Context, key: String, args: Map<*, *>) {
        val json = JSONObject()
        args.forEach { (name, value) ->
            if (name is String && value != null) {
                json.put(name, value)
            }
        }
        context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(key, json.toString())
            .apply()
    }

    private fun read(context: Context, key: String): Map<String, Any?>? {
        val raw = context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(key, null)
            ?: return null
        val json = JSONObject(raw)
        val result = linkedMapOf<String, Any?>()
        json.keys().forEach { name ->
            result[name] = json.opt(name)
        }
        return result
    }
}
