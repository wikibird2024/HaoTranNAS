package vn.haotran.haotrannas_mobile

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of lib/core/transport/multicast_lock.dart: the Wi-Fi
 * multicast lock for mDNS discovery (copied from Protocol Lab).
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
    }
}
