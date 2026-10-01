package com.thinkswift.softphoneapp

/** Only a held first call may coexist with a newly dialed consultation call. */
internal object OutgoingCallAdmission {
    fun rejection(states: List<AndroidCallCoordinator.State>): String? {
        val live = states.filter {
            it != AndroidCallCoordinator.State.ENDED &&
                it != AndroidCallCoordinator.State.FAILED
        }
        if (live.size >= 2) return "Two calls are already open. Finish one before dialing again."
        if (live.any { it != AndroidCallCoordinator.State.HELD }) {
            return "Put the current call on hold before dialing another call."
        }
        return null
    }
}
