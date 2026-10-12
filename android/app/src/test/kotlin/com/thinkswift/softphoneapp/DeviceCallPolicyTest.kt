package com.thinkswift.softphoneapp

import org.junit.Assert.assertEquals
import org.junit.Test

class DeviceCallPolicyTest {
    @Test fun createsPolicyOnColdStart() {
        assertEquals("x-voipcloud-dnd=1", DeviceCallPolicy.contactParameters(null, true))
        assertEquals("x-voipcloud-dnd=0", DeviceCallPolicy.contactParameters(null, false))
    }
    @Test fun preservesPushAndTransportParameters() {
        assertEquals("transport=tls;pn-provider=fcm;pn-prid=test;x-voipcloud-dnd=1",
            DeviceCallPolicy.contactParameters("transport=tls;pn-provider=fcm;pn-prid=test", true))
    }
    @Test fun replacesEveryPriorPolicyWithoutDuplicating() {
        assertEquals("transport=tcp;x-voipcloud-dnd=0",
            DeviceCallPolicy.contactParameters("X-VOIPCLOUD-DND=1;transport=tcp;x-voipcloud-dnd=1", false))
    }
    @Test fun repeatUpdatesAreIdempotent() {
        val original = DeviceCallPolicy.contactParameters("pn-provider=apns", true)
        assertEquals(original, DeviceCallPolicy.contactParameters(original, true))
    }
}
