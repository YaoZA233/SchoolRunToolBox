package com.campusruntoolbox.flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.location.Location
import android.location.LocationManager
import android.location.provider.ProviderProperties
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log

/**
 * 模拟定位前台服务。
 *
 * 行为：
 * - 用 HandlerThread 按固定间隔（默认 200ms）**持续**注入最近一次位置。只靠 Flutter 每帧
 *   调一次 `pushLocation` 是不够的：切到目标 App、熄屏、Flutter 引擎被系统降频后定时器会停，
 *   系统定位会立刻回到真实位置，校园跑就会判定“定位漂移”。原生侧保持一个定时器，
 *   即使 Dart 暂停也能继续推最后已知位置。
 * - 同时注入 GPS 与（可选）NETWORK provider，附带完整 NMEA 与高精度元数据。
 * - 坐标统一 BD-09（百度地图）→ WGS-84（系统 Location）后注入。
 * - 持有 PARTIAL_WAKE_LOCK，避免熄屏后注入被挂起。
 */
class MockLocationService : Service() {
    companion object {
        private const val TAG = "MockLocationService"
        private const val CHANNEL_ID = "schoolrun_mock_location"
        private const val NOTIFICATION_ID = 1
        private const val DEFAULT_INTERVAL_MS = 200L
    }

    private lateinit var locationManager: LocationManager
    private val gpsProvider = LocationManager.GPS_PROVIDER
    private val networkProvider = LocationManager.NETWORK_PROVIDER
    private var handlerThread: HandlerThread? = null
    private var handler: Handler? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var gpsProviderReady = false
    private var networkProviderReady = false

    // 最近一次运动状态。坐标已经是 WGS-84，直接可用于注入。
    private var hasFix = false
    private var latitude = 0.0
    private var longitude = 0.0
    private var altitude = 55.0
    private var speed = 1.2f
    private var bearing = 0f
    private var satelliteCount = 8
    private var signalQuality = 2
    private var hdop = 1.5f
    private var networkSimulation = false
    private var intervalMillis = DEFAULT_INTERVAL_MS

    private val injectTask = object : Runnable {
        override fun run() {
            injectCurrent()
            handler?.postDelayed(this, intervalMillis.coerceIn(80L, 5_000L))
        }
    }

    override fun onCreate() {
        super.onCreate()
        locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        startForeground(NOTIFICATION_ID, buildNotification())
        setupProviders()
        startLooper()
        acquireWakeLock()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent != null && intent.hasExtra("latitude")) {
            updateMotion(
                intent.getDoubleExtra("latitude", 0.0),
                intent.getDoubleExtra("longitude", 0.0),
                intent.getDoubleExtra("altitude", 55.0),
                intent.getFloatExtra("speed", 1.2f),
                intent.getFloatExtra("bearing", 0f),
                intent.getIntExtra("satelliteCount", 8),
                intent.getIntExtra("signalQuality", 2),
                intent.getFloatExtra("hdop", 1.5f),
                intent.getBooleanExtra("networkSimulation", false),
                intent.getLongExtra("intervalMillis", DEFAULT_INTERVAL_MS),
            )
        }
        return START_STICKY
    }

    override fun onDestroy() {
        handler?.removeCallbacksAndMessages(null)
        handlerThread?.quitSafely()
        handlerThread = null
        handler = null
        removeProviders()
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startLooper() {
        if (handler != null) return
        val thread = HandlerThread("schoolrun-mock-location")
        thread.start()
        handlerThread = thread
        handler = Handler(thread.looper)
        handler?.postDelayed(injectTask, intervalMillis)
    }

    /**
     * 更新运动状态。入参坐标是 BD-09（地图取点/路线点/定位流的坐标系）。
     */
    private fun updateMotion(
        bdLatitude: Double,
        bdLongitude: Double,
        altitudeMeters: Double,
        speedMetersPerSecond: Float,
        bearingDegrees: Float,
        satellites: Int,
        quality: Int,
        hdopValue: Float,
        networkEnabled: Boolean,
        interval: Long,
    ) {
        if (bdLatitude == 0.0 && bdLongitude == 0.0) return
        val wgs = CoordinateConverter.bd09ToWgs84(bdLongitude, bdLatitude)
        longitude = wgs[0]
        latitude = wgs[1]
        altitude = altitudeMeters
        speed = speedMetersPerSecond.coerceAtLeast(0f)
        bearing = ((bearingDegrees % 360f) + 360f) % 360f
        satelliteCount = CompleteNmea.normalizeSatelliteCount(satellites)
        signalQuality = CompleteNmea.normalizeSignalQuality(quality)
        hdop = CompleteNmea.normalizeHdop(hdopValue)
        networkSimulation = networkEnabled
        intervalMillis = interval.coerceIn(80L, 5_000L)
        hasFix = true
        if (handler != null) {
            // 立刻注入一次，避免刚点开始时要等到下一个周期才有位置。
            handler?.removeCallbacks(injectTask)
            handler?.post(injectTask)
        }
    }

    private fun injectCurrent() {
        if (!hasFix) return
        val mockAllowed = try {
            val appOps = getSystemService(Context.APP_OPS_SERVICE) as android.app.AppOpsManager
            appOps.checkOpNoThrow(
                android.app.AppOpsManager.OPSTR_MOCK_LOCATION,
                android.os.Process.myUid(),
                packageName,
            ) == android.app.AppOpsManager.MODE_ALLOWED
        } catch (_: Exception) {
            true
        }
        if (!mockAllowed) {
            // 用户没在开发者选项里选中本应用时无需刷日志，注入成功也会被系统丢弃。
            return
        }
        injectGps()
        if (networkSimulation) injectNetwork()
    }

    private fun injectGps() {
        if (!ensureGpsProvider()) return
        try {
            val now = System.currentTimeMillis()
            val location = createLocation(gpsProvider, hdop * 2.5f, now).apply {
                extras = android.os.Bundle().apply {
                    putString(
                        "nmea",
                        CompleteNmea.generate(
                            latitude,
                            longitude,
                            altitude,
                            speed,
                            bearing,
                            satelliteCount,
                            signalQuality,
                            hdop,
                            now,
                        ),
                    )
                    // 同时写入多种常见字段名，兼容不同校园 App 的解析习惯。
                    putInt("satellites", satelliteCount)
                    putInt("satelliteCount", satelliteCount)
                    putInt("signalQuality", signalQuality)
                    putFloat("hdop", hdop)
                    putString("source", gpsProvider)
                }
            }
            locationManager.setTestProviderLocation(gpsProvider, location)
        } catch (error: SecurityException) {
            Log.w(TAG, "mock location permission denied", error)
        } catch (error: Exception) {
            Log.w(TAG, "inject gps failed", error)
        }
    }

    private fun injectNetwork() {
        if (!ensureNetworkProvider()) return
        try {
            val location = createLocation(
                networkProvider,
                kotlin.math.max(25f, hdop * 10f),
                System.currentTimeMillis(),
            ).apply {
                extras = android.os.Bundle().apply {
                    putString("source", networkProvider)
                    putBoolean("networkSimulation", true)
                    putInt("satelliteCount", satelliteCount)
                }
            }
            locationManager.setTestProviderLocation(networkProvider, location)
        } catch (error: SecurityException) {
            Log.w(TAG, "network mock location permission denied", error)
        } catch (error: Exception) {
            Log.w(TAG, "inject network failed", error)
        }
    }

    private fun createLocation(provider: String, accuracyMeters: Float, time: Long): Location {
        val location = Location(provider)
        location.latitude = latitude
        location.longitude = longitude
        location.altitude = altitude
        location.speed = speed
        location.bearing = bearing
        location.accuracy = accuracyMeters
        location.time = time
        location.elapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            location.verticalAccuracyMeters = kotlin.math.max(accuracyMeters, hdop * 3f)
            location.speedAccuracyMetersPerSecond = 0.1f
            location.bearingAccuracyDegrees = 1f
        }
        return location
    }

    private fun ensureGpsProvider(): Boolean {
        if (gpsProviderReady) return true
        gpsProviderReady = addProvider(
            gpsProvider,
            requiresNetwork = false,
            requiresSatellite = true,
            powerUsage = ProviderProperties.POWER_USAGE_HIGH,
            accuracy = ProviderProperties.ACCURACY_FINE,
        )
        return gpsProviderReady
    }

    private fun ensureNetworkProvider(): Boolean {
        if (networkProviderReady) return true
        networkProviderReady = addProvider(
            networkProvider,
            requiresNetwork = true,
            requiresSatellite = false,
            powerUsage = ProviderProperties.POWER_USAGE_LOW,
            accuracy = ProviderProperties.ACCURACY_COARSE,
        )
        return networkProviderReady
    }

    private fun addProvider(
        provider: String,
        requiresNetwork: Boolean,
        requiresSatellite: Boolean,
        powerUsage: Int,
        accuracy: Int,
    ): Boolean {
        return try {
            runCatching { locationManager.removeTestProvider(provider) }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                locationManager.addTestProvider(
                    provider,
                    requiresNetwork,
                    requiresSatellite,
                    false,
                    false,
                    true,
                    true,
                    true,
                    powerUsage,
                    accuracy,
                )
            } else {
                @Suppress("DEPRECATION")
                locationManager.addTestProvider(
                    provider,
                    requiresNetwork,
                    requiresSatellite,
                    false,
                    false,
                    true,
                    true,
                    true,
                    powerUsage,
                    accuracy,
                )
            }
            locationManager.setTestProviderEnabled(provider, true)
            true
        } catch (error: Exception) {
            Log.w(TAG, "add test provider $provider failed", error)
            false
        }
    }

    private fun setupProviders() {
        // 预创建 provider，避免第一帧注入时才创建导致目标 App 还没订阅到位置。
        ensureGpsProvider()
        if (networkSimulation) ensureNetworkProvider()
    }

    private fun removeProviders() {
        for (provider in listOf(gpsProvider, networkProvider)) {
            try {
                locationManager.setTestProviderEnabled(provider, false)
            } catch (_: Exception) {
                // Provider may not exist.
            }
            try {
                locationManager.removeTestProvider(provider)
            } catch (_: Exception) {
                // Provider may not exist.
            }
        }
        gpsProviderReady = false
        networkProviderReady = false
    }

    private fun acquireWakeLock() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "$packageName:mock-location",
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (error: Exception) {
            Log.w(TAG, "acquire wake lock failed", error)
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.takeIf { it.isHeld }?.release()
        } catch (_: Exception) {
            // Ignore.
        }
        wakeLock = null
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "路线模拟", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("路线模拟运行中")
            .setContentText("正在向系统发送模拟位置")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .build()
    }
}
