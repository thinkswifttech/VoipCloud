package com.thinkswift.softphoneapp

/** Route matching only; Telecom remains the authority for managed calls. */
internal object AudioRoutePolicy {
    fun sessionPriority(state: String): Int = when (state) {
        "ACTIVE" -> 0
        "CONNECTING", "DIALING" -> 1
        "HELD" -> 2
        else -> 3
    }

    fun normalize(route: String): String = when (route) {
        "speaker", "bluetooth", "wired", "streaming" -> route
        else -> "earpiece"
    }

    fun matchesOutput(route: String, type: String): Boolean = when (normalize(route)) {
        "speaker" -> type.equals("Speaker", true)
        "bluetooth" -> type.contains("Bluetooth", true)
        "wired" -> !type.contains("Bluetooth", true) &&
            (type.contains("Headset", true) || type.contains("Headphone", true) || type.equals("Usb", true))
        "streaming" -> type.equals("Generic", true)
        else -> type.equals("Earpiece", true)
    }
}
