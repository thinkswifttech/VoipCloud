package com.thinkswift.softphoneapp

internal object DeviceCallPolicy {
    fun contactParameters(original: String?, enabled: Boolean): String {
        val parameters = original.orEmpty().split(';').filter {
            it.isNotEmpty() && !it.substringBefore('=').equals("x-voipcloud-dnd", ignoreCase = true)
        }
        return (parameters + "x-voipcloud-dnd=${if (enabled) 1 else 0}").joinToString(";")
    }
}
