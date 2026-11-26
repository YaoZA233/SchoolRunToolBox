# 坐标系约定与偏差修复

## 结论

1. Flutter / Dart 侧、本地快照、路线编辑、百度地图绘制，全程使用 **BD-09（百度坐标）**，
   绘制时直接透传、不做转换。
2. 只有向 Android 注入模拟定位、生成 NMEA 时，做一次 **BD-09 → WGS-84** 解密。
3. `wgs84ToBd09()` 只允许在「输入数据本身只有 WGS-84」的导入场景使用
   （目前唯一调用点是 `RoutePoint.fromJson`）；**不要**把它接回显示或注入链路，
   否则会叠出 1 km 级的坐标偏移。

## 为什么

坐标的唯一真实来源全部是百度 SDK，产出的本来就是 BD-09：

| 来源 | 代码位置 | 坐标系 |
| --- | --- | --- |
| 地图点击取点 `onMapClick` / `onMapLongClick` | `BaiduMapPlatformView.kt` | BD-09（`com.baidu.mapapi.model.LatLng` 原生值） |
| 定位流 | `MainActivity.startLocation()` 中 `setCoorType("bd09ll")` | BD-09 |
| POI 搜索 / 逆地理编码 | `MainActivity.searchPoi()` / `reverseGeocode()` | BD-09 |

因此 `RoutePoint`、历史记录、模拟帧里的经纬度都是 BD-09。

百度地图 `MapView` 期望的输入也是 BD-09，所以绘制路径上任何一次 `wgs84ToBd09`
都是多余的双重转换。

而 Android 的 `LocationManager.setTestProviderLocation()` 与 NMEA 语句只认 **WGS-84**，
这是整条链路上**唯一**需要转换的地方。

## 修复前的 Bug

上一版误以为 Flutter 传来的是 WGS-84，于是在所有显示环节都加了一次
`wgs84ToBd09`，同时 `MockLocationService` 不做转换。结果：

1. 路线折线画在 `BD09(P)` —— 比用户实际点击的位置偏出约 1.2 km。
2. 模拟位置经 `pushLocation` 原样注入（把 BD-09 当 WGS-84），百度定位回读后再加密成
   `BD09(P)`，显示层又转一次得到 `BD09(BD09(P))`。
3. 两者相差一个完整的 BD-09 偏移量 —— **实测 1211 ~ 1373 米**，即「位置和路线偏差很远」。
4. 目标 App 拿到的模拟 GPS 同样是偏出约 1 km 的错误位置。

偏移量实测（`wgs84ToBd09` 连续套用两次）：

| 城市 | 路线偏离点击点 | 位置标记偏离点击点 | 标记与路线间距 |
| --- | --- | --- | --- |
| 北京 (116.397, 39.908) | 1378.2 m | 2750.7 m | **1372.5 m** |
| 武汉 (114.305, 30.593) | 1206.8 m | 2417.9 m | **1211.2 m** |
| 广州 (113.264, 23.129) | 1266.8 m | 2535.7 m | **1268.9 m** |

`bd09ToWgs84()` 的往返误差为 0.18 ~ 0.97 米，远小于 GPS 本身精度，可忽略。

## 各文件职责

| 文件 / 方法 | 输入 | 输出 | 转换 |
| --- | --- | --- | --- |
| `lib/main.dart` / `lib/route_engine.dart` | BD-09 | BD-09 | 无（纯透传） |
| `BaiduMapPlatformView.kt` `setRoutePoints` / `setCurrentLocation` | BD-09 | BD-09 | **无** |
| `RouteSimulationOverlayService.kt` show / update | BD-09 | BD-09 | **无** |
| `JoystickOverlayService.kt` | BD-09 | BD-09 | 无（按米增量推进） |
| `models.dart` `RoutePoint.toJson` | BD-09 | BD-09 + WGS-84 双字段 | `bd09ToWgs84()` |
| `models.dart` `RoutePoint.fromJson` | 优先 BD-09，缺失时用 WGS-84 | BD-09 | 仅 WGS 输入时 `wgs84ToBd09()` |
| `share_api.dart` 上传路线 | BD-09 | BD-09 + WGS-84 | `bd09ToWgs84()` |
| `MockLocationService.kt` `inject()` | BD-09 | **WGS-84** | ✅ `CoordinateConverter.bd09ToWgs84()` |
| `CompleteNmea.kt` | WGS-84 | NMEA 语句 | 无 |

唯一注入转换点位于 `MockLocationService.inject()`，注入值和 `generateNmea()`
都使用转换后的 WGS-84。

## 注意

- **历史路线无需迁移**：既有 `SharedPreferences` 里保存的路线点本来就是 BD-09，
  修复后语义不变。
- `wgs84ToBd09()` 在显示/注入链路没有调用方，只服务于「仅 WGS-84 的导入数据」。
  **不要再把它接到任何显示链路上**，那会立刻重现 1 km 级偏移。
- 若将来改用高德 / 腾讯地图（GCJ-02），需要的是 BD-09 → GCJ-02（`bd09ToGcj02`），
  而不是重新引入 `wgs84ToBd09`。
- 相关回归测试见 `test/coord_test.dart`。
