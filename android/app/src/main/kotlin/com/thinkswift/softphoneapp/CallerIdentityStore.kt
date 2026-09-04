package com.thinkswift.softphoneapp

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.ContactsContract
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import androidx.core.content.ContextCompat
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

/** Small encrypted identity cache available before Flutter starts. */
internal object CallerIdentityStore {
    private const val TAG = "VoIPCloud/Identity"
    private const val PREFS = "voipcloud_native_call_state"
    private const val KEY_DIRECTORY = "directory_v1"
    private const val KEY_DND = "dnd"
    private const val KEY_ALIAS = "voipcloud_directory_cache_v1"
    private const val MAX_ENTRIES = 2_000

    fun callerNumber(data: Map<String, String>): String {
        val raw = sequenceOf(
            data["caller_number"], data["number"], data["from"],
            data["from_uri"], data["from-uri"], data["caller"]
        ).firstOrNull { !it.isNullOrBlank() }?.trim().orEmpty()
        if (raw.isBlank()) return ""
        val withoutScheme = raw.substringAfter(':', raw)
        return Uri.decode(withoutScheme.substringBefore('@').substringBefore(';')).trim()
    }

    fun resolve(context: Context, number: String, trustedName: String?): String {
        val cleanNumber = number.trim()
        contactName(context, cleanNumber)?.let {
            return displayNameWithQueuePrefix(cleanNumber, it, trustedName)
        }
        val cached = directory(context)
        identityKeys(cleanNumber).firstNotNullOfOrNull { cached[it] }?.let {
            return displayNameWithQueuePrefix(cleanNumber, it, trustedName)
        }
        val trusted = trustedName?.trim().orEmpty()
        return displayNameWithQueuePrefix(
            cleanNumber,
            trusted.ifBlank { cleanNumber.ifBlank { "Incoming call" } },
            trustedName
        )
    }

    fun updateDirectory(context: Context, tenantKey: String, entries: List<Map<*, *>>) {
        val values = LinkedHashMap<String, String>()
        entries.take(MAX_ENTRIES).forEach { entry ->
            val name = (entry["name"] ?: entry["displayName"])?.toString()?.trim().orEmpty()
            val rawNumbers = entry["numbers"]
            val numbers = when (rawNumbers) {
                is Iterable<*> -> rawNumbers.mapNotNull { it?.toString()?.trim() }
                else -> listOfNotNull((entry["number"] ?: entry["extension"])?.toString()?.trim())
            }
            if (name.isNotBlank()) numbers.filter { it.isNotBlank() }.forEach { number ->
                identityKeys(number).forEach { key -> values.putIfAbsent(key, name) }
            }
        }
        val payload = JSONObject().apply {
            put("tenant", tenantKey.take(200))
            put("updatedAt", System.currentTimeMillis())
            put("values", JSONObject(values as Map<*, *>))
        }.toString()
        runCatching {
            prefs(context).edit().putString(KEY_DIRECTORY, encrypt(payload)).apply()
        }.onFailure { Log.w(TAG, "Unable to persist encrypted directory cache", it) }
    }

    fun clear(context: Context) {
        prefs(context).edit().remove(KEY_DIRECTORY).remove(KEY_DND).apply()
    }

    fun setDnd(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_DND, enabled).apply()
    }

    fun isDnd(context: Context): Boolean = prefs(context).getBoolean(KEY_DND, false)

    private fun directory(context: Context): Map<String, String> {
        val encrypted = prefs(context).getString(KEY_DIRECTORY, null) ?: return emptyMap()
        return runCatching {
            val values = JSONObject(decrypt(encrypted)).getJSONObject("values")
            buildMap {
                val keys = values.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    put(key, values.optString(key))
                }
            }
        }.onFailure {
            Log.w(TAG, "Encrypted directory cache was unreadable; clearing it")
            prefs(context).edit().remove(KEY_DIRECTORY).apply()
        }.getOrDefault(emptyMap())
    }

    private fun contactName(context: Context, number: String): String? {
        if (number.isBlank() || ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.READ_CONTACTS
            ) != PackageManager.PERMISSION_GRANTED
        ) return null
        val uri = Uri.withAppendedPath(
            ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
            Uri.encode(number)
        )
        return runCatching {
            context.contentResolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0)?.trim() else null
            }?.takeIf { it.isNotBlank() }
        }.getOrNull()
    }

    private fun identityKeys(value: String): List<String> {
        val trimmed = value.trim().lowercase()
        if (trimmed.isBlank()) return emptyList()
        val digits = directoryKeyCandidate(trimmed)
        return buildList {
            add("exact:$trimmed")
            if (digits.isNotBlank()) add("digits:$digits")
            if (digits.length >= 10) add("nanp:${digits.takeLast(10)}")
        }
    }

    private fun directoryKeyCandidate(value: String): String = value.filter(Char::isDigit)

    fun displayNameWithQueuePrefix(
        number: String,
        resolvedName: String,
        sourceDisplayName: String? = null
    ): String {
        val dialMatch = Regex("^([A-Za-z][A-Za-z0-9._-]*):(.+)$")
            .matchEntire(number.trim())
        val displayMatch = Regex("^([A-Za-z][A-Za-z0-9._ -]{0,31}):\\s*.+$")
            .matchEntire(sourceDisplayName?.trim().orEmpty())
        val prefix = dialMatch?.groupValues?.get(1)
            ?: displayMatch?.groupValues?.get(1)?.trim()
            ?: return resolvedName
        val suffix = dialMatch?.groupValues?.get(2).orEmpty()
        val name = resolvedName.trim()
        if (name.startsWith("$prefix:", ignoreCase = true)) return name
        if (name.isBlank() || (suffix.isNotBlank() && name == suffix)) return number.trim()
        return "$prefix: $name"
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun encrypt(clear: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val envelope = JSONObject().apply {
            put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            put("data", Base64.encodeToString(cipher.doFinal(clear.toByteArray()), Base64.NO_WRAP))
        }
        return envelope.toString()
    }

    private fun decrypt(envelopeText: String): String {
        val envelope = JSONObject(envelopeText)
        val iv = Base64.decode(envelope.getString("iv"), Base64.NO_WRAP)
        val ciphertext = Base64.decode(envelope.getString("data"), Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
        return cipher.doFinal(ciphertext).toString(Charsets.UTF_8)
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .build()
            )
            generateKey()
        }
    }
}
