package com.thinkswift.softphoneapp

import android.Manifest
import android.app.KeyguardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.net.Uri
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.linphone.core.Account
import org.linphone.core.AccountParams
import org.linphone.core.AudioDevice
import org.linphone.core.AVPFMode
import org.linphone.core.Call
import org.linphone.core.ChatMessage
import org.linphone.core.ChatRoom
import org.linphone.core.Core
import org.linphone.core.CoreListenerStub
import org.linphone.core.Content
import org.linphone.core.Event
import org.linphone.core.Factory
import org.linphone.core.LogLevel
import org.linphone.core.LoggingService
import org.linphone.core.LoggingServiceListener
import org.linphone.core.MediaDirection
import org.linphone.core.Reason
import org.linphone.core.RegistrationState
import org.linphone.core.SubscriptionState
import org.linphone.core.ToneID
import org.linphone.core.TransportType
import java.util.Collections
import java.util.IdentityHashMap
import java.util.UUID

class MainActivity : FlutterActivity() {
    companion object {
        const val ACTION_EXTERNAL_CALL =
            "com.thinkswift.softphoneapp.action.EXTERNAL_CALL"
        const val ACTION_EXTERNAL_MESSAGE =
            "com.thinkswift.softphoneapp.action.EXTERNAL_MESSAGE"
        const val EXTRA_EXTERNAL_DESTINATION = "external_destination"
    }

    private val methodChannelName = "voipcloud/linphone"
    private val registrationEventsName = "voipcloud/linphone/registration"
    private val callEventsName = "voipcloud/linphone/calls"
    private val messageEventsName = "voipcloud/linphone/messages"
    private val sipLogEventsName = "voipcloud/linphone/logs"
    private val presenceEventsName = "voipcloud/linphone/presence"
    private val proximityChannelName = "voipcloud/proximity"
    private val messagingNotificationsChannelName = "voipcloud/messaging_notifications"
    private val externalCommunicationChannelName =
        "voipcloud/external_communication_intents"
    private val pickCsvRequestCode = 2401

    private var bridge: LinphoneBridge? = null
    private var proximityBridge: ProximityBridge? = null
    private var pendingCsvPickResult: MethodChannel.Result? = null
    private var messagingNotificationsChannel: MethodChannel? = null
    private var pendingMessagingNotification: Map<String, String>? = null
    private var externalCommunicationChannel: MethodChannel? = null
    private var pendingExternalCommunicationIntent: Map<String, String>? = null
    private var launchedForIncomingCall = false
    private var incomingCallSessionId: String? = null
    private val lockScreenCallListener: (AndroidCallCoordinator.Snapshot?) -> Unit = { snapshot ->
        runOnUiThread {
            if (!launchedForIncomingCall) return@runOnUiThread
            val expectedId = incomingCallSessionId
            val matches = snapshot != null && !snapshot.isTerminal &&
                (expectedId.isNullOrBlank() ||
                    snapshot.sessionId == expectedId || snapshot.sipCallId == expectedId)
            if (!matches) dismissLockScreenCallSurface()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Must run before super so LaunchTheme splash attrs (incl. icon plate color) apply.
        installSplashScreen()
        super.onCreate(savedInstanceState)
        AndroidCallCoordinator.initialize(applicationContext)
        AndroidCallCoordinator.addListener(lockScreenCallListener)
        configureIncomingCallWindow(intent)
        requestAudioPermissions()
        handleNotificationIntent(intent)
        handleExternalCommunicationIntent(intent)
    }

    override fun getInitialRoute(): String? {
        // Incoming-call launch state is native session data, not a Flutter
        // route. Let GoRouter use its configured initial location;
        // CallRouteListener will route the matched SIP call once synchronized.
        if (SoftphoneWakeHandler.isIncomingCallFullScreenIntent(intent)) {
            Log.i("VoIPCloud/Telecom", "Suppressing Flutter initial route for incoming call")
            return null
        }
        return super.getInitialRoute()
    }

    override fun onNewIntent(intent: Intent) {
        if (SoftphoneWakeHandler.isIncomingCallFullScreenIntent(intent)) {
            // Keep compatibility with any old full-screen PendingIntent that
            // survived an in-place app update and still contains a data URI.
            val flutterIntent = Intent(intent).apply { data = null }
            super.onNewIntent(flutterIntent)
        } else {
            super.onNewIntent(intent)
        }
        setIntent(intent)
        configureIncomingCallWindow(intent)
        handleNotificationIntent(intent)
        handleExternalCommunicationIntent(intent)
        bridge?.syncCurrentCall("new-intent")
    }

    override fun onStart() {
        super.onStart()
        SoftphoneAppState.isInForeground = true
        SoftphoneWakeHandler.refreshCallNotificationIfActive(this, "activity-visible")
    }

    override fun onResume() {
        super.onResume()
        bridge?.syncCurrentCall("activity-resume")
    }

    override fun onStop() {
        SoftphoneAppState.isInForeground = false
        SoftphoneWakeHandler.refreshCallNotificationIfActive(this, "activity-hidden")
        super.onStop()
    }

    override fun onDestroy() {
        AndroidCallCoordinator.removeListener(lockScreenCallListener)
        proximityBridge?.setEnabled(this, false)
        super.onDestroy()
    }

    private fun configureIncomingCallWindow(intent: Intent?) {
        if (!SoftphoneWakeHandler.isIncomingCallFullScreenIntent(intent)) return
        launchedForIncomingCall = true
        incomingCallSessionId = intent?.getStringExtra("call_session_id")
        val snapshot = AndroidCallCoordinator.snapshot()
        val matches = snapshot != null && !snapshot.isTerminal &&
            (incomingCallSessionId.isNullOrBlank() ||
                snapshot.sessionId == incomingCallSessionId ||
                snapshot.sipCallId == incomingCallSessionId)
        if (!matches) {
            Log.i("VoIPCloud/Telecom", "Discarding stale full-screen call intent")
            dismissLockScreenCallSurface()
            return
        }
        Log.i("VoIPCloud/Telecom", "Displaying Flutter incoming-call UI over keyguard")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun dismissLockScreenCallSurface() {
        if (!launchedForIncomingCall) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(false)
            setTurnScreenOn(false)
        }
        window.clearFlags(
            android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        )
        val keyguard = getSystemService(KeyguardManager::class.java)
        launchedForIncomingCall = false
        incomingCallSessionId = null
        if (keyguard?.isKeyguardLocked == true) finishAndRemoveTask()
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickCsvRequestCode) {
            return
        }
        val pending = pendingCsvPickResult
        pendingCsvPickResult = null
        if (pending == null) {
            return
        }
        if (resultCode != RESULT_OK || data?.data == null) {
            pending.success(null)
            return
        }
        try {
            val bytes = contentResolver.openInputStream(data.data!!)?.use { stream ->
                stream.readBytes()
            }
            if (bytes == null) {
                pending.error(
                    "READ_FAILED",
                    "Could not read the selected file.",
                    null
                )
            } else {
                pending.success(bytes)
            }
        } catch (error: Exception) {
            pending.error(
                "READ_FAILED",
                error.message ?: "Could not read the selected file.",
                null
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = LinphoneBridge.shared(applicationContext)
        bridge?.attachActivity(this)
        proximityBridge = ProximityBridge()

        messagingNotificationsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            messagingNotificationsChannelName
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumePendingNotification" -> {
                        val pending = pendingMessagingNotification
                        pendingMessagingNotification = null
                        result.success(pending)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        externalCommunicationChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            externalCommunicationChannelName
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumePendingIntent" -> {
                        val pending = pendingExternalCommunicationIntent
                        pendingExternalCommunicationIntent = null
                        result.success(pending)
                    }
                    "openSystemMessageFallback" -> {
                        val destination =
                            call.argument<String>("destination")?.trim().orEmpty()
                        if (!isSafeExternalDestination(destination)) {
                            result.error(
                                "INVALID_DESTINATION",
                                "The destination is not a valid phone number.",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        val fallback = Intent(
                            Intent.ACTION_SENDTO,
                            Uri.fromParts("smsto", destination, null)
                        )
                        if (fallback.resolveActivity(packageManager) == null) {
                            result.success(false)
                        } else {
                            startActivity(fallback)
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            methodChannelName
        ).setMethodCallHandler { call, result ->
            bridge?.handle(call, result) ?: result.error(
                "LINPHONE_BRIDGE_UNAVAILABLE",
                "Linphone bridge is unavailable.",
                null
            )
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            proximityChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    proximityBridge?.setEnabled(
                        activity = this,
                        enabled = call.argument<Boolean>("enabled") ?: false
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "voipcloud/files"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveToDownloads" -> {
                    try {
                        val fileName = call.argument<String>("fileName")?.trim().orEmpty()
                        val mimeType = call.argument<String>("mimeType")?.trim()
                            ?.ifEmpty { null } ?: "application/octet-stream"
                        val bytes = call.argument<ByteArray>("bytes")
                        if (fileName.isEmpty() || bytes == null) {
                            result.error(
                                "INVALID_ARGS",
                                "fileName and bytes are required.",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        val saved = saveBytesToDownloads(fileName, mimeType, bytes)
                        result.success(saved)
                    } catch (error: Exception) {
                        result.error(
                            "SAVE_FAILED",
                            error.message ?: "Could not save file to Downloads.",
                            null
                        )
                    }
                }
                "pickCsv" -> {
                    if (pendingCsvPickResult != null) {
                        result.error(
                            "PICK_IN_PROGRESS",
                            "A file picker is already open.",
                            null
                        )
                        return@setMethodCallHandler
                    }
                    pendingCsvPickResult = result
                    val picker = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        putExtra(
                            Intent.EXTRA_MIME_TYPES,
                            arrayOf(
                                "text/*",
                                "text/csv",
                                "text/comma-separated-values",
                                "application/csv",
                                "application/vnd.ms-excel",
                                "*/*"
                            )
                        )
                    }
                    @Suppress("DEPRECATION")
                    startActivityForResult(picker, pickCsvRequestCode)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            registrationEventsName
        ).setStreamHandler(ForwardingStreamHandler {
            bridge?.registrationSink = it
            if (it != null) {
                bridge?.syncRegistrationState("registration-stream-listen")
            }
        })
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            callEventsName
        ).setStreamHandler(ForwardingStreamHandler {
            bridge?.callSink = it
            if (it != null) {
                bridge?.syncCurrentCall("call-stream-listen")
            }
        })
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            messageEventsName
        ).setStreamHandler(ForwardingStreamHandler { bridge?.messageSink = it })
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            sipLogEventsName
        ).setStreamHandler(ForwardingStreamHandler { bridge?.sipLogSink = it })
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            presenceEventsName
        ).setStreamHandler(ForwardingStreamHandler { bridge?.presenceSink = it })

        bridge?.prepareForAppStart()
    }

    private fun requestAudioPermissions() {
        val permissions = mutableListOf(Manifest.permission.RECORD_AUDIO)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        val missing = permissions.filter {
            ActivityCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, missing.toTypedArray(), 1001)
        }
    }

    private fun handleNotificationIntent(intent: Intent?) {
        SoftphoneWakeHandler.carrierMessagePayload(intent)?.let { payload ->
            // Retain the cold-start notification until Dart explicitly consumes
            // it. The engine channel can exist before Dart installs its handler.
            pendingMessagingNotification = payload
            val channel = messagingNotificationsChannel
            if (channel != null) {
                channel.invokeMethod("notificationTapped", payload)
            }
            return
        }
    }

    private fun handleExternalCommunicationIntent(intent: Intent?) {
        if (intent == null) return

        val action = when {
            intent.action == ACTION_EXTERNAL_CALL -> "call"
            intent.action == ACTION_EXTERNAL_MESSAGE -> "message"
            intent.action == Intent.ACTION_DIAL &&
                intent.data?.scheme.equals("tel", ignoreCase = true) -> "call"
            else -> return
        }
        val destination = (
            intent.getStringExtra(EXTRA_EXTERNAL_DESTINATION)
                ?: intent.data?.schemeSpecificPart
            )?.trim().orEmpty()

        if (!isSafeExternalDestination(destination)) {
            Log.w("VoIPCloud/ExternalIntent", "Rejected invalid $action destination")
            return
        }

        val payload = mapOf(
            "id" to UUID.randomUUID().toString(),
            "action" to action,
            "destination" to destination
        )
        pendingExternalCommunicationIntent = payload
        externalCommunicationChannel?.invokeMethod(
            "externalCommunicationIntent",
            payload
        )

        // Prevent an activity recreation from replaying the same external action.
        intent.action = null
        intent.data = null
        intent.removeExtra(EXTRA_EXTERNAL_DESTINATION)
        Log.i("VoIPCloud/ExternalIntent", "Accepted external $action action")
    }

    private fun isSafeExternalDestination(destination: String): Boolean {
        if (destination.isBlank() || destination.length > 128) return false
        return destination.all { character ->
            character.isDigit() || character in "+*#().- "
        }
    }

    private fun saveBytesToDownloads(
        fileName: String,
        mimeType: String,
        bytes: ByteArray
    ): String {
        val resolver = contentResolver
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            val values = android.content.ContentValues().apply {
                put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(android.provider.MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(
                    android.provider.MediaStore.MediaColumns.RELATIVE_PATH,
                    android.os.Environment.DIRECTORY_DOWNLOADS
                )
                put(android.provider.MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(
                android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                values
            ) ?: throw IllegalStateException("Could not create Downloads entry.")
            resolver.openOutputStream(uri)?.use { output ->
                output.write(bytes)
                output.flush()
            } ?: throw IllegalStateException("Could not open Downloads stream.")
            values.clear()
            values.put(android.provider.MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return "Downloads/$fileName"
        }

        @Suppress("DEPRECATION")
        val directory = android.os.Environment.getExternalStoragePublicDirectory(
            android.os.Environment.DIRECTORY_DOWNLOADS
        )
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("Downloads folder is unavailable.")
        }
        var target = java.io.File(directory, fileName)
        if (target.exists()) {
            val stamp = java.text.SimpleDateFormat(
                "yyyyMMdd_HHmmss",
                java.util.Locale.US
            ).format(java.util.Date())
            val dot = fileName.lastIndexOf('.')
            val renamed = if (dot > 0) {
                "${fileName.substring(0, dot)}_$stamp${fileName.substring(dot)}"
            } else {
                "${fileName}_$stamp"
            }
            target = java.io.File(directory, renamed)
        }
        java.io.FileOutputStream(target).use { output ->
            output.write(bytes)
            output.flush()
        }
        return "Downloads/${target.name}"
    }
}

private class ProximityBridge {
    private var wakeLock: PowerManager.WakeLock? = null

    fun setEnabled(activity: MainActivity, enabled: Boolean) {
        if (enabled) {
            val existing = wakeLock
            if (existing?.isHeld == true) return
            val powerManager = activity.getSystemService(PowerManager::class.java)
            if (!powerManager.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
                return
            }
            wakeLock = powerManager.newWakeLock(
                PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                "VoIPCloud:Proximity"
            ).also { it.acquire() }
            return
        }
        wakeLock?.let {
            if (it.isHeld) {
                it.release()
            }
        }
        wakeLock = null
    }
}

private class ForwardingStreamHandler(
    private val update: (EventChannel.EventSink?) -> Unit
) : EventChannel.StreamHandler {
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) = update(events)

    override fun onCancel(arguments: Any?) = update(null)
}

private class LinphoneBridge private constructor(private val context: android.content.Context) {
    var registrationSink: EventChannel.EventSink? = null
    var callSink: EventChannel.EventSink? = null
    var messageSink: EventChannel.EventSink? = null
    var sipLogSink: EventChannel.EventSink? = null
    var presenceSink: EventChannel.EventSink? = null
    private var hostActivity: MainActivity? = null
    private val telecomListener: (AndroidCallCoordinator.Snapshot?) -> Unit = { snapshot ->
        if (snapshot != null) emitCoordinatorSnapshot(snapshot)
    }

    init {
        AndroidCallCoordinator.initialize(context)
        AndroidCallCoordinator.addListener(telecomListener)
    }

    companion object {
        private const val FEATURE_CODE_HANGUP_DELAY_MS = 1500L
        private const val MOBILE_REGISTRATION_EXPIRES_SECONDS = 604_800
        private const val PUSH_CALL_RECONCILE_INTERVAL_MS = 150L
        private const val PUSH_CALL_RECONCILE_TIMEOUT_MS = 20_000L
        private var instance: LinphoneBridge? = null

        fun shared(context: android.content.Context): LinphoneBridge {
            return instance ?: LinphoneBridge(context.applicationContext).also {
                instance = it
            }
        }
    }

    fun attachActivity(activity: MainActivity) {
        hostActivity = activity
    }

    private var core: Core? = null
    private var account: Account? = null
    private val calls = mutableMapOf<String, Call>()
    private data class PresenceSubscription(
        val extension: String,
        val eventPackage: String
    )

    private val presenceSubscriptions =
        IdentityHashMap<Event, PresenceSubscription>()
    private val featureCodeCalls =
        Collections.newSetFromMap(IdentityHashMap<Call, Boolean>())
    private val featureCodeTerminateScheduled =
        Collections.newSetFromMap(IdentityHashMap<Call, Boolean>())
    private var featureCodePreviousMicEnabled: Boolean? = null
    @Volatile private var pendingFeatureCodeDial = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pushCallReconcileGeneration = 0
    private var linphoneLogListener: LoggingServiceListener? = null
    private var audioRouteCallId: String? = null
    private var requestedAudioRoute = "earpiece"
    @Volatile private var sipLoggingEnabled: Boolean = false
    private val sipLogFileLock = Any()
    private val maxSipLogBytes = 1_500_000L
    private val callProgressToneGainDb = -9.0f

    private val listener = object : CoreListenerStub() {
        override fun onAccountRegistrationStateChanged(
            core: Core,
            account: Account,
            state: RegistrationState?,
            message: String
        ) {
            Log.i(
                "VoIPCloud/Linphone",
                "Registration state=${registrationState(state)} message=${message.ifBlank { "none" }}"
            )
            emitRegistration(registrationState(state), message)
        }

        override fun onCallStateChanged(
            core: Core,
            call: Call,
            state: Call.State?,
            message: String
        ) {
            val currentState = state ?: call.state
            updateCallToneLevel(core, currentState)
            // inviteAddressWithParams can notify synchronously before dialFeatureCode
            // adds the Call to featureCodeCalls — adopt it while a feature dial is pending.
            if (pendingFeatureCodeDial) {
                featureCodeCalls.add(call)
            }
            val isFeatureCode = call in featureCodeCalls
            if (isFeatureCode) {
                maybeTerminateFeatureCodeCall(call, currentState)
                emitCall(call, currentState, featureCode = true)
                if (isTerminalCallState(currentState)) {
                    clearFeatureCodeCall(call)
                }
                return
            }
            reportCallToCoordinator(call, currentState, "listener")
            if (!AndroidCallCoordinator.isManagingCall()) {
                prepareAudioRoute(call, currentState)
            }
            emitCall(call, currentState, featureCode = false)
        }

        override fun onAudioDevicesListUpdated(core: Core) {
            if (!AndroidCallCoordinator.isManagingCall()) {
                reconcileAudioDevices("devices-updated")
            }
        }

        override fun onAudioDeviceChanged(core: Core, audioDevice: AudioDevice) {
            // Keep requested route authoritative, but refresh UI if hardware flapped.
            findCurrentCall()?.let { emitCall(it, it.state) }
        }

        override fun onMessageReceived(core: Core, chatRoom: ChatRoom, message: ChatMessage) {
            val from = message.fromAddress?.asStringUriOnly() ?: ""
            messageSink?.success(
                mapOf(
                    "id" to (message.messageId ?: "${System.currentTimeMillis()}"),
                    "remoteUri" to from,
                    "direction" to "incoming",
                    "text" to (message.utf8Text ?: ""),
                    "status" to "delivered",
                    "createdAt" to System.currentTimeMillis()
                )
            )
        }

        override fun onNotifyReceived(
            core: Core,
            linphoneEvent: Event,
            notifiedEvent: String,
            body: Content?
        ) {
            val subscription = presenceSubscriptions[linphoneEvent] ?: return
            if (!notifiedEvent.equals(subscription.eventPackage, ignoreCase = true)) return
            presenceSink?.success(
                mapOf(
                    "kind" to "notify",
                    "extension" to subscription.extension,
                    "event" to notifiedEvent,
                    "contentType" to "${body?.type.orEmpty()}/${body?.subtype.orEmpty()}",
                    "body" to body?.utf8Text.orEmpty()
                )
            )
        }

        override fun onSubscriptionStateChanged(
            core: Core,
            linphoneEvent: Event,
            state: SubscriptionState?
        ) {
            val subscription = presenceSubscriptions[linphoneEvent] ?: return
            presenceSink?.success(
                mapOf(
                    "kind" to "subscription",
                    "extension" to subscription.extension,
                    "event" to subscription.eventPackage,
                    "state" to subscriptionState(state)
                )
            )
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "initialize" -> {
                    initialize()
                    result.success(null)
                }
                "configureAccount" -> {
                    configureAccount(call.arguments as? Map<*, *> ?: emptyMap<String, Any?>())
                    result.success(null)
                }
                "register" -> {
                    updateRegistrationEnabled(true)
                    core?.refreshRegisters()
                    result.success(null)
                }
                "syncCurrentCall" -> {
                    syncCurrentCall("dart-sync")
                    result.success(null)
                }
                "hasActiveCall" -> {
                    result.success(hasActiveCall())
                }
                "enterBackground" -> {
                    SoftphoneAppState.isInForeground = false
                    SoftphoneWakeHandler.startLinphoneCore(context, "enter-background")
                    core?.enterBackground()
                    result.success(null)
                }
                "enterForeground" -> {
                    SoftphoneAppState.isInForeground = true
                    core?.enterForeground()
                    result.success(null)
                }
                "isBatteryOptimizationIgnored" -> {
                    result.success(
                        SoftphoneBackgroundPermissions.isIgnoringBatteryOptimizations(context)
                    )
                }
                "requestIgnoreBatteryOptimizations" -> {
                    val activity = hostActivity
                    if (activity == null) {
                        result.success(false)
                    } else {
                        result.success(
                            SoftphoneBackgroundPermissions.requestIgnoreBatteryOptimizations(activity)
                        )
                    }
                }
                "openBatteryOptimizationSettings" -> {
                    try {
                        val activity = hostActivity
                        SoftphoneBackgroundPermissions.openBatteryOptimizationSettings(
                            activity ?: context
                        )
                        result.success(null)
                    } catch (error: Throwable) {
                        Log.e("Softphone/Background", "Failed to open battery settings", error)
                        result.success(null)
                    }
                }
                "canUseFullScreenIntent" -> {
                    result.success(
                        SoftphoneBackgroundPermissions.canUseFullScreenIntent(context)
                    )
                }
                "requestFullScreenIntentPermission" -> {
                    val activity = hostActivity
                    if (activity == null) {
                        result.success(false)
                    } else {
                        result.success(
                            SoftphoneBackgroundPermissions
                                .requestFullScreenIntentPermission(activity)
                        )
                    }
                }
                "updateDirectoryCache" -> {
                    val entries = call.argument<List<Map<*, *>>>("entries") ?: emptyList()
                    CallerIdentityStore.updateDirectory(
                        context,
                        call.argument<String>("tenantKey") ?: "default",
                        entries
                    )
                    result.success(null)
                }
                "setNativeDnd" -> {
                    CallerIdentityStore.setDnd(
                        context,
                        call.argument<Boolean>("enabled") ?: false
                    )
                    result.success(null)
                }
                "clearNativeCallState" -> {
                    CallerIdentityStore.clear(context)
                    result.success(null)
                }
                "ensureBluetoothPermission" -> {
                    result.success(ensureBluetoothPermission())
                }
                "getAudioRoutes" -> {
                    result.success(getAudioRoutes())
                }
                "setAudioRoute" -> {
                    val route = call.argument<String>("route") ?: "earpiece"
                    val endpointId = call.argument<String>("endpointId")
                    if (AndroidCallCoordinator.isManagingCall()) {
                        val callback: (Result<String>) -> Unit = { outcome ->
                            outcome.fold(
                                onSuccess = result::success,
                                onFailure = { error -> result.error("AUDIO_ROUTE", error.message, null) }
                            )
                        }
                        if (endpointId.isNullOrBlank()) {
                            AndroidCallCoordinator.requestRoute(route, callback)
                        } else {
                            AndroidCallCoordinator.requestEndpoint(endpointId, callback)
                        }
                    } else {
                        result.success(setAudioRoute(route))
                    }
                }
                "unregister" -> {
                    stopPresenceSubscriptions()
                    updateRegistrationEnabled(false)
                    core?.refreshRegisters()
                    result.success(null)
                }
                "purgeAccount" -> {
                    purgeAccount()
                    result.success(null)
                }
                "makeCall" -> {
                    val destination = call.argument<String>("destination") ?: ""
                    AndroidCallCoordinator.beginOutgoing(context, destination) { outcome ->
                        outcome.fold(
                            onSuccess = {
                                runCatching { makeCall(destination) }.fold(
                                    onSuccess = { result.success(null) },
                                    onFailure = { error ->
                                        AndroidCallCoordinator.endFromApp(context)
                                        result.error("CALL_FAILED", error.message, null)
                                    }
                                )
                            },
                            onFailure = { error -> result.error("TELECOM_UNAVAILABLE", error.message, null) }
                        )
                    }
                }
                "dialFeatureCode" -> {
                    val id = dialFeatureCode(call.argument<String>("code") ?: "")
                    result.success(id)
                }
                "acceptCall" -> {
                    val requestedId = call.argument<String>("callId")
                    val incoming = findCall(requestedId)
                    if (AndroidCallCoordinator.canAnswerIncoming(requestedId) ||
                        (incoming != null && isIncomingRinging(incoming))
                    ) {
                        AndroidCallCoordinator.answerFromApp(context)
                        result.success(null)
                    } else {
                        result.error("CALL_ENDED", "This incoming call has already ended.", null)
                    }
                }
                "rejectCall" -> {
                    AndroidCallCoordinator.rejectFromApp(context)
                    result.success(null)
                }
                "endCall" -> {
                    val requestedId = call.argument<String>("callId")
                    val activeCall = findCall(requestedId)
                    if (activeCall == null) {
                        Log.w(
                            "VoIPCloud/Linphone",
                            "End call requested but no active call was found id=$requestedId"
                        )
                        result.error("CALL_NOT_FOUND", "There is no active call to end.", null)
                    } else {
                        Log.i(
                            "VoIPCloud/Linphone",
                            "Ending call requestedId=$requestedId nativeId=${callId(activeCall)} state=${activeCall.state}"
                        )
                        AndroidCallCoordinator.endFromApp(context)
                        result.success(null)
                    }
                }
                "mute" -> {
                    AndroidCallCoordinator.setMuted(
                        context,
                        call.argument<Boolean>("enabled") ?: false
                    )
                    result.success(null)
                }
                "hold" -> {
                    holdCall(call.argument<String>("callId"), result)
                }
                "resume" -> {
                    resumeCall(call.argument<String>("callId"), result)
                }
                "setSpeaker" -> {
                    val route = if (call.argument<Boolean>("enabled") == true) "speaker" else "earpiece"
                    if (AndroidCallCoordinator.isManagingCall()) {
                        AndroidCallCoordinator.requestRoute(route) { }
                    } else setAudioRoute(route)
                    result.success(null)
                }
                "setBluetooth" -> {
                    val route = if (call.argument<Boolean>("enabled") == true) "bluetooth" else "earpiece"
                    if (AndroidCallCoordinator.isManagingCall()) {
                        AndroidCallCoordinator.requestRoute(route) { }
                    } else setAudioRoute(route)
                    result.success(null)
                }
                "sendDtmf" -> {
                    findCurrentCall()?.sendDtmf((call.argument<String>("value") ?: "").firstOrNull() ?: return result.success(null))
                    result.success(null)
                }
                "getCallQuality" -> {
                    result.success(getCallQuality(call.argument<String>("callId")))
                }
                "transferCall" -> {
                    transferCall(
                        call.argument<String>("callId"),
                        call.argument<String>("destination") ?: ""
                    )
                    result.success(null)
                }
                "sendMessage" -> {
                    sendMessage(
                        call.argument<String>("destination") ?: "",
                        call.argument<String>("text") ?: ""
                    )
                    result.success(null)
                }
                "startPresenceSubscriptions" -> {
                    val extensions = call.argument<List<*>>("extensions") ?: emptyList<Any?>()
                    startPresenceSubscriptions(extensions)
                    result.success(null)
                }
                "stopPresenceSubscriptions" -> {
                    stopPresenceSubscriptions()
                    result.success(null)
                }
                "setSipLoggingEnabled" -> {
                    setSipLoggingEnabled(call.argument<Boolean>("enabled") ?: false)
                    result.success(null)
                }
                "appendSipLogLine" -> {
                    appendSipLogLine(call.argument<String>("line") ?: "")
                    result.success(null)
                }
                "readSipLogFile" -> {
                    result.success(readSipLogFile())
                }
                "clearSipLogFile" -> {
                    clearSipLogFile()
                    result.success(null)
                }
                "dispose" -> {
                    if (hasActiveCall()) {
                        Log.w(
                            "VoIPCloud/Linphone",
                            "Skipping native core dispose while a call is active"
                        )
                    } else {
                        dispose()
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            result.error("LINPHONE_ERROR", error.message ?: "Linphone operation failed.", null)
        }
    }

    private fun initialize() {
        if (core != null) return
        val factory = Factory.instance()
        factory.setDebugMode(sipLoggingEnabled || BuildConfig.DEBUG, "VoIPCloud")
        configureLinphoneLogging(sipLoggingEnabled || BuildConfig.DEBUG)
        val basePath = context.filesDir.absolutePath
        core = factory.createCore(
            "$basePath/.linphonerc",
            "$basePath/linphonerc",
            context
        ).also {
            it.addListener(listener)
            it.isIpv6Enabled = true
            // Identify VoIPCloud mobile registrations so Flexisip can route
            // app and server-side anchor traffic without per-extension rules.
            it.setUserAgent("VoIPCloud-Mobile", BuildConfig.VERSION_NAME)
            // Ensure liblinphone creates its PushNotificationConfig before
            // account setup. configurePushNotifications() then replaces the
            // generated values with the FCM token supplied by Flutter.
            it.isPushNotificationEnabled = true
            // FreePBX/Asterisk: prefer sendonly hold SDP (not inactive). Inactive
            // re-INVITEs are a known cause of immediate remote BYE on some PBXs.
            it.config?.setInt("sip", "inactive_audio_on_pause", 0)
            // Don't auto-pause when Android audio focus briefly drops (common on
            // OnePlus/Oppo during route changes); that races with explicit Hold.
            it.config?.setInt("audio", "android_pause_calls_when_audio_focus_lost", 0)
            // Use Linphone's internal ringer so call-progress volume can be
            // attenuated independently of Android's user-controlled ring volume.
            it.isNativeRingingEnabled = false
            it.isCallToneIndicationsEnabled = false
            it.playbackGainDb = 0.0f
            // AVPF re-INVITEs during hold are poorly tolerated by many Asterisk builds.
            it.avpfMode = AVPFMode.Disabled
            it.setTone(
                ToneID.CallEnd,
                "${context.cacheDir}/__voipcloud_disabled_call_end_tone__.wav"
            )
            it.start()
        }
        // An INVITE can be processed while createCore()/start() is still
        // returning on a cold wake. Reconcile it only after [core] is assigned
        // so coordinator answer/decline operations can find the SDK call.
        core?.calls?.toList()?.forEach { existingCall ->
            reportCallToCoordinator(existingCall, existingCall.state, "core_start")
        }
        account = core?.defaultAccount ?: core?.accountList?.firstOrNull()
        val loadedState = account?.state
        if (loadedState != null) {
            emitRegistration(registrationState(loadedState), null)
        } else {
            emitRegistration("unregistered", null)
        }
    }

    private fun updateCallToneLevel(core: Core, state: Call.State) {
        core.playbackGainDb = when (state) {
            Call.State.PushIncomingReceived,
            Call.State.IncomingReceived,
            Call.State.IncomingEarlyMedia,
            Call.State.OutgoingInit,
            Call.State.OutgoingProgress,
            Call.State.OutgoingRinging,
            Call.State.OutgoingEarlyMedia -> callProgressToneGainDb
            else -> 0.0f
        }
    }

    fun isRegistered(): Boolean {
        val currentAccount = account ?: core?.defaultAccount ?: core?.accountList?.firstOrNull()
        return currentAccount?.state == RegistrationState.Ok
    }

    fun sipExtension(): String? {
        val currentAccount = account ?: core?.defaultAccount ?: core?.accountList?.firstOrNull()
        val username = currentAccount?.params?.identityAddress?.username?.trim()
        if (!username.isNullOrEmpty()) return username
        val saved = SipCredentialStore.load(context) ?: return null
        return (saved["sipUsername"] as? String)?.trim()?.takeIf { it.isNotEmpty() }
    }

    fun syncRegistrationState(reason: String) {
        val currentAccount = account ?: core?.defaultAccount ?: core?.accountList?.firstOrNull()
        val currentState = currentAccount?.state
        val status = registrationState(currentState)
        Log.i(
            "VoIPCloud/Linphone",
            "Replaying registration state reason=$reason status=$status accounts=${core?.accountList?.size ?: 0}"
        )
        emitRegistration(status, null)
    }

    fun prepareForAppStart() {
        try {
            initialize()
            restoreSavedAccountIfNeeded()
            account = core?.defaultAccount ?: core?.accountList?.firstOrNull() ?: account
            core?.refreshRegisters()
            syncCurrentCall("app-start")
            Log.i(
                "VoIPCloud/Linphone",
                "Prepared SIP core at app start accounts=${core?.accountList?.size ?: 0} registered=${isRegistered()}"
            )
        } catch (error: Throwable) {
            Log.e("VoIPCloud/Linphone", "Failed to prepare SIP core at app start", error)
        }
    }

    fun wakeFromPush(reason: String = "fcm_push") {
        try {
            initialize()
            restoreSavedAccountIfNeeded()
            account = core?.defaultAccount ?: core?.accountList?.firstOrNull() ?: account
            core?.refreshRegisters()
            syncCurrentCall(reason)
            schedulePushCallReconciliation(reason)
            Log.i(
                "VoIPCloud/Linphone",
                "Woke SIP core from push reason=$reason accounts=${core?.accountList?.size ?: 0} registered=${isRegistered()}"
            )
        } catch (error: Throwable) {
            Log.e("VoIPCloud/Linphone", "Failed to wake SIP core from push reason=$reason", error)
        }
    }

    private fun restoreSavedAccountIfNeeded() {
        val currentCore = core ?: return
        if (currentCore.accountList.isNotEmpty()) {
            account = currentCore.defaultAccount ?: currentCore.accountList.firstOrNull()
            enforceMobileRegistrationExpiry()
            return
        }
        val saved = SipCredentialStore.load(context) ?: return
        if (BuildConfig.DEBUG) {
            Log.d("VoIPCloud/Linphone", "Restoring saved SIP account after process restart")
        }
        configureAccount(saved)
    }

    private fun enforceMobileRegistrationExpiry() {
        val currentAccount = account ?: return
        if (currentAccount.params.expires == MOBILE_REGISTRATION_EXPIRES_SECONDS) return

        val params = currentAccount.params.clone()
        params.expires = MOBILE_REGISTRATION_EXPIRES_SECONDS
        currentAccount.params = params
        currentAccount.refreshRegister()
        Log.i(
            "VoIPCloud/Linphone",
            "Migrated SIP registration expiry to $MOBILE_REGISTRATION_EXPIRES_SECONDS seconds"
        )
    }

    private fun configureAccount(args: Map<*, *>) {
        if (hasActiveCall()) {
            if (BuildConfig.DEBUG) {
                Log.d(
                    "VoIPCloud/Linphone",
                    "Skipping configureAccount while a call is active"
                )
            }
            return
        }
        initialize()
        val currentCore = requireNotNull(core)
        val username = stringArg(args, "sipUsername")
        val authUsername = stringArg(args, "authUsername").ifEmpty { username }
        val password = stringArg(args, "password")
        val ha1 = stringArg(args, "ha1")
        val algorithm = stringArg(args, "algorithm")
        val domain = stringArg(args, "domain")
        val registrar = stringArg(args, "registrar").ifEmpty { domain }
        val realm = stringArg(args, "realm").ifEmpty { domain }
        val authDomain = stringArg(args, "authDomain").ifEmpty { realm }
        val outboundProxy = stringArg(args, "outboundProxy")
        val stunServer = stringArg(args, "stunServer")
        val turnServer = stringArg(args, "turnServer")
        val displayName = stringArg(args, "displayName").ifEmpty { null }
        val transport = transportType(stringArg(args, "transport"))
        val pushProvider = stringArg(args, "pushProvider")
        val pushToken = stringArg(args, "pushToken")
        val pushParam = stringArg(args, "pushParam")
        val pushBundleId = stringArg(args, "pushBundleId")
        val pushTeamId = stringArg(args, "pushTeamId")

        currentCore.accountList.forEach { currentCore.removeAccount(it) }
        currentCore.authInfoList.forEach { currentCore.removeAuthInfo(it) }
        configureNatPolicy(currentCore, stunServer, turnServer)

        val authInfo = Factory.instance().createAuthInfo(
            authUsername,
            username,
            password.ifEmpty { null },
            ha1.ifEmpty { null },
            realm,
            authDomain,
            algorithm.ifEmpty { null }
        )
        currentCore.addAuthInfo(authInfo)
        if (BuildConfig.DEBUG) {
            Log.d(
                "VoIPCloud/Linphone",
                "Added SIP auth info username=$authUsername userid=$username realm=$realm authDomain=$authDomain hasPassword=${password.isNotEmpty()} hasHa1=${ha1.isNotEmpty()} algorithm=${algorithm.ifEmpty { "default" }}"
            )
        }

        val identity = requireNotNull(Factory.instance().createAddress("sip:$username@$domain"))
        identity.displayName = displayName
        // Liblinphone's route list applies to calls, but REGISTER is sent to
        // serverAddress. Use the edge proxy as the server so push contacts are
        // stored by Flexisip instead of registering directly with the PBX.
        val serverAddressValue = normalizeSipAddress(outboundProxy.ifEmpty { registrar })
        val server = requireNotNull(Factory.instance().createAddress(serverAddressValue))
        server.transport = transport

        val params = currentCore.createAccountParams()
        params.identityAddress = identity
        params.serverAddress = server
        // Mobile push contacts must outlive OS suspension. This matches the
        // Flexisip registrar's seven-day max-expires policy.
        params.expires = MOBILE_REGISTRATION_EXPIRES_SECONDS
        params.setOutboundProxyEnabled(outboundProxy.isNotEmpty())
        configurePushNotifications(
            currentCore,
            params,
            pushProvider,
            pushToken,
            pushParam,
            pushBundleId,
            pushTeamId
        )
        params.setRegisterEnabled(true)

        account = currentCore.createAccount(params)
        currentCore.addAccount(account!!)
        currentCore.defaultAccount = account
        SipCredentialStore.save(context, args)
        Log.i(
            "VoIPCloud/Linphone",
            "Account signaling configuredRegistrar=${normalizeSipAddress(registrar)} server=${server.asStringUriOnly()} edgeProxy=${outboundProxy.isNotEmpty()} outboundProxyMode=${params.isOutboundProxyEnabled}"
        )
        if (BuildConfig.DEBUG) {
            Log.d(
                "VoIPCloud/Linphone",
                "Configured SIP account identity=${identity.asStringUriOnly()} registrar=${normalizeSipAddress(registrar)} server=${server.asStringUriOnly()} edge=${outboundProxy.ifEmpty { "none" }} routingMode=${if (outboundProxy.isEmpty()) "registrar-direct" else "edge-proxy"} stun=${stunServer.ifEmpty { "none" }} turn=${turnServer.ifEmpty { "none" }}"
            )
        }
        emitRegistration("configuring", "SIP account configured")
    }

    private fun configurePushNotifications(
        currentCore: Core,
        params: AccountParams,
        provider: String,
        token: String,
        param: String,
        bundleId: String,
        teamId: String
    ) {
        if (provider.isEmpty() || token.isEmpty()) {
            params.setPushNotificationAllowed(false)
            params.setRemotePushNotificationAllowed(false)
            return
        }

        val config = currentCore.pushNotificationConfig?.clone()
            ?: params.pushNotificationConfig?.clone()
            ?: run {
                params.setPushNotificationAllowed(false)
                params.setRemotePushNotificationAllowed(false)
                if (BuildConfig.DEBUG) {
                    Log.w(
                        "VoIPCloud/Linphone",
                        "Push token is available, but Linphone did not provide a push notification config"
                    )
                }
                return
            }
        config.provider = provider
        config.prid = token
        if (param.isNotEmpty()) {
            config.param = param
        }
        config.bundleIdentifier = bundleId.ifEmpty { context.packageName }
        if (teamId.isNotEmpty()) {
            config.teamId = teamId
        }
        params.setPushNotificationConfig(config)
        params.setPushNotificationAllowed(true)
        params.setRemotePushNotificationAllowed(true)

        if (BuildConfig.DEBUG) {
            Log.d(
                "VoIPCloud/Linphone",
                "Configured push provider=$provider param=${param.ifEmpty { "none" }} bundle=${config.bundleIdentifier} hasToken=${token.isNotEmpty()}"
            )
        }
    }

    private fun configureNatPolicy(currentCore: Core, stunServer: String, turnServer: String) {
        val normalizedStun = normalizeRelayServer(stunServer)
        val normalizedTurn = normalizeRelayServer(turnServer)
        if (normalizedStun.isEmpty() && normalizedTurn.isEmpty()) {
            return
        }

        val policy = currentCore.createNatPolicy()
        if (normalizedStun.isNotEmpty()) {
            policy.stunServer = normalizedStun
            policy.isStunEnabled = true
            policy.isIceEnabled = true
        }
        if (normalizedTurn.isNotEmpty()) {
            policy.stunServer = normalizedTurn
            policy.isTurnEnabled = true
            policy.isUdpTurnTransportEnabled = true
            policy.isIceEnabled = true
        }
        currentCore.natPolicy = policy
        if (BuildConfig.DEBUG) {
            Log.d(
                "VoIPCloud/Linphone",
                "Configured NAT policy stun=${normalizedStun.ifEmpty { "none" }} turn=${normalizedTurn.ifEmpty { "none" }} ice=${policy.isIceEnabled}"
            )
        }
    }

    private fun makeCall(destination: String) {
        val currentCore = requireNotNull(core)
        val address = normalizeDestination(destination)
        val params = currentCore.createCallParams(null)
        params?.isVideoEnabled = false
        if (!AndroidCallCoordinator.isManagingCall()) {
            params?.outputAudioDevice = preferredOutputDevice(currentCore)
        }
        val call = params?.let { currentCore.inviteAddressWithParams(address, it) }
            ?: currentCore.inviteAddress(address)
        if (call != null) {
            calls[callId(call)] = call
            emitCall(call, call.state)
        }
    }

    private fun dialFeatureCode(code: String): String? {
        val trimmed = code.trim()
        if (trimmed.isEmpty()) {
            throw IllegalArgumentException("Feature code is required.")
        }
        val currentCore = requireNotNull(core)
        val address = normalizeDestination(trimmed)
        val params = currentCore.createCallParams(null)
        params?.isVideoEnabled = false
        params?.outputAudioDevice = preferredOutputDevice(currentCore)
        if (featureCodePreviousMicEnabled == null) {
            featureCodePreviousMicEnabled = currentCore.isMicEnabled
            currentCore.isMicEnabled = false
        }
        // Mark before invite — Core may fire onCallStateChanged synchronously.
        pendingFeatureCodeDial = true
        val call = try {
            params?.let { currentCore.inviteAddressWithParams(address, it) }
                ?: currentCore.inviteAddress(address)
        } finally {
            pendingFeatureCodeDial = false
        } ?: return null
        featureCodeCalls.add(call)
        val id = callId(call)
        calls[id] = call
        Log.i("VoIPCloud/Linphone", "Feature-code dial code=$trimmed id=$id")
        emitCall(call, call.state, featureCode = true)
        return id
    }

    private fun maybeTerminateFeatureCodeCall(call: Call, state: Call.State) {
        if (state != Call.State.Connected && state != Call.State.StreamsRunning) {
            return
        }
        if (!featureCodeTerminateScheduled.add(call)) {
            return
        }
        mainHandler.postDelayed({
            try {
                if (call in featureCodeCalls && !isTerminalCallState(call.state)) {
                    Log.i(
                        "VoIPCloud/Linphone",
                        "Auto-terminating feature-code call id=${callId(call)}"
                    )
                    call.terminate()
                }
            } catch (error: Throwable) {
                Log.w(
                    "VoIPCloud/Linphone",
                    "Failed to terminate feature-code call id=${callId(call)}",
                    error
                )
            }
        }, FEATURE_CODE_HANGUP_DELAY_MS)
    }

    private fun clearFeatureCodeCall(call: Call) {
        featureCodeCalls.remove(call)
        featureCodeTerminateScheduled.remove(call)
        if (featureCodeCalls.isEmpty()) {
            featureCodePreviousMicEnabled?.let { previous ->
                core?.isMicEnabled = previous
            }
            featureCodePreviousMicEnabled = null
        }
    }

    private fun transferCall(callId: String?, destination: String) {
        val activeCall = findCall(callId)
            ?: throw IllegalStateException("There is no active call to transfer.")
        val trimmed = destination.trim()
        if (trimmed.isEmpty()) {
            throw IllegalArgumentException("Transfer destination is required.")
        }
        val address = normalizeDestination(trimmed)
        val status = activeCall.transferTo(address)
        if (status < 0) {
            throw IllegalStateException("Call transfer failed.")
        }
        Log.i(
            "VoIPCloud/Linphone",
            "Blind transfer requestedId=$callId destination=${address.asStringUriOnly()} status=$status"
        )
    }

    private fun sendMessage(destination: String, text: String) {
        if (destination.isBlank() || text.isBlank()) return
        val currentCore = requireNotNull(core)
        val peer = normalizeDestination(destination)
        val params = currentCore.createConferenceParams(null)
        params.isChatEnabled = true
        params.account = account
        val chatRoom = requireNotNull(currentCore.createChatRoom(params, arrayOf(peer)))
        val message = chatRoom.createEmptyMessage()
        message.addUtf8TextContent(text)
        message.send()
        messageSink?.success(
            mapOf(
                "id" to (message.messageId ?: "${System.currentTimeMillis()}"),
                "remoteUri" to peer.asStringUriOnly(),
                "direction" to "outgoing",
                "text" to text,
                "status" to "sent",
                "createdAt" to System.currentTimeMillis()
            )
        )
    }

    private fun getCallQuality(callId: String?): Map<String, Any?> {
        val active = findCall(callId) ?: findCurrentCall()
            ?: throw IllegalStateException("There is no active call.")
        val stats = active.audioStats
        val roundTripSeconds = stats?.roundTripDelay?.toDouble()
        val codec = active.currentParams?.usedAudioPayloadType?.mimeType
        return mapOf(
            "callId" to callId(active),
            "capturedAt" to java.time.Instant.now().toString(),
            "currentQuality" to active.currentQuality.toDouble().takeIf { it >= 0 },
            "averageQuality" to active.averageQuality.toDouble().takeIf { it >= 0 },
            "roundTripMs" to roundTripSeconds?.times(1000.0),
            "jitterBufferMs" to stats?.jitterBufferSizeMs?.toDouble(),
            "receiverLossPercent" to stats?.receiverLossRate?.toDouble(),
            "senderLossPercent" to stats?.senderLossRate?.toDouble(),
            "localLossPercent" to stats?.localLossRate?.toDouble(),
            "downloadKbps" to stats?.downloadBandwidth?.toDouble(),
            "uploadKbps" to stats?.uploadBandwidth?.toDouble(),
            "codec" to codec,
            "durationSeconds" to active.duration,
            "audioRoute" to audioRouteForCall(active),
            "remoteUri" to (active.remoteAddress?.asStringUriOnly() ?: ""),
        )
    }

    private fun reconcileAudioDevices(reason: String) {
        val currentCore = core ?: return
        val currentCall = findCurrentCall()
        if (AndroidCallCoordinator.isManagingCall()) {
            // Core-Telecom is the only route authority for a managed call.
            // Linphone follows Android's communication route; assigning one of
            // its enumerated devices here races Bluetooth/automotive endpoints.
            currentCall?.let { emitCall(it, it.state) }
            Log.i(
                "VoIPCloud/Linphone",
                "Audio device update observed under Telecom reason=$reason"
            )
            return
        }
        val devices = availableAudioDevices(currentCore)
        val bluetoothAvailable = findOutputDevice(devices, "bluetooth") != null
        val previous = requestedAudioRoute

        when {
            requestedAudioRoute == "bluetooth" && !bluetoothAvailable -> {
                requestedAudioRoute = "earpiece"
            }
            findOutputDevice(devices, requestedAudioRoute) == null -> {
                requestedAudioRoute = "earpiece"
            }
        }

        if (currentCall != null) {
            applyAudioRoute(currentCore, currentCall, requestedAudioRoute)
            emitCall(currentCall, currentCall.state)
        } else if (previous != requestedAudioRoute) {
            applyAudioRoute(currentCore, null, requestedAudioRoute)
        }
        Log.i(
            "VoIPCloud/Linphone",
            "Audio devices reconciled reason=$reason route=$requestedAudioRoute bt=$bluetoothAvailable"
        )
    }

    private fun setAudioRoute(enabled: Boolean, type: AudioDevice.Type) {
        setAudioRoute(
            if (!enabled) {
                "earpiece"
            } else {
                when (type) {
                    AudioDevice.Type.Speaker -> "speaker"
                    AudioDevice.Type.Bluetooth -> "bluetooth"
                    else -> "earpiece"
                }
            }
        )
    }

    private fun setAudioRoute(route: String): String {
        val normalized = normalizeAudioRoute(route)
        val currentCore = core ?: return requestedAudioRoute
        val currentCall = findCurrentCall()
        // Persist the user/app selection immediately. Observed output can lag behind
        // Bluetooth SCO teardown and previously snapped the route back to Bluetooth.
        requestedAudioRoute = normalized
        val applied = applyAudioRoute(
            core = currentCore,
            call = currentCall,
            route = normalized
        )
        currentCall?.let {
            audioRouteCallId = callId(it)
            emitCall(it, it.state)
            mainHandler.postDelayed({
                if (audioRouteCallId == callId(it) && calls.containsKey(callId(it))) {
                    emitCall(it, it.state)
                }
            }, 300)
        }
        Log.i(
            "VoIPCloud/Linphone",
            "Audio route requested=$normalized applied=$applied"
        )
        return normalized
    }

    private fun applyAudioRoute(core: Core, call: Call?, route: String): String {
        val normalized = normalizeAudioRoute(route)
        val devices = availableAudioDevices(core)
        val output = findOutputDevice(devices, normalized)
            ?: return call?.let(::observedAudioRouteForCall) ?: requestedAudioRoute
        val input = findInputDevice(devices, normalized, output)

        core.defaultOutputAudioDevice = output
        if (input != null) {
            core.defaultInputAudioDevice = input
        }

        if (call != null) {
            call.outputAudioDevice = output
            if (input != null) {
                call.inputAudioDevice = input
            }
        } else {
            core.outputAudioDevice = output
            if (input != null) {
                core.inputAudioDevice = input
            }
        }
        return normalized
    }

    private fun prepareAudioRoute(call: Call, state: Call.State) {
        val id = callId(call)
        if (state == Call.State.End ||
            state == Call.State.Released ||
            state == Call.State.Error
        ) {
            if (audioRouteCallId == id) {
                audioRouteCallId = null
                requestedAudioRoute = preferredDefaultAudioRoute()
            }
            return
        }
        if (AndroidCallCoordinator.isManagingCall()) {
            // Endpoint changes are requested through CallControlScope. Do not
            // overwrite the resulting AudioManager route from Linphone.
            return
        }
        if (audioRouteCallId != id) {
            audioRouteCallId = id
            requestedAudioRoute = preferredDefaultAudioRoute()
        } else if (
            requestedAudioRoute == "bluetooth" &&
            findOutputDevice(availableAudioDevices(core ?: return), "bluetooth") == null
        ) {
            // Headset disconnected mid-call — fall back instead of thrashing.
            requestedAudioRoute = "earpiece"
        }
        if (state == Call.State.PushIncomingReceived ||
            state == Call.State.IncomingReceived ||
            state == Call.State.IncomingEarlyMedia ||
            state == Call.State.OutgoingInit ||
            state == Call.State.OutgoingProgress ||
            state == Call.State.OutgoingRinging ||
            state == Call.State.Connected ||
            state == Call.State.StreamsRunning
        ) {
            applyAudioRoute(
                core = core ?: return,
                call = call,
                route = requestedAudioRoute
            )
        }
    }

    private fun preferredDefaultAudioRoute(): String {
        val currentCore = core ?: return "earpiece"
        if (findOutputDevice(availableAudioDevices(currentCore), "bluetooth") != null) {
            return "bluetooth"
        }
        return "earpiece"
    }

    private fun preferredOutputDevice(core: Core): AudioDevice? {
        return findOutputDevice(availableAudioDevices(core), preferredDefaultAudioRoute())
    }

    private fun availableAudioDevices(core: Core): List<AudioDevice> {
        val extended = runCatching { core.extendedAudioDevices?.toList().orEmpty() }
            .getOrDefault(emptyList())
        if (extended.isNotEmpty()) {
            return extended
        }
        return core.audioDevices?.toList().orEmpty()
    }

    private fun normalizeAudioRoute(route: String): String {
        return when (route) {
            "speaker", "bluetooth" -> route
            else -> "earpiece"
        }
    }

    private fun isBluetoothType(type: AudioDevice.Type?): Boolean {
        if (type == null) return false
        return type == AudioDevice.Type.Bluetooth ||
            type.name.contains("Bluetooth", ignoreCase = true)
    }

    private fun isHandsetOutputType(type: AudioDevice.Type?): Boolean {
        if (type == null) return false
        if (type == AudioDevice.Type.Earpiece) return true
        val name = type.name
        return name.contains("Headset", ignoreCase = true) ||
            name.contains("Headphone", ignoreCase = true)
    }

    private fun canPlay(device: AudioDevice): Boolean {
        return runCatching {
            device.hasCapability(AudioDevice.Capabilities.CapabilityPlay)
        }.getOrDefault(true)
    }

    private fun canRecord(device: AudioDevice): Boolean {
        return runCatching {
            device.hasCapability(AudioDevice.Capabilities.CapabilityRecord)
        }.getOrDefault(true)
    }

    private fun findOutputDevice(devices: List<AudioDevice>, route: String): AudioDevice? {
        val playable = devices.filter(::canPlay)
        return when (normalizeAudioRoute(route)) {
            "speaker" -> playable.firstOrNull { it.type == AudioDevice.Type.Speaker }
            "bluetooth" -> playable.firstOrNull { isBluetoothType(it.type) }
            else -> playable.firstOrNull { it.type == AudioDevice.Type.Earpiece }
                ?: playable.firstOrNull { isHandsetOutputType(it.type) }
        }
    }

    private fun findInputDevice(
        devices: List<AudioDevice>,
        route: String,
        output: AudioDevice
    ): AudioDevice? {
        val recordable = devices.filter(::canRecord)
        return when (normalizeAudioRoute(route)) {
            "bluetooth" -> {
                if (canRecord(output)) {
                    output
                } else {
                    recordable.firstOrNull { isBluetoothType(it.type) }
                }
            }
            else -> recordable.firstOrNull { it.type == AudioDevice.Type.Microphone }
                ?: recordable.firstOrNull { isHandsetOutputType(it.type) }
                ?: recordable.firstOrNull { !isBluetoothType(it.type) }
        }
    }

    private fun getAudioRoutes(): List<Map<String, Any?>> {
        if (AndroidCallCoordinator.isManagingCall()) {
            return AndroidCallCoordinator.endpoints()
        }
        val currentCore = core
        val devices = currentCore?.let(::availableAudioDevices).orEmpty()
        val bluetooth = findOutputDevice(devices, "bluetooth")
        val earpiece = findOutputDevice(devices, "earpiece")
        val routes = mutableListOf(
            mapOf(
                "route" to "earpiece",
                "label" to "Audio",
                "available" to (currentCore == null || earpiece != null || bluetooth == null)
            ),
            mapOf(
                "route" to "speaker",
                "label" to "Speaker",
                "available" to (
                    currentCore == null || findOutputDevice(devices, "speaker") != null
                    )
            ),
        )
        if (bluetooth != null) {
            routes.add(
                mapOf(
                    "route" to "bluetooth",
                    "label" to (bluetooth.deviceName?.ifBlank { "Bluetooth" } ?: "Bluetooth"),
                    "available" to true
                )
            )
        }
        return routes
    }

    private fun ensureBluetoothPermission(): Boolean {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.S) {
            return true
        }
        val activity = hostActivity ?: return false
        val granted = ActivityCompat.checkSelfPermission(
            activity,
            Manifest.permission.BLUETOOTH_CONNECT
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            return true
        }
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.BLUETOOTH_CONNECT),
            1002
        )
        return false
    }

    private fun audioRouteForCall(call: Call): String {
        AndroidCallCoordinator.snapshot()?.takeIf {
            it.telecomManaged && !it.isTerminal
        }?.let { snapshot ->
            return snapshot.endpoints.firstOrNull {
                it.id == snapshot.currentEndpointId
            }?.route ?: "earpiece"
        }
        if (audioRouteCallId == callId(call)) {
            return requestedAudioRoute
        }
        return observedAudioRouteForCall(call)
    }

    private fun observedAudioRouteForCall(call: Call): String {
        val type = call.outputAudioDevice?.type
        return when {
            type == AudioDevice.Type.Speaker -> "speaker"
            isBluetoothType(type) -> "bluetooth"
            else -> "earpiece"
        }
    }

    private fun holdCall(requestedId: String?, result: MethodChannel.Result) {
        val activeCall = findCall(requestedId)
        if (activeCall == null) {
            Log.w("VoIPCloud/Linphone", "Hold requested but no active call id=$requestedId")
            result.error("CALL_NOT_FOUND", "There is no active call to hold.", null)
            return
        }
        val state = activeCall.state
        val nativeId = callId(activeCall)
        if (state == Call.State.Paused || state == Call.State.Pausing) {
            Log.i("VoIPCloud/Linphone", "Hold ignored; already held id=$nativeId state=$state")
            result.success(null)
            return
        }
        if (state != Call.State.StreamsRunning && state != Call.State.Connected) {
            Log.w(
                "VoIPCloud/Linphone",
                "Hold refused id=$nativeId requestedId=$requestedId state=$state"
            )
            result.error(
                "CALL_STATE",
                "Cannot hold call while it is $state.",
                null
            )
            return
        }

        // Prefer classic SIP pause(). If that fails (some Asterisk builds), fall back to
        // an explicit sendonly re-INVITE which FreePBX generally accepts for MOH.
        var code = activeCall.pause()
        Log.i(
            "VoIPCloud/Linphone",
            "Hold pause() id=$nativeId requestedId=$requestedId stateBefore=$state result=$code"
        )
        if (code != 0) {
            val currentCore = core
            val params = currentCore?.createCallParams(activeCall)
            if (params != null) {
                params.isVideoEnabled = false
                params.audioDirection = MediaDirection.SendOnly
                code = activeCall.update(params)
                Log.i(
                    "VoIPCloud/Linphone",
                    "Hold fallback update(sendonly) id=$nativeId result=$code"
                )
            }
        }
        if (code != 0) {
            result.error("HOLD_FAILED", "Unable to put the call on hold (code $code).", null)
        } else {
            result.success(null)
        }
    }

    private fun resumeCall(requestedId: String?, result: MethodChannel.Result) {
        val activeCall = findCall(requestedId)
        if (activeCall == null) {
            Log.w("VoIPCloud/Linphone", "Resume requested but no active call id=$requestedId")
            result.error("CALL_NOT_FOUND", "There is no held call to resume.", null)
            return
        }
        val state = activeCall.state
        val nativeId = callId(activeCall)
        if (state == Call.State.StreamsRunning || state == Call.State.Connected) {
            Log.i("VoIPCloud/Linphone", "Resume ignored; already active id=$nativeId state=$state")
            result.success(null)
            return
        }
        if (state != Call.State.Paused &&
            state != Call.State.PausedByRemote &&
            state != Call.State.Pausing
        ) {
            Log.w(
                "VoIPCloud/Linphone",
                "Resume refused id=$nativeId requestedId=$requestedId state=$state"
            )
            result.error(
                "CALL_STATE",
                "Cannot resume call while it is $state.",
                null
            )
            return
        }

        var code = activeCall.resume()
        Log.i(
            "VoIPCloud/Linphone",
            "Resume resume() id=$nativeId requestedId=$requestedId stateBefore=$state result=$code"
        )
        if (code != 0) {
            val currentCore = core
            val params = currentCore?.createCallParams(activeCall)
            if (params != null) {
                params.isVideoEnabled = false
                params.audioDirection = MediaDirection.SendRecv
                code = activeCall.update(params)
                Log.i(
                    "VoIPCloud/Linphone",
                    "Resume fallback update(sendrecv) id=$nativeId result=$code"
                )
            }
        }
        if (code != 0) {
            result.error("RESUME_FAILED", "Unable to resume the call (code $code).", null)
        } else {
            result.success(null)
        }
    }

    private fun findCall(id: String?): Call? {
        val indexedCall = id?.let { calls[it] }
        if (indexedCall != null && !isTerminalCallState(indexedCall.state)) {
            return indexedCall
        }

        // Linphone may initially expose a call before callLog.callId exists. In
        // that case Flutter receives the temporary object-hash ID, while later
        // native events are indexed by the SIP Call-ID. Always fall back to the
        // SDK's current call so actions using that earlier ID cannot become
        // successful no-ops (most importantly, terminating an outgoing INVITE).
        return findCurrentCall()
    }

    private fun findCurrentCall(): Call? {
        val current = core?.currentCall
        if (current != null && isLiveCall(current)) return current
        return recoverLiveCall()
    }

    internal fun hasActiveCall(): Boolean {
        val call = findCurrentCall() ?: return false
        return when (call.state) {
            Call.State.Released,
            Call.State.End,
            Call.State.Error -> false
            else -> true
        }
    }

    private fun normalizeDestination(destination: String): org.linphone.core.Address {
        val trimmed = destination.trim()
        val currentAccount = account
        val domain = currentAccount?.params?.identityAddress?.domain ?: ""
        val uri = if (trimmed.startsWith("sip:") || trimmed.contains("@")) {
            if (trimmed.startsWith("sip:")) trimmed else "sip:$trimmed"
        } else {
            "sip:$trimmed@$domain"
        }
        return requireNotNull(Factory.instance().createAddress(uri))
    }

    private fun startPresenceSubscriptions(rawExtensions: List<*>) {
        val currentCore = requireNotNull(core) { "Linphone core is not initialized" }
        stopPresenceSubscriptions()
        rawExtensions
            .mapNotNull { (it as? String)?.trim() }
            .filter { it.matches(Regex("^[0-9]{2,8}$")) }
            .distinct()
            .take(250)
            .forEach { extension ->
              listOf(
                "dialog" to "application/dialog-info+xml",
                "presence" to "application/pidf+xml"
              ).forEach { (eventPackage, accept) ->
                val event = currentCore.createSubscribe(
                    normalizeDestination(extension),
                    eventPackage,
                    300
                )
                event.addCustomHeader("Accept", accept)
                presenceSubscriptions[event] = PresenceSubscription(
                    extension,
                    eventPackage
                )
                if (event.sendSubscribe(null) != 0) {
                    presenceSubscriptions.remove(event)
                    event.terminate()
                    presenceSink?.success(
                        mapOf(
                            "kind" to "subscription",
                            "extension" to extension,
                            "event" to eventPackage,
                            "state" to "error"
                        )
                    )
                }
              }
            }
        Log.i(
            "VoIPCloud/Linphone",
            "Started ${presenceSubscriptions.size} dialog/PIDF subscriptions"
        )
    }

    private fun stopPresenceSubscriptions() {
        presenceSubscriptions.keys.toList().forEach { event ->
            try {
                event.terminate()
            } catch (error: Throwable) {
                Log.w("VoIPCloud/Linphone", "Failed to terminate BLF subscription", error)
            }
        }
        presenceSubscriptions.clear()
    }

    private fun subscriptionState(state: SubscriptionState?): String = when (state) {
        SubscriptionState.Active -> "active"
        SubscriptionState.Error -> "error"
        SubscriptionState.Terminated -> "terminated"
        SubscriptionState.OutgoingProgress -> "progress"
        SubscriptionState.Pending -> "pending"
        SubscriptionState.IncomingReceived -> "incoming"
        SubscriptionState.None -> "none"
        else -> "unknown"
    }

    private fun emitRegistration(status: String, message: String?) {
        registrationSink?.success(mapOf("status" to status, "message" to message))
    }

    private fun emitCall(call: Call, state: Call.State, featureCode: Boolean = call in featureCodeCalls) {
        val id = callId(call)
        if (isTerminalCallState(state)) {
            calls.remove(id)
        } else {
            calls[id] = call
        }
        val telecom = AndroidCallCoordinator.snapshot()
        callSink?.success(
            mapOf(
                "id" to id,
                "remoteUri" to (call.remoteAddress?.asStringUriOnly() ?: ""),
                "remoteDisplayName" to callerDisplayLabel(call),
                "direction" to if (call.dir == Call.Dir.Incoming) "incoming" else "outgoing",
                "status" to callStatus(state),
                "startedAt" to (call.callLog?.startDate ?: System.currentTimeMillis()),
                "isMuted" to (core?.isMicEnabled == false),
                "isSpeakerEnabled" to (audioRouteForCall(call) == "speaker"),
                "audioRoute" to audioRouteForCall(call),
                "featureCode" to featureCode,
                "telecomManaged" to (telecom?.telecomManaged == true),
                "telecomState" to telecom?.state?.name?.lowercase(),
                "currentEndpointId" to telecom?.currentEndpointId,
                "availableEndpoints" to telecom?.endpoints?.map {
                    it.toMap(telecom.currentEndpointId)
                }.orEmpty()
            )
        )
    }

    private fun emitCoordinatorSnapshot(snapshot: AndroidCallCoordinator.Snapshot) {
        if (snapshot.isTerminal && recoverLiveCall() != null) return
        val status = when (snapshot.state) {
            AndroidCallCoordinator.State.PUSH_RECEIVED,
            AndroidCallCoordinator.State.RINGING -> "ringing"
            AndroidCallCoordinator.State.DIALING -> "dialing"
            AndroidCallCoordinator.State.ACTIVE -> "active"
            AndroidCallCoordinator.State.HELD -> "held"
            AndroidCallCoordinator.State.ENDED -> "ended"
            AndroidCallCoordinator.State.FAILED -> "failed"
            AndroidCallCoordinator.State.CONNECTING -> "connecting"
        }
        callSink?.success(
            mapOf(
                "id" to (snapshot.sipCallId ?: snapshot.sessionId),
                "remoteUri" to snapshot.callerNumber,
                "remoteDisplayName" to snapshot.callerName,
                "direction" to snapshot.direction.name.lowercase(),
                "status" to status,
                "startedAt" to snapshot.startedAtMs,
                "isMuted" to snapshot.muted,
                "isSpeakerEnabled" to (
                    snapshot.endpoints.firstOrNull { it.id == snapshot.currentEndpointId }?.route == "speaker"
                    ),
                "audioRoute" to (
                    snapshot.endpoints.firstOrNull { it.id == snapshot.currentEndpointId }?.route ?: "earpiece"
                    ),
                "featureCode" to false,
                "telecomManaged" to snapshot.telecomManaged,
                "telecomState" to snapshot.state.name.lowercase(),
                "currentEndpointId" to snapshot.currentEndpointId,
                "availableEndpoints" to snapshot.endpoints.map {
                    it.toMap(snapshot.currentEndpointId)
                }
            )
        )
    }

    private fun callerDisplayLabel(call: Call): String {
        val address = call.remoteAddress
        val username = Uri.decode(address?.username?.trim().orEmpty())
        val displayName = address?.displayName?.trim().orEmpty()
        val hasDialPrefix = username.matches(
            Regex("^[A-Za-z][A-Za-z0-9._-]*:.*")
        )
        val prefix = username.substringBefore(':')
        val suffix = username.substringAfter(':', "")
        return when {
            hasDialPrefix && displayName.startsWith("$prefix:", ignoreCase = true) -> displayName
            hasDialPrefix && (displayName.isEmpty() || displayName == suffix) -> username
            hasDialPrefix -> "$prefix: $displayName"
            displayName.isNotEmpty() -> displayName
            username.isNotEmpty() -> username
            !address?.asStringUriOnly().isNullOrBlank() -> address?.asStringUriOnly().orEmpty()
            else -> "Incoming call"
        }
    }

    fun syncCurrentCall(reason: String) {
        val call = findCurrentCall()
        if (call == null) {
            AndroidCallCoordinator.snapshot()?.takeIf { !it.isTerminal }?.let {
                emitCoordinatorSnapshot(it)
                return
            }
            Log.i("VoIPCloud/Linphone", "syncCurrentCall($reason) => none")
            callSink?.success(mapOf("status" to "none"))
            return
        }
        if (BuildConfig.DEBUG) {
            Log.d(
                "VoIPCloud/Linphone",
                "Syncing current call to Flutter reason=$reason id=${callId(call)} state=${call.state}"
            )
        }
        reportCallToCoordinator(call, call.state, "sync_$reason")
        emitCall(call, call.state)
    }

    private fun reportCallToCoordinator(call: Call, state: Call.State, source: String) {
        val authoritativeSipCallId = call.callLog?.callId?.trim().orEmpty()
        // Linphone exposes an outgoing Call before its SIP Call-ID exists. The
        // temporary hash returned by callId() changes as soon as the INVITE is
        // built, so matching it would make the same call look concurrent on the
        // next callback. Keep the Telecom placeholder unmatched until the real
        // Call-ID is available.
        if (call.dir == Call.Dir.Outgoing &&
            authoritativeSipCallId.isEmpty() &&
            !isTerminalCallState(state)
        ) {
            Log.i(
                "VoIPCloud/Linphone",
                "Deferring outgoing SIP/Telecom match source=$source state=$state"
            )
            return
        }
        Log.i(
            "VoIPCloud/Linphone",
            "Reporting SIP call to coordinator source=$source state=$state " +
                "direction=${call.dir}"
        )
        AndroidCallCoordinator.onSipCallState(
            context = context,
            sipCallId = authoritativeSipCallId.ifEmpty { callId(call) },
            direction = if (call.dir == Call.Dir.Incoming) {
                AndroidCallCoordinator.Direction.INCOMING
            } else {
                AndroidCallCoordinator.Direction.OUTGOING
            },
            state = telecomState(state),
            callerName = callerDisplayLabel(call),
            callerNumber = call.remoteAddress?.username?.trim().orEmpty()
        )
    }

    private fun recoverLiveCall(): Call? {
        pruneTerminalCachedCalls()
        calls.values.lastOrNull { isLiveCall(it) }?.let { return it }
        val fromSdk = core?.calls?.lastOrNull { isLiveCall(it) } ?: return null
        calls[callId(fromSdk)] = fromSdk
        return fromSdk
    }

    private fun pruneTerminalCachedCalls() {
        val terminalIds = calls.filter { (_, call) ->
            try {
                isTerminalCallState(call.state)
            } catch (_: Throwable) {
                true
            }
        }.keys.toList()
        terminalIds.forEach { calls.remove(it) }
    }

    private fun isLiveCall(call: Call): Boolean {
        return try {
            !isTerminalCallState(call.state)
        } catch (_: Throwable) {
            false
        }
    }

    fun acceptIncomingFromNotification() {
        val incoming = findCurrentIncomingCall() ?: return
        try {
            val params = core?.createCallParams(incoming)
            if (params != null) {
                params.isVideoEnabled = false
                incoming.acceptWithParams(params)
            } else {
                incoming.accept()
            }
        } catch (error: Throwable) {
            Log.w("VoIPCloud/Linphone", "Failed to accept incoming call from notification", error)
        }
    }

    fun hasSipCall(requestedId: String?): Boolean = findCall(requestedId) != null

    fun acceptFromCoordinator(requestedId: String?): Boolean {
        val incoming = findCall(requestedId) ?: findCurrentIncomingCall() ?: return false
        if (!isIncomingRinging(incoming)) return incoming.state == Call.State.Connected ||
            incoming.state == Call.State.StreamsRunning
        return runCatching {
            val params = core?.createCallParams(incoming)
            if (params != null) {
                params.isVideoEnabled = false
                incoming.acceptWithParams(params)
            } else {
                incoming.accept()
            }
            true
        }.getOrElse {
            Log.w("VoIPCloud/Linphone", "Coordinator answer failed", it)
            false
        }
    }

    fun updateFcmPushToken(token: String) {
        if (token.isBlank()) return
        val saved = SipCredentialStore.load(context)?.toMutableMap() ?: return
        saved["pushProvider"] = "fcm"
        saved["pushToken"] = token
        // Persist before touching liblinphone so a process interruption cannot
        // restore the obsolete token on the next cold start.
        SipCredentialStore.save(context, saved)
        try {
            initialize()
            restoreSavedAccountIfNeeded()
            val currentCore = core ?: return
            val currentAccount = account ?: currentCore.defaultAccount
                ?: currentCore.accountList.firstOrNull()
                ?: return
            val params = currentAccount.params.clone()
            configurePushNotifications(
                currentCore = currentCore,
                params = params,
                provider = "fcm",
                token = token,
                param = stringArg(saved, "pushParam"),
                bundleId = stringArg(saved, "pushBundleId"),
                teamId = stringArg(saved, "pushTeamId")
            )
            currentAccount.params = params
            account = currentAccount
            currentAccount.refreshRegister()
            Log.i("VoIPCloud/Linphone", "Applied refreshed FCM token to SIP registration")
        } catch (error: Throwable) {
            // The saved token is authoritative and will be applied by the next
            // native wake even if this immediate refresh cannot complete.
            Log.e("VoIPCloud/Linphone", "Could not immediately apply refreshed FCM token", error)
        }
    }

    /**
     * Linphone can create an incoming call during a cold Core startup without
     * delivering the initial IncomingReceived callback to our listener. This
     * bridge-owned poller is intentionally independent from CoreService's
     * notification handler, whose callbacks Linphone may cancel while changing
     * foreground state. Reporting is idempotent and stops on the first live call.
     */
    private fun schedulePushCallReconciliation(reason: String) {
        val generation = ++pushCallReconcileGeneration
        val deadline = SystemClock.elapsedRealtime() + PUSH_CALL_RECONCILE_TIMEOUT_MS
        val check = object : Runnable {
            override fun run() {
                if (generation != pushCallReconcileGeneration) return
                val snapshot = AndroidCallCoordinator.snapshot()
                if (snapshot == null || snapshot.isTerminal) return

                val incoming = findCurrentCall()
                if (incoming != null) {
                    Log.i(
                        "VoIPCloud/Linphone",
                        "Recovered cold-start SIP call reason=$reason state=${incoming.state}"
                    )
                    reportCallToCoordinator(incoming, incoming.state, "push_reconcile")
                    emitCall(incoming, incoming.state)
                    return
                }

                if (SystemClock.elapsedRealtime() < deadline) {
                    mainHandler.postDelayed(this, PUSH_CALL_RECONCILE_INTERVAL_MS)
                } else {
                    Log.w("VoIPCloud/Linphone", "Cold-start SIP reconciliation timed out")
                }
            }
        }
        mainHandler.post(check)
    }

    fun declineFromCoordinator(requestedId: String?): Boolean {
        val incoming = findCall(requestedId) ?: findCurrentIncomingCall() ?: return false
        return runCatching { incoming.decline(Reason.Declined); true }.getOrElse {
            Log.w("VoIPCloud/Linphone", "Coordinator decline failed", it)
            false
        }
    }

    fun endFromCoordinator(requestedId: String?): Boolean {
        val active = findCall(requestedId) ?: findCurrentCall() ?: return false
        return runCatching { active.terminate(); true }.getOrElse {
            Log.w("VoIPCloud/Linphone", "Coordinator disconnect failed", it)
            false
        }
    }

    fun holdFromCoordinator(requestedId: String?): Boolean {
        val active = findCall(requestedId) ?: findCurrentCall() ?: return false
        if (active.state == Call.State.Paused || active.state == Call.State.Pausing) return true
        return runCatching { active.pause() == 0 }.getOrDefault(false)
    }

    fun resumeFromCoordinator(requestedId: String?): Boolean {
        val active = findCall(requestedId) ?: findCurrentCall() ?: return false
        if (active.state == Call.State.StreamsRunning || active.state == Call.State.Connected) return true
        return runCatching { active.resume() == 0 }.getOrDefault(false)
    }

    fun setMutedFromCoordinator(muted: Boolean) {
        core?.isMicEnabled = !muted
        findCurrentCall()?.let { emitCall(it, it.state) }
    }

    fun declineIncomingFromNotification() {
        val incoming = findCurrentIncomingCall() ?: return
        try {
            incoming.decline(Reason.Declined)
        } catch (error: Throwable) {
            Log.w("VoIPCloud/Linphone", "Failed to decline incoming call from notification", error)
        }
    }

    private fun dispose() {
        pushCallReconcileGeneration++
        stopPresenceSubscriptions()
        core?.removeListener(listener)
        core?.stop()
        core = null
        account = null
        calls.clear()
    }

    private fun findCurrentIncomingCall(): Call? {
        val current = core?.currentCall
        if (current != null &&
            current.dir == Call.Dir.Incoming &&
            (current.state == Call.State.IncomingReceived || current.state == Call.State.IncomingEarlyMedia)
        ) {
            return current
        }
        return calls.values.lastOrNull {
            it.dir == Call.Dir.Incoming &&
                (it.state == Call.State.IncomingReceived || it.state == Call.State.IncomingEarlyMedia)
        }
    }

    private fun isIncomingRinging(call: Call): Boolean =
        call.dir == Call.Dir.Incoming &&
            (call.state == Call.State.PushIncomingReceived ||
                call.state == Call.State.IncomingReceived ||
                call.state == Call.State.IncomingEarlyMedia)

    private fun isTerminalCallState(state: Call.State): Boolean =
        state == Call.State.End || state == Call.State.Released || state == Call.State.Error

    private fun setSipLoggingEnabled(enabled: Boolean) {
        sipLoggingEnabled = enabled
        try {
            initialize()
        } catch (_: Throwable) {
            // Core may not be ready yet; logging still toggles for later init.
        }
        Factory.instance().setDebugMode(enabled || BuildConfig.DEBUG, "VoIPCloud")
        configureLinphoneLogging(enabled || BuildConfig.DEBUG)
        if (enabled) {
            emitSipLog(
                level = "info",
                source = "linphone",
                message = "Native SIP logging enabled"
            )
        }
    }

    private fun appendSipLogLine(line: String) {
        val trimmed = line.trim()
        if (trimmed.isEmpty()) return
        writeSipLogLine(trimmed)
    }

    private fun readSipLogFile(): String {
        val file = sipLogFile()
        if (!file.exists()) return ""
        return try {
            file.readText()
        } catch (_: Throwable) {
            ""
        }
    }

    private fun clearSipLogFile() {
        synchronized(sipLogFileLock) {
            try {
                val file = sipLogFile()
                if (file.exists()) {
                    file.writeText("")
                }
            } catch (_: Throwable) {
            }
        }
    }

    private fun configureLinphoneLogging(enabled: Boolean) {
        val factory = Factory.instance()
        // Liblinphone's direct logcat sink writes raw SIP headers, including
        // push identifiers. Forward only through our sanitizing listener.
        factory.enableLogcatLogs(false)
        val logging = factory.loggingService
        logging.setDomain("linphone")
        logging.setLogLevel(
            if (enabled) {
                // Message captures useful SIP signaling without Trace-level spam.
                LogLevel.Message
            } else if (BuildConfig.DEBUG) {
                LogLevel.Warning
            } else {
                LogLevel.Error
            }
        )
        if (linphoneLogListener == null) {
            linphoneLogListener = object : LoggingServiceListener {
                override fun onLogMessageWritten(
                    service: LoggingService,
                    domain: String,
                    level: LogLevel,
                    message: String
                ) {
                    val tag = "VoIPCloud/Linphone"
                    val line = sanitizeLinphoneLog("[$domain] $message")
                    when (level) {
                        LogLevel.Error, LogLevel.Fatal -> Log.e(tag, line)
                        LogLevel.Warning -> Log.w(tag, line)
                        LogLevel.Message -> Log.i(tag, line)
                        LogLevel.Debug, LogLevel.Trace -> Log.d(tag, line)
                        else -> Log.v(tag, line)
                    }
                    if (!sipLoggingEnabled) {
                        return
                    }
                    emitSipLog(
                        level = when (level) {
                            LogLevel.Error, LogLevel.Fatal -> "error"
                            LogLevel.Warning -> "warn"
                            LogLevel.Debug, LogLevel.Trace -> "debug"
                            else -> "info"
                        },
                        source = "linphone",
                        message = line
                    )
                }
            }
            logging.addListener(linphoneLogListener)
        }
    }

    private fun sanitizeLinphoneLog(message: String): String = message
        .replace(Regex("(?i)(pn-prid=)[^;>\\s]+")) { match ->
            "${match.groupValues[1]}<redacted>"
        }
        .replace(Regex("(?im)^(Proxy-)?Authorization:.*$")) { match ->
            if (match.value.startsWith("Proxy-", ignoreCase = true)) {
                "Proxy-Authorization: <redacted>"
            } else {
                "Authorization: <redacted>"
            }
        }

    private fun emitSipLog(level: String, source: String, message: String) {
        val at = java.time.Instant.now().toString()
        val persisted = "$at [${level.uppercase()}] [$source] $message"
        writeSipLogLine(persisted)
        try {
            sipLogSink?.success(
                mapOf(
                    "at" to at,
                    "level" to level,
                    "source" to source,
                    "message" to message
                )
            )
        } catch (_: Throwable) {
            // Event sink can be detached while backgrounded; file still has the line.
        }
    }

    private fun writeSipLogLine(line: String) {
        synchronized(sipLogFileLock) {
            try {
                val file = sipLogFile()
                file.parentFile?.mkdirs()
                if (file.exists() && file.length() > maxSipLogBytes) {
                    val keep = file.readText().takeLast((maxSipLogBytes / 2).toInt())
                    file.writeText(keep)
                }
                file.appendText(line.trimEnd() + "\n")
            } catch (error: Throwable) {
                Log.w("VoIPCloud/Linphone", "Failed to append SIP log line", error)
            }
        }
    }

    private fun sipLogFile(): java.io.File {
        return java.io.File(context.filesDir, "sip_logs/voipcloud_sip.log")
    }

    private fun updateRegistrationEnabled(enabled: Boolean) {
        val currentAccount = account ?: return
        val params = currentAccount.params.clone()
        params.setRegisterEnabled(enabled)
        currentAccount.params = params
    }

    private fun purgeAccount() {
        stopPresenceSubscriptions()
        val currentCore = core
        currentCore?.accountList?.toList()?.forEach {
            currentCore.removeAccount(it)
        }
        currentCore?.authInfoList?.toList()?.forEach {
            currentCore.removeAuthInfo(it)
        }
        account = null
        SipCredentialStore.clear(context)
        CallerIdentityStore.clear(context)
        Log.i("VoIPCloud/Linphone", "Purged logged-out SIP account")
    }
}

private fun stringArg(args: Map<*, *>, key: String): String = (args[key] as? String)?.trim().orEmpty()

private fun normalizeRelayServer(value: String): String {
    return value
        .removePrefix("stun:")
        .removePrefix("turn:")
        .removePrefix("turns:")
        .trim()
}

private fun normalizeSipAddress(value: String): String {
    val trimmed = value.trim()
    if (trimmed.startsWith("sip:") || trimmed.startsWith("sips:")) {
        return trimmed
    }
    return "sip:$trimmed"
}

private fun transportType(value: String): TransportType {
    return when (value.lowercase()) {
        "tls" -> TransportType.Tls
        "tcp" -> TransportType.Tcp
        else -> TransportType.Udp
    }
}

private fun registrationState(state: RegistrationState?): String {
    return when (state) {
        RegistrationState.Ok -> "registered"
        RegistrationState.Progress,
        RegistrationState.Refreshing -> "registering"
        RegistrationState.Failed -> "failed"
        RegistrationState.Cleared,
        RegistrationState.None -> "unregistered"
        null -> "unregistered"
    }
}

private fun callStatus(state: Call.State): String {
    return when (state) {
        Call.State.IncomingReceived,
        Call.State.IncomingEarlyMedia -> "ringing"
        Call.State.OutgoingInit,
        Call.State.OutgoingProgress,
        Call.State.OutgoingRinging,
        Call.State.OutgoingEarlyMedia -> "dialing"
        Call.State.Connected,
        Call.State.StreamsRunning -> "active"
        Call.State.Pausing,
        Call.State.Paused,
        Call.State.PausedByRemote -> "held"
        Call.State.End,
        Call.State.Released -> "ended"
        Call.State.Error -> "failed"
        else -> "connecting"
    }
}

private fun telecomState(state: Call.State): AndroidCallCoordinator.State = when (state) {
    Call.State.PushIncomingReceived,
    Call.State.IncomingReceived,
    Call.State.IncomingEarlyMedia -> AndroidCallCoordinator.State.RINGING
    Call.State.OutgoingInit,
    Call.State.OutgoingProgress,
    Call.State.OutgoingRinging,
    Call.State.OutgoingEarlyMedia -> AndroidCallCoordinator.State.DIALING
    Call.State.Connected -> AndroidCallCoordinator.State.CONNECTING
    Call.State.StreamsRunning -> AndroidCallCoordinator.State.ACTIVE
    Call.State.Pausing,
    Call.State.Paused,
    Call.State.PausedByRemote -> AndroidCallCoordinator.State.HELD
    Call.State.End,
    Call.State.Released -> AndroidCallCoordinator.State.ENDED
    Call.State.Error -> AndroidCallCoordinator.State.FAILED
    else -> AndroidCallCoordinator.State.CONNECTING
}

private fun callId(call: Call): String = call.callLog?.callId ?: call.hashCode().toString()

internal object LinphoneBridgeAccessor {
    fun wakeFromPush(context: android.content.Context, reason: String) {
        LinphoneBridge.shared(context.applicationContext).wakeFromPush(reason)
    }

    fun isRegistered(context: android.content.Context): Boolean {
        return LinphoneBridge.shared(context.applicationContext).isRegistered()
    }

    fun hasActiveCall(context: android.content.Context): Boolean {
        return LinphoneBridge.shared(context.applicationContext).hasActiveCall()
    }

    fun reconcileCurrentCall(context: android.content.Context, reason: String) {
        LinphoneBridge.shared(context.applicationContext).syncCurrentCall(reason)
    }

    fun sipExtension(context: android.content.Context): String? {
        return LinphoneBridge.shared(context.applicationContext).sipExtension()
    }

    fun hasSipCall(context: android.content.Context, callId: String?): Boolean =
        LinphoneBridge.shared(context.applicationContext).hasSipCall(callId)

    fun accept(context: android.content.Context, callId: String?): Boolean =
        LinphoneBridge.shared(context.applicationContext).acceptFromCoordinator(callId)

    fun decline(context: android.content.Context, callId: String?): Boolean =
        LinphoneBridge.shared(context.applicationContext).declineFromCoordinator(callId)

    fun end(context: android.content.Context, callId: String?): Boolean =
        LinphoneBridge.shared(context.applicationContext).endFromCoordinator(callId)

    fun hold(context: android.content.Context, callId: String?): Boolean =
        LinphoneBridge.shared(context.applicationContext).holdFromCoordinator(callId)

    fun resume(context: android.content.Context, callId: String?): Boolean =
        LinphoneBridge.shared(context.applicationContext).resumeFromCoordinator(callId)

    fun setMuted(context: android.content.Context, muted: Boolean) {
        LinphoneBridge.shared(context.applicationContext).setMutedFromCoordinator(muted)
    }

    fun updateFcmPushToken(context: android.content.Context, token: String) {
        LinphoneBridge.shared(context.applicationContext).updateFcmPushToken(token)
    }
}
