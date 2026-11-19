package com.thinkswift.softphoneapp

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.Executors
import org.linphone.core.Core

/**
 * Applies the user's calling-network preference to the whole app process.
 *
 * Android exposes no per-socket hook into the Linphone SDK, so the only public
 * way to make its signalling and media follow a chosen path is
 * [ConnectivityManager.bindProcessToNetwork]. The preference therefore also
 * steers the app's other traffic. The class is off unless the app was built
 * with the feature and the Flutter side enables it.
 *
 * Rules:
 * - Auto (or disabled, or a VPN) leaves routing to Android and the SDK.
 * - Wi-Fi / Mobile data: use the preferred path when it is usable, otherwise the
 *   other usable path, for registration and new or incoming calls.
 * - The route never changes while a call is live. A call keeps the network it
 *   started on.
 * - Sockets created under a binding stay pinned to that network, so when the
 *   exact bound network is lost the calls cannot recover. They are ended at
 *   once with a dedicated reason; the route is then reselected after the calls
 *   are released.
 * - Weak signal, packet loss, failed probes and a lost "validated" flag never
 *   end a call. A connected-but-dead network is left to the SDK's media timeout.
 *
 * Preferences are stored natively so a push cold start applies them before
 * Flutter runs. All state is touched only on the main thread.
 */
internal class CallingNetworkManager(
    private val context: Context,
    private val core: () -> Core?,
    /** Registrar host and port to validate each path against. */
    private val endpoint: () -> Pair<String, Int>?,
    private val hasLiveCall: () -> Boolean,
    /** Ends every live call because [path], the network they run on, was lost. */
    private val endCallsForNetworkLoss: (CallingNetworkPolicy.Path) -> Unit,
    private val onStatusChanged: () -> Unit = {}
) {
    private val tag = "VoIPCloud/CallingNetwork"
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val manager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val main = Handler(Looper.getMainLooper())
    private val probes = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "calling-network-probe").apply { isDaemon = true }
    }

    private class Slot(val path: CallingNetworkPolicy.Path) {
        var network: Network? = null
        var validated = false
        var healthySinceMs: Long? = null
        var callback: ConnectivityManager.NetworkCallback? = null
        var probing = false
        var lastProbeMs = 0L
        /** Bumped whenever the network or its tracking changes; stale probes are dropped. */
        var generation = 0
        var consecutiveFailures = 0
        var firstFailureMs: Long? = null
    }

    private val wifi = Slot(CallingNetworkPolicy.Path.WIFI)
    private val cellular = Slot(CallingNetworkPolicy.Path.CELLULAR)

    private var enabled = prefs.getBoolean(KEY_ENABLED, false)
    private var preference = CallingNetworkPolicy.Preference.parse(
        prefs.getString(KEY_PREFERENCE, null)
    )
    private var started = false
    private var reason = CallingNetworkPolicy.Reason.DISABLED
    private var lastSwitchMs: Long? = null
    private var pending = false

    // The route actually applied to the process.
    private var boundNetwork: Network? = null
    private var boundPath: CallingNetworkPolicy.Path? = null
    private var bindingGeneration = 0

    /** True from the start of a route change until the SDK has reconnected. */
    private var transitioning = false
    private var reconnect: Runnable? = null

    /** Calls were ended for a network loss and are not yet released. */
    private var cleanupPending = false

    /** After the calls are released, hold the route this long so a hang-up can leave. */
    private var settleUntilMs: Long? = null

    private fun slot(path: CallingNetworkPolicy.Path) =
        if (path == CallingNetworkPolicy.Path.WIFI) wifi else cellular

    /** Called when the bridge owns a core. Safe to call again. */
    fun start() = main.post {
        if (started) return@post
        started = true
        reconfigureRequests()
        schedulePeriodicCheck()
        evaluate("start")
    }

    fun stop() = main.post {
        started = false
        main.removeCallbacks(periodicCheck)
        cancelReconnect()
        for (item in listOf(wifi, cellular)) release(item)
        bind(null)
        boundNetwork = null
        boundPath = null
        transitioning = false
        cleanupPending = false
        reason = CallingNetworkPolicy.Reason.DISABLED
        pending = false
    }

    /** Sets both values together; Flutter mirrors them on every change. */
    fun configure(enabled: Boolean, preference: CallingNetworkPolicy.Preference) = main.post {
        val changed = this.enabled != enabled || this.preference != preference
        this.enabled = enabled
        this.preference = preference
        prefs.edit().putBoolean(KEY_ENABLED, enabled).putString(KEY_PREFERENCE, preference.wire)
            .apply()
        if (started && changed) {
            reconfigureRequests()
            evaluate("configure")
        }
        onStatusChanged()
    }

    /** Call when the number of live calls changes. */
    fun liveCallsChanged() = main.post { if (started) evaluate("calls_changed") }

    /** True while the route is being changed; new calls should wait a moment. */
    fun isTransitioning(): Boolean = transitioning

    fun status(): Map<String, Any?> = mapOf(
        "enabled" to enabled,
        "requested" to preference.wire,
        "effective" to (boundPath?.wire ?: "system"),
        "reason" to reason.wire,
        "pending" to pending,
        "liveCall" to hasLiveCall(),
        "transitioning" to transitioning,
        "wifiAvailable" to (wifi.network != null),
        "cellularAvailable" to (cellular.network != null),
        "wifiValidated" to wifi.validated,
        "cellularValidated" to cellular.validated,
        "vpnActive" to vpnActive()
    )

    // --- path tracking -----------------------------------------------------

    private fun reconfigureRequests() {
        for (item in listOf(wifi, cellular)) release(item)
        if (!enabled || preference == CallingNetworkPolicy.Preference.AUTO) return
        // Android may drop the cellular radio when Wi-Fi is the default, so the
        // preferred path is explicitly requested; the other is only observed.
        val preferred = if (preference == CallingNetworkPolicy.Preference.WIFI) wifi else cellular
        track(preferred, request = true)
        track(slot(preferred.path.other), request = false)
    }

    private fun track(item: Slot, request: Boolean) {
        val transport = if (item.path == CallingNetworkPolicy.Path.WIFI) {
            NetworkCapabilities.TRANSPORT_WIFI
        } else {
            NetworkCapabilities.TRANSPORT_CELLULAR
        }
        val networkRequest = NetworkRequest.Builder()
            .addTransportType(transport)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                main.post {
                    item.network = network
                    item.generation++
                    item.validated = false
                    item.healthySinceMs = null
                    item.consecutiveFailures = 0
                    item.firstFailureMs = null
                    validate(item)
                    onStatusChanged()
                }
            }

            override fun onLost(network: Network) {
                main.post {
                    // Only the exact tracked network counts; a report about any
                    // other network never touches a call.
                    if (item.network != network) return@post
                    item.network = null
                    item.generation++
                    item.validated = false
                    item.healthySinceMs = null
                    if (boundNetwork == network) {
                        onBoundNetworkLost(item.path)
                    } else {
                        evaluate("other_path_lost")
                    }
                }
            }

            override fun onLinkPropertiesChanged(network: Network, properties: android.net.LinkProperties) {
                main.post {
                    if (!transitioning && boundNetwork == network) applyDns(network)
                }
            }
        }
        item.callback = callback
        try {
            if (request) {
                manager.requestNetwork(networkRequest, callback)
            } else {
                manager.registerNetworkCallback(networkRequest, callback)
            }
        } catch (error: Throwable) {
            Log.w(tag, "Unable to track ${item.path.wire}", error)
            item.callback = null
        }
    }

    private fun release(item: Slot) {
        item.callback?.let {
            try {
                manager.unregisterNetworkCallback(it)
            } catch (_: Throwable) {
            }
        }
        item.callback = null
        item.network = null
        item.generation++
        item.validated = false
        item.healthySinceMs = null
        item.consecutiveFailures = 0
        item.firstFailureMs = null
    }

    // --- loss of the bound network ----------------------------------------

    /**
     * The exact network the process (and so every live call's sockets) is bound
     * to is gone. Release the binding at once so a hang-up can still leave over
     * whatever Android now offers, end the calls, and only reselect the route
     * after the calls are released.
     */
    private fun onBoundNetworkLost(path: CallingNetworkPolicy.Path) {
        Log.i(tag, "Bound ${path.wire} network lost (generation $bindingGeneration)")
        settleUntilMs = null
        cancelReconnect()
        transitioning = false
        bind(null)
        boundNetwork = null
        boundPath = null
        bindingGeneration++
        applyDns(null)
        // The SDK's sockets are pinned to the dead network: move them now, so
        // the hang-up (BYE) below can reach the server.
        cycleSdk()
        if (hasLiveCall()) {
            cleanupPending = true
            endCallsForNetworkLoss(path)
        }
        evaluate("path_lost")
    }

    // --- validation --------------------------------------------------------

    /** Three bounded probes (IPv4 and IPv6 addresses tried); two successes validate a path. */
    private fun validate(item: Slot) {
        val network = item.network ?: return
        if (item.probing) return
        val target = endpoint()
        if (target == null) {
            Log.i(tag, "No registrar known yet; cannot validate ${item.path.wire}")
            return
        }
        item.probing = true
        item.lastProbeMs = System.currentTimeMillis()
        val generation = item.generation
        probes.execute {
            var successes = 0
            var attempts = 0
            while (attempts < 3 && successes < 2 && attempts - successes < 2) {
                attempts++
                if (probeOnce(network, target.first, target.second)) successes++
            }
            val ok = successes >= 2
            Log.i(tag, "Probe ${item.path.wire} -> ${target.first}:${target.second} " +
                "successes=$successes attempts=$attempts ok=$ok")
            main.post {
                item.probing = false
                // A newer network, or a change of tracking, makes this result stale.
                if (item.network != network || item.generation != generation) return@post
                if (ok) {
                    item.consecutiveFailures = 0
                    item.firstFailureMs = null
                    if (!item.validated) item.healthySinceMs = System.currentTimeMillis()
                    item.validated = true
                } else {
                    noteFailure(item)
                }
                evaluate("validated")
            }
        }
    }

    private fun noteFailure(item: Slot) {
        val now = System.currentTimeMillis()
        item.consecutiveFailures++
        if (item.firstFailureMs == null) item.firstFailureMs = now
        // Three consecutive failures over at least ten seconds: persistent.
        // This only affects route selection; it never ends a call.
        if (item.consecutiveFailures >= 3 &&
            now - (item.firstFailureMs ?: now) >= PERSISTENT_FAILURE_MS
        ) {
            item.validated = false
            item.healthySinceMs = null
        }
    }

    /**
     * Connects to the registrar through [network]. Every address the name
     * resolves to is tried, IPv6 first when the network has it, within one
     * overall deadline. This proves transport reachability only, not that SIP
     * registration or audio would work.
     */
    private fun probeOnce(network: Network, host: String, port: Int): Boolean {
        return try {
            val deadline = System.currentTimeMillis() + PROBE_DEADLINE_MS
            val addresses = network.getAllByName(host).sortedBy { it is java.net.Inet4Address }
            for (address in addresses) {
                val remaining = (deadline - System.currentTimeMillis()).toInt()
                if (remaining <= 250) break
                if (connect(network, address, port, minOf(remaining, PROBE_TIMEOUT_MS))) return true
            }
            false
        } catch (_: Throwable) {
            false
        }
    }

    private fun connect(network: Network, address: InetAddress, port: Int, timeoutMs: Int): Boolean = try {
        network.socketFactory.createSocket().use { socket ->
            socket.connect(InetSocketAddress(address, port), timeoutMs)
            true
        }
    } catch (_: Throwable) {
        false
    }

    private val periodicCheck = object : Runnable {
        override fun run() {
            if (!started) return
            if (enabled && preference != CallingNetworkPolicy.Preference.AUTO) {
                for (item in listOf(wifi, cellular)) {
                    // Re-check the bound path and any path not yet validated.
                    // Probes are skipped during calls so media is not disturbed.
                    // Spaced out so an idle phone does not keep the radio and server busy.
                    val gap = if (item.validated) HEALTHY_REPROBE_MS else FAILED_REPROBE_MS
                    if (item.network != null && (!item.validated || boundPath == item.path) &&
                        !hasLiveCall() && System.currentTimeMillis() - item.lastProbeMs >= gap
                    ) validate(item)
                }
                evaluate("periodic")
            }
            schedulePeriodicCheck()
        }
    }

    private fun schedulePeriodicCheck() {
        main.removeCallbacks(periodicCheck)
        main.postDelayed(periodicCheck, PERIODIC_CHECK_MS)
    }

    // --- selection and application ----------------------------------------

    private fun candidate(item: Slot) =
        CallingNetworkPolicy.Candidate(item.network != null, item.validated)

    private fun vpnActive(): Boolean {
        val active = manager.activeNetwork ?: return false
        return manager.getNetworkCapabilities(active)
            ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
    }

    private fun evaluate(why: String) {
        val live = hasLiveCall()
        var settling = false
        if (cleanupPending && !live) {
            val now = System.currentTimeMillis()
            val until = settleUntilMs ?: (now + CLEANUP_SETTLE_MS).also { settleUntilMs = it }
            if (now < until) {
                settling = true
                main.postDelayed({ if (started) evaluate("cleanup_settled") }, until - now + 50)
            } else {
                cleanupPending = false
                settleUntilMs = null
            }
        }
        val selection = CallingNetworkPolicy.select(
            enabled, preference, candidate(wifi), candidate(cellular), vpnActive()
        )
        // Moving back to the preferred path after a fallback is elective: it
        // needs a stable, cooled-down preferred path.
        val movingBackToPreferred = selection.reason == CallingNetworkPolicy.Reason.PREFERRED &&
            boundPath != null && boundPath != selection.path
        val electiveBlocked = movingBackToPreferred && !CallingNetworkPolicy.mayMoveBackToPreferred(
            selection.path?.let { slot(it).healthySinceMs }, lastSwitchMs, System.currentTimeMillis()
        )
        val differs = selection.path != boundPath
        val allowed = CallingNetworkPolicy.mayApplyNow(live) && !cleanupPending &&
            !settling && !transitioning && !electiveBlocked
        pending = differs && !allowed
        reason = selection.reason
        if (differs && allowed) {
            Log.i(tag, "Applying ${selection.path?.wire ?: "system"} (${selection.reason.wire}, $why)")
            applyRoute(selection.path)
        }
        Log.i(tag, "Evaluated ($why): pref=${preference.wire} enabled=$enabled " +
            "wifi=${candidate(wifi)} cellular=${candidate(cellular)} " +
            "selected=${selection.path?.wire ?: "system"}/${selection.reason.wire} " +
            "bound=${boundPath?.wire ?: "system"} pending=$pending live=$live " +
            "transitioning=$transitioning")
        onStatusChanged()
    }

    /**
     * Idle route change: bind, set DNS, and reconnect the SDK when the route
     * really changes. Reports the actually applied route, not the intended one.
     */
    private fun applyRoute(path: CallingNetworkPolicy.Path?) {
        val target = path?.let { slot(it).network }
        if (path != null && target == null) return
        val before = boundNetwork ?: manager.activeNetwork
        if (!bind(target)) {
            // Nothing was applied; keep reporting the previous route.
            reason = CallingNetworkPolicy.Reason.BIND_FAILED
            return
        }
        bindingGeneration++
        boundNetwork = target
        boundPath = path
        lastSwitchMs = System.currentTimeMillis()
        applyDns(target)
        val after = target ?: manager.activeNetwork
        val routeChanged = before != null && after != null && before != after
        Log.i(tag, "Route ${if (routeChanged) "changed" else "unchanged"}; " +
            "bound=${path?.wire ?: "system"} generation=$bindingGeneration")
        if (!routeChanged) return
        cycleSdk()
    }

    /**
     * Registration moves to the current route: SDK offline, then online again.
     * Needed whenever the SDK's sockets may be pinned to a network that is gone;
     * Android does not report a default-network change when the lost network
     * was not the default (mobile data lost while Wi-Fi stays up).
     */
    private fun cycleSdk() {
        val generation = bindingGeneration
        transitioning = true
        core()?.let { it.isNetworkReachable = false }
        val task = Runnable {
            reconnect = null
            if (generation != bindingGeneration) return@Runnable
            core()?.let { it.isNetworkReachable = true }
            transitioning = false
            evaluate("route_settled")
        }
        reconnect = task
        main.postDelayed(task, RECONNECT_GAP_MS)
    }

    private fun cancelReconnect() {
        // A cancelled task never turns the SDK back on, so do it here.
        reconnect?.let {
            main.removeCallbacks(it)
            core()?.let { c -> c.isNetworkReachable = true }
        }
        reconnect = null
    }

    /** Returns true only when Android accepted the binding. */
    private fun bind(network: Network?): Boolean = try {
        val ok = manager.bindProcessToNetwork(network)
        if (!ok) Log.w(tag, "bindProcessToNetwork refused")
        ok
    } catch (error: Throwable) {
        Log.w(tag, "bindProcessToNetwork failed", error)
        false
    }

    private fun applyDns(network: Network?) {
        val core = core() ?: return
        try {
            // The SDK's native binding aborts the process on a null array, so
            // "use the system's DNS servers" is expressed as an empty list.
            val servers = network?.let { manager.getLinkProperties(it)?.dnsServers }
                ?.mapNotNull { it.hostAddress }.orEmpty()
            core.setDnsServersApp(servers.toTypedArray())
        } catch (error: Throwable) {
            Log.w(tag, "Unable to set DNS servers", error)
        }
    }

    private companion object {
        const val PREFS = "voipcloud_calling_network"
        const val KEY_ENABLED = "enabled"
        const val KEY_PREFERENCE = "preference"
        const val PROBE_TIMEOUT_MS = 3_000
        const val PROBE_DEADLINE_MS = 6_000L
        const val PERSISTENT_FAILURE_MS = 10_000L
        const val PERIODIC_CHECK_MS = 5_000L
        const val HEALTHY_REPROBE_MS = 60_000L
        const val FAILED_REPROBE_MS = 15_000L
        const val RECONNECT_GAP_MS = 300L
        const val CLEANUP_SETTLE_MS = 1_500L
    }
}
