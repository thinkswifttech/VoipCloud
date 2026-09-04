package com.thinkswift.softphoneapp

import android.app.Activity
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
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
