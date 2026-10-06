package com.thinkswift.softphoneapp

import org.junit.Assert.*
import org.junit.Test

class AudioRoutePolicyTest {
    @Test fun waitingCallCannotStealEstablishedAudioSession() {
        assertEquals("ACTIVE", listOf("RINGING", "ACTIVE").minByOrNull(AudioRoutePolicy::sessionPriority))
        assertEquals("HELD", listOf("PUSH_RECEIVED", "HELD").minByOrNull(AudioRoutePolicy::sessionPriority))
        assertEquals("DIALING", listOf("HELD", "DIALING").minByOrNull(AudioRoutePolicy::sessionPriority))
    }
    @Test fun handsetNeverFallsBackToSpeakerOrHeadset() {
        assertTrue(AudioRoutePolicy.matchesOutput("earpiece", "Earpiece"))
        for (type in listOf("Speaker", "Headset", "Headphones", "Bluetooth", "BluetoothA2DP")) {
            assertFalse(AudioRoutePolicy.matchesOutput("earpiece", type))
        }
    }
    @Test fun bluetoothAndWiredRemainDistinct() {
        assertTrue(AudioRoutePolicy.matchesOutput("bluetooth", "Bluetooth"))
        assertTrue(AudioRoutePolicy.matchesOutput("bluetooth", "BluetoothA2DP"))
        assertFalse(AudioRoutePolicy.matchesOutput("wired", "BluetoothHeadset"))
        for (type in listOf("Headset", "Headphones", "Usb")) {
            assertTrue(AudioRoutePolicy.matchesOutput("wired", type))
            assertFalse(AudioRoutePolicy.matchesOutput("bluetooth", type))
        }
    }
    @Test fun supportedRoutesAreNotCollapsedToHandset() {
        for (route in listOf("speaker", "bluetooth", "wired", "streaming", "earpiece")) {
            assertEquals(route, AudioRoutePolicy.normalize(route))
        }
        assertEquals("earpiece", AudioRoutePolicy.normalize("unknown"))
        assertTrue(AudioRoutePolicy.matchesOutput("streaming", "Generic"))
        assertFalse(AudioRoutePolicy.matchesOutput("speaker", "Earpiece"))
    }
}
