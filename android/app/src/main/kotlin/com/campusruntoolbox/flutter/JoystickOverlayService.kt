package com.campusruntoolbox.flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import kotlin.math.cos
import kotlin.math.sin

class JoystickOverlayService : Service() {
    private val channelId = "schoolrun_joystick"
    private val handler = Handler()
    private var windowManager: WindowManager? = null
    private var view: JoystickView? = null
    private var params: WindowManager.LayoutParams? = null
    private var latitude = 39.908
    private var longitude = 116.397
    private var altitude = 55.0
    private var direction = 0.0
    private var radius = 0.0
    private var speed = 1.2
    private var walkSpeed = 1.2
    private var runSpeed = 3.6
    private var bikeSpeed = 10.0
    private var running = false
    private var downX = 0f
    private var downY = 0f
    private var isDragging = false
    private var startX = 0
    private var startY = 0
    private var dragThreshold = 10f
    private var resizeStartRawX = 0f
    private var resizeStartRawY = 0f
    private var resizeStartScale = 0.5f
    private var currentScale = 0.5f
    private val minScale = 0.35f
    private val maxScale = 0.90f

    private val moveTask = object : Runnable {
        override fun run() {
            if (running && radius > 0) {
                val distance = speed * 1.0 * radius
                latitude += distance * sin(Math.toRadians(direction)) / 111000.0
                longitude += distance * cos(Math.toRadians(direction)) /
                    (111000.0 * cos(Math.toRadians(latitude)).coerceAtLeast(.2))
                val intent = Intent(this@JoystickOverlayService, MockLocationService::class.java).apply {
                    putExtra("latitude", latitude)
                    putExtra("longitude", longitude)
                    putExtra("altitude", altitude)
                    putExtra("speed", speed.toFloat())
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                view?.invalidate()
            }
            handler.postDelayed(this, 1000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        startForeground(31, notification())
        handler.post(moveTask)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) return START_NOT_STICKY
        intent?.let {
            latitude = it.getDoubleExtra("latitude", latitude)
            longitude = it.getDoubleExtra("longitude", longitude)
            altitude = it.getDoubleExtra("altitude", altitude)
            walkSpeed = it.getDoubleExtra("walkSpeed", walkSpeed)
            runSpeed = it.getDoubleExtra("runSpeed", runSpeed)
            bikeSpeed = it.getDoubleExtra("bikeSpeed", bikeSpeed)
        }
        show()
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        view?.let { try { windowManager?.removeView(it) } catch (_: Exception) {} }
        view = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun show() {
        if (view != null) return
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE

        val displayWidth = resources.displayMetrics.widthPixels
        val size = (displayWidth * currentScale).toInt()

        params = WindowManager.LayoutParams(size, size, type, WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN, PixelFormat.TRANSLUCENT).apply {
            gravity = Gravity.TOP or Gravity.START
            x = 24
            y = 260
        }
        view = JoystickView(this)
        view?.setOnTouchListener { _, event -> handleTouch(event) }
        windowManager?.addView(view, params)
    }

    private fun handleTouch(event: MotionEvent): Boolean {
        val current = view ?: return false
        val layout = params ?: return false
        val windowManager = windowManager ?: return false
        val currentSize = layout.width

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.rawX
                downY = event.rawY
                startX = layout.x
                startY = layout.y
                isDragging = false

                // Detect resize zone (bottom-right corner)
                if (event.x > currentSize - 40 && event.y > currentSize - 40) {
                    resizeStartRawX = event.rawX
                    resizeStartRawY = event.rawY
                    resizeStartScale = currentScale
                    return true
                }

                // Detect drag zone (top bar, excluding right edge for close button)
                if (event.y < 48 && event.x < currentSize - 60) {
                    isDragging = true
                    return true
                }

                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val deltaX = event.rawX - downX
                val deltaY = event.rawY - downY

                if (isDragging) {
                    layout.x = startX + deltaX.toInt()
                    layout.y = startY + deltaY.toInt()
                    try { windowManager.updateViewLayout(current, layout) } catch (_: Exception) { }
                    return true
                }

                // Check if we're in resize mode (started in bottom-right corner)
                if (event.x > currentSize - 40 && event.y > currentSize - 40 &&
                    kotlin.math.abs(event.rawX - resizeStartRawX) + kotlin.math.abs(event.rawY - resizeStartRawY) > dragThreshold) {
                    // 使用对角线拖动计算缩放
                    val resizeDeltaX = event.rawX - resizeStartRawX
                    val resizeDeltaY = event.rawY - resizeStartRawY
                    val displayWidth = resources.displayMetrics.widthPixels.toFloat()
                    val scaleDelta = ((resizeDeltaX) + resizeDeltaY) / maxOf(1f, displayWidth)

                    updateWindowLayoutForScale(resizeStartScale + scaleDelta, windowManager, layout, current)
                    return true
                }

                // Handle joystick control (only if not dragging or resizing)
                if (event.y < 48) {
                    // Top bar speed selection
                    val buttonWidth = (currentSize - 60) / 6f
                    speed = when {
                        event.x < buttonWidth -> walkSpeed
                        event.x < buttonWidth * 2 -> runSpeed
                        event.x < buttonWidth * 3 -> bikeSpeed
                        else -> speed
                    }
                    current.invalidate()
                    return true
                }

                // Joystick movement
                val dx = event.x - (currentSize / 2).toFloat()
                val dy = event.y - (currentSize / 2 + 40).toFloat()
                radius = (kotlin.math.sqrt((dx * dx + dy * dy).toDouble()) / (currentSize * 0.25)).coerceIn(0.0, 1.0)
                direction = Math.toDegrees(kotlin.math.atan2(-dy.toDouble(), dx.toDouble()))
                if (direction < 0) direction += 360
                running = radius > .05
                current.invalidate()
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                // Button click detection on ACTION_UP
                if (!isDragging && event.y < 48) {
                    val buttonWidth = (currentSize - 60) / 6f
                    when {
                        event.x >= buttonWidth * 3 && event.x < buttonWidth * 4 -> openDestination("map")
                        event.x >= buttonWidth * 4 && event.x < buttonWidth * 5 -> openDestination("history")
                        event.x >= currentSize - 50 -> {
                            stopSelf()
                            return true
                        }
                    }
                }

                radius = 0.0
                running = false
                isDragging = false
                current.invalidate()
                return true
            }
        }
        return true
    }

    private fun updateWindowLayoutForScale(
        scale: Float,
        windowManager: WindowManager,
        layout: WindowManager.LayoutParams,
        view: View
    ) {
        // 限制缩放范围
        currentScale = scale.coerceIn(minScale, maxScale)

        val displayWidth = resources.displayMetrics.widthPixels
        val size = (displayWidth * currentScale).toInt()

        layout.width = size
        layout.height = size

        try {
            windowManager.updateViewLayout(view, layout)
            // 强制重新测量和布局
            view.measure(
                View.MeasureSpec.makeMeasureSpec(size, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(size, View.MeasureSpec.EXACTLY)
            )
            view.layout(0, 0, size, size)
            view.invalidate()
        } catch (_: Exception) { }
    }

    private fun openDestination(destination: String) {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("overlayDestination", destination)
        }
        startActivity(intent)
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(NotificationChannel(channelId, "悬浮摇杆", NotificationManager.IMPORTANCE_LOW))
            return Notification.Builder(this, channelId).setContentTitle("悬浮摇杆运行中").setContentText("可在其他应用上方控制模拟位置").setSmallIcon(android.R.drawable.ic_media_play).build()
        }
        return Notification.Builder(this).setContentTitle("悬浮摇杆运行中").setSmallIcon(android.R.drawable.ic_media_play).build()
    }

    private inner class JoystickView(context: Context) : View(context) {
        private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
        private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }

        override fun onDraw(canvas: Canvas) {
            val w = width.toFloat()
            val h = height.toFloat()
            val centerX = w / 2
            val centerY = h / 2 + 20

            // 根据窗口大小动态调整元素尺寸
            val scaleFactor = (w / 280f).coerceIn(0.7f, 1.5f)
            val topBarHeight = 48f * scaleFactor
            val cornerRadius = 24f * scaleFactor
            val joystickRadius = 72f * scaleFactor
            val knobRadius = 22f * scaleFactor
            val textSize = 13f * scaleFactor

            text.textSize = textSize

            fill.color = Color.WHITE
            canvas.drawRoundRect(0f, 0f, w, h, cornerRadius, cornerRadius, fill)
            fill.color = Color.rgb(30, 43, 39)
            canvas.drawRoundRect(0f, 0f, w, topBarHeight, cornerRadius, cornerRadius, fill)
            text.color = Color.WHITE
            canvas.drawText("步  跑  骑  地图  历史  X", centerX, topBarHeight * 0.625f, text)

            // Draw joystick background
            fill.color = Color.rgb(224, 238, 232)
            canvas.drawCircle(centerX, centerY, joystickRadius, fill)

            // Draw joystick knob
            fill.color = Color.rgb(57, 120, 107)
            val knobX = centerX + (cos(Math.toRadians(direction)) * radius * joystickRadius * 0.67).toFloat()
            val knobY = centerY - (sin(Math.toRadians(direction)) * radius * joystickRadius * 0.67).toFloat()
            canvas.drawCircle(knobX, knobY, knobRadius, fill)

            // Draw speed indicator
            text.color = Color.rgb(30, 43, 39)
            canvas.drawText("%.1f m/s".format(speed), centerX, h - (25f * scaleFactor), text)

            // Draw resize indicator (bottom-right corner)
            fill.color = Color.rgb(57, 120, 107)
            val resizeSize = 30f * scaleFactor
            val path = Path().apply {
                moveTo(w - resizeSize, h - 5)
                lineTo(w - 5, h - 5)
                lineTo(w - 5, h - resizeSize)
                close()
            }
            canvas.drawPath(path, fill)
        }
    }
}
