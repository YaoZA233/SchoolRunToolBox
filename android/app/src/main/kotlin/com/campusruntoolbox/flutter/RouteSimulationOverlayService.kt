package com.campusruntoolbox.flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import com.baidu.mapapi.map.BaiduMap
import com.baidu.mapapi.map.MapStatus
import com.baidu.mapapi.map.MapStatusUpdateFactory
import com.baidu.mapapi.map.MapView
import com.baidu.mapapi.map.Marker
import com.baidu.mapapi.map.MarkerOptions
import com.baidu.mapapi.map.PolylineOptions
import com.baidu.mapapi.model.LatLng

class RouteSimulationOverlayService : Service() {
    private val channelId = "route_simulation_overlay"
    private var windowManager: WindowManager? = null
    private var rootView: FrameLayout? = null
    private var mapView: MapView? = null
    private var baiduMap: BaiduMap? = null
    private var marker: Marker? = null
    private var titleView: TextView? = null
    private var pauseButton: TextView? = null
    private var resumeButton: TextView? = null
    private var params: WindowManager.LayoutParams? = null
    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0
    private var isDragging = false
    private var resizeStartRawX = 0f
    private var resizeStartRawY = 0f
    private var resizeStartScale = 0.5f
    private var currentScale = 0.5f
    private val minScale = 0.35f
    private val maxScale = 0.90f
    private var buttonSize = 44
    private var controlRow: LinearLayout? = null
    private var routePoints: List<LatLng> = emptyList()
    private var currentLatitude = 0.0
    private var currentLongitude = 0.0
    private var isSimulationRunning = false
    // 窗口当前是否真的挂在 WindowManager 上。隐藏时保留 View 和 MapView 供复用，
    // 靠这个标志区分"服务活着"和"窗口可见"，避免对着已 onPause 的地图推帧。
    private var windowAttached = false

    override fun onCreate() {
        super.onCreate()
        startForeground(41, notification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
            // 权限没给时必须显式收尾：onCreate 已经 startForeground，
            // 静默返回会留下一条永远不消失的通知，而窗口根本不出现。
            Toast.makeText(this, "请先授予悬浮窗权限，然后重新开始模拟", Toast.LENGTH_LONG).show()
            stopSelf()
            return START_NOT_STICKY
        }
        intent?.let {
            currentScale = it.getFloatExtra("scale", currentScale).coerceIn(minScale, maxScale)
            buttonSize = it.getIntExtra("buttonSize", buttonSize).coerceIn(32, 72)
            when (it.getStringExtra("action")) {
                "show" -> {
                    val title = it.getStringExtra("title") ?: "路线模拟"
                    // Flutter 侧统一使用 BD-09，百度地图直接绘制，不做任何转换
                    currentLatitude = it.getDoubleExtra("latitude", 0.0)
                    currentLongitude = it.getDoubleExtra("longitude", 0.0)

                    isSimulationRunning = it.getBooleanExtra("isRunning", false)
                    @Suppress("UNCHECKED_CAST")
                    val points = it.getSerializableExtra("routePoints") as? ArrayList<HashMap<String, Double>>
                    routePoints = points?.mapNotNull { point ->
                        val lat = point["latitude"] ?: return@mapNotNull null
                        val lng = point["longitude"] ?: return@mapNotNull null
                        LatLng(lat, lng)  // 注意：LatLng(纬度, 经度)
                    } ?: emptyList()
                    showWindow(title)
                }
                "update" -> {
                    currentLatitude = it.getDoubleExtra("latitude", 0.0)
                    currentLongitude = it.getDoubleExtra("longitude", 0.0)

                    // 缺省沿用当前状态，避免一次不带 isRunning 的更新把按键翻成"已暂停"
                    isSimulationRunning = it.getBooleanExtra("isRunning", isSimulationRunning)
                    updatePosition()
                    updateControlButtons()
                }
                "hide" -> hideWindow()
            }
        }
        // 用户改了「小窗大小/按键高度」后立即生效，不必等下次浮出。
        applyWindowSize()
        return START_STICKY
    }

    override fun onDestroy() {
        destroyWindow()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun showWindow(title: String) {
        if (rootView != null) {
            titleView?.text = title
            attachWindow()
            updatePosition()
            updateControlButtons()
            return
        }
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        val root = FrameLayout(this).apply {
            isFocusable = true
            isFocusableInTouchMode = true
            requestFocus()
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#F7F9FC"))
                cornerRadius = dp(18f)
                setStroke(maxOf(1, dp(1f).toInt()), Color.parseColor("#D0D7E2"))
            }
            setPadding(dp(12f).toInt(), dp(12f).toInt(), dp(12f).toInt(), dp(12f).toInt())
            elevation = dp(8f)
        }
        val container = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(container, FrameLayout.LayoutParams(-1, -1))
        val dragHandle = LinearLayout(this).apply {
            gravity = Gravity.CENTER
            setPadding(0, dp(4f).toInt(), 0, dp(4f).toInt())
            addView(View(this@RouteSimulationOverlayService).apply {
                background = GradientDrawable().apply {
                    setColor(Color.parseColor("#6B7280"))
                    cornerRadius = dp(2f)
                }
            }, LinearLayout.LayoutParams(dp(40f).toInt(), dp(4f).toInt()))
        }
        dragHandle.setOnTouchListener { _, event -> handleDrag(event) }
        container.addView(dragHandle, LinearLayout.LayoutParams(-1, dp(32f).toInt()))
        titleView = TextView(this).apply {
            text = title
            setTextColor(Color.parseColor("#111111"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        }
        container.addView(titleView, LinearLayout.LayoutParams(-1, -2))
        // 地图用 height=0 + weight=1f 吃掉剩余空间，标题行和按键行都是 WRAP_CONTENT，
        // 于是空间不够时被压缩的永远是地图，按键行不会被挤出固定高度的窗口。
        mapView = MapView(this).apply {
            showZoomControls(false)
            showScaleControl(false)
        }
        container.addView(mapView, LinearLayout.LayoutParams(-1, 0, 1f).apply { topMargin = dp(10f).toInt() })
        baiduMap = mapView?.map
        baiduMap?.let { map ->
            map.setMapType(BaiduMap.MAP_TYPE_NORMAL)
            map.isMyLocationEnabled = false
            // 小窗里的地图只用来看，禁掉手势免得误触把视野拖走
            map.uiSettings.setAllGesturesEnabled(false)
        }
        drawRoute()
        val controlRow = LinearLayout(this).apply {
            gravity = Gravity.CENTER
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(8f).toInt(), 0, 0)
        }
        this.controlRow = controlRow
        val buttonHeight = dp(buttonSize.toFloat()).toInt()
        pauseButton = buildButton("暂停", Color.parseColor("#1565C0")).apply {
            setOnClickListener { sendBroadcast(Intent(MainActivity.ACTION_PAUSE_SIMULATION)) }
        }
        resumeButton = buildButton("继续", Color.parseColor("#2E7D32")).apply {
            setOnClickListener { sendBroadcast(Intent(MainActivity.ACTION_RESUME_SIMULATION)) }
        }
        val margin = dp(4f).toInt()
        controlRow.addView(pauseButton, LinearLayout.LayoutParams(0, buttonHeight, 1f).apply { setMargins(0, 0, margin, 0) })
        controlRow.addView(resumeButton, LinearLayout.LayoutParams(0, buttonHeight, 1f).apply { setMargins(margin, 0, 0, 0) })
        container.addView(controlRow, LinearLayout.LayoutParams(-1, -2))
        val resizeHandle = LinearLayout(this).apply {
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#B4B4B4"))
                cornerRadii = floatArrayOf(0f, 0f, 0f, 0f, 0f, 0f, dp(18f), dp(18f))
            }
            alpha = 0.5f
        }
        resizeHandle.setOnTouchListener { _, event -> handleResize(event) }
        root.addView(resizeHandle, FrameLayout.LayoutParams(dp(56f).toInt(), dp(56f).toInt(), Gravity.BOTTOM or Gravity.END))
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE
        val displayWidth = resources.displayMetrics.widthPixels
        val width = (displayWidth * currentScale).toInt()
        val height = maxOf((width * 0.72f).toInt(), dp(180f).toInt())
        params = WindowManager.LayoutParams(width, height, type, WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN, PixelFormat.TRANSLUCENT).apply {
            gravity = Gravity.TOP or Gravity.END
            x = 20
            y = 100
        }
        windowManager?.addView(root, params)
        mapView?.onResume()
        rootView = root
        windowAttached = true
        updatePosition()
        updateControlButtons()
    }

    /**
     * 把已建好的窗口重新挂回去，反复显隐时复用同一份 View 和 MapView：
     * 只有 `parent == null` 时才 addView + onResume。
     * 若隐藏时置空 rootView，下一轮就会新建 MapView，而旧的只 onPause 没 onDestroy，纯泄漏。
     */
    private fun attachWindow() {
        val root = rootView ?: return
        if (root.parent != null) {
            try { windowManager?.updateViewLayout(root, params) } catch (_: Exception) { }
            return
        }
        try {
            windowManager?.addView(root, params)
            mapView?.onResume()
            windowAttached = true
        } catch (_: Exception) { }
    }

    private fun drawRoute() {
        val map = baiduMap ?: return
        map.clear()
        // clear() 会让已持有的 Marker 句柄失效，必须置空强制下一帧重建
        marker = null
        if (routePoints.size > 1) {
            map.addOverlay(PolylineOptions().width(8).color(0xAA1565C0.toInt()).points(routePoints))
            map.setMapStatus(
                MapStatusUpdateFactory.newMapStatus(
                    MapStatus.Builder().target(routePoints[0]).zoom(18f).build(),
                ),
            )
        }
        updatePosition()
    }

    private fun updatePosition() {
        // 窗口没挂着时只存坐标、不碰地图：MapView 已经 onPause，推帧没意义还可能出错。
        // 坐标留在 currentLatitude/Longitude 里，重新 attach 后由 showWindow 补画。
        if (!windowAttached) return
        val map = baiduMap ?: return
        if (currentLatitude == 0.0 && currentLongitude == 0.0) return
        val latLng = LatLng(currentLatitude, currentLongitude)
        if (marker == null) {
            marker = map.addOverlay(
                MarkerOptions()
                    .position(latLng)
                    .icon(com.baidu.mapapi.map.BitmapDescriptorFactory.fromResource(android.R.drawable.ic_menu_mylocation)),
            ) as? Marker
        } else {
            marker?.position = latLng
        }
        map.animateMapStatus(MapStatusUpdateFactory.newLatLng(latLng))
    }

    /**
     * 暂停 / 继续 两个按键常驻显示，只用 enabled + alpha（0.42）表达禁用态，从不调用
     * setVisibility。
     *
     * 用 GONE/VISIBLE 切换时任何一次漏刷新都会让按键永久消失，那正是
     * "按键显示一直有问题"的成因。状态仍完全由 Dart 侧回传的 isRunning 驱动：
     * 按键自己只发广播，不自改状态。
     */
    private fun updateControlButtons() {
        setControlEnabled(pauseButton, isSimulationRunning)
        setControlEnabled(resumeButton, !isSimulationRunning)
    }

    private fun setControlEnabled(button: TextView?, enabled: Boolean) {
        button ?: return
        button.isEnabled = enabled
        button.alpha = if (enabled) 1f else 0.42f
    }

    /**
     * 只把窗口从 WindowManager 摘下来，View 和 MapView 全部留给下次 attachWindow 复用。
     * 真正的销毁走 destroyWindow()，只在 onDestroy 调一次。
     */
    private fun hideWindow() {
        val view = rootView ?: return
        windowAttached = false
        if (view.parent == null) return
        try {
            mapView?.onPause()
            // 用 removeViewImmediate：延迟移除会和下一次 addView 抢同一个 View
            windowManager?.removeViewImmediate(view)
        } catch (_: Exception) { }
    }

    private fun applyWindowSize() {
        val root = rootView ?: return
        val layout = params ?: return
        val wm = windowManager ?: return
        val displayWidth = resources.displayMetrics.widthPixels
        val width = (displayWidth * currentScale).toInt()
        val height = maxOf((width * 0.72f).toInt(), dp(180f).toInt())
        layout.width = width
        layout.height = height
        layout.x = layout.x.coerceIn(0, maxOf(0, displayWidth - width))
        try {
            wm.updateViewLayout(root, layout)
        } catch (_: Exception) {
            // Window may be detached; next attach uses the new size.
        }
        val buttonHeight = dp(buttonSize.toFloat()).toInt()
        listOf(pauseButton, resumeButton).forEach { button ->
            button ?: return@forEach
            val params = button.layoutParams as? LinearLayout.LayoutParams
                ?: return@forEach
            params.height = buttonHeight
            button.layoutParams = params
        }
        root.requestLayout()
    }

    private fun destroyWindow() {
        hideWindow()
        // MapView 的 onDestroy 只能在真正销毁时调一次
        mapView?.onDestroy()
        mapView = null
        baiduMap = null
        marker = null
        rootView = null
        titleView = null
        pauseButton = null
        resumeButton = null
        controlRow = null
        params = null
    }

    private fun handleDrag(event: MotionEvent): Boolean {
        val layout = params ?: return false
        val root = rootView ?: return false
        val wm = windowManager ?: return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> { downX = event.rawX; downY = event.rawY; startX = layout.x; startY = layout.y; isDragging = false; return true }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - downX; val dy = event.rawY - downY
                if (!isDragging && (kotlin.math.abs(dx) > 15 || kotlin.math.abs(dy) > 15)) isDragging = true
                if (isDragging) { layout.x = (startX - dx.toInt()).coerceAtLeast(0); layout.y = (startY + dy.toInt()).coerceAtLeast(0); try { wm.updateViewLayout(root, layout) } catch (_: Exception) { } }
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> { val was = isDragging; isDragging = false; return was }
        }
        return false
    }

    private fun handleResize(event: MotionEvent): Boolean {
        val layout = params ?: return false
        val root = rootView ?: return false
        val wm = windowManager ?: return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> { resizeStartRawX = event.rawX; resizeStartRawY = event.rawY; resizeStartScale = currentScale; return true }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - resizeStartRawX; val dy = event.rawY - resizeStartRawY
                val dw = resources.displayMetrics.widthPixels.toFloat()
                currentScale = (resizeStartScale + ((-dx) + dy) / maxOf(1f, dw)).coerceIn(minScale, maxScale)
                val w = (dw * currentScale).toInt(); val h = maxOf((w * 0.72f).toInt(), dp(180f).toInt())
                layout.width = w; layout.height = h; layout.x = maxOf(0, minOf(layout.x, dw.toInt() - w))
                try { wm.updateViewLayout(root, layout); root.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY)); root.layout(0, 0, w, h) } catch (_: Exception) { }
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> return true
        }
        return false
    }

    private fun buildButton(label: String, bgColor: Int) = TextView(this).apply {
        text = label; gravity = Gravity.CENTER; setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f); setTextColor(Color.WHITE)
        setPadding(dp(12f).toInt(), dp(8f).toInt(), dp(12f).toInt(), dp(8f).toInt())
        background = GradientDrawable().apply { setColor(bgColor); cornerRadius = dp(8f) }
        isClickable = true; isFocusable = true
    }

    private fun notification(): Notification {
        val mgr = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            mgr.createNotificationChannel(NotificationChannel(channelId, "路线模拟悬浮窗", NotificationManager.IMPORTANCE_LOW))
            return Notification.Builder(this, channelId).setContentTitle("路线模拟运行中").setContentText("悬浮窗显示实时位置").setSmallIcon(android.R.drawable.ic_dialog_map).build()
        }
        return Notification.Builder(this).setContentTitle("路线模拟运行中").setSmallIcon(android.R.drawable.ic_dialog_map).build()
    }

    private fun dp(value: Float): Float = value * resources.displayMetrics.density
}
