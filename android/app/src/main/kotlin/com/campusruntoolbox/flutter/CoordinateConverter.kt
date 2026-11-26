package com.campusruntoolbox.flutter

/**
 * 地图坐标系转换工具类
 *
 * 中国地图坐标系统：
 * - WGS-84: GPS 原始坐标系（国际标准）
 * - GCJ-02: 火星坐标系（中国国测局加密，高德地图/腾讯地图使用）
 * - BD-09:  百度坐标系（百度地图专用）
 *
 * 转换关系：
 * WGS-84 -> GCJ-02 -> BD-09 (正向加密)
 * BD-09 -> GCJ-02 -> WGS-84 (反向解密)
 */
object CoordinateConverter {
    private const val PI = 3.14159265358979324
    private const val A = 6378245.0  // 长半轴
    private const val EE = 0.00669342162296594323  // 偏心率平方
    private const val X_PI = PI * 3000.0 / 180.0

    /**
     * WGS-84 转 BD-09（百度坐标）
     * @param wgsLng WGS-84 经度
     * @param wgsLat WGS-84 纬度
     * @return DoubleArray [BD-09经度, BD-09纬度]
     */
    fun wgs84ToBd09(wgsLng: Double, wgsLat: Double): DoubleArray {
        // 第一步：WGS-84 转 GCJ-02
        var dLat = transformLat(wgsLng - 105.0, wgsLat - 35.0)
        var dLng = transformLon(wgsLng - 105.0, wgsLat - 35.0)
        val radLat = wgsLat / 180.0 * PI
        var magic = kotlin.math.sin(radLat)
        magic = 1 - EE * magic * magic
        val sqrtMagic = kotlin.math.sqrt(magic)
        dLat = (dLat * 180.0) / ((A * (1 - EE)) / (magic * sqrtMagic) * PI)
        dLng = (dLng * 180.0) / (A / sqrtMagic * kotlin.math.cos(radLat) * PI)
        val gcjLat = wgsLat + dLat
        val gcjLng = wgsLng + dLng

        // 第二步：GCJ-02 转 BD-09
        val z = kotlin.math.sqrt(gcjLng * gcjLng + gcjLat * gcjLat) + 0.00002 * kotlin.math.sin(gcjLat * X_PI)
        val theta = kotlin.math.atan2(gcjLat, gcjLng) + 0.000003 * kotlin.math.cos(gcjLng * X_PI)
        val bdLng = z * kotlin.math.cos(theta) + 0.0065
        val bdLat = z * kotlin.math.sin(theta) + 0.006

        return doubleArrayOf(bdLng, bdLat)
    }

    /**
     * BD-09（百度坐标）转 WGS-84
     * @param bdLng BD-09 经度
     * @param bdLat BD-09 纬度
     * @return DoubleArray [WGS-84经度, WGS-84纬度]
     */
    fun bd09ToWgs84(bdLng: Double, bdLat: Double): DoubleArray {
        // 第一步：BD-09 转 GCJ-02
        val gcj = bd09ToGcj02(bdLng, bdLat)
        // 第二步：GCJ-02 转 WGS-84
        return gcj02ToWgs84(gcj[0], gcj[1])
    }

    /**
     * BD-09 转 GCJ-02
     */
    private fun bd09ToGcj02(bdLng: Double, bdLat: Double): DoubleArray {
        val x = bdLng - 0.0065
        val y = bdLat - 0.006
        val z = kotlin.math.sqrt(x * x + y * y) - 0.00002 * kotlin.math.sin(y * X_PI)
        val theta = kotlin.math.atan2(y, x) - 0.000003 * kotlin.math.cos(x * X_PI)
        val gcjLng = z * kotlin.math.cos(theta)
        val gcjLat = z * kotlin.math.sin(theta)
        return doubleArrayOf(gcjLng, gcjLat)
    }

    /**
     * GCJ-02 转 WGS-84
     */
    private fun gcj02ToWgs84(gcjLng: Double, gcjLat: Double): DoubleArray {
        var dLat = transformLat(gcjLng - 105.0, gcjLat - 35.0)
        var dLng = transformLon(gcjLng - 105.0, gcjLat - 35.0)
        val radLat = gcjLat / 180.0 * PI
        var magic = kotlin.math.sin(radLat)
        magic = 1 - EE * magic * magic
        val sqrtMagic = kotlin.math.sqrt(magic)
        dLat = (dLat * 180.0) / ((A * (1 - EE)) / (magic * sqrtMagic) * PI)
        dLng = (dLng * 180.0) / (A / sqrtMagic * kotlin.math.cos(radLat) * PI)
        val mgLat = gcjLat + dLat
        val mgLng = gcjLng + dLng
        return doubleArrayOf(gcjLng * 2 - mgLng, gcjLat * 2 - mgLat)
    }

    /**
     * 纬度转换
     */
    private fun transformLat(lng: Double, lat: Double): Double {
        var ret = -100.0 + 2.0 * lng + 3.0 * lat + 0.2 * lat * lat + 0.1 * lng * lat +
                  0.2 * kotlin.math.sqrt(kotlin.math.abs(lng))
        ret += (20.0 * kotlin.math.sin(6.0 * lng * PI) + 20.0 * kotlin.math.sin(2.0 * lng * PI)) * 2.0 / 3.0
        ret += (20.0 * kotlin.math.sin(lat * PI) + 40.0 * kotlin.math.sin(lat / 3.0 * PI)) * 2.0 / 3.0
        ret += (160.0 * kotlin.math.sin(lat / 12.0 * PI) + 320.0 * kotlin.math.sin(lat * PI / 30.0)) * 2.0 / 3.0
        return ret
    }

    /**
     * 经度转换
     */
    private fun transformLon(lng: Double, lat: Double): Double {
        var ret = 300.0 + lng + 2.0 * lat + 0.1 * lng * lng + 0.1 * lng * lat +
                  0.1 * kotlin.math.sqrt(kotlin.math.abs(lng))
        ret += (20.0 * kotlin.math.sin(6.0 * lng * PI) + 20.0 * kotlin.math.sin(2.0 * lng * PI)) * 2.0 / 3.0
        ret += (20.0 * kotlin.math.sin(lng * PI) + 40.0 * kotlin.math.sin(lng / 3.0 * PI)) * 2.0 / 3.0
        ret += (150.0 * kotlin.math.sin(lng / 12.0 * PI) + 300.0 * kotlin.math.sin(lng / 30.0 * PI)) * 2.0 / 3.0
        return ret
    }
}
