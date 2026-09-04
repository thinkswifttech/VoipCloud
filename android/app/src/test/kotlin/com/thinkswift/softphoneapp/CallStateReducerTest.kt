package com.thinkswift.softphoneapp

import org.junit.Assert.assertEquals
import org.junit.Test

private typealias State = AndroidCallCoordinator.State

class CallStateReducerTest {
    @Test
    fun `normal incoming and outgoing progressions advance`() {
        assertEquals(State.RINGING, reduce(State.PUSH_RECEIVED, State.RINGING))
        assertEquals(State.CONNECTING, reduce(State.RINGING, State.CONNECTING))
        assertEquals(State.ACTIVE, reduce(State.CONNECTING, State.ACTIVE))
        assertEquals(State.HELD, reduce(State.ACTIVE, State.HELD))
        assertEquals(State.ACTIVE, reduce(State.HELD, State.ACTIVE))
        assertEquals(State.CONNECTING, reduce(State.DIALING, State.CONNECTING))
    }

    @Test
    fun `late push and ringing events cannot regress an answered call`() {
        assertEquals(State.CONNECTING, reduce(State.CONNECTING, State.RINGING))
        assertEquals(State.ACTIVE, reduce(State.ACTIVE, State.CONNECTING))
        assertEquals(State.ACTIVE, reduce(State.ACTIVE, State.PUSH_RECEIVED))
        assertEquals(State.HELD, reduce(State.HELD, State.RINGING))
    }

    @Test
    fun `terminal events end every live phase`() {
        State.entries.filterNot { it == State.ENDED || it == State.FAILED }.forEach { state ->
            assertEquals(State.ENDED, reduce(state, State.ENDED))
            assertEquals(State.FAILED, reduce(state, State.FAILED))
        }
    }

    @Test
    fun `terminal sessions cannot be resurrected by duplicate events`() {
        State.entries.forEach { state ->
            assertEquals(State.ENDED, reduce(State.ENDED, state))
            assertEquals(State.FAILED, reduce(State.FAILED, state))
        }
    }

    private fun reduce(current: State, incoming: State): State =
        CallStateReducer.reduce(current, incoming)

}
