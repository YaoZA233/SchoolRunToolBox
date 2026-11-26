package com.campusruntoolbox.flutter

import android.app.AppOpsManager
import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.content.ActivityNotFoundException
import android.content.pm.PackageManager
import android.Manifest
import android.nfc.NfcAdapter
import android.nfc.NdefMessage
import android.nfc.NdefRecord
import android.nfc.Tag
import android.nfc.tech.Ndef
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.Settings
import android.view.WindowManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Base64
import java.nio.charset.Charset
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import com.baidu.location.BDAbstractLocationListener
import com.baidu.location.BDLocation
import com.baidu.location.LocationClient
import com.baidu.location.LocationClientOption
import com.baidu.mapapi.model.LatLng
import com.baidu.mapapi.search.core.PoiInfo
import com.baidu.mapapi.search.geocode.GeoCodeResult
import com.baidu.mapapi.search.geocode.GeoCoder
import com.baidu.mapapi.search.geocode.OnGetGeoCoderResultListener
import com.baidu.mapapi.search.geocode.ReverseGeoCodeOption
import com.baidu.mapapi.search.geocode.ReverseGeoCodeResult
import com.baidu.mapapi.search.poi.OnGetPoiSearchResultListener
import com.baidu.mapapi.search.poi.PoiCitySearchOption
import com.baidu.mapapi.search.poi.PoiDetailResult
import com.baidu.mapapi.search.poi.PoiDetailSearchResult
import com.baidu.mapapi.search.poi.PoiIndoorResult
import com.baidu.mapapi.search.poi.PoiResult
import com.baidu.mapapi.search.poi.PoiSearch
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformViewRegistry

class MainActivity : FlutterActivity(), SensorEventListener {
    private val storageChannel = "schoolrun/storage"
    private val platformChannel = "schoolrun/platform"
    private val storageName = "schoolrun_flutter_store"
    private val storageKey = "snapshot"
    private var sensorManager: SensorManager? = null
    private var sensorSink: EventChannel.EventSink? = null
    private var steps = 0f
    private var azimuth = 0f
    private var pendingFileResult: MethodChannel.Result? = null
    private var pendingExportContent: String? = null
    private var gravity: FloatArray? = null
    private var magnetic: FloatArray? = null
    private var locationClient: LocationClient? = null
    private val locationSinks = mutableListOf<EventChannel.EventSink>()
    private var locationListener: BDAbstractLocationListener? = null
    private var poiSearch: PoiSearch? = null
    private var pendingPoiResult: MethodChannel.Result? = null
    private var geoCoder: GeoCoder? = null
    private var pendingReverseResult: MethodChannel.Result? = null
    private var mockLocationStarted = false
    private var flutterPlatformChannel: MethodChannel? = null

    // ---- NFC 前台读取 ----
    // 用 enableReaderMode 监听贴卡，再通过 EventChannel 把读到的 payload 推给 Dart 的
    // NFC 页。仅在 NFC 页可见时开启，离开就关。
    private var nfcEventSink: EventChannel.EventSink? = null
    private var nfcReaderEnabled = false
    private var nfcReaderRequested = false
    private var pendingNfcPayload: Map<String, String>? = null
    private val nfcReaderCallback = NfcAdapter.ReaderCallback { tag -> handleNfcTag(tag) }

    // 路线模拟小窗的状态登记处。小窗不在"开始模拟"时立刻拉起，而是等本 Activity 退到
    // 后台（onStop）才浮出、回到前台（onResume）就收起。
    // 这里缓存路线和最新坐标，供重新浮出时直接渲染。
    private var routeSimulationActive = false
    private var routeSimulationRunning = false
    // 悬浮窗服务是否已启动；窗口本身可能因生命周期暂时摘下，所以这不代表当前可见。
    private var routeOverlayServiceUp = false
    private var pendingRouteTitle = "路线模拟"
    private var pendingRoutePoints: ArrayList<HashMap<String, Double>>? = null
    private var pendingRouteLatitude = 0.0
    private var pendingRouteLongitude = 0.0
    private var routeOverlayScale = 0.58f
    private var routeOverlayButtonSize = 44
    private var simulationControlReceiver: BroadcastReceiver? = null

    // 是否显示悬浮小窗，由 Dart 侧下发。
    private var floatingWindowEnabled = true
    private val mainHandler = Handler(Looper.getMainLooper())
    private val showOverlayRetry = Runnable { maybeShowRouteOverlay() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestRuntimePermissions()
        registerSimulationControlReceiver()
    }

    /**
     * 悬浮窗的暂停/继续按键发的是应用内广播，由这里接住转发给 Dart 侧的模拟循环。
     * 悬浮窗自己不翻转按键状态——等 Dart 真的停了计时器再回推 isRunning 才刷新，
     * 否则广播丢失时会留下"显示已暂停但其实在跑"的错误状态。
     */
    private fun registerSimulationControlReceiver() {
        if (simulationControlReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val command = when (intent?.action) {
                    ACTION_PAUSE_SIMULATION -> "pause"
                    ACTION_RESUME_SIMULATION -> "resume"
                    else -> return
                }
                flutterPlatformChannel?.invokeMethod("simulationControl", command)
            }
        }
        val filter = IntentFilter().apply {
            addAction(ACTION_PAUSE_SIMULATION)
            addAction(ACTION_RESUME_SIMULATION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }
        simulationControlReceiver = receiver
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.getStringExtra("overlayDestination")?.let { destination ->
            flutterPlatformChannel?.invokeMethod("overlayDestination", destination)
        }
        if (intent.action == NfcAdapter.ACTION_NDEF_DISCOVERED ||
            intent.action == NfcAdapter.ACTION_TAG_DISCOVERED ||
            intent.action == NfcAdapter.ACTION_TECH_DISCOVERED
        ) {
            readNfcIntent()?.let { emitNfcPayload(it) }
        }
    }

    private fun requestRuntimePermissions() {
        val permissions = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            permissions.add(Manifest.permission.ACTIVITY_RECOGNITION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        val missing = permissions.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) requestPermissions(missing.toTypedArray(), 7001)
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "schoolrun/baidu_map",
            BaiduMapPlatformViewFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storageChannel).setMethodCallHandler { call, result ->
            val preferences = getSharedPreferences(storageName, Context.MODE_PRIVATE)
            when (call.method) {
                "load" -> result.success(preferences.getString(storageKey, "{}"))
                "save" -> {
                    preferences.edit().putString(storageKey, call.arguments as? String ?: "{}").apply()
                    result.success(null)
                }
                "deviceInfo" -> {
                    // 用 ANDROID_ID 作为 deviceId（后端按设备绑定账号）。
                    val androidId = try {
                        Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
                    } catch (_: Exception) {
                        ""
                    }
                    result.success(
                        mapOf(
                            "deviceId" to (androidId ?: ""),
                            "deviceName" to (Build.BRAND + " " + Build.MODEL).trim(),
                        ),
                    )
                }
                else -> result.notImplemented()

            }
        }
        flutterPlatformChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, platformChannel)
        flutterPlatformChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startMockLocation" -> {
                    val serviceIntent = Intent(this, MockLocationService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(serviceIntent) else startService(serviceIntent)
                    mockLocationStarted = true
                    result.success(true)
                }
                "pushLocation" -> {
                    val serviceIntent = Intent(this, MockLocationService::class.java).apply {
                        putExtra("latitude", call.argument<Double>("latitude") ?: 0.0)
                        putExtra("longitude", call.argument<Double>("longitude") ?: 0.0)
                        putExtra("altitude", call.argument<Double>("altitude") ?: 55.0)
                        putExtra("speed", (call.argument<Double>("speed") ?: 1.0).toFloat())
                        putExtra("bearing", (call.argument<Double>("bearing") ?: 0.0).toFloat())
                        putExtra("satelliteCount", call.argument<Int>("satelliteCount") ?: 8)
                        putExtra("signalQuality", call.argument<Int>("signalQuality") ?: 2)
                        putExtra("hdop", (call.argument<Double>("hdop") ?: 1.0).toFloat())
                        putExtra("networkSimulation", call.argument<Boolean>("networkSimulation") ?: false)
                        putExtra("intervalMillis", (call.argument<Int>("intervalMillis") ?: 200).toLong())
                    }
                    if (mockLocationStarted) startService(serviceIntent)
                    else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(serviceIntent)
                    else startService(serviceIntent)
                    mockLocationStarted = true
                    result.success(true)
                }
                "stopMockLocation" -> {
                    stopService(Intent(this, MockLocationService::class.java))
                    mockLocationStarted = false
                    result.success(true)
                }
                "dispatchNfc" -> result.success(dispatchNfc(call.argument<String>("url"), call.argument<String>("packageName")))
                "openUrl" -> {
                    val url = call.argument<String>("url")
                    result.success(if (url.isNullOrBlank()) false else try {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                        true
                    } catch (_: Exception) { false })
                }
                "startRouteSimulation" -> result.success(startRouteSimulation(call))
                "updateRouteSimulation" -> result.success(updateRouteSimulation(call))
                "stopRouteSimulation" -> result.success(stopRouteSimulation())
                "openOverlayPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${this.packageName}")))
                    }
                    result.success(true)
                }
                "startLocation" -> {
                    startLocation()
                    result.success(true)
                }
                "stopLocation" -> {
                    stopLocation()
                    result.success(true)
                }
                "searchPoi" -> searchPoi(call.argument<String>("query"), call.argument<String>("city"), result)
                "reverseGeocode" -> reverseGeocode(call.argument<Double>("latitude"), call.argument<Double>("longitude"), result)
                "pickRouteJson" -> {
                    pendingFileResult = result
                    try {
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            type = "application/json"
                            addCategory(Intent.CATEGORY_OPENABLE)
                        }, 4101)
                    } catch (_: ActivityNotFoundException) {
                        pendingFileResult = null
                        result.error("NO_FILE_PICKER", "系统没有可用的文件选择器", null)
                    }
                }
                "exportRouteJson" -> {
                    pendingExportContent = call.argument<String>("content")
                    pendingFileResult = result
                    try {
                        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            type = "application/json"
                            putExtra(Intent.EXTRA_TITLE, "schoolrun_routes.json")
                            addCategory(Intent.CATEGORY_OPENABLE)
                        }, 4102)
                    } catch (_: ActivityNotFoundException) {
                        pendingFileResult = null
                        pendingExportContent = null
                        result.error("NO_FILE_PICKER", "系统没有可用的文件选择器", null)
                    }
                }
                "pickWord" -> {
                    pendingFileResult = result
                    try {
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                            addCategory(Intent.CATEGORY_OPENABLE)
                        }, 4103)
                    } catch (_: ActivityNotFoundException) {
                        pendingFileResult = null
                        result.error("NO_FILE_PICKER", "系统没有可用的文件选择器", null)
                    }
                }
                "readNfc" -> result.success(readNfcIntent())
                "startNfcReader" -> result.success(startNfcReader())
                "stopNfcReader" -> {
                    stopNfcReader()
                    result.success(true)
                }
                "checkMockLocation" -> result.success(checkMockLocationState())
                "openMockLocationSettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "openAppSettings" -> {
                    try {
                        startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName"),
                            ),
                        )
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "isOverlayGranted" -> result.success(hasOverlayPermission())
                "keepScreenOn" -> {
                    if (call.argument<Boolean>("enabled") == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(true)
                }
                "getVersionName" -> result.success(BuildConfig.VERSION_NAME)
                "nfcStatus" -> {
                    val adapter = NfcAdapter.getDefaultAdapter(this)
                    result.success(mapOf(
                        "available" to (adapter != null),
                        "enabled" to (adapter?.isEnabled == true),
                    ))
                }
                "startJoystickOverlay" -> result.success(startJoystickOverlay(call))
                "stopJoystickOverlay" -> {
                    stopService(Intent(this, JoystickOverlayService::class.java))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "schoolrun/sensors").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sensorSink = events
                startSensors()
            }

            override fun onCancel(arguments: Any?) {
                sensorSink = null
                stopSensors()
            }
        })
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "schoolrun/location").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                events?.let { locationSinks.add(it) }
                startLocation()
            }

            override fun onCancel(arguments: Any?) {
                if (locationSinks.isNotEmpty()) {
                    // EventChannel does not identify the cancelled sink; listeners
                    // are removed in reverse subscription order.
                    locationSinks.removeAt(locationSinks.lastIndex)
                }
                if (locationSinks.isEmpty()) stopLocation()
            }
        })
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "schoolrun/nfc").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                nfcEventSink = events
                // 冷启动时贴卡读到的 payload 先缓存，等 Dart 页面订阅后补发一次。
                pendingNfcPayload?.let {
                    events?.success(it)
                    pendingNfcPayload = null
                }
            }

            override fun onCancel(arguments: Any?) {
                nfcEventSink = null
            }
        })
    }


    private fun readNfcIntent(): Map<String, String>? {
        val intent = intent ?: return null
        // 注意：不要因为 NFC 开关/硬件状态提前返回——冷启动时 intent 里已经带着标签数据，
        // 这里只解析 intent，硬件状态只影响提示文案。
        val direct = intent.dataString
        if (!direct.isNullOrBlank()) {
            intent.data = null
            return mapOf("url" to direct, "packageName" to "", "text" to "", "source" to "nfc")
        }
        val messages = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayExtra(NfcAdapter.EXTRA_NDEF_MESSAGES, NdefMessage::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayExtra(NfcAdapter.EXTRA_NDEF_MESSAGES)
        } ?: return null
        for (raw in messages) {
            val message = raw as? NdefMessage ?: continue
            val payload = parseNdefMessage(message) ?: continue
            // 一次读取后清掉 intent 里的消息，避免第二次点“读取标签”拿到旧数据。
            intent.removeExtra(NfcAdapter.EXTRA_NDEF_MESSAGES)
            return payload
        }
        return null
    }

    /** 开启 NFC 前台读取（enableReaderMode）。 */
    private fun startNfcReader(): Boolean {
        val adapter = NfcAdapter.getDefaultAdapter(this) ?: return false
        if (!adapter.isEnabled) return false
        nfcReaderRequested = true
        if (nfcReaderEnabled) return true
        return try {
            val flags = NfcAdapter.FLAG_READER_NFC_A or
                NfcAdapter.FLAG_READER_NFC_B or
                NfcAdapter.FLAG_READER_NFC_F or
                NfcAdapter.FLAG_READER_NFC_V
            adapter.enableReaderMode(this, nfcReaderCallback, flags, null)
            nfcReaderEnabled = true
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun stopNfcReader() {
        nfcReaderRequested = false
        if (!nfcReaderEnabled) return
        try {
            NfcAdapter.getDefaultAdapter(this)?.disableReaderMode(this)
        } catch (_: Exception) {
            // Reader may already be disabled by the system.
        }
        nfcReaderEnabled = false
    }

    /** 读取贴到手机上的标签（在后台线程解析 NDEF，避免阻塞主线程）。 */
    private fun handleNfcTag(tag: Tag) {
        Thread {
            val message = try {
                val ndef = Ndef.get(tag)
                if (ndef == null) {
                    null
                } else {
                    ndef.connect()
                    val value = ndef.ndefMessage
                    ndef.close()
                    value
                }
            } catch (_: Exception) {
                null
            }
            val payload = message?.let { parseNdefMessage(it) } ?: return@Thread
            mainHandler.post { emitNfcPayload(payload) }
        }.start()
    }

    private fun emitNfcPayload(payload: Map<String, String>) {
        pendingNfcPayload = payload
        vibrateNfc()
        mainHandler.post {
            nfcEventSink?.success(payload)
            pendingNfcPayload = null
        }
    }

    /**
     * 解析 NDEF 消息：URL / android.com:pkg 应用记录 / 文本记录。
     * 包名优先取 EXTERNAL_TYPE `android.com:pkg` 记录，同时兼容文本与 MIME 记录。
     */
    private fun parseNdefMessage(message: NdefMessage): Map<String, String>? {
        var url = ""
        var text = ""
        var packageName = ""
        val appRecordType = "android.com:pkg".toByteArray(Charset.forName("US-ASCII"))
        for (record in message.records) {
            val uri = try {
                record.toUri()?.toString().orEmpty()
            } catch (_: Exception) {
                ""
            }
            if (uri.isNotBlank() && url.isBlank()) url = uri.trim()
            if (record.tnf == NdefRecord.TNF_WELL_KNOWN &&
                record.type.contentEquals(NdefRecord.RTD_TEXT)
            ) {
                val payload = record.payload
                if (payload.isNotEmpty()) {
                    val languageLength = payload[0].toInt() and 0x3f
                    val start = (languageLength + 1).coerceAtMost(payload.size)
                    text = payload.copyOfRange(start, payload.size)
                        .toString(Charset.forName("UTF-8"))
                        .trim()
                }
            }
            if (record.tnf == NdefRecord.TNF_EXTERNAL_TYPE &&
                record.type.contentEquals(appRecordType)
            ) {
                packageName = record.payload
                    .toString(Charset.forName("UTF-8"))
                    .trim()
            }
            if (record.tnf == NdefRecord.TNF_MIME_MEDIA &&
                text.isEmpty() &&
                record.type.contentEquals("text/plain".toByteArray(Charset.forName("US-ASCII")))
            ) {
                text = record.payload.toString(Charset.forName("UTF-8")).trim()
            }
        }
        if (url.isBlank() && text.startsWith("http", ignoreCase = true)) url = text.trim()
        if (url.isBlank() && text.isBlank() && packageName.isBlank()) return null
        return mapOf(
            "url" to url,
            "packageName" to packageName,
            "text" to text,
            "source" to "nfc",
        )
    }

    /** 是否已把本应用设为“模拟位置信息应用”。 */
    private fun checkMockLocationState(): Map<String, Boolean> {
        val allowed = try {
            val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_MOCK_LOCATION,
                Process.myUid(),
                packageName,
            ) == AppOpsManager.MODE_ALLOWED
        } catch (_: Exception) {
            false
        }
        val developerOptions = try {
            Settings.Global.getInt(
                contentResolver,
                Settings.Global.DEVELOPMENT_SETTINGS_ENABLED,
                0,
            ) == 1
        } catch (_: Exception) {
            false
        }
        return mapOf(
            "allowed" to allowed,
            "developerOptions" to developerOptions,
        )
    }

    private fun startSensors() {
        if (sensorManager != null) return
        sensorManager = getSystemService(SENSOR_SERVICE) as SensorManager
        sensorManager?.getDefaultSensor(Sensor.TYPE_STEP_COUNTER)?.let {
            sensorManager?.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
        sensorManager?.getDefaultSensor(Sensor.TYPE_STEP_DETECTOR)?.let {
            sensorManager?.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
        sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let {
            sensorManager?.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
        }
        sensorManager?.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD)?.let {
            sensorManager?.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
        }
    }

    private fun startLocation() {
        if (locationClient != null) return
        try {
            LocationClient.setAgreePrivacy(true)
            locationClient = LocationClient(applicationContext).also { client ->
                locationListener = object : BDAbstractLocationListener() {
                    override fun onReceiveLocation(location: BDLocation?) {
                        if (location == null) return
                        val payload = mapOf(
                            "latitude" to location.latitude,
                            "longitude" to location.longitude,
                            "altitude" to location.altitude,
                            "speed" to location.speed,
                            "direction" to location.direction,
                            "address" to (location.addrStr ?: ""),
                            "city" to (location.city ?: ""),
                            "errorCode" to location.locType,
                        )
                        locationSinks.toList().forEach { it.success(payload) }
                    }
                }
                client.registerLocationListener(locationListener)
                val option = LocationClientOption().apply {
                    locationMode = LocationClientOption.LocationMode.Hight_Accuracy
                    isOpenGps = true
                    setCoorType("bd09ll")
                    setScanSpan(1000)
                    setIsNeedAddress(true)
                    setIsNeedLocationDescribe(true)
                }
                client.locOption = option
                client.start()
            }
        } catch (_: Exception) {
            locationSinks.toList().forEach { it.error("LOCATION_UNAVAILABLE", "百度定位服务不可用", null) }
        }
    }

    private fun searchPoi(query: String?, city: String?, result: MethodChannel.Result) {
        val keyword = query?.trim().orEmpty()
        if (keyword.isEmpty()) {
            result.success(emptyList<Map<String, Any>>())
            return
        }
        try {
            pendingPoiResult?.error("CANCELLED", "上一次搜索已取消", null)
            pendingPoiResult = result
            if (poiSearch == null) {
                poiSearch = PoiSearch.newInstance().also { search ->
                    search.setOnGetPoiSearchResultListener(object : OnGetPoiSearchResultListener {
                        override fun onGetPoiResult(value: PoiResult?) {
                            val items = value?.allPoi.orEmpty().mapNotNull { info: PoiInfo? ->
                                if (info?.location == null) return@mapNotNull null
                                mapOf<String, Any>(
                                    "name" to (info.name ?: ""),
                                    "address" to (info.address ?: ""),
                                    "latitude" to info.location.latitude,
                                    "longitude" to info.location.longitude,
                                )
                            }
                            pendingPoiResult?.success(items)
                            pendingPoiResult = null
                        }

                        override fun onGetPoiDetailResult(value: PoiDetailResult?) = Unit
                        override fun onGetPoiDetailResult(value: PoiDetailSearchResult?) = Unit
                        override fun onGetPoiIndoorResult(value: PoiIndoorResult?) = Unit
                    })
                }
            }
            val cityName = city?.trim().orEmpty().ifEmpty { "全国" }
            poiSearch?.searchInCity(
                PoiCitySearchOption()
                    .city(cityName)
                    .keyword(keyword)
                    .pageCapacity(20)
                    .pageNum(0)
                    .cityLimit(false)
                    .isReturnAddr(true),
            )
        } catch (error: Exception) {
            pendingPoiResult = null
            result.error("POI_SEARCH_FAILED", error.message, null)
        }
    }

    private fun reverseGeocode(latitude: Double?, longitude: Double?, result: MethodChannel.Result) {
        if (latitude == null || longitude == null) {
            result.error("INVALID_COORDINATE", "缺少经纬度", null)
            return
        }
        try {
            pendingReverseResult?.error("CANCELLED", "上一次地址查询已取消", null)
            pendingReverseResult = result
            if (geoCoder == null) {
                geoCoder = GeoCoder.newInstance().also { coder ->
                    coder.setOnGetGeoCodeResultListener(object : OnGetGeoCoderResultListener {
                        override fun onGetGeoCodeResult(value: GeoCodeResult?) = Unit
                        override fun onGetReverseGeoCodeResult(value: ReverseGeoCodeResult?) {
                            val callback = pendingReverseResult
                            pendingReverseResult = null
                            if (value == null) callback?.error("GEOCODE_FAILED", "地址查询失败", null)
                            else callback?.success(mapOf("address" to (value.address ?: ""), "latitude" to (value.location?.latitude ?: 0.0), "longitude" to (value.location?.longitude ?: 0.0)))
                        }
                    })
                }
            }
            geoCoder?.reverseGeoCode(ReverseGeoCodeOption().location(LatLng(latitude, longitude)))
        } catch (error: Exception) {
            pendingReverseResult = null
            result.error("GEOCODE_FAILED", error.message, null)
        }
    }

    private fun stopLocation() {
        locationClient?.stop()
        locationListener?.let { locationClient?.unRegisterLocationListener(it) }
        locationListener = null
        locationClient = null
    }

    private fun stopSensors() {
        sensorManager?.unregisterListener(this)
        sensorManager = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type == Sensor.TYPE_STEP_COUNTER) steps = event.values.firstOrNull() ?: steps
        if (event.sensor.type == Sensor.TYPE_STEP_DETECTOR) steps += 1f
        if (event.sensor.type == Sensor.TYPE_ACCELEROMETER) gravity = event.values.clone()
        if (event.sensor.type == Sensor.TYPE_MAGNETIC_FIELD) magnetic = event.values.clone()
        val rotation = FloatArray(9)
        val inclination = FloatArray(9)
        if (gravity != null && magnetic != null && SensorManager.getRotationMatrix(rotation, inclination, gravity, magnetic)) {
            val orientation = SensorManager.getOrientation(rotation, FloatArray(3))
            azimuth = Math.toDegrees(orientation[0].toDouble()).toFloat().let { if (it < 0) it + 360 else it }
        }
        sensorSink?.success(mapOf("steps" to steps, "azimuth" to azimuth, "stepDetected" to (event.sensor.type == Sensor.TYPE_STEP_DETECTOR)))
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    /**
     * 悬浮小窗的显隐完全由 Activity 生命周期驱动：
     * 离开本应用（onStop）才浮出，回到本应用（onResume）就收起。
     * 跳转目标应用的一瞬间窗口未必挂得上，所以 onPause / onStop 各排一次延迟重试
     * （250ms / 600ms）。
     */
    override fun onResume() {
        super.onResume()
        mainHandler.removeCallbacks(showOverlayRetry)
        hideRouteOverlayWindow()
        if (nfcReaderRequested && !nfcReaderEnabled) startNfcReader()
    }

    override fun onPause() {
        super.onPause()
        // 退到后台时关闭 reader mode，避免持续占用 NFC 硬件；回到前台按请求恢复。
        if (nfcReaderEnabled) {
            runCatching { NfcAdapter.getDefaultAdapter(this)?.disableReaderMode(this) }
            nfcReaderEnabled = false
        }
        mainHandler.postDelayed(showOverlayRetry, 250L)
    }

    override fun onStop() {
        maybeShowRouteOverlay()
        mainHandler.postDelayed(showOverlayRetry, 600L)
        super.onStop()
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(showOverlayRetry)
        stopSensors()
        stopLocation()
        stopNfcReader()
        simulationControlReceiver?.let { runCatching { unregisterReceiver(it) } }
        simulationControlReceiver = null
        poiSearch?.destroy()
        geoCoder?.destroy()
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 4101 && requestCode != 4102 && requestCode != 4103) return
        val callback = pendingFileResult
        pendingFileResult = null
        if (resultCode != RESULT_OK || data?.data == null) {
            pendingExportContent = null
            callback?.success(null)
            return
        }
        try {
            if (requestCode == 4101) {
                val content = contentResolver.openInputStream(data.data!!)?.bufferedReader()?.use { it.readText() }
                callback?.success(content)
            } else if (requestCode == 4103) {
                val bytes = contentResolver.openInputStream(data.data!!)?.use { it.readBytes() } ?: ByteArray(0)
                callback?.success(mapOf(
                    "filename" to (data.data?.lastPathSegment ?: "tip.docx"),
                    "bytes" to Base64.encodeToString(bytes, Base64.NO_WRAP),
                ))
            } else {
                contentResolver.openOutputStream(data.data!!)?.bufferedWriter()?.use { it.write(pendingExportContent.orEmpty()) }
                callback?.success(true)
            }
        } catch (error: Exception) {
            callback?.error("FILE_IO", error.message, null)
        } finally {
            pendingExportContent = null
        }
    }

    private fun dispatchNfc(url: String?, packageName: String?): Map<String, String> {
        val cleanUrl = url?.trim().orEmpty()
        val cleanPackage = packageName?.trim().orEmpty()
        if (cleanUrl.isEmpty()) {
            return mapOf("status" to "failed", "detail" to "跳转 URL 为空")
        }
        vibrateNfc()

        // NFC 派发只负责拉起目标应用，自己不建任何悬浮窗，也就不需要悬浮窗权限。
        // 跳转会让本 Activity 退到后台，小窗由 onStop → maybeShowRouteOverlay() 自动浮出，
        // 不在这里插手。
        val status = launchTargetApp(cleanUrl, cleanPackage)
        val detail = when (status) {
            "ndef" -> "已通过 NFC 记录启动目标应用"
            "view" -> "已通过目标应用打开链接"
            "browser" -> "目标应用不可用，已用浏览器打开链接"
            else -> "目标应用启动失败，请检查跳转 URL 与应用包名"
        }
        return mapOf("status" to status, "detail" to detail)
    }

    /** 返回 ndef / view / browser / failed 四档派发结果。 */
    private fun launchTargetApp(cleanUrl: String, cleanPackage: String): String {
        // Strategy 1: Try NDEF intent with original URL (what apps expect from real NFC tags)
        // For Alipay and similar apps, they need the full redirect URL to process correctly
        if (cleanPackage.isNotEmpty()) {
            try {
                val uri = Uri.parse(cleanUrl)
                val uriRecord = NdefRecord.createUri(uri)
                val appRecord = NdefRecord.createApplicationRecord(cleanPackage)
                val message = NdefMessage(arrayOf(uriRecord, appRecord))

                val ndefIntent = Intent(NfcAdapter.ACTION_NDEF_DISCOVERED).apply {
                    data = uri
                    setPackage(cleanPackage)
                    putExtra(NfcAdapter.EXTRA_NDEF_MESSAGES, arrayOf(message))
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                }
                startActivity(ndefIntent)
                return "ndef"
            } catch (_: ActivityNotFoundException) {
                // Fall through to strategy 2
            } catch (_: SecurityException) {
                // Fall through to strategy 2
            } catch (_: Exception) {
                // Fall through to strategy 2
            }
        }

        // Strategy 2: Try ACTION_VIEW with the original URL and package
        if (cleanPackage.isNotEmpty()) {
            try {
                val viewIntent = Intent(Intent.ACTION_VIEW, Uri.parse(cleanUrl)).apply {
                    setPackage(cleanPackage)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(viewIntent)
                return "view"
            } catch (_: ActivityNotFoundException) {
                // Fall through to strategy 3
            } catch (_: SecurityException) {
                // Fall through to strategy 3
            } catch (_: Exception) {
                // Fall through to strategy 3
            }
        }

        // Strategy 3: Extract and try the deep link scheme if present (for fallback)
        val extractedScheme = try {
            val uri = Uri.parse(cleanUrl)
            val schemeParam = uri.getQueryParameter("scheme")
            if (!schemeParam.isNullOrEmpty()) {
                java.net.URLDecoder.decode(schemeParam, "UTF-8")
            } else {
                null
            }
        } catch (_: Exception) {
            null
        }

        // Try extracted scheme with package
        if (extractedScheme != null && cleanPackage.isNotEmpty()) {
            try {
                val schemeIntent = Intent(Intent.ACTION_VIEW, Uri.parse(extractedScheme)).apply {
                    setPackage(cleanPackage)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(schemeIntent)
                return "view"
            } catch (_: Exception) {
                // Fall through to strategy 4
            }
        }

        // Strategy 4: Try ACTION_VIEW without package restriction (original URL)
        return try {
            val genericIntent = Intent(Intent.ACTION_VIEW, Uri.parse(cleanUrl)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(genericIntent)
            "browser"
        } catch (_: Exception) {
            "failed"
        }
    }

    private fun vibrateNfc() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vibrator = getSystemService(VibratorManager::class.java).defaultVibrator
                vibrator.vibrate(VibrationEffect.createOneShot(45, VibrationEffect.DEFAULT_AMPLITUDE))
            } else {
                @Suppress("DEPRECATION")
                (getSystemService(VIBRATOR_SERVICE) as Vibrator).vibrate(45)
            }
        } catch (_: Exception) {
            // Vibration is optional on devices without a vibrator.
        }
    }

    private fun startJoystickOverlay(call: MethodCall): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
            startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${this.packageName}")))
            return false
        }
        val joystick = Intent(this, JoystickOverlayService::class.java).apply {
            putExtra("latitude", call.argument<Double>("latitude") ?: 39.908)
            putExtra("longitude", call.argument<Double>("longitude") ?: 116.397)
            putExtra("altitude", call.argument<Double>("altitude") ?: 55.0)
            putExtra("walkSpeed", call.argument<Double>("walkSpeed") ?: 1.2)
            putExtra("runSpeed", call.argument<Double>("runSpeed") ?: 3.6)
            putExtra("bikeSpeed", call.argument<Double>("bikeSpeed") ?: 10.0)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(joystick) else startService(joystick)
        return true
    }

    /**
     * 登记一次路线模拟。小窗不在这里拉起——它由 Activity 生命周期驱动，等本应用退到
     * 后台（通常就是下面那次 NFC 跳转造成的）才浮出。
     *
     * 顺序：先开始模拟，再派发待触发的 NFC 跳转；开始模拟本身完全不碰悬浮窗。
     * 调用方带 nfcUrl/nfcPackage 即表示有待触发的跳转。
     */
    private fun startRouteSimulation(call: MethodCall): Boolean {
        floatingWindowEnabled = call.argument<Boolean>("floatingWindow") ?: floatingWindowEnabled
        // 缺悬浮窗权限只提示、不拦模拟：弹完对话框照样往下走，继续起服务与开始模拟。
        if (floatingWindowEnabled && !hasOverlayPermission()) {
            startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${this.packageName}")))
        }
        pendingRouteTitle = call.argument<String>("title") ?: "路线模拟"
        pendingRoutePoints = call.argument<ArrayList<HashMap<String, Double>>>("routePoints")
        pendingRouteLatitude = call.argument<Double>("latitude") ?: 0.0
        pendingRouteLongitude = call.argument<Double>("longitude") ?: 0.0
        routeOverlayScale = (call.argument<Double>("floatingWindowScale") ?: routeOverlayScale.toDouble()).toFloat().coerceIn(0.35f, 0.90f)
        routeOverlayButtonSize = (call.argument<Int>("floatingWindowButtonSize") ?: routeOverlayButtonSize).coerceIn(32, 72)
        routeSimulationRunning = true
        routeSimulationActive = true
        // 趁还在前台先把悬浮窗服务起好（这一发只挂通知、不建窗口），
        // 否则等 onStop 再 startForegroundService 会被 Android 12+ 直接拒掉。
        if (floatingWindowEnabled) sendRouteOverlay("idle")

        val nfcUrl = call.argument<String>("nfcUrl")
        val nfcPackage = call.argument<String>("nfcPackage")
        if (!nfcUrl.isNullOrBlank() && !nfcPackage.isNullOrBlank()) {
            return dispatchNfc(nfcUrl, nfcPackage)["status"] != "failed"
        }
        return true
    }

    /** 小窗显示条件：设置开着、Activity 还活着、模拟在进行。 */
    private fun shouldShowRouteOverlay() =
        floatingWindowEnabled && !isFinishing && !isDestroyed && routeSimulationActive

    private fun maybeShowRouteOverlay() {
        if (shouldShowRouteOverlay()) sendRouteOverlay("show") else hideRouteOverlayWindow()
    }

    /** 只摘窗口、不停服务——模拟还在跑，服务要留着下次浮出时复用 View 和 MapView。 */
    private fun hideRouteOverlayWindow() {
        if (!routeOverlayServiceUp) return
        sendRouteOverlay("hide")
    }

    /**
     * 给悬浮窗服务下发一个动作，服务还没起就先起。
     *
     * 首次启动必须走 startForegroundService，而 Android 12+ 禁止从后台拉起前台服务
     * （ForegroundServiceStartNotAllowedException）。onStop 时我们已经被算作后台，
     * 所以服务是在 startRouteSimulation——那时还在前台——用 "idle" 先起好的，
     * 之后的 show / hide / update 只是给一个已在运行的前台服务发指令。
     *
     * 没权限时一律不拉服务：服务 onStartCommand 会 toast + stopSelf，而模拟每
     * 200ms 推一帧，拉起来只会把 toast 刷成连播，还留一条永不消失的通知。
     * 提前 return 也让 routeOverlayServiceUp 保持 false，后续指令自然全部短路。
     */
    private fun sendRouteOverlay(action: String) {
        if (!hasOverlayPermission()) return
        val intent = Intent(this, RouteSimulationOverlayService::class.java).apply {
            putExtra("action", action)
            putExtra("title", pendingRouteTitle)
            putExtra("latitude", pendingRouteLatitude)
            putExtra("longitude", pendingRouteLongitude)
            putExtra("isRunning", routeSimulationRunning)
            putExtra("routePoints", pendingRoutePoints)
            putExtra("scale", routeOverlayScale)
            putExtra("buttonSize", routeOverlayButtonSize)
        }
        if (routeOverlayServiceUp) startService(intent)
        else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
        else startService(intent)
        routeOverlayServiceUp = true
    }

    private fun hasOverlayPermission() =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)

    private fun updateRouteSimulation(call: MethodCall): Boolean {
        if (!routeSimulationActive) return false
        pendingRouteLatitude = call.argument<Double>("latitude") ?: pendingRouteLatitude
        pendingRouteLongitude = call.argument<Double>("longitude") ?: pendingRouteLongitude
        routeSimulationRunning = call.argument<Boolean>("isRunning") ?: routeSimulationRunning
        // 服务还没起时只更新缓存，别为了推一帧把前台服务拉起来
        if (!routeOverlayServiceUp) return true
        sendRouteOverlay("update")
        return true
    }

    private fun stopRouteSimulation(): Boolean {
        routeSimulationActive = false
        routeSimulationRunning = false
        pendingRoutePoints = null
        if (!routeOverlayServiceUp) return true
        routeOverlayServiceUp = false
        startService(
            Intent(this, RouteSimulationOverlayService::class.java).putExtra("action", "hide"),
        )
        stopService(Intent(this, RouteSimulationOverlayService::class.java))
        return true
    }

    companion object {
        const val ACTION_PAUSE_SIMULATION = "com.campusruntoolbox.PAUSE_SIMULATION"
        const val ACTION_RESUME_SIMULATION = "com.campusruntoolbox.RESUME_SIMULATION"
    }
}
