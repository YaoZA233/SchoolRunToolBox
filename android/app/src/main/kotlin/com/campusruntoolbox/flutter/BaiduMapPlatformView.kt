package com.campusruntoolbox.flutter

import android.content.Context
import android.view.View
import com.baidu.mapapi.map.BaiduMap
import com.baidu.mapapi.map.MapStatusUpdateFactory
import com.baidu.mapapi.map.MapView
import com.baidu.mapapi.map.MarkerOptions
import com.baidu.mapapi.map.BitmapDescriptorFactory
import com.baidu.mapapi.map.PolylineOptions
import com.baidu.mapapi.map.Overlay
import com.baidu.mapapi.map.MapPoi
import com.baidu.mapapi.model.LatLng
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugin.common.StandardMessageCodec
import android.os.Bundle

class BaiduMapPlatformView(
    context: Context,
    messenger: BinaryMessenger,
    id: Int,
    args: Any?,
) : PlatformView {
    private val mapView = MapView(context)
    private val map = mapView.map
    private val channel = MethodChannel(messenger, "schoolrun/baidu_map_$id")
    private var routeOverlay: Overlay? = null
    private var markerOverlay: Overlay? = null

    init {
        mapView.onCreate(context, null)
        mapView.onResume()
        map.setMapType(BaiduMap.MAP_TYPE_NORMAL)
        map.uiSettings.isZoomGesturesEnabled = true
        map.uiSettings.isScrollGesturesEnabled = true
        map.setOnMapClickListener(object : BaiduMap.OnMapClickListener {
            override fun onMapClick(point: LatLng?) {
                point?.let {
                    channel.invokeMethod("mapClick", mapOf("latitude" to it.latitude, "longitude" to it.longitude))
                }
            }

            override fun onMapPoiClick(poi: MapPoi?) {
                // POI click handling - optional
            }
        })
        map.setOnMapLongClickListener(object : BaiduMap.OnMapLongClickListener {
            override fun onMapLongClick(point: LatLng?) {
                point?.let {
                    channel.invokeMethod("mapLongClick", mapOf("latitude" to it.latitude, "longitude" to it.longitude))
                }
            }
        })
        val initial = args as? Map<*, *>
        val mapType = (initial?.get("mapType") as? Number)?.toInt() ?: 1
        map.setMapType(
            if (mapType == 2) BaiduMap.MAP_TYPE_SATELLITE else BaiduMap.MAP_TYPE_NORMAL,
        )
        val latitude = (initial?.get("latitude") as? Number)?.toDouble() ?: 39.908
        val longitude = (initial?.get("longitude") as? Number)?.toDouble() ?: 116.397
        map.setMapStatus(MapStatusUpdateFactory.newLatLngZoom(LatLng(latitude, longitude), 16f))
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setRoutePoints" -> {
                    setRoutePoints(call.arguments as? List<*>)
                    result.success(true)
                }
                "setCurrentLocation" -> {
                    val value = call.arguments as? Map<*, *>
                    val lat = (value?.get("latitude") as? Number)?.toDouble()
                    val lon = (value?.get("longitude") as? Number)?.toDouble()
                    if (lat != null && lon != null) setCurrentLocation(lat, lon)
                    result.success(true)
                }
                "centerOnLocation" -> {
                    val value = call.arguments as? Map<*, *>
                    val lat = (value?.get("latitude") as? Number)?.toDouble()
                    val lon = (value?.get("longitude") as? Number)?.toDouble()
                    if (lat != null && lon != null) map.setMapStatus(MapStatusUpdateFactory.newLatLng(LatLng(lat, lon)))
                    result.success(true)
                }
                "setMapType" -> {
                    map.setMapType(if ((call.arguments as? Number)?.toInt() == 2) {
                        BaiduMap.MAP_TYPE_SATELLITE
                    } else {
                        BaiduMap.MAP_TYPE_NORMAL
                    })
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        setRoutePoints(initial?.get("routePoints") as? List<*>)
    }

    override fun getView(): View = mapView

    override fun dispose() {
        channel.setMethodCallHandler(null)
        routeOverlay?.remove()
        markerOverlay?.remove()
        mapView.onPause()
        mapView.onDestroy()
    }

    private fun setRoutePoints(raw: List<*>?) {
        routeOverlay?.remove()
        routeOverlay = null
        val points = raw.orEmpty().mapNotNull { item ->
            val value = item as? Map<*, *>
            val lat = (value?.get("latitude") as? Number)?.toDouble()
            val lon = (value?.get("longitude") as? Number)?.toDouble()
            // Flutter 传来的路线点已是 BD-09（地图取点原样回传），直接绘制，禁止再转换
            if (lat == null || lon == null) null else LatLng(lat, lon)
        }
        if (points.size >= 2) {
            // 绘制路线 - 使用醒目的蓝色
            routeOverlay = map.addOverlay(
                PolylineOptions()
                    .points(points)
                    .width(10)
                    .color(0xFF1565C0.toInt())  // 深蓝色，完全不透明
                    .dottedLine(false)
            )

            // 自动调整视野以显示整条路线
            try {
                val builder = com.baidu.mapapi.model.LatLngBounds.Builder()
                points.forEach { builder.include(it) }
                val bounds = builder.build()
                // 使用四边距的重载方法
                val padding = 100
                val update = MapStatusUpdateFactory.newLatLngBounds(bounds, padding, padding, padding, padding)
                map.animateMapStatus(update)
            } catch (e: Exception) {
                // 如果自动调整失败，至少居中到第一个点
                map.setMapStatus(MapStatusUpdateFactory.newLatLngZoom(points[0], 15f))
            }
        }
    }

    private fun setCurrentLocation(latitude: Double, longitude: Double) {
        markerOverlay?.remove()
        markerOverlay = null

        // 定位流已配置 setCoorType("bd09ll")，收到的就是 BD-09，直接绘制
        val location = LatLng(latitude, longitude)

        // 添加自定义标记点，使其更明显
        markerOverlay = map.addOverlay(
            MarkerOptions()
                .position(location)
                .icon(BitmapDescriptorFactory.fromResource(android.R.drawable.ic_menu_mylocation))
                .zIndex(10)  // 确保标记在路线之上
        )

        // 将地图中心移动到当前位置（不改变缩放级别）
        map.animateMapStatus(MapStatusUpdateFactory.newLatLng(location))
    }
}

class BaiduMapPlatformViewFactory(private val messenger: BinaryMessenger) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        BaiduMapPlatformView(context, messenger, viewId, args)
}
