package com.thinkswift.softphoneapp

import android.app.Activity
import android.app.ActivityManager
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.app.usage.UsageStatsManager
import android.os.PowerManager
import android.provider.Settings
import android.util.Log

internal object SoftphoneBackgroundPermissions {
    private const val TAG = "Softphone/Background"

    fun isIgnoringBatteryOptimizations(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(context.packageName)
    }

    /**
     * Android has two separate switches. The battery-optimisation exemption (Doze) is one; the
     * app's own "Background usage" choice (Unrestricted / Optimised / Restricted, shown on some
     * phones as "Allow background activity") is the other. A restricted app is not allowed to
     * run in the background even when it is exempt from Doze, so registration is never renewed.
     */
    fun backgroundStatus(context: Context): Map<String, Any> {
        val exempt = isIgnoringBatteryOptimizations(context)
        var restricted = false
        var bucket = 10
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            restricted = manager.isBackgroundRestricted
            val usage = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
            bucket = usage.appStandbyBucket
        }
        Log.i(TAG, "Background status exempt=$exempt restricted=$restricted standbyBucket=$bucket")
        return mapOf("exempt" to exempt, "restricted" to restricted, "standbyBucket" to bucket)
    }

    /** The app's own settings page, where Battery / Background usage can be changed. */
    fun openAppSettings(context: Context) {
        launchSettingsIntent(
            context,
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:${context.packageName}")
            }
        )
    }

    fun requestIgnoreBatteryOptimizations(activity: MainActivity): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }
        if (isIgnoringBatteryOptimizations(activity)) {
            return true
        }
        openBatteryOptimizationSettings(activity)
        return false
    }

    fun canUseFullScreenIntent(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return true
        }
        return context.getSystemService(NotificationManager::class.java)
            .canUseFullScreenIntent()
    }

    fun requestFullScreenIntentPermission(activity: MainActivity): Boolean {
        if (canUseFullScreenIntent(activity)) {
            return true
        }
        launchSettingsIntent(
            activity,
            Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                data = Uri.parse("package:${activity.packageName}")
            }
        )
        return false
    }

    fun openBatteryOptimizationSettings(context: Context) {
        try {
            launchSettingsIntent(context, Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            return
        } catch (error: Throwable) {
            Log.w(TAG, "Battery optimization list unavailable, opening app details", error)
        }

        try {
            launchSettingsIntent(
                context,
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:${context.packageName}")
                }
            )
        } catch (error: Throwable) {
            Log.e(TAG, "Unable to open any battery settings screen", error)
        }
    }

    private fun launchSettingsIntent(context: Context, intent: Intent) {
        val launchIntent = Intent(intent)
        if (context !is Activity) {
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            context.startActivity(launchIntent)
        } catch (error: ActivityNotFoundException) {
            throw error
        } catch (error: Throwable) {
            if (context is Activity) {
                launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(launchIntent)
            } else {
                throw error
            }
        }
    }
}
