package com.thinkswift.softphoneapp

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Durable, at-least-once delivery for terminal call events. */
internal object CallHistoryOutbox {
    private const val TAG = "VoIPCloud/CallHistory"
    private const val PREFERENCES = "voipcloud_call_history_outbox"
    private const val EVENTS_KEY = "terminal_events_v1"
    private const val MAX_EVENTS = 200
    private const val MAX_AGE_MS = 30L * 24L * 60L * 60L * 1000L
    private val historyKeys = listOf(
        "id", "remoteUri", "remoteDisplayName", "direction", "status",
        "startedAt", "endedAt", "stateMessage", "answeredElsewhere"
    )

    @Synchronized
    fun record(context: Context, rawEvent: Map<String, Any?>): Map<String, Any?> {
        val callId = rawEvent["id"]?.toString()?.trim().orEmpty()
        if (callId.isEmpty()) return rawEvent
        return runCatching {
            val now = System.currentTimeMillis()
            val eventId = UUID.randomUUID().toString()
            val event = linkedMapOf<String, Any?>()
            historyKeys.forEach { key ->
                if (rawEvent.containsKey(key)) event[key] = rawEvent[key]
            }
            event["historyEventId"] = eventId
            event["historyReplay"] = true
            val entries = load(context)
                .filter { now - it.storedAt <= MAX_AGE_MS && it.callId != callId }
                .toMutableList()
            entries.add(Entry(eventId, callId, now, event))
            while (entries.size > MAX_EVENTS) entries.removeAt(0)
            save(context, entries)
            event
        }.getOrElse { error ->
            // Call-state delivery must remain available even if the device has
            // exhausted storage. Dart will still receive the live event.
            Log.e(TAG, "Unable to persist terminal-call event", error)
            rawEvent
        }
    }

    @Synchronized
    fun pending(context: Context): List<Map<String, Any?>> {
        val now = System.currentTimeMillis()
        val loaded = load(context)
        val retained = loaded.filter { now - it.storedAt <= MAX_AGE_MS }.takeLast(MAX_EVENTS)
        if (retained.size != loaded.size) save(context, retained)
        return retained.sortedBy { it.storedAt }.map { LinkedHashMap(it.event) }
    }

    @Synchronized
    fun acknowledge(context: Context, eventId: String): Boolean {
        if (eventId.isBlank()) return false
        val entries = load(context)
        val retained = entries.filterNot { it.eventId == eventId }
        if (retained.size == entries.size) return false
        save(context, retained)
        return true
    }

    @Synchronized
    fun clear(context: Context) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit().remove(EVENTS_KEY).commit()
    }

    private fun load(context: Context): List<Entry> {
        val raw = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .getString(EVENTS_KEY, null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    val eventId = item.optString("eventId").trim()
                    val callId = item.optString("callId").trim()
                    val eventJson = item.optJSONObject("event") ?: continue
                    if (eventId.isEmpty() || callId.isEmpty()) continue
                    add(Entry(eventId, callId, item.optLong("storedAt"), eventJson.toMap()))
                }
            }
        }.getOrElse { error ->
            Log.e(TAG, "Discarding unreadable terminal-call outbox", error)
            emptyList()
        }
    }

    private fun save(context: Context, entries: List<Entry>) {
        val array = JSONArray()
        entries.forEach { entry ->
            array.put(JSONObject()
                .put("eventId", entry.eventId)
                .put("callId", entry.callId)
                .put("storedAt", entry.storedAt)
                .put("event", JSONObject(entry.event.filterValues { it != null })))
        }
        // A synchronous commit closes the process-death window this outbox fixes.
        if (!context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .edit().putString(EVENTS_KEY, array.toString()).commit()
        ) {
            error("Unable to persist terminal-call history outbox")
        }
    }

    private fun JSONObject.toMap(): Map<String, Any?> = buildMap {
        keys().forEach { key ->
            put(key, when (val value = opt(key)) {
                JSONObject.NULL -> null
                is JSONObject -> value.toMap()
                is JSONArray -> value.toList()
                else -> value
            })
        }
    }

    private fun JSONArray.toList(): List<Any?> = buildList {
        for (index in 0 until length()) add(when (val value = opt(index)) {
            JSONObject.NULL -> null
            is JSONObject -> value.toMap()
            is JSONArray -> value.toList()
            else -> value
        })
    }

    private data class Entry(
        val eventId: String,
        val callId: String,
        val storedAt: Long,
        val event: Map<String, Any?>
    )
}
