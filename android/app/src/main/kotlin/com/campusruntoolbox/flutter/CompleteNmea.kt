package com.campusruntoolbox.flutter

import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

/**
 * 完整 NMEA 语句生成器。
 *
 * 一次生成 RMC + GGA + GSV + GSA + VTG，而不是只有 GGA/RMC 两句。
 * 校园跑类 App 会解析 `Location.getExtras().getString("nmea")`
 * （或 `getString("NMEA")`）里的卫星数、HDOP、定位质量等字段，语句缺失会被判定为
 * “信号异常 / 非真实定位”，所以这里必须输出完整的字段与精度。
 *
 * 约定：传入的经纬度是 **WGS-84**（系统 Location 只接受 WGS-84）。BD-09 → WGS-84 的
 * 转换由 [MockLocationService] 在注入前完成。
 */
class CompleteNmea private constructor() {
    companion object {
        const val SIGNAL_QUALITY_WEAK = 0
        const val SIGNAL_QUALITY_MEDIUM = 1
        const val SIGNAL_QUALITY_STRONG = 2

        const val MIN_SATELLITE_COUNT = 1
        const val MAX_SATELLITE_COUNT = 12
        const val DEFAULT_HDOP = 1.5f

        private const val METERS_PER_SECOND_TO_KNOTS = 1.9438444924406
        private const val METERS_PER_SECOND_TO_KILOMETERS_PER_HOUR = 3.6
        private const val MAX_SATELLITES_PER_GSV_SENTENCE = 4
        private val UTC: TimeZone = TimeZone.getTimeZone("UTC")

        @JvmStatic
        fun generate(
            latitude: Double,
            longitude: Double,
            altitudeMeters: Double,
            speedMetersPerSecond: Float,
            bearingDegrees: Float,
            satelliteCount: Int,
            signalQuality: Int,
            hdop: Float,
            timeMillis: Long = System.currentTimeMillis(),
        ): String {
            val normalizedSatellites = normalizeSatelliteCount(satelliteCount)
            val normalizedSignalQuality = normalizeSignalQuality(signalQuality)
            val normalizedHdop = normalizeHdop(hdop)
            val sentences = ArrayList<String>(8)
            sentences.add(
                gprmc(
                    latitude,
                    longitude,
                    speedMetersPerSecond,
                    bearingDegrees,
                    timeMillis,
                ),
            )
            sentences.add(
                gpgga(
                    latitude,
                    longitude,
                    altitudeMeters,
                    timeMillis,
                    normalizedSatellites,
                    normalizedHdop,
                ),
            )
            sentences.addAll(gsv(normalizedSatellites, normalizedSignalQuality))
            sentences.add(gsa(normalizedSatellites, normalizedHdop))
            sentences.add(vtg(speedMetersPerSecond, bearingDegrees))
            return sentences.joinToString("\r\n")
        }

        fun normalizeSatelliteCount(satelliteCount: Int): Int =
            satelliteCount.coerceIn(MIN_SATELLITE_COUNT, MAX_SATELLITE_COUNT)

        fun normalizeSignalQuality(signalQuality: Int): Int =
            signalQuality.coerceIn(SIGNAL_QUALITY_WEAK, SIGNAL_QUALITY_STRONG)

        fun normalizeHdop(hdop: Float): Float {
            if (hdop.isNaN() || hdop.isInfinite()) return DEFAULT_HDOP
            return hdop.coerceIn(0.5f, 99.9f)
        }

        private fun gprmc(
            latitude: Double,
            longitude: Double,
            speedMetersPerSecond: Float,
            bearingDegrees: Float,
            timeMillis: Long,
        ): String {
            val body = String.format(
                Locale.US,
                "GPRMC,%s,A,%s,%s,%s,%s,%.1f,%.1f,%s,,,A",
                formatUtcTime(timeMillis),
                formatLatitude(latitude),
                latitudeHemisphere(latitude),
                formatLongitude(longitude),
                longitudeHemisphere(longitude),
                (kotlin.math.max(0f, speedMetersPerSecond) * METERS_PER_SECOND_TO_KNOTS),
                normalizeBearing(bearingDegrees),
                formatUtcDate(timeMillis),
            )
            return withChecksum(body)
        }

        private fun gpgga(
            latitude: Double,
            longitude: Double,
            altitudeMeters: Double,
            timeMillis: Long,
            satelliteCount: Int,
            hdop: Float,
        ): String {
            val body = String.format(
                Locale.US,
                "GPGGA,%s,%s,%s,%s,%s,1,%02d,%.1f,%.1f,M,0.0,M,,",
                formatUtcTime(timeMillis),
                formatLatitude(latitude),
                latitudeHemisphere(latitude),
                formatLongitude(longitude),
                longitudeHemisphere(longitude),
                satelliteCount,
                hdop,
                altitudeMeters,
            )
            return withChecksum(body)
        }

        private fun gsv(satelliteCount: Int, signalQuality: Int): List<String> {
            val sentenceCount =
                (satelliteCount + MAX_SATELLITES_PER_GSV_SENTENCE - 1) / MAX_SATELLITES_PER_GSV_SENTENCE
            val sentences = ArrayList<String>(sentenceCount)
            for (sentenceNumber in 1..sentenceCount) {
                val body = StringBuilder("GPGSV,")
                    .append(sentenceCount)
                    .append(',')
                    .append(sentenceNumber)
                    .append(',')
                    .append(String.format(Locale.US, "%02d", satelliteCount))
                val sentenceOffset = (sentenceNumber - 1) * MAX_SATELLITES_PER_GSV_SENTENCE
                val satellitesInSentence = kotlin.math.min(
                    MAX_SATELLITES_PER_GSV_SENTENCE,
                    satelliteCount - sentenceOffset,
                )
                for (index in 0 until satellitesInSentence) {
                    val satelliteId = sentenceOffset + index + 1
                    body.append(
                        String.format(
                            Locale.US,
                            ",%02d,%02d,%03d,%02d",
                            satelliteId,
                            elevation(satelliteId),
                            azimuth(satelliteId),
                            snr(satelliteId, signalQuality),
                        ),
                    )
                }
                sentences.add(withChecksum(body.toString()))
            }
            return sentences
        }

        private fun gsa(satelliteCount: Int, hdop: Float): String {
            val body = StringBuilder("GPGSA,A,3,")
            for (satelliteId in 1..MAX_SATELLITE_COUNT) {
                if (satelliteId <= satelliteCount) {
                    body.append(String.format(Locale.US, "%02d", satelliteId))
                }
                body.append(',')
            }
            val pdop = hdop * 1.2
            val vdop = kotlin.math.sqrt(kotlin.math.max(0.0, pdop * pdop - hdop * hdop))
            body.append(String.format(Locale.US, "%.1f,%.1f,%.1f", pdop, hdop, vdop))
            return withChecksum(body.toString())
        }

        private fun vtg(speedMetersPerSecond: Float, bearingDegrees: Float): String {
            val normalizedSpeed = kotlin.math.max(0f, speedMetersPerSecond)
            val body = String.format(
                Locale.US,
                "GPVTG,%.1f,T,,M,%.1f,N,%.1f,K",
                normalizeBearing(bearingDegrees),
                normalizedSpeed * METERS_PER_SECOND_TO_KNOTS,
                normalizedSpeed * METERS_PER_SECOND_TO_KILOMETERS_PER_HOUR,
            )
            return withChecksum(body)
        }

        private fun elevation(satelliteId: Int): Int = 10 + (satelliteId * 7) % 80

        private fun azimuth(satelliteId: Int): Int = (satelliteId * 30) % 360

        private fun snr(satelliteId: Int, signalQuality: Int): Int = when (signalQuality) {
            SIGNAL_QUALITY_WEAK -> 25 + (satelliteId * 3) % 10
            SIGNAL_QUALITY_MEDIUM -> 35 + (satelliteId * 3) % 10
            SIGNAL_QUALITY_STRONG -> 45 + (satelliteId * 3) % 10
            else -> 40
        }

        private fun formatUtcTime(timeMillis: Long): String {
            val calendar = Calendar.getInstance(UTC, Locale.US)
            calendar.timeInMillis = timeMillis
            return String.format(
                Locale.US,
                "%02d%02d%02d.00",
                calendar.get(Calendar.HOUR_OF_DAY),
                calendar.get(Calendar.MINUTE),
                calendar.get(Calendar.SECOND),
            )
        }

        private fun formatUtcDate(timeMillis: Long): String {
            val calendar = Calendar.getInstance(UTC, Locale.US)
            calendar.timeInMillis = timeMillis
            return String.format(
                Locale.US,
                "%02d%02d%02d",
                calendar.get(Calendar.DAY_OF_MONTH),
                calendar.get(Calendar.MONTH) + 1,
                calendar.get(Calendar.YEAR) % 100,
            )
        }

        private fun formatLatitude(latitude: Double): String {
            val absolute = kotlin.math.abs(latitude)
            val degrees = absolute.toInt()
            val minutes = (absolute - degrees) * 60.0
            return String.format(Locale.US, "%02d%07.4f", degrees, minutes)
        }

        private fun formatLongitude(longitude: Double): String {
            val absolute = kotlin.math.abs(longitude)
            val degrees = absolute.toInt()
            val minutes = (absolute - degrees) * 60.0
            return String.format(Locale.US, "%03d%07.4f", degrees, minutes)
        }

        private fun latitudeHemisphere(latitude: Double): String = if (latitude >= 0) "N" else "S"

        private fun longitudeHemisphere(longitude: Double): String = if (longitude >= 0) "E" else "W"

        private fun normalizeBearing(bearingDegrees: Float): Double {
            var normalized = bearingDegrees % 360.0
            if (normalized < 0) normalized += 360.0
            return normalized.toDouble()
        }

        private fun withChecksum(body: String): String {
            var checksum = 0
            body.forEach { checksum = checksum xor it.code }
            return "\$$body*${String.format(Locale.US, "%02X", checksum)}"
        }
    }
}
