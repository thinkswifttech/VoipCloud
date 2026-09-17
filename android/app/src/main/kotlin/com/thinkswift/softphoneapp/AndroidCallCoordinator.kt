package com.thinkswift.softphoneapp

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telecom.DisconnectCause
import android.telecom.TelecomManager
import android.util.Log
import androidx.core.telecom.CallAttributesCompat
import androidx.core.telecom.CallControlResult
import androidx.core.telecom.CallControlScope
import androidx.core.telecom.CallEndpointCompat
import androidx.core.telecom.CallException
import androidx.core.telecom.CallsManager
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Process-wide authority for Android call lifecycle and audio routing.
 *
 * Linphone owns SIP/media; Core-Telecom owns platform call state and endpoints.
 * UI surfaces are projections of [snapshot], never independent call sessions.
 */
internal object AndroidCallCoordinator {
    private const val TAG = "VoIPCloud/Telecom"
    private const val INVITE_TIMEOUT_MS = 20_000L
    private const val TELECOM_RELEASE_GRACE_MS = 500L
    private const val REJECTED_CALL_ID_TTL_MS = 120_000L

    enum class Direction { INCOMING, OUTGOING }
    enum class State { PUSH_RECEIVED, RINGING, DIALING, CONNECTING, ACTIVE, HELD, ENDED, FAILED }

    data class Endpoint(
        val id: String,
        val route: String,
        val label: String,
        val type: Int
    ) {
        fun toMap(currentId: String?): Map<String, Any?> = mapOf(
            "id" to id,
            "route" to route,
            "label" to label,
            "type" to type,
            "available" to true,
            "selected" to (id == currentId)
        )
    }

    data class Snapshot(
        val sessionId: String,
        val sipCallId: String?,
        val direction: Direction,
        val state: State,
        val callerName: String,
        val callerNumber: String,
        val telecomManaged: Boolean,
        val muted: Boolean,
        val currentEndpointId: String?,
        val endpoints: List<Endpoint>,
        val startedAtMs: Long,
        val terminalReason: String? = null
    ) {
        val isTerminal: Boolean get() = state == State.ENDED || state == State.FAILED
        fun toMap(): Map<String, Any?> = mapOf(
            "sessionId" to sessionId,
            "sipCallId" to sipCallId,
            "direction" to direction.name.lowercase(),
            "telecomState" to state.name.lowercase(),
            "callerName" to callerName,
            "callerNumber" to callerNumber,
            "telecomManaged" to telecomManaged,
            "isMuted" to muted,
            "currentEndpointId" to currentEndpointId,
            "audioRoute" to endpoints.firstOrNull { it.id == currentEndpointId }?.route,
            "availableEndpoints" to endpoints.map { it.toMap(currentEndpointId) },
            "startedAt" to startedAtMs,
            "terminalReason" to terminalReason
        )
    }

    private data class Session(
        var snapshot: Snapshot,
        var control: CallControlScope? = null,
        var rawEndpoints: List<CallEndpointCompat> = emptyList(),
        var pendingAnswer: Boolean = false,
        var pendingReject: Boolean = false,
        var pendingSystemActive: Boolean? = null,
        var sipMatched: Boolean = false,
        var finishing: Boolean = false,
        val finished: CompletableDeferred<Unit> = CompletableDeferred(),
        var telecomJob: Job? = null,
        var timeoutJob: Job? = null,
        var outgoingReady: ((Result<Unit>) -> Unit)? = null
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val listeners = CopyOnWriteArraySet<(Snapshot?) -> Unit>()
    private val rejectedSipCallIds = ConcurrentHashMap.newKeySet<String>()
    private val endpointChangeMutex = Mutex()
    @Volatile private var session: Session? = null
    @Volatile private var secondarySession: Session? = null
    @Volatile private var registered = false
    private var callsManager: CallsManager? = null

    fun initialize(context: Context) {
        if (registered) return
        synchronized(this) {
            if (registered) return
            try {
                val manager = CallsManager(context.applicationContext)
                manager.registerAppWithTelecom(CallsManager.CAPABILITY_BASELINE)
                callsManager = manager
                registered = true
                Log.i(TAG, "Core-Telecom registration complete")
            } catch (error: Throwable) {
                callsManager = null
                registered = false
                Log.e(TAG, "Core-Telecom registration failed; CallStyle fallback remains active", error)
            }
        }
    }

    fun snapshot(): Snapshot? = preferredSession()?.snapshot

    private fun managedSessions(): List<Session> =
        listOfNotNull(session, secondarySession).filter { !it.snapshot.isTerminal }

    private fun owns(target: Session): Boolean = session === target || secondarySession === target

    private fun preferredSession(): Session? {
        val sessions = managedSessions()
        return sessions.firstOrNull {
            it.snapshot.direction == Direction.INCOMING &&
                it.snapshot.state in setOf(State.PUSH_RECEIVED, State.RINGING)
        } ?: sessions.firstOrNull { it.snapshot.state == State.ACTIVE }
            ?: sessions.firstOrNull { it.snapshot.state == State.CONNECTING || it.snapshot.state == State.DIALING }
            ?: sessions.firstOrNull()
    }

    private fun findSession(callId: String?): Session? {
        if (callId.isNullOrBlank()) return null
        return managedSessions().firstOrNull {
            it.snapshot.sessionId == callId || it.snapshot.sipCallId == callId
        }
    }

    private fun attachSession(target: Session): Boolean {
        if (session == null || session?.snapshot?.isTerminal == true) {
            session = target
            return true
        }
        if (secondarySession == null || secondarySession?.snapshot?.isTerminal == true) {
            secondarySession = target
            return true
        }
        return false
    }

    fun addListener(listener: (Snapshot?) -> Unit) {
        listeners.add(listener)
        listener(snapshot())
    }

    fun removeListener(listener: (Snapshot?) -> Unit) {
        listeners.remove(listener)
    }

    /** Returns true only when an authoritative, fresh call push was accepted. */
    fun onIncomingPush(context: Context, data: Map<String, String>): Boolean {
        val callId = firstNonBlank(data["call_id"], data["call-id"], data["callId"])
        if (callId.isBlank()) {
            Log.w(TAG, "Call push missing Call-ID; waking SIP without creating a placeholder")
            return false
        }
        val number = CallerIdentityStore.callerNumber(data)
        val trustedName = firstNonBlank(
            data["caller_name"], data["from_name"], data["from-name"],
            data["display_name"], data["display-name"], data["displayName"], data["caller"]
        )
        val existing = findSession(callId)
        if (existing != null) {
            Log.i(TAG, "Deduplicated call push correlation=${correlation(callId)}")
            refreshIdentityFromPush(context, existing, number, trustedName)
            return true
        }
        if (managedSessions().size >= 2) {
            Log.w(TAG, "Rejected third VoIP push as busy correlation=${correlation(callId)}")
            rememberRejectedCallId(callId)
            return false
        }

        val immediateName = CallerIdentityStore.displayNameWithQueuePrefix(
            number,
            trustedName.ifBlank { number.ifBlank { "Incoming call" } },
            trustedName
        )
        val newSession = Session(
            snapshot = Snapshot(
                sessionId = callId,
                sipCallId = null,
                direction = Direction.INCOMING,
                state = State.PUSH_RECEIVED,
                callerName = immediateName,
                callerNumber = number,
                telecomManaged = false,
                muted = false,
                currentEndpointId = null,
                endpoints = emptyList(),
                startedAtMs = System.currentTimeMillis()
            )
        )
        if (!attachSession(newSession)) {
            rememberRejectedCallId(callId)
            return false
        }
        publish(newSession, State.RINGING)
        Log.i(TAG, "Accepted incoming push correlation=${correlation(callId)}")
        SoftphoneWakeHandler.refreshCallNotification(context, "incoming_push")
        initialize(context)
        update(newSession) { it.copy(telecomManaged = registered) }
        val unavailableReason = telecomUnavailableReason(context, Direction.INCOMING)
        if (registered && unavailableReason == null) {
            addToTelecom(context, newSession)
        } else {
            update(newSession) { it.copy(telecomManaged = false) }
            Log.w(TAG, "Incoming call using CallStyle fallback reason=${unavailableReason ?: "registration_failed"}")
        }
        refreshIdentityFromPush(context, newSession, number, trustedName)
        newSession.timeoutJob = scope.launch {
            delay(INVITE_TIMEOUT_MS)
            if (owns(newSession) && !newSession.snapshot.isTerminal &&
                !newSession.sipMatched
            ) {
                // A cold-start SDK call may exist even if its initial callback
                // was not observed. Do not leave Linphone's ringtone/vibrator
                // alive after the coordinator placeholder expires.
                LinphoneBridgeAccessor.decline(context, callId)
                finish(context, DisconnectCause.MISSED, "invite_timeout", State.FAILED, newSession)
            }
        }
        return true
    }

    fun onCallCancelled(context: Context, data: Map<String, String>): Boolean {
        val callId = firstNonBlank(data["call_id"], data["call-id"], data["callId"])
        if (callId.isBlank()) return false
        val target = findSession(callId) ?: return false
        val matches = target.snapshot.sessionId == callId || target.snapshot.sipCallId == callId
        if (!matches || target.snapshot.isTerminal) return false
        finish(context, DisconnectCause.REMOTE, "remote_cancel_push", State.ENDED, target)
        Log.i(TAG, "Applied remote cancel push correlation=${correlation(callId)}")
        return true
    }

    fun rejectIncomingPushWithoutUi(data: Map<String, String>) {
        val callId = firstNonBlank(data["call_id"], data["call-id"], data["callId"])
        if (callId.isNotBlank()) rememberRejectedCallId(callId)
    }

    fun isCurrentSession(expectedSessionId: String?): Boolean {
        if (expectedSessionId.isNullOrBlank()) return false
        val current = findSession(expectedSessionId) ?: return false
        return !current.snapshot.isTerminal &&
            (current.snapshot.sessionId == expectedSessionId ||
                current.snapshot.sipCallId == expectedSessionId)
    }

    fun canAnswerIncoming(expectedSessionId: String?): Boolean {
        if (expectedSessionId.isNullOrBlank()) return false
        val current = findSession(expectedSessionId) ?: return false
        return current.snapshot.direction == Direction.INCOMING &&
            !current.snapshot.isTerminal &&
            (current.snapshot.state == State.RINGING ||
                current.snapshot.state == State.CONNECTING) &&
            (current.snapshot.sessionId == expectedSessionId ||
                current.snapshot.sipCallId == expectedSessionId)
    }

    fun beginOutgoing(
        context: Context,
        destination: String,
        onReady: (Result<Unit>) -> Unit
    ) {
        initialize(context)
        val current = preferredSession()
        if (current != null) {
            if (!current.snapshot.isTerminal) {
                onReady(Result.failure(IllegalStateException("Another call is already active.")))
                return
            }
            // Never retain dial intent past the initiating user action. A
            // delayed coroutine here can place an unexpected call long after
            // the user dismissed the error or left the dialer.
            onReady(Result.failure(IllegalStateException(
                "The previous call is still closing. Please try again."
            )))
            return
        }
        val id = UUID.randomUUID().toString()
        val newSession = Session(
            snapshot = Snapshot(
                sessionId = id,
                sipCallId = null,
                direction = Direction.OUTGOING,
                state = State.DIALING,
                callerName = destination,
                callerNumber = destination,
                telecomManaged = registered,
                muted = false,
                currentEndpointId = null,
                endpoints = emptyList(),
                startedAtMs = System.currentTimeMillis()
            ),
            outgoingReady = onReady
        )
        if (!attachSession(newSession)) {
            onReady(Result.failure(IllegalStateException("Another call is already active.")))
            return
        }
        publish(newSession)
        SoftphoneWakeHandler.refreshCallNotification(context, "outgoing_start")
        if (!registered) {
            onReady(Result.failure(IllegalStateException("Android Telecom is unavailable.")))
            finishFallback(context, "telecom_unavailable", newSession)
            return
        }
        val unavailableReason = telecomUnavailableReason(context, Direction.OUTGOING)
        if (unavailableReason != null) {
            Log.w(TAG, "Outgoing Telecom preflight rejected reason=$unavailableReason")
            onReady(Result.failure(IllegalStateException(
                "Android Telecom cannot start this call right now."
            )))
            finishFallback(context, unavailableReason, newSession)
            return
        }
        addToTelecom(context, newSession)
    }

    /**
     * Android 13+ exposes the app's own self-managed accounts and whether a
     * call is currently permitted. Checking before addCall prevents Telecom's
     * system ErrorDialogActivity on OEM builds when the account is missing,
     * another call owns audio, or Telecom still has a call at its limit.
     *
     * Older supported versions do not expose the permission-free own-account
     * query, so addCall remains the authoritative check there.
     */
    private fun telecomUnavailableReason(context: Context, direction: Direction): String? {
        if (!registered) return "telecom_unregistered"
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return null
        return try {
            val telecom = context.getSystemService(TelecomManager::class.java)
                ?: return "telecom_service_missing"
            val accounts = telecom.ownSelfManagedPhoneAccounts.filter {
                it.componentName.packageName == context.packageName
            }
            if (accounts.isEmpty()) {
                registered = false
                callsManager = null
                "telecom_phone_account_missing"
            } else {
                // Do not call getPhoneAccount(): some OEMs require the broader
                // READ_PHONE_NUMBERS permission even for this app's own
                // self-managed account. is*CallPermitted is the supported,
                // permission-minimal preflight for our handles.
                val permitted = accounts.any { handle ->
                    if (direction == Direction.INCOMING) {
                        telecom.isIncomingCallPermitted(handle)
                    } else {
                        telecom.isOutgoingCallPermitted(handle)
                    }
                }
                if (permitted) null else "telecom_call_not_permitted"
            }
        } catch (error: SecurityException) {
            // MANAGE_OWN_CALLS is declared, but a vendor may restrict this
            // introspection. Let Core-Telecom perform its normal check.
            Log.w(TAG, "Telecom preflight unavailable; deferring to addCall", error)
            null
        } catch (error: RuntimeException) {
            Log.w(TAG, "Telecom preflight failed; deferring to addCall", error)
            null
        }
    }

    private fun addToTelecom(context: Context, target: Session) {
        val manager = callsManager ?: return
        val s = target.snapshot
        val addressValue = s.callerNumber.ifBlank { "unknown" }
        val attributes = CallAttributesCompat(
            displayName = s.callerName,
            // Telecom implementations are only required to understand
            // standard telephone/SIP handles. A private URI scheme was
            // rejected as ERROR_CALL_NOT_PERMITTED_AT_PRESENT_TIME on
            // OxygenOS/API 36 before CallControl could be created.
            address = telecomAddress(addressValue),
            direction = if (s.direction == Direction.INCOMING) {
                CallAttributesCompat.DIRECTION_INCOMING
            } else {
                CallAttributesCompat.DIRECTION_OUTGOING
            },
            callType = CallAttributesCompat.CALL_TYPE_AUDIO_CALL,
            callCapabilities = CallAttributesCompat.SUPPORTS_SET_INACTIVE
        )
        Log.i(
            TAG,
            "Adding ${s.direction.name.lowercase()} call to Telecom " +
                "scheme=${attributes.address.scheme ?: "none"} " +
                "correlation=${correlation(s.sessionId)}"
        )
        target.telecomJob = scope.launch {
            try {
                manager.addCall(
                    attributes,
                    onAnswer = {
                        requestAnswer(context, target)
                    },
                    onDisconnect = { cause ->
                        requestDisconnectFromSystem(context, cause, target)
                    },
                    onSetActive = {
                        applySystemActiveRequest(context, target, active = true)
                    },
                    onSetInactive = {
                        applySystemActiveRequest(context, target, active = false)
                    }
                ) {
                    if (!owns(target)) {
                        launch { disconnect(DisconnectCause(DisconnectCause.LOCAL)) }
                        return@addCall
                    }
                    target.control = this
                    publish(target)
                    target.outgoingReady?.also {
                        target.outgoingReady = null
                        it(Result.success(Unit))
                    }
                    // These flows are infinite. Keep them beneath one lifecycle
                    // child and explicitly cancel them when the call finishes;
                    // otherwise addCall never returns and Telecom retains a
                    // ghost call until the application process is restarted.
                    launch {
                        val observers = listOf(
                            launch {
                                currentCallEndpoint.collectLatest { endpoint ->
                                    updateCurrentEndpoint(target, endpoint)
                                }
                            },
                            launch {
                                availableEndpoints.collectLatest { endpoints ->
                                    updateEndpoints(target, endpoints)
                                }
                            },
                            launch {
                                isMuted.collectLatest { muted ->
                                    if (!target.snapshot.isTerminal) {
                                        LinphoneBridgeAccessor.setMuted(context, muted)
                                        update(target) { it.copy(muted = muted) }
                                    }
                                }
                            }
                        )
                        try {
                            target.finished.await()
                        } finally {
                            observers.forEach { it.cancel() }
                        }
                    }
                }
            } catch (error: Throwable) {
                if (owns(target) && !target.snapshot.isTerminal) {
                    val reason = when {
                        error is CallException &&
                            error.code == CallException.ERROR_CALL_NOT_PERMITTED_AT_PRESENT_TIME ->
                            "telecom_call_not_permitted"
                        error is CallException &&
                            error.code == CallException.ERROR_OPERATION_TIMED_OUT ->
                            "telecom_add_timeout"
                        else -> "telecom_add_failed"
                    }
                    Log.e(TAG, "Telecom addCall failed correlation=${correlation(target.snapshot.sessionId)}", error)
                    target.outgoingReady?.also {
                        target.outgoingReady = null
                        it(Result.failure(error))
                    }
                    if (target.snapshot.direction == Direction.INCOMING) {
                        update(target) { it.copy(telecomManaged = false, terminalReason = reason) }
                    } else {
                        finishFallback(context, reason, target)
                    }
                }
            } finally {
                target.telecomJob = null
            }
        }
    }

    fun onSipCallState(
        context: Context,
        sipCallId: String,
        direction: Direction,
        state: State,
        callerName: String,
        callerNumber: String,
        terminationMessage: String? = null
    ) {
        initialize(context)
        if (direction == Direction.INCOMING && state == State.RINGING &&
            CallerIdentityStore.isDnd(context)
        ) {
            rememberRejectedCallId(sipCallId)
            LinphoneBridgeAccessor.decline(context, sipCallId)
            return
        }
        if (rejectedSipCallIds.contains(sipCallId)) {
            if (state == State.RINGING || state == State.CONNECTING) {
                LinphoneBridgeAccessor.decline(context, sipCallId)
            }
            if (state == State.ENDED || state == State.FAILED) rejectedSipCallIds.remove(sipCallId)
            return
        }
        val terminalSipState = state == State.ENDED || state == State.FAILED
        var target = findSession(sipCallId)
        if (target == null) {
            target = managedSessions().firstOrNull {
                !it.sipMatched && it.snapshot.direction == direction
            }
        }
        if (terminalSipState && (target == null || target.snapshot.isTerminal)) {
            Log.i(TAG, "Ignoring orphan terminal SIP callback correlation=${correlation(sipCallId)}")
            return
        }
        if (terminalSipState && target != null &&
            target.snapshot.direction == Direction.OUTGOING && !target.sipMatched
        ) {
            // A late Released/Error callback from the preceding outgoing call
            // must not bind itself to a fresh Telecom placeholder whose SIP
            // INVITE has not been created yet.
            Log.i(TAG, "Ignoring unmatched outgoing terminal callback correlation=${correlation(sipCallId)}")
            return
        }
        if (target == null || target.snapshot.isTerminal) {
            target = Session(
                snapshot = Snapshot(
                    sessionId = sipCallId,
                    sipCallId = sipCallId,
                    direction = direction,
                    state = state,
                    callerName = CallerIdentityStore.resolve(context, callerNumber, callerName),
                    callerNumber = callerNumber,
                    telecomManaged = registered,
                    muted = false,
                    currentEndpointId = null,
                    endpoints = emptyList(),
                    startedAtMs = System.currentTimeMillis()
                ),
                sipMatched = true
            )
            if (!attachSession(target)) {
                Log.w(TAG, "Declining third concurrent SIP call correlation=${correlation(sipCallId)}")
                if (direction == Direction.INCOMING) {
                    rememberRejectedCallId(sipCallId)
                    LinphoneBridgeAccessor.decline(context, sipCallId)
                } else {
                    LinphoneBridgeAccessor.end(context, sipCallId)
                }
                return
            }
            if (registered) addToTelecom(context, target)
        } else if (target.snapshot.direction != direction ||
            (direction == Direction.INCOMING && !target.sipMatched &&
                target.snapshot.sessionId != sipCallId) ||
            (target.sipMatched && target.snapshot.sipCallId != sipCallId)
        ) {
            val replacement = managedSessions().firstOrNull {
                it.snapshot.sipCallId == sipCallId || it.snapshot.sessionId == sipCallId
            }
            if (replacement != null) {
                target = replacement
            } else {
                Log.w(TAG, "Ignoring mismatched SIP callback correlation=${correlation(sipCallId)}")
                return
            }
        }

        target.sipMatched = true

        target.timeoutJob?.cancel()
        update(target) {
            it.copy(
                sipCallId = sipCallId,
                state = state,
                callerName = CallerIdentityStore.resolve(context, callerNumber, callerName),
                callerNumber = callerNumber.ifBlank { it.callerNumber }
            )
        }
        if (target.pendingReject) {
            LinphoneBridgeAccessor.decline(context, sipCallId)
        } else if (target.pendingAnswer && (state == State.RINGING || state == State.CONNECTING)) {
            LinphoneBridgeAccessor.accept(context, sipCallId)
        }
        when (state) {
            State.ACTIVE -> scope.launch {
                if (target.pendingSystemActive == false) {
                    if (LinphoneBridgeAccessor.hold(context, target.snapshot.sipCallId)) {
                        target.pendingSystemActive = null
                    }
                    return@launch
                }
                target.pendingSystemActive = null
                val result = target.control?.let {
                    if (target.snapshot.direction == Direction.INCOMING) {
                        it.answer(CallAttributesCompat.CALL_TYPE_AUDIO_CALL)
                    } else it.setActive()
                }
                logControlResult("active", target, result)
            }
            State.HELD -> scope.launch {
                if (target.pendingSystemActive == true) {
                    if (LinphoneBridgeAccessor.resume(context, target.snapshot.sipCallId)) {
                        target.pendingSystemActive = null
                    }
                    return@launch
                }
                target.pendingSystemActive = null
                logControlResult("held", target, target.control?.setInactive())
            }
            State.ENDED,
            State.FAILED -> {
                val answeredElsewhere = direction == Direction.INCOMING &&
                    isAnsweredElsewhereReason(terminationMessage)
                finish(
                    context,
                    // Core-Telecom transactional calls reject
                    // ANSWERED_ELSEWHERE (11). Preserve that semantic in the
                    // terminal reason sent to Flutter, but use one of the four
                    // disconnect causes accepted by CallControl.
                    DisconnectCause.REMOTE,
                    if (answeredElsewhere) {
                        "Call completed elsewhere"
                    } else if (state == State.ENDED) {
                        "sip_ended"
                    } else {
                        "sip_failed"
                    },
                    state,
                    target
                )
            }
            else -> Unit
        }
        if (!target.snapshot.isTerminal) {
            SoftphoneWakeHandler.refreshCallNotification(
                context,
                "sip_${state.name.lowercase()}"
            )
        }
    }

    private fun isAnsweredElsewhereReason(message: String?): Boolean {
        val normalized = message?.trim()?.lowercase().orEmpty()
        return normalized.contains("call completed elsewhere") ||
            normalized.contains("answered elsewhere") ||
            normalized.contains("completed elsewhere")
    }

    fun requestAnswer(context: Context) {
        val target = managedSessions().firstOrNull {
            it.snapshot.direction == Direction.INCOMING &&
                it.snapshot.state in setOf(State.PUSH_RECEIVED, State.RINGING, State.CONNECTING)
        } ?: return
        requestAnswer(context, target)
    }

    private fun requestAnswer(context: Context, target: Session) {
        if (target.snapshot.direction != Direction.INCOMING || target.snapshot.isTerminal) return
        managedSessions().firstOrNull {
            it !== target && it.snapshot.state == State.ACTIVE
        }?.let { activePeer ->
            activePeer.pendingSystemActive = false
            LinphoneBridgeAccessor.hold(context, activePeer.snapshot.sipCallId)
        }
        target.pendingAnswer = true
        LinphoneBridgeAccessor.accept(context, target.snapshot.sipCallId)
        publish(target, State.CONNECTING)
        SoftphoneWakeHandler.refreshCallNotification(context, "local_answer")
    }

    fun answerFromApp(context: Context, callId: String? = null) {
        val target = findSession(callId)?.takeIf {
            it.snapshot.direction == Direction.INCOMING &&
                it.snapshot.state in setOf(State.PUSH_RECEIVED, State.RINGING, State.CONNECTING)
        } ?: managedSessions().firstOrNull {
            it.snapshot.direction == Direction.INCOMING &&
                it.snapshot.state in setOf(State.PUSH_RECEIVED, State.RINGING, State.CONNECTING)
        } ?: return
        // Record the user's intent before waiting for Telecom. On a cold start
        // the authoritative SIP INVITE may not have arrived yet; requestAnswer
        // keeps that action pending and accepts immediately after Call-ID match.
        requestAnswer(context, target)
        scope.launch {
            logControlResult(
                "answer",
                target,
                target.control?.answer(CallAttributesCompat.CALL_TYPE_AUDIO_CALL)
            )
        }
    }

    fun rejectFromApp(context: Context, callId: String? = null) {
        val target = findSession(callId) ?: preferredSession() ?: return
        target.pendingReject = true
        rememberRejectedCallId(target.snapshot.sipCallId ?: target.snapshot.sessionId)
        LinphoneBridgeAccessor.decline(context, target.snapshot.sipCallId)
        finish(context, DisconnectCause.REJECTED, "local_reject", State.ENDED, target)
    }

    fun endFromApp(context: Context, callId: String? = null) {
        val target = findSession(callId) ?: preferredSession() ?: return
        LinphoneBridgeAccessor.end(context, target.snapshot.sipCallId)
        finish(context, DisconnectCause.LOCAL, "local_end", State.ENDED, target)
    }

    fun setMuted(context: Context, muted: Boolean) {
        LinphoneBridgeAccessor.setMuted(context, muted)
        preferredSession()?.let { update(it) { old -> old.copy(muted = muted) } }
    }

    fun requestEndpoint(endpointId: String, onResult: (Result<String>) -> Unit) {
        scope.launch {
            endpointChangeMutex.withLock {
                val target = preferredSession()
                val endpoint = target?.rawEndpoints?.firstOrNull {
                    it.identifier.toString() == endpointId
                }
                val control = target?.control
                if (target == null || target.snapshot.isTerminal || endpoint == null || control == null) {
                    onResult(Result.failure(
                        IllegalArgumentException("Audio endpoint is no longer available.")
                    ))
                    return@withLock
                }
                when (val result = control.requestEndpointChange(endpoint)) {
                    is CallControlResult.Success -> onResult(Result.success(routeFor(endpoint)))
                    is CallControlResult.Error -> onResult(
                        Result.failure(IllegalStateException(
                            "Telecom endpoint change failed: ${result.errorCode}"
                        ))
                    )
                }
            }
        }
    }

    fun requestRoute(route: String, onResult: (Result<String>) -> Unit) {
        val normalized = when (route) {
            "speaker", "bluetooth", "wired", "streaming" -> route
            else -> "earpiece"
        }
        val endpoint = preferredSession()?.snapshot?.endpoints?.firstOrNull { it.route == normalized }
        if (endpoint == null) {
            onResult(Result.failure(IllegalArgumentException("Audio route is unavailable.")))
        } else {
            requestEndpoint(endpoint.id, onResult)
        }
    }

    fun endpoints(): List<Map<String, Any?>> {
        val current = snapshot() ?: return emptyList()
        return current.endpoints.map { it.toMap(current.currentEndpointId) }
    }

    fun isManagingCall(): Boolean = managedSessions().any { it.snapshot.telecomManaged }

    private suspend fun requestDisconnectFromSystem(
        context: Context,
        cause: DisconnectCause,
        target: Session
    ) {
        if (cause.code == DisconnectCause.REJECTED) {
            target.pendingReject = true
            rememberRejectedCallId(target.snapshot.sipCallId ?: target.snapshot.sessionId)
            LinphoneBridgeAccessor.decline(context, target.snapshot.sipCallId)
        } else {
            LinphoneBridgeAccessor.end(context, target.snapshot.sipCallId)
        }
        finishFallback(context, "system_disconnect_${cause.code}", target)
    }

    /**
     * Telecom may request inactive/active while addCall is still negotiating
     * CallControl and before an outgoing SIP call exists. Those callbacks must
     * complete normally; throwing aborts the Telecom handshake on some OEMs.
     */
    private fun applySystemActiveRequest(context: Context, target: Session, active: Boolean) {
        if (!owns(target) || target.snapshot.isTerminal) return
        target.pendingSystemActive = active
        val sipCallId = target.snapshot.sipCallId
        if (!target.sipMatched || sipCallId.isNullOrBlank()) {
            Log.i(
                TAG,
                "Deferring system ${if (active) "active" else "inactive"} request " +
                    "until SIP match correlation=${correlation(target.snapshot.sessionId)}"
            )
            return
        }
        if ((active && target.snapshot.state == State.ACTIVE) ||
            (!active && target.snapshot.state == State.HELD)
        ) {
            target.pendingSystemActive = null
            return
        }
        val applied = if (active) {
            managedSessions().firstOrNull {
                it !== target && it.snapshot.state == State.ACTIVE
            }?.let { activePeer ->
                activePeer.pendingSystemActive = false
                LinphoneBridgeAccessor.hold(context, activePeer.snapshot.sipCallId)
            }
            LinphoneBridgeAccessor.resume(context, sipCallId)
        } else {
            LinphoneBridgeAccessor.hold(context, sipCallId)
        }
        if (applied) {
            target.pendingSystemActive = null
        } else {
            Log.i(
                TAG,
                "System ${if (active) "active" else "inactive"} request remains deferred " +
                    "correlation=${correlation(target.snapshot.sessionId)}"
            )
        }
    }

    private fun finish(
        context: Context,
        cause: Int,
        reason: String,
        terminalState: State,
        target: Session
    ) {
        if (target.finishing) return
        target.finishing = true
        Log.i(
            TAG,
            "Finishing call correlation=${correlation(target.snapshot.sessionId)} " +
                "state=$terminalState reason=$reason cause=$cause"
        )
        if (cause == DisconnectCause.MISSED) {
            rememberRejectedCallId(target.snapshot.sipCallId ?: target.snapshot.sessionId)
        }
        update(target) { it.copy(state = terminalState, terminalReason = reason) }
        target.timeoutJob?.cancel()
        if (target.control == null) {
            target.finished.complete(Unit)
            target.telecomJob?.cancel()
        }
        scope.launch {
            // Core-Telecom requires the platform disconnect to complete before
            // its addCall scope is allowed to return. Completing [finished]
            // first races OEM Telecom implementations and can surface their
            // ErrorDialogActivity while a remote rejection is being handled.
            val callJob = target.telecomJob
            val telecomCause = supportedTelecomDisconnectCause(cause)
            try {
                logControlResult(
                    "disconnect",
                    target,
                    target.control?.disconnect(DisconnectCause(telecomCause))
                )
            } catch (error: Exception) {
                // A device-specific Telecom failure must not terminate the app.
                // SIP has already reached a terminal state, so continue the
                // local cleanup and let Flutter persist the call outcome.
                Log.e(
                    TAG,
                    "Telecom disconnect failed correlation=${correlation(target.snapshot.sessionId)} " +
                        "cause=$telecomCause",
                    error
                )
            }
            target.finished.complete(Unit)
            callJob?.join()
            delay(TELECOM_RELEASE_GRACE_MS)
            if (owns(target)) {
                detachSession(target)
                val remaining = snapshot()
                notifyListeners(remaining)
                if (remaining == null) {
                    SoftphoneWakeHandler.clearIncomingCallNotification(context)
                } else {
                    SoftphoneWakeHandler.refreshCallNotification(context, "peer_call_finished")
                }
            }
        }
    }

    private fun supportedTelecomDisconnectCause(cause: Int): Int = when (cause) {
        DisconnectCause.LOCAL,
        DisconnectCause.REMOTE,
        DisconnectCause.MISSED,
        DisconnectCause.REJECTED -> cause
        else -> {
            Log.w(TAG, "Unsupported Core-Telecom disconnect cause=$cause; using REMOTE")
            DisconnectCause.REMOTE
        }
    }

    private fun finishFallback(
        context: Context,
        reason: String,
        target: Session
    ) {
        if (!target.finished.complete(Unit)) return
        if (!target.snapshot.isTerminal) {
            update(target) { it.copy(state = State.FAILED, terminalReason = reason) }
        }
        target.timeoutJob?.cancel()
        if (target.control == null) {
            target.telecomJob?.cancel()
        }
        val callJob = target.telecomJob
        scope.launch {
            callJob?.join()
            delay(TELECOM_RELEASE_GRACE_MS)
            if (owns(target)) {
                detachSession(target)
                val remaining = snapshot()
                notifyListeners(remaining)
                if (remaining == null) {
                    SoftphoneWakeHandler.clearIncomingCallNotification(context)
                } else {
                    SoftphoneWakeHandler.refreshCallNotification(context, "peer_call_fallback")
                }
            }
        }
    }

    private fun detachSession(target: Session) {
        if (session === target) session = null
        if (secondarySession === target) secondarySession = null
        if (session == null && secondarySession != null) {
            session = secondarySession
            secondarySession = null
        }
    }

    private fun updateEndpoints(target: Session, raw: List<CallEndpointCompat>) {
        if (!owns(target) || target.snapshot.isTerminal) return
        val distinctEndpoints = raw.distinctBy { it.identifier.toString() }
        val mappedEndpoints = distinctEndpoints.map(::endpointFrom)
        if (target.snapshot.endpoints == mappedEndpoints) return
        target.rawEndpoints = distinctEndpoints
        update(target) { current ->
            current.copy(endpoints = mappedEndpoints)
        }
    }

    private fun updateCurrentEndpoint(target: Session, endpoint: CallEndpointCompat) {
        if (!owns(target) || target.snapshot.isTerminal) return
        val mapped = endpointFrom(endpoint)
        if (target.snapshot.currentEndpointId == mapped.id &&
            target.snapshot.endpoints.any { it == mapped }
        ) {
            return
        }
        update(target) { current ->
            val endpoints = if (current.endpoints.any { it.id == mapped.id }) {
                current.endpoints
            } else {
                current.endpoints + mapped
            }
            current.copy(currentEndpointId = mapped.id, endpoints = endpoints)
        }
    }

    private fun endpointFrom(endpoint: CallEndpointCompat): Endpoint = Endpoint(
        id = endpoint.identifier.toString(),
        route = routeFor(endpoint),
        label = endpoint.name.toString().ifBlank { routeFor(endpoint).replaceFirstChar(Char::uppercase) },
        type = endpoint.type
    )

    private fun routeFor(endpoint: CallEndpointCompat): String = when (endpoint.type) {
        CallEndpointCompat.TYPE_SPEAKER -> "speaker"
        CallEndpointCompat.TYPE_BLUETOOTH -> "bluetooth"
        CallEndpointCompat.TYPE_WIRED_HEADSET -> "wired"
        CallEndpointCompat.TYPE_STREAMING -> "streaming"
        else -> "earpiece"
    }

    private fun publish(target: Session, state: State = target.snapshot.state) {
        update(target) { it.copy(state = state) }
    }

    private fun update(target: Session, transform: (Snapshot) -> Snapshot) {
        if (!owns(target)) return
        val previous = target.snapshot
        val proposed = transform(previous)
        target.snapshot = proposed.copy(
            state = CallStateReducer.reduce(previous.state, proposed.state)
        )
        notifyListeners(target.snapshot)
    }

    private fun notifyListeners(value: Snapshot?) {
        val deliver = Runnable {
            listeners.forEach { listener ->
                runCatching { listener(value) }.onFailure { error ->
                    Log.e(TAG, "Call surface listener failed", error)
                }
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            deliver.run()
        } else {
            mainHandler.post(deliver)
        }
    }

    private fun logControlResult(operation: String, target: Session, result: CallControlResult?) {
        when (result) {
            null -> Log.d(TAG, "$operation deferred correlation=${correlation(target.snapshot.sessionId)}")
            is CallControlResult.Success -> Log.i(TAG, "$operation complete correlation=${correlation(target.snapshot.sessionId)}")
            is CallControlResult.Error -> Log.w(TAG, "$operation failed code=${result.errorCode} correlation=${correlation(target.snapshot.sessionId)}")
        }
    }

    private fun refreshIdentityFromPush(
        context: Context,
        target: Session,
        number: String,
        trustedName: String
    ) {
        if (number.isNotBlank() && number != target.snapshot.callerNumber) {
            update(target) { it.copy(callerNumber = number) }
        }
        scope.launch(Dispatchers.IO) {
            val effectiveNumber = number.ifBlank { target.snapshot.callerNumber }
            val resolvedName = CallerIdentityStore.resolve(context, effectiveNumber, trustedName)
            withContext(Dispatchers.Main.immediate) {
                if (owns(target) && !target.snapshot.isTerminal &&
                    resolvedName != target.snapshot.callerName
                ) {
                    update(target) { it.copy(callerName = resolvedName) }
                    SoftphoneWakeHandler.refreshCallNotification(context, "caller_identity")
                }
            }
        }
    }

    private fun rememberRejectedCallId(callId: String) {
        if (callId.isBlank()) return
        rejectedSipCallIds.add(callId)
        scope.launch {
            delay(REJECTED_CALL_ID_TTL_MS)
            rejectedSipCallIds.remove(callId)
        }
    }

    private fun telecomAddress(value: String): Uri {
        val normalized = value.trim().ifBlank { "unknown" }
        return if (normalized.startsWith("sip:", ignoreCase = true) ||
            normalized.startsWith("sips:", ignoreCase = true)
        ) {
            Uri.parse(normalized)
        } else {
            Uri.fromParts("tel", normalized, null)
        }
    }

    private fun correlation(value: String): String {
        val bytes = MessageDigest.getInstance("SHA-256").digest(value.toByteArray())
        return bytes.take(6).joinToString("") { "%02x".format(it) }
    }

    private fun firstNonBlank(vararg values: String?): String =
        values.firstOrNull { !it.isNullOrBlank() }?.trim().orEmpty()
}
