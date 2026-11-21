package vn.haotran.haotrannas_mobile

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of lib/core/transport/multicast_lock.dart: the Wi-Fi
 * multicast lock for mDNS discovery (copied from Protocol Lab); and of
 * WorkmanagerManualBackupLauncher (lib/backup/background.dart): the
 * notification permission for the "Back up now" notification; and of
 * lib/backup/battery.dart: the battery saver exemption (D-047).
 */
class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, MULTICAST_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "multicastLock" -> {
                    setMulticastLock(call.argument<Boolean>("hold") == true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, NOTIFICATION_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "request" -> result.success(requestNotificationPermission())
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, BATTERY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isExempt" -> result.success(isBatteryExempt())
                "ask" -> {
                    askBatteryExemption()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** True when the battery saver leaves this app's background work alone. */
    private fun isBatteryExempt(): Boolean {
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        return power.isIgnoringBatteryOptimizations(packageName)
    }

    /**
     * The system's one-tap "Let app always run in background?" dialog
     * (needs REQUEST_IGNORE_BATTERY_OPTIMIZATIONS). A phone without that
     * dialog gets the battery optimization list instead.
     */
    private fun askBatteryExemption() {
        if (isBatteryExempt()) return
        val ask = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:$packageName"),
        )
        try {
            startActivity(ask)
        } catch (missing: ActivityNotFoundException) {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }

    /**
     * Android 13+ shows notifications only with POST_NOTIFICATIONS. Asks
     * once (the system dialog); returns whether it is granted right now.
     */
    private fun requestNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        val permission = Manifest.permission.POST_NOTIFICATIONS
        if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) return true
        requestPermissions(arrayOf(permission), NOTIFICATION_REQUEST_CODE)
        return false
    }

    override fun onDestroy() {
        setMulticastLock(false)
        super.onDestroy()
    }

    /** Android drops multicast packets (mDNS) unless an app holds this lock. */
    private fun setMulticastLock(hold: Boolean) {
        if (hold && multicastLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("haotrannas_mdns").apply {
                setReferenceCounted(false)
                acquire()
            }
        } else if (!hold) {
            multicastLock?.release()
            multicastLock = null
        }
    }

    private companion object {
        /** Must match MulticastLock.channelName in multicast_lock.dart. */
        const val MULTICAST_CHANNEL = "vn.haotran.haotrannas_mobile/multicast"

        /** Must match the channel in background.dart. */
        const val NOTIFICATION_CHANNEL = "vn.haotran.haotrannas_mobile/notifications"
        const val NOTIFICATION_REQUEST_CODE = 4710

        /** Must match the channel in battery.dart. */
        const val BATTERY_CHANNEL = "vn.haotran.haotrannas_mobile/battery"
    }
}
