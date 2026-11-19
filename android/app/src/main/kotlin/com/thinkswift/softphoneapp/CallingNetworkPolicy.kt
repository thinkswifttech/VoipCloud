package com.thinkswift.softphoneapp

/**
 * Pure selection rules for the calling-network preference. No Android types,
 * so they are unit-tested directly and shared in behaviour with the manager.
 */
internal object CallingNetworkPolicy {
    enum class Preference(val wire: String) {
        AUTO("auto"),
        WIFI("wifi"),
        CELLULAR("cellular");

        companion object {
            fun parse(value: String?): Preference =
                entries.firstOrNull { it.wire.equals(value?.trim(), ignoreCase = true) } ?: AUTO
        }
    }

    enum class Path(val wire: String) {
        WIFI("wifi"),
        CELLULAR("cellular");

        val other: Path get() = if (this == WIFI) CELLULAR else WIFI
    }

    /** What the manager knows about one physical path. */
    data class Candidate(
        val available: Boolean,
        /** True only after a connection to the SIP server succeeded on this path. */
        val validated: Boolean
    ) {
        val usable: Boolean get() = available && validated
    }

    data class Selection(
        /** Path to bind calling traffic to; null leaves routing to the OS. */
        val path: Path?,
        val reason: Reason
    )

    enum class Reason(val wire: String) {
        /** Auto, or a path is not constrained: Android chooses. */
        SYSTEM_MANAGED("system_managed"),
        PREFERRED("preferred"),
        PREFERRED_UNAVAILABLE("preferred_unavailable"),
        NO_USABLE_PATH("no_usable_path"),
        VPN_ACTIVE("vpn_active"),
        /** Android refused to bind the process; the previous route is still in use. */
        BIND_FAILED("bind_failed"),
        DISABLED("disabled")
    }

    /**
     * Chooses the path for new traffic.
     *
     * - Disabled, Auto or an active VPN leave routing to the OS.
     * - A preferred path that is usable is kept.
     * - A preferred path that is not usable falls back to the other usable path.
     * - If neither path is usable the OS keeps control so registration can retry.
     */
    fun select(
        enabled: Boolean,
        preference: Preference,
        wifi: Candidate,
        cellular: Candidate,
        vpnActive: Boolean
    ): Selection {
        if (!enabled) return Selection(null, Reason.DISABLED)
        if (preference == Preference.AUTO) return Selection(null, Reason.SYSTEM_MANAGED)
        if (vpnActive) return Selection(null, Reason.VPN_ACTIVE)
        val preferred = if (preference == Preference.WIFI) Path.WIFI else Path.CELLULAR
        val byPath = mapOf(Path.WIFI to wifi, Path.CELLULAR to cellular)
        if (byPath.getValue(preferred).usable) return Selection(preferred, Reason.PREFERRED)
        if (byPath.getValue(preferred.other).usable) {
            return Selection(preferred.other, Reason.PREFERRED_UNAVAILABLE)
        }
        return Selection(null, Reason.NO_USABLE_PATH)
    }

    /**
     * The route never changes while a call is live: a call keeps the network it
     * started on, and losing that network ends the call (see the manager).
     */
    fun mayApplyNow(liveCall: Boolean): Boolean = !liveCall

    /** Minimum time between elective (non-failure) switches. */
    const val ELECTIVE_SWITCH_COOLDOWN_MS = 60_000L

    /** A recovered preferred path must stay healthy this long before moving back. */
    const val PREFERRED_STABLE_MS = 30_000L

    fun mayMoveBackToPreferred(
        preferredHealthySinceMs: Long?,
        lastSwitchMs: Long?,
        nowMs: Long
    ): Boolean {
        val healthySince = preferredHealthySinceMs ?: return false
        if (nowMs - healthySince < PREFERRED_STABLE_MS) return false
        val last = lastSwitchMs ?: return true
        return nowMs - last >= ELECTIVE_SWITCH_COOLDOWN_MS
    }
}
