package net.ezbookkeeping.app

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.icu.text.Collator
import android.icu.text.RuleBasedCollator
import com.amap.api.location.AMapLocationClient
import com.amap.api.location.AMapLocationClientOption
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.Locale

class MainActivity : FlutterFragmentActivity() {
    private var channel: MethodChannel? = null
    private var pendingLaunchRoute: String? = null
    private var locationClient: AMapLocationClient? = null
    private val inbox: File get() = File(filesDir, "shared_inbox")

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ezbookkeeping/native")
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "sortStrings" -> {
                    val values = call.argument<List<String>>("values") ?: emptyList()
                    val standard = call.argument<Boolean>("localeCompare") == true
                    val locale = if (standard) Locale.getDefault()
                        else Locale.forLanguageTag(call.argument<String>("locale") ?: "en")
                    val collator = Collator.getInstance(locale) as RuleBasedCollator
                    if (!standard) {
                        collator.strength = Collator.PRIMARY
                        collator.numericCollation = true
                    }
                    val descending = call.argument<Boolean>("descending") == true
                    val order = values.indices.sortedWith { left, right ->
                        if (descending) collator.compare(values[right], values[left])
                        else collator.compare(values[left], values[right])
                    }
                    result.success(order)
                }
                "readShareFiles" -> result.success(inbox.listFiles()?.filter { it.isFile && !it.name.endsWith(".partial") }?.map { it.absolutePath } ?: emptyList<String>())
                "readShareError" -> {
                    val preferences = getSharedPreferences("share_errors", MODE_PRIVATE)
                    val message = preferences.getString("message", null)
                    if (message != null) preferences.edit().remove("message").commit()
                    result.success(message)
                }
                "acknowledgeShareFiles" -> {
                    val paths = call.arguments as? List<*> ?: emptyList<String>()
                    for (path in paths) {
                        val file = File(path.toString())
                        if (file.canonicalFile.parentFile == inbox.canonicalFile) file.delete()
                    }
                    result.success(null)
                }
                "consumeLaunchRoute" -> {
                    result.success(pendingLaunchRoute)
                    pendingLaunchRoute = null
                }
                "updateHomeWidgets" -> {
                    HomeWidgetSupport.updateSnapshot(this, call.arguments as? Map<*, *> ?: emptyMap<Any, Any>())
                    result.success(null)
                }
                "clearHomeWidgets" -> {
                    HomeWidgetSupport.clearSnapshot(this)
                    result.success(null)
                }
                "getAmapLocation" -> getAmapLocation(result)
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        receiveLauncherEntry(intent, false)
        super.onCreate(savedInstanceState)
        // Activity recreation must not enqueue the same incoming Intent again.
        if (savedInstanceState == null) {
            receiveSharedImages(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        receiveLauncherEntry(intent, true)
        super.onNewIntent(intent)
        setIntent(intent)
        receiveSharedImages(intent)
    }

    override fun onDestroy() {
        locationClient?.onDestroy()
        locationClient = null
        super.onDestroy()
    }

    private fun getAmapLocation(result: MethodChannel.Result) {
        val apiKey = packageManager
            .getApplicationInfo(packageName, PackageManager.GET_META_DATA)
            .metaData
            ?.getString("com.amap.api.v2.apikey")
        if (apiKey.isNullOrBlank()) {
            result.error("AMAP_KEY_MISSING", "AMap Android API key is not configured", null)
            return
        }

        locationClient?.onDestroy()
        locationClient = null

        try {
            AMapLocationClient.updatePrivacyShow(applicationContext, true, true)
            AMapLocationClient.updatePrivacyAgree(applicationContext, true)
            AMapLocationClient.setApiKey(apiKey)

            val client = AMapLocationClient(applicationContext)
            locationClient = client
            client.setLocationOption(AMapLocationClientOption().apply {
                locationMode = AMapLocationClientOption.AMapLocationMode.Hight_Accuracy
                isOnceLocation = true
                isOnceLocationLatest = true
                isNeedAddress = true
                httpTimeOut = 20000
            })
            client.setLocationListener { location ->
                if (locationClient !== client) return@setLocationListener
                client.stopLocation()
                client.onDestroy()
                locationClient = null

                if (location != null && location.errorCode == 0) {
                    val locationName = location.poiName
                        ?.takeIf { it.isNotBlank() }
                        ?: location.address?.takeIf { it.isNotBlank() }
                    result.success(buildMap<String, Any> {
                        put("latitude", location.latitude)
                        put("longitude", location.longitude)
                        if (locationName != null) put("name", locationName.take(255))
                    })
                } else {
                    result.error(
                        "AMAP_LOCATION_FAILED",
                        location?.errorInfo ?: "AMap geolocation failed",
                        location?.errorCode,
                    )
                }
            }
            client.startLocation()
        } catch (error: Exception) {
            locationClient?.onDestroy()
            locationClient = null
            result.error("AMAP_LOCATION_FAILED", error.message, null)
        }
    }

    private fun receiveLauncherEntry(intent: Intent?, notifyFlutter: Boolean) {
        val route = launcherRoute(intent) ?: return
        // Consume the launcher command on this Intent so activity recreation does
        // not enqueue it again. A new shortcut or widget click supplies a new Intent.
        intent?.action = Intent.ACTION_MAIN
        intent?.data = null
        pendingLaunchRoute = route
        if (notifyFlutter) {
            channel?.let {
                it.invokeMethod("openRoute", pendingLaunchRoute)
                pendingLaunchRoute = null
            }
        }
    }

    private fun launcherRoute(intent: Intent?): String? {
        val quickAdd = intent?.action == ACTION_QUICK_ADD ||
            (intent?.action == Intent.ACTION_VIEW &&
                intent.data?.scheme == "net.ezbookkeeping.app" &&
                intent.data?.host == "transaction" &&
                intent.data?.path == "/add")
        return when {
            quickAdd -> "/transaction/add"
            intent?.action == ACTION_OPEN_HOME -> "/"
            else -> null
        }
    }

    @Suppress("DEPRECATION")
    private fun receiveSharedImages(intent: Intent?) {
        if (intent == null || intent.type?.startsWith("image/") != true) return
        val uris = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
            Intent.ACTION_SEND_MULTIPLE -> intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.toList() ?: emptyList()
            else -> return
        }
        Thread {
            inbox.mkdirs()
            var failure = if (uris.size > 10) "Only the first 10 shared images were received. Please share the remaining images again." else null
            for (uri in uris.take(10)) {
                if (uri.scheme != "content") {
                    failure = "The shared image could not be read. Please share it again from a photo or file application."
                    continue
                }
                val destination = File(inbox, UUID.randomUUID().toString())
                val partial = File(inbox, destination.name + ".partial")
                try {
                    requireNotNull(contentResolver.openInputStream(uri)).use { input ->
                        partial.outputStream().use { output ->
                            val buffer = ByteArray(8192)
                            var total = 0L
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                total += count
                                require(total <= 50L * 1024 * 1024) { "Shared image exceeds 50 MiB" }
                                output.write(buffer, 0, count)
                            }
                            output.fd.sync()
                        }
                    }
                    check(partial.renameTo(destination)) { "Could not save the shared image" }
                } catch (_: Exception) {
                    partial.delete()
                    failure = "A shared image could not be saved. Check its read permission and that it is no larger than 50 MiB, then share it again."
                }
            }
            if (failure != null) {
                getSharedPreferences("share_errors", MODE_PRIVATE).edit().putString("message", failure).commit()
            }
            runOnUiThread { channel?.invokeMethod("sharedImages", null) }
        }.start()
    }

    companion object {
        const val ACTION_QUICK_ADD = "net.ezbookkeeping.app.action.QUICK_ADD"
        const val ACTION_OPEN_HOME = "net.ezbookkeeping.app.action.OPEN_HOME"
    }
}
