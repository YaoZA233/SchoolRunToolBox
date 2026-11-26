import 'dart:convert';

import 'coord.dart';

class RoutePoint {
  const RoutePoint({
    required this.longitude,
    required this.latitude,
    this.altitude = 55,
  });

  /// 百度 BD-09 经度（地图取点、定位流、路线点统一使用该坐标系）。
  final double longitude;
  final double latitude;
  final double altitude;

  /// WGS-84 经度（注入系统定位、上传共享后端时使用）。
  double get wgsLongitude => bd09ToWgs84(longitude, latitude).longitude;

  double get wgsLatitude => bd09ToWgs84(longitude, latitude).latitude;

  Map<String, dynamic> toJson() {
    final wgs = bd09ToWgs84(longitude, latitude);
    return {
      // 本地快照沿用旧字段，保证升级后老数据仍能读回。
      'longitude': longitude,
      'latitude': latitude,
      'altitude': altitude,
      // 同时保留 BD/WGS 两套字段，导出的 JSON 可被任何一端直接读回。
      'bdLongitude': longitude,
      'bdLatitude': latitude,
      'wgsLongitude': wgs.longitude,
      'wgsLatitude': wgs.latitude,
    };
  }

  factory RoutePoint.fromJson(Map<String, dynamic> json) {
    final bdLongitude = _numberOrNull(json, const [
      'bdLongitude',
      'bdLng',
      'longitude',
      'lng',
    ]);
    final bdLatitude = _numberOrNull(json, const [
      'bdLatitude',
      'bdLat',
      'latitude',
      'lat',
    ]);
    final altitude = (json['altitude'] as num?)?.toDouble() ?? 55;
    if (bdLongitude != null && bdLatitude != null) {
      return RoutePoint(
        longitude: bdLongitude,
        latitude: bdLatitude,
        altitude: altitude,
      );
    }
    // 只有 WGS-84 时（导入的文件、共享后端响应）反算 BD-09。
    final wgsLongitude = _numberOrNull(json, const [
      'wgsLongitude',
      'wgsLng',
      'gpsLongitude',
    ]);
    final wgsLatitude = _numberOrNull(json, const [
      'wgsLatitude',
      'wgsLat',
      'gpsLatitude',
    ]);
    if (wgsLongitude != null && wgsLatitude != null) {
      final bd = wgs84ToBd09(wgsLongitude, wgsLatitude);
      return RoutePoint(
        longitude: bd.longitude,
        latitude: bd.latitude,
        altitude: altitude,
      );
    }
    return RoutePoint(
      longitude: bdLongitude ?? wgsLongitude ?? 0,
      latitude: bdLatitude ?? wgsLatitude ?? 0,
      altitude: altitude,
    );
  }

  RoutePoint lerp(RoutePoint other, double t) => RoutePoint(
        longitude: longitude + (other.longitude - longitude) * t,
        latitude: latitude + (other.latitude - latitude) * t,
        altitude: altitude + (other.altitude - altitude) * t,
      );
}

double? _numberOrNull(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is num) return value.toDouble();
  }
  return null;
}

class RouteDefinition {
  const RouteDefinition({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.points,
    this.shared = false,
    this.privacyMode = false,
    this.downloadedFromShared = false,
    this.shareId = '',
    this.sharedAt,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<RoutePoint> points;
  final bool shared;
  final bool privacyMode;
  final bool downloadedFromShared;

  /// 后端共享记录 id（本地路线为空）。重新上传 / 定位共享路线时使用。
  final String shareId;
  final DateTime? sharedAt;

  bool get hasEnoughPoints => points.length >= 2;

  RouteDefinition copyWith({
    String? name,
    DateTime? updatedAt,
    List<RoutePoint>? points,
    bool? shared,
    bool? privacyMode,
    bool? downloadedFromShared,
    String? shareId,
    DateTime? sharedAt,
  }) =>
      RouteDefinition(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        points: List.unmodifiable(points ?? this.points),
        shared: shared ?? this.shared,
        privacyMode: privacyMode ?? this.privacyMode,
        downloadedFromShared: downloadedFromShared ?? this.downloadedFromShared,
        shareId: shareId ?? this.shareId,
        sharedAt: sharedAt ?? this.sharedAt,
      );

  Map<String, dynamic> toJson() => {
        'version': 1,
        'id': id,
        'name': name,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'points': points.map((point) => point.toJson()).toList(),
        'shared': shared,
        'privacyMode': privacyMode,
        'downloadedFromShared': downloadedFromShared,
        // 共享状态放在 share 子对象里，导出时一并写入，
        // 导入后不会丢掉“隐私 / 来自共享”的标记。
        'share': {
          'shareId': shareId,
          'shared': shared,
          'privacyMode': privacyMode,
          'downloadedFromShared': downloadedFromShared,
          'sharedAt': sharedAt?.millisecondsSinceEpoch ?? 0,
        },
      };

  factory RouteDefinition.fromJson(Map<String, dynamic> json) {
    final rawPoints = json['points'] as List<dynamic>? ?? const [];
    final share = json['share'] as Map<dynamic, dynamic>?;
    return RouteDefinition(
      id: json['id'] as String? ??
          share?['shareId'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name'] as String? ?? '未命名路线',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['updatedAt'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      ),
      points: rawPoints
          .whereType<Map<String, dynamic>>()
          .map(RoutePoint.fromJson)
          .toList(growable: false),
      shared: json['shared'] as bool? ?? share?['shared'] as bool? ?? false,
      privacyMode: json['privacyMode'] as bool? ??
          share?['privacyMode'] as bool? ??
          false,
      downloadedFromShared: json['downloadedFromShared'] as bool? ??
          share?['downloadedFromShared'] as bool? ??
          false,
      shareId: json['shareId'] as String? ?? share?['shareId'] as String? ?? '',
      sharedAt: _optionalDate(json['sharedAt'] ?? share?['sharedAt']),
    );
  }
}

enum SimulationMode { speed, cadence }

/// 模拟参数。
///
/// 默认值：速度 15m/s、循环 100 圈、每米 1 步、
/// HDOP 1.5、网络定位辅助默认开启、节拍 1000ms。
class SimulationConfig {
  const SimulationConfig({
    this.mode = SimulationMode.speed,
    this.speed = 15,
    this.cadence = 120,
    this.loops = 100,
    this.dynamicIntensity = true,
    this.intensityRange = 2,
    this.intensityFrequency = .35,
    this.naturalPath = false,
    this.pathAmplitude = 1,
    this.naturalAltitude = false,
    this.altitudeBase = 55,
    this.altitudeRange = .6,
    this.altitudeHeight = 170,
    this.altitudeProbability = .35,
    this.linkRatio = 1,
    this.tickMillis = 1000,
    this.updateIntervalMs = 200,
    this.networkSimulation = true,
    this.satelliteCount = 8,
    this.signalQuality = 2,
    this.hdop = 1.5,
    this.realStepLink = false,
    this.stepsPerMeter = 1,
    this.floatingWindow = true,
    this.floatingWindowScale = .58,
    this.floatingWindowButtonSize = 44,
  });

  final SimulationMode mode;
  final double speed;
  final double cadence;
  final int loops;
  final bool dynamicIntensity;
  final double intensityRange;
  final double intensityFrequency;
  final bool naturalPath;
  final double pathAmplitude;
  final bool naturalAltitude;
  final double altitudeBase;
  final double altitudeRange;
  final double altitudeHeight;
  final double altitudeProbability;
  final double linkRatio;

  /// 引擎推进的节拍（毫秒），默认 1000ms：每帧推进 速度(m/s) × 1s。
  final int tickMillis;

  /// 向系统定位注入的间隔（毫秒），由原生模拟定位服务消费。
  final int updateIntervalMs;
  final bool networkSimulation;
  final int satelliteCount;

  /// 0=弱 1=中 2=强，决定 NMEA GSV 语句中的信噪比档位。
  final int signalQuality;
  final double hdop;
  final bool realStepLink;
  final double stepsPerMeter;

  /// 离开本应用时是否自动显示路线悬浮小窗。
  final bool floatingWindow;
  final double floatingWindowScale;
  final int floatingWindowButtonSize;

  SimulationConfig copyWith({
    SimulationMode? mode,
    double? speed,
    double? cadence,
    int? loops,
    bool? dynamicIntensity,
    double? intensityRange,
    double? intensityFrequency,
    bool? naturalPath,
    double? pathAmplitude,
    bool? naturalAltitude,
    double? altitudeBase,
    double? altitudeRange,
    double? altitudeHeight,
    double? altitudeProbability,
    double? linkRatio,
    int? tickMillis,
    int? updateIntervalMs,
    bool? networkSimulation,
    int? satelliteCount,
    int? signalQuality,
    double? hdop,
    bool? realStepLink,
    double? stepsPerMeter,
    bool? floatingWindow,
    double? floatingWindowScale,
    int? floatingWindowButtonSize,
  }) =>
      SimulationConfig(
        mode: mode ?? this.mode,
        speed: speed ?? this.speed,
        cadence: cadence ?? this.cadence,
        loops: loops ?? this.loops,
        dynamicIntensity: dynamicIntensity ?? this.dynamicIntensity,
        intensityRange: intensityRange ?? this.intensityRange,
        intensityFrequency: intensityFrequency ?? this.intensityFrequency,
        naturalPath: naturalPath ?? this.naturalPath,
        pathAmplitude: pathAmplitude ?? this.pathAmplitude,
        naturalAltitude: naturalAltitude ?? this.naturalAltitude,
        altitudeBase: altitudeBase ?? this.altitudeBase,
        altitudeRange: altitudeRange ?? this.altitudeRange,
        altitudeHeight: altitudeHeight ?? this.altitudeHeight,
        altitudeProbability: altitudeProbability ?? this.altitudeProbability,
        linkRatio: linkRatio ?? this.linkRatio,
        tickMillis: tickMillis ?? this.tickMillis,
        updateIntervalMs: updateIntervalMs ?? this.updateIntervalMs,
        networkSimulation: networkSimulation ?? this.networkSimulation,
        satelliteCount: satelliteCount ?? this.satelliteCount,
        signalQuality: signalQuality ?? this.signalQuality,
        hdop: hdop ?? this.hdop,
        realStepLink: realStepLink ?? this.realStepLink,
        stepsPerMeter: stepsPerMeter ?? this.stepsPerMeter,
        floatingWindow: floatingWindow ?? this.floatingWindow,
        floatingWindowScale: floatingWindowScale ?? this.floatingWindowScale,
        floatingWindowButtonSize:
            floatingWindowButtonSize ?? this.floatingWindowButtonSize,
      );

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'speed': speed,
        'cadence': cadence,
        'loops': loops,
        'dynamicIntensity': dynamicIntensity,
        'intensityRange': intensityRange,
        'intensityFrequency': intensityFrequency,
        'naturalPath': naturalPath,
        'pathAmplitude': pathAmplitude,
        'naturalAltitude': naturalAltitude,
        'altitudeBase': altitudeBase,
        'altitudeRange': altitudeRange,
        'altitudeHeight': altitudeHeight,
        'altitudeProbability': altitudeProbability,
        'linkRatio': linkRatio,
        'tickMillis': tickMillis,
        'updateIntervalMs': updateIntervalMs,
        'networkSimulation': networkSimulation,
        'satelliteCount': satelliteCount,
        'signalQuality': signalQuality,
        'hdop': hdop,
        'realStepLink': realStepLink,
        'stepsPerMeter': stepsPerMeter,
        'floatingWindow': floatingWindow,
        'floatingWindowScale': floatingWindowScale,
        'floatingWindowButtonSize': floatingWindowButtonSize,
      };

  factory SimulationConfig.fromJson(Map<String, dynamic> json) =>
      SimulationConfig(
        mode: json['mode'] == 'cadence'
            ? SimulationMode.cadence
            : SimulationMode.speed,
        speed: (json['speed'] as num?)?.toDouble() ?? 15,
        cadence: (json['cadence'] as num?)?.toDouble() ?? 120,
        loops: (json['loops'] as num?)?.toInt() ?? 100,
        dynamicIntensity: json['dynamicIntensity'] as bool? ?? true,
        intensityRange: (json['intensityRange'] as num?)?.toDouble() ?? 2,
        intensityFrequency:
            (json['intensityFrequency'] as num?)?.toDouble() ?? .35,
        naturalPath: json['naturalPath'] as bool? ?? false,
        pathAmplitude: (json['pathAmplitude'] as num?)?.toDouble() ?? 1,
        naturalAltitude: json['naturalAltitude'] as bool? ?? false,
        altitudeBase: (json['altitudeBase'] as num?)?.toDouble() ?? 55,
        altitudeRange: (json['altitudeRange'] as num?)?.toDouble() ?? .6,
        altitudeHeight: (json['altitudeHeight'] as num?)?.toDouble() ?? 170,
        altitudeProbability:
            (json['altitudeProbability'] as num?)?.toDouble() ?? .35,
        linkRatio: (json['linkRatio'] as num?)?.toDouble() ?? 1,
        // 旧版本快照默认 200ms 节拍，升级后按 1000ms 推进。
        tickMillis: (json['tickMillis'] as num?)?.toInt() ?? 1000,
        updateIntervalMs: (json['updateIntervalMs'] as num?)?.toInt() ?? 200,
        networkSimulation: json['networkSimulation'] as bool? ?? true,
        satelliteCount: (json['satelliteCount'] as num?)?.toInt() ?? 8,
        signalQuality: (json['signalQuality'] as num?)?.toInt() ?? 2,
        hdop: (json['hdop'] as num?)?.toDouble() ?? 1.5,
        realStepLink: json['realStepLink'] as bool? ?? false,
        stepsPerMeter: (json['stepsPerMeter'] as num?)?.toDouble() ?? 1,
        floatingWindow: json['floatingWindow'] as bool? ?? true,
        floatingWindowScale:
            (json['floatingWindowScale'] as num?)?.toDouble() ?? .58,
        floatingWindowButtonSize:
            (json['floatingWindowButtonSize'] as num?)?.toInt() ?? 44,
      );
}

class NfcConfig {
  const NfcConfig({
    required this.name,
    required this.url,
    required this.packageName,
    this.source = 'manual',
  });

  final String name;
  final String url;
  final String packageName;
  final String source;

  bool get isComplete =>
      name.trim().isNotEmpty &&
      url.trim().isNotEmpty &&
      packageName.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'packageName': packageName,
        'source': source,
      };

  factory NfcConfig.fromJson(Map<String, dynamic> json) => NfcConfig(
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
        packageName: json['packageName'] as String? ?? '',
        source: json['source'] as String? ?? 'manual',
      );
}

class SharedSimulationConfig {
  const SharedSimulationConfig({
    required this.id,
    required this.name,
    required this.config,
    this.author = '',
    this.createdAt,
  });

  final String id;
  final String name;
  final SimulationConfig config;
  final String author;
  final DateTime? createdAt;

  factory SharedSimulationConfig.fromJson(Map<String, dynamic> json) {
    return SharedSimulationConfig(
      id: '${json['id'] ?? json['configId'] ?? ''}',
      name: json['name'] as String? ?? '共享模拟配置',
      author:
          json['authorUsername'] as String? ?? json['author'] as String? ?? '',
      createdAt: _optionalDate(json['createdAt']),
      config: SimulationConfig.fromJson({
        ...json,
        ...((json['config'] as Map?)?.cast<String, dynamic>() ?? const {}),
        'loops': json['loopCount'] ?? json['loops'],
        'dynamicIntensity':
            json['dynamicIntensityEnabled'] ?? json['dynamicIntensity'],
        'intensityRange':
            json['intensityVariationRange'] ?? json['intensityRange'],
        'intensityFrequency':
            json['intensityVariationFrequency'] ?? json['intensityFrequency'],
        'naturalPath':
            json['naturalPathVariationEnabled'] ?? json['naturalPath'],
        'pathAmplitude':
            json['pathVariationAmplitude'] ?? json['pathAmplitude'],
        'naturalAltitude':
            json['naturalAltitudeVariationEnabled'] ?? json['naturalAltitude'],
        'altitudeBase': json['altitudeBaseMeters'] ?? json['altitudeBase'],
        'altitudeRange':
            json['altitudeVariationRange'] ?? json['altitudeRange'],
        'altitudeHeight': json['altitudeVariationHeightCentimeters'] ??
            json['altitudeHeight'],
        'altitudeProbability':
            json['altitudeVariationProbability'] ?? json['altitudeProbability'],
        'linkRatio': json['linkRatioNumerator'] ?? json['linkRatio'],
      }),
    );
  }
}

class UsageTipSummary {
  const UsageTipSummary({
    required this.id,
    required this.title,
    this.excerpt = '',
    this.author = '',
    this.published = false,
    this.editable = false,
  });

  final String id;
  final String title;
  final String excerpt;
  final String author;
  final bool published;
  final bool editable;

  factory UsageTipSummary.fromJson(Map<String, dynamic> json) =>
      UsageTipSummary(
        id: '${json['id'] ?? ''}',
        title: json['title'] as String? ?? '',
        excerpt:
            json['excerpt'] as String? ?? json['plainText'] as String? ?? '',
        author: json['authorUsername'] as String? ?? '',
        published:
            json['isPublished'] as bool? ?? json['published'] as bool? ?? false,
        editable: json['editable'] as bool? ?? false,
      );
}

class UsageTipDetail extends UsageTipSummary {
  const UsageTipDetail({
    required super.id,
    required super.title,
    super.excerpt,
    super.author,
    super.published,
    super.editable,
    this.htmlContent = '',
    this.contributorQq = '',
  });

  final String htmlContent;
  final String contributorQq;

  factory UsageTipDetail.fromJson(Map<String, dynamic> json) => UsageTipDetail(
        id: '${json['id'] ?? ''}',
        title: json['title'] as String? ?? '',
        excerpt:
            json['plainText'] as String? ?? json['excerpt'] as String? ?? '',
        author: json['authorUsername'] as String? ?? '',
        published: json['isPublished'] as bool? ?? false,
        editable: json['editable'] as bool? ?? false,
        htmlContent: json['htmlContent'] as String? ?? '',
        contributorQq: json['contributorQq'] as String? ?? '',
      );
}

DateTime? _optionalDate(Object? value) {
  if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  if (value is String) return DateTime.tryParse(value);
  return null;
}

class HistoryEntry {
  const HistoryEntry({
    required this.title,
    required this.detail,
    required this.createdAt,
    this.kind = 'route',
    this.latitude,
    this.longitude,
  });

  final String title;
  final String detail;
  final DateTime createdAt;
  final String kind;
  final double? latitude;
  final double? longitude;

  HistoryEntry copyWith({String? title}) => HistoryEntry(
        title: title ?? this.title,
        detail: detail,
        createdAt: createdAt,
        kind: kind,
        latitude: latitude,
        longitude: longitude,
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'detail': detail,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'kind': kind,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        title: json['title'] as String? ?? '',
        detail: json['detail'] as String? ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (json['createdAt'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
        ),
        kind: json['kind'] as String? ?? 'route',
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
      );
}

String encodeJson(Object? value) => jsonEncode(value);

/// 共享路线列表项。列表接口只返回摘要，下载时要再取一次详情拿 points。
class SharedRouteSummary {
  const SharedRouteSummary({
    required this.id,
    required this.name,
    required this.privacyMode,
    required this.pointCount,
    required this.createdAt,
  });

  final String id;
  final String name;
  final bool privacyMode;
  final int pointCount;
  final DateTime createdAt;

  factory SharedRouteSummary.fromJson(Map<String, dynamic> json) =>
      SharedRouteSummary(
        id: '${json['id'] ?? ''}',
        name: json['name'] as String? ?? '共享路线',
        privacyMode: json['privacyMode'] as bool? ?? false,
        pointCount: (json['pointCount'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (json['createdAt'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
        ),
      );
}

/// 后端公告 / 联系方式（`GET /api/client-config`）。
class AppClientConfig {
  const AppClientConfig({
    this.noticeTitle = '',
    this.noticeMessage = '',
    this.qqGroupNumber = '',
    this.bilibiliText = '',
    this.bilibiliUrl = '',
  });

  final String noticeTitle;
  final String noticeMessage;
  final String qqGroupNumber;
  final String bilibiliText;
  final String bilibiliUrl;

  bool get hasNotice =>
      noticeTitle.trim().isNotEmpty || noticeMessage.trim().isNotEmpty;

  factory AppClientConfig.fromJson(Map<String, dynamic> json) =>
      AppClientConfig(
        noticeTitle: json['noticeTitle'] as String? ?? '',
        noticeMessage: json['noticeMessage'] as String? ?? '',
        qqGroupNumber: json['qqGroupNumber'] as String? ?? '',
        bilibiliText: json['bilibiliText'] as String? ?? '',
        bilibiliUrl: json['bilibiliUrl'] as String? ?? '',
      );
}

/// 内部测试账号资料。
class InternalAccountProfile {
  const InternalAccountProfile({
    this.id = '',
    this.username = '',
    this.remark = '',
    this.testerType = '',
    this.testerTypeLabel = '',
    this.status = '',
  });

  final String id;
  final String username;
  final String remark;
  final String testerType;
  final String testerTypeLabel;
  final String status;

  bool get isActive => status.toLowerCase() == 'active';

  String get displayLabel =>
      testerTypeLabel.trim().isEmpty ? '未分类账号' : testerTypeLabel;

  factory InternalAccountProfile.fromJson(Map<String, dynamic> json) {
    final type = (json['testerType'] as String? ?? '').trim().toLowerCase();
    return InternalAccountProfile(
      id: '${json['id'] ?? ''}',
      username: json['username'] as String? ?? '',
      remark: json['remark'] as String? ?? '',
      testerType: type,
      testerTypeLabel: json['testerTypeLabel'] as String? ?? '',
      status: json['status'] as String? ?? '',
    );
  }
}
