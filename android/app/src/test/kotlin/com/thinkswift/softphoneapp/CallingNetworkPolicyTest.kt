package com.thinkswift.softphoneapp

import com.thinkswift.softphoneapp.CallingNetworkPolicy.Candidate
import com.thinkswift.softphoneapp.CallingNetworkPolicy.Path
import com.thinkswift.softphoneapp.CallingNetworkPolicy.Preference
import com.thinkswift.softphoneapp.CallingNetworkPolicy.Reason
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CallingNetworkPolicyTest {
    private val good = Candidate(available = true, validated = true)
    private val unvalidated = Candidate(available = true, validated = false)
    private val gone = Candidate(available = false, validated = false)

    private fun select(
        preference: Preference,
        wifi: Candidate,
        cellular: Candidate,
        enabled: Boolean = true,
        vpn: Boolean = false
    ) = CallingNetworkPolicy.select(enabled, preference, wifi, cellular, vpn)

    @Test fun parsesUnknownValuesAsAuto() {
        assertEquals(Preference.AUTO, Preference.parse(null))
        assertEquals(Preference.AUTO, Preference.parse("bogus"))
        assertEquals(Preference.WIFI, Preference.parse(" WiFi "))
        assertEquals(Preference.CELLULAR, Preference.parse("cellular"))
    }

    @Test fun disabledAndAutoLeaveRoutingToTheSystem() {
        assertEquals(Reason.DISABLED, select(Preference.CELLULAR, good, good, enabled = false).reason)
        assertNull(select(Preference.CELLULAR, good, good, enabled = false).path)
        val auto = select(Preference.AUTO, good, good)
        assertNull(auto.path)
        assertEquals(Reason.SYSTEM_MANAGED, auto.reason)
    }

    @Test fun keepsAUsablePreferredPath() {
        assertEquals(Path.CELLULAR, select(Preference.CELLULAR, good, good).path)
        assertEquals(Path.WIFI, select(Preference.WIFI, good, good).path)
        assertEquals(Reason.PREFERRED, select(Preference.WIFI, good, good).reason)
    }

    @Test fun fallsBackWhenThePreferredPathIsNotUsable() {
        val unavailable = select(Preference.WIFI, gone, good)
        assertEquals(Path.CELLULAR, unavailable.path)
        assertEquals(Reason.PREFERRED_UNAVAILABLE, unavailable.reason)
        // A connected but dead Wi-Fi (no working route to the server) also falls back.
        assertEquals(Path.CELLULAR, select(Preference.WIFI, unvalidated, good).path)
        assertEquals(Path.WIFI, select(Preference.CELLULAR, good, unvalidated).path)
    }

    @Test fun leavesRoutingToTheSystemWhenNothingIsUsable() {
        val none = select(Preference.CELLULAR, unvalidated, unvalidated)
        assertNull(none.path)
        assertEquals(Reason.NO_USABLE_PATH, none.reason)
    }

    @Test fun vpnKeepsTheSystemPath() {
        val vpn = select(Preference.CELLULAR, good, good, vpn = true)
        assertNull(vpn.path)
        assertEquals(Reason.VPN_ACTIVE, vpn.reason)
    }

    @Test fun theRouteNeverChangesWhileACallIsLive() {
        assertTrue(CallingNetworkPolicy.mayApplyNow(liveCall = false))
        assertFalse(CallingNetworkPolicy.mayApplyNow(liveCall = true))
    }

    @Test fun movesBackToThePreferredPathOnlyWhenStableAndCooledDown() {
        val now = 1_000_000L
        // Never healthy: stay.
        assertFalse(CallingNetworkPolicy.mayMoveBackToPreferred(null, null, now))
        // Healthy for 29 s: not yet.
        assertFalse(CallingNetworkPolicy.mayMoveBackToPreferred(now - 29_000, null, now))
        // Healthy for 30 s with no earlier switch: allowed.
        assertTrue(CallingNetworkPolicy.mayMoveBackToPreferred(now - 30_000, null, now))
        // Stable, but we switched 20 s ago: cooldown holds.
        assertFalse(CallingNetworkPolicy.mayMoveBackToPreferred(now - 60_000, now - 20_000, now))
        assertTrue(CallingNetworkPolicy.mayMoveBackToPreferred(now - 120_000, now - 60_000, now))
    }
}
