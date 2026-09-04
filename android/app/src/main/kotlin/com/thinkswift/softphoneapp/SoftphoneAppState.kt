package com.thinkswift.softphoneapp

/**
 * Shared process-level app visibility used by native call UI (notifications, CallKit).
 */
internal object SoftphoneAppState {
    @Volatile
    var isInForeground: Boolean = false
}
