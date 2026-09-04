package com.thinkswift.softphoneapp

/** Pure transition reducer used to make reordered push/SIP events deterministic. */
internal object CallStateReducer {
    fun reduce(
        current: AndroidCallCoordinator.State,
        incoming: AndroidCallCoordinator.State
    ): AndroidCallCoordinator.State {
        if (current == AndroidCallCoordinator.State.ENDED ||
            current == AndroidCallCoordinator.State.FAILED
        ) return current
        if (incoming == AndroidCallCoordinator.State.ENDED ||
            incoming == AndroidCallCoordinator.State.FAILED
        ) return incoming

        return when (current) {
            AndroidCallCoordinator.State.CONNECTING -> when (incoming) {
                AndroidCallCoordinator.State.PUSH_RECEIVED,
                AndroidCallCoordinator.State.RINGING,
                AndroidCallCoordinator.State.DIALING -> current
                else -> incoming
            }
            AndroidCallCoordinator.State.ACTIVE -> when (incoming) {
                AndroidCallCoordinator.State.PUSH_RECEIVED,
                AndroidCallCoordinator.State.RINGING,
                AndroidCallCoordinator.State.DIALING,
                AndroidCallCoordinator.State.CONNECTING -> current
                else -> incoming
            }
            AndroidCallCoordinator.State.HELD -> when (incoming) {
                AndroidCallCoordinator.State.PUSH_RECEIVED,
                AndroidCallCoordinator.State.RINGING,
                AndroidCallCoordinator.State.DIALING,
                AndroidCallCoordinator.State.CONNECTING -> current
                else -> incoming
            }
            else -> incoming
        }
    }
}
