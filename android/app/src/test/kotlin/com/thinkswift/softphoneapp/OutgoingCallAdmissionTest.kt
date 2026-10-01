package com.thinkswift.softphoneapp

import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class OutgoingCallAdmissionTest {
    @Test fun `first call is permitted`() {
        assertNull(OutgoingCallAdmission.rejection(emptyList()))
    }

    @Test fun `held original permits consultation`() {
        assertNull(OutgoingCallAdmission.rejection(listOf(AndroidCallCoordinator.State.HELD)))
    }

    @Test fun `active or progressing call must be held first`() {
        listOf(
            AndroidCallCoordinator.State.ACTIVE,
            AndroidCallCoordinator.State.RINGING,
            AndroidCallCoordinator.State.DIALING,
            AndroidCallCoordinator.State.CONNECTING,
            AndroidCallCoordinator.State.PUSH_RECEIVED
        ).forEach { assertNotNull(OutgoingCallAdmission.rejection(listOf(it))) }
    }

    @Test fun `a third call is blocked even if both peers are held`() {
        assertNotNull(OutgoingCallAdmission.rejection(listOf(
            AndroidCallCoordinator.State.HELD, AndroidCallCoordinator.State.HELD
        )))
        assertNotNull(OutgoingCallAdmission.rejection(listOf(
            AndroidCallCoordinator.State.HELD, AndroidCallCoordinator.State.ACTIVE
        )))
    }

    @Test fun `finished calls do not block admission`() {
        assertNull(OutgoingCallAdmission.rejection(listOf(
            AndroidCallCoordinator.State.HELD, AndroidCallCoordinator.State.ENDED,
            AndroidCallCoordinator.State.FAILED
        )))
    }
}
