import 'dart:math' as math;

/// 中国地图坐标系转换。
///
/// 约定：
/// - 地图取点、百度定位流、路线点都是 **BD-09**；
/// - Android `LocationManager` 的 TestProvider 只接受 **WGS-84**；
/// - 共享后端要求同时上传 BD-09 与 WGS-84。
///
/// 链路为 BD-09 → GCJ-02 → WGS-84（反向同理），GCJ-02 是中间态，
/// 单独暴露是为了将来换高德/腾讯地图时复用。
const double _pi = 3.14159265358979324;
const double _a = 6378245.0;
const double _ee = 0.00669342162296594323;
const double _xPi = _pi * 3000.0 / 180.0;

class LatLng {
  const LatLng(this.longitude, this.latitude);

  final double longitude;
  final double latitude;

  @override
  String toString() =>
      'LatLng(${longitude.toStringAsFixed(6)}, ${latitude.toStringAsFixed(6)})';
}

/// BD-09 → GCJ-02 → WGS-84。
LatLng bd09ToWgs84(double longitude, double latitude) {
  final gcj = _bd09ToGcj02(longitude, latitude);
  return _gcj02ToWgs84(gcj.longitude, gcj.latitude);
}

/// WGS-84 → GCJ-02 → BD-09。
LatLng wgs84ToBd09(double longitude, double latitude) {
  final first = _wgs84ToGcj02(longitude, latitude);
  final z = math.sqrt(
        first.longitude * first.longitude + first.latitude * first.latitude,
      ) +
      0.00002 * math.sin(first.latitude * _xPi);
  final theta = math.atan2(first.latitude, first.longitude) +
      0.000003 * math.cos(first.longitude * _xPi);
  return LatLng(
    z * math.cos(theta) + 0.0065,
    z * math.sin(theta) + 0.006,
  );
}

LatLng _bd09ToGcj02(double longitude, double latitude) {
  final x = longitude - 0.0065;
  final y = latitude - 0.006;
  final z = math.sqrt(x * x + y * y) - 0.00002 * math.sin(y * _xPi);
  final theta = math.atan2(y, x) - 0.000003 * math.cos(x * _xPi);
  return LatLng(z * math.cos(theta), z * math.sin(theta));
}

LatLng _wgs84ToGcj02(double longitude, double latitude) {
  var dLat = _transformLat(longitude - 105.0, latitude - 35.0);
  var dLng = _transformLon(longitude - 105.0, latitude - 35.0);
  final radLat = latitude / 180.0 * _pi;
  var magic = math.sin(radLat);
  magic = 1 - _ee * magic * magic;
  final sqrtMagic = math.sqrt(magic);
  dLat = (dLat * 180.0) /
      ((_a * (1 - _ee)) / (magic * sqrtMagic) * _pi);
  dLng = (dLng * 180.0) /
      (_a / sqrtMagic * math.cos(radLat) * _pi);
  return LatLng(longitude + dLng, latitude + dLat);
}

LatLng _gcj02ToWgs84(double longitude, double latitude) {
  final gcj = _wgs84ToGcj02(longitude, latitude);
  return LatLng(
    longitude * 2 - gcj.longitude,
    latitude * 2 - gcj.latitude,
  );
}

double _transformLat(double x, double y) {
  var ret = -100.0 +
      2.0 * x +
      3.0 * y +
      0.2 * y * y +
      0.1 * x * y +
      0.2 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * _pi) +
          20.0 * math.sin(2.0 * x * _pi)) *
      2.0 /
      3.0;
  ret += (20.0 * math.sin(y * _pi) + 40.0 * math.sin(y / 3.0 * _pi)) *
      2.0 /
      3.0;
  ret += (160.0 * math.sin(y / 12.0 * _pi) +
          320 * math.sin(y * _pi / 30.0)) *
      2.0 /
      3.0;
  return ret;
}

double _transformLon(double x, double y) {
  var ret = 300.0 +
      x +
      2.0 * y +
      0.1 * x * x +
      0.1 * x * y +
      0.1 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * _pi) +
          20.0 * math.sin(2.0 * x * _pi)) *
      2.0 /
      3.0;
  ret += (20.0 * math.sin(x * _pi) + 40.0 * math.sin(x / 3.0 * _pi)) *
      2.0 /
      3.0;
  ret += (150.0 * math.sin(x / 12.0 * _pi) +
          300.0 * math.sin(x / 30.0 * _pi)) *
      2.0 /
      3.0;
  return ret;
}
