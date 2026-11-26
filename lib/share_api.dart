import 'dart:convert';
import 'dart:io';

import 'coord.dart';
import 'models.dart';

/// 共享后端客户端。
///
/// 端点与字段约定：
/// - 列表接口包装成 `{items:[...]}`；
/// - 详情接口包装成 `{data:{...}}`；
/// - 路线点必须同时提交 BD-09 与 WGS-84；
/// - `/api/auth/me` 直接返回 `{authenticated, account}`。
class ShareApi {
  ShareApi(String baseUrl, {this.token = ''})
      : baseUrl = baseUrl.trim().endsWith('/')
            ? baseUrl.trim()
            : '${baseUrl.trim()}/';

  final String baseUrl;
  final String token;

  static const _clientVariant = 'schoolrun_toolbox';

  Future<Map<String, dynamic>> login(
    String username,
    String password, {
    required String deviceId,
    required String deviceName,
  }) async {
    return _request(
      'api/auth/login',
      method: 'POST',
      body: {
        'username': username,
        'password': password,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'appVariant': _clientVariant,
      },
      withToken: false,
    );
  }

  Future<InternalAccountProfile> accountProfile() async {
    final value = await _request('api/auth/me');
    final account = value['account'];
    if (account is Map) {
      return InternalAccountProfile.fromJson(
        account.cast<String, dynamic>(),
      );
    }
    return InternalAccountProfile.fromJson(value);
  }

  Future<AppClientConfig> clientConfig() async {
    final value = _objectValueAllowingData(await _request('api/client-config'));
    return AppClientConfig.fromJson(value);
  }

  Future<List<SharedRouteSummary>> sharedRouteSummaries() async {
    final value = await _request('api/shared/routes');
    return _listValue(value)
        .whereType<Map<String, dynamic>>()
        .map(SharedRouteSummary.fromJson)
        .where((item) => item.id.isNotEmpty)
        .toList(growable: false);
  }

  /// 拉取共享路线详情（列表只给 pointCount，没有 points）。
  Future<RouteDefinition> sharedRoute(SharedRouteSummary summary) async {
    final value = _objectValueAllowingData(
      await _request('api/shared/routes/${summary.id}'),
    );
    return _routeFromShared(
      value,
      fallbackId: summary.id,
      fallbackName: summary.name,
    );
  }

  Future<RouteDefinition> uploadRoute(RouteDefinition route) async {
    final value = await _request(
      'api/shared/routes',
      method: 'POST',
      body: {
        'name': route.name,
        'privacyMode': route.privacyMode,
        'points': route.points.map((point) {
          final wgs = bd09ToWgs84(point.longitude, point.latitude);
          return {
            'bdLongitude': point.longitude,
            'bdLatitude': point.latitude,
            'wgsLongitude': wgs.longitude,
            'wgsLatitude': wgs.latitude,
            'altitude': point.altitude,
          };
        }).toList(),
      },
    );
    return _routeFromShared(
      _objectValueAllowingData(value),
      fallbackId: route.id,
      fallbackName: route.name,
    );
  }

  Future<List<NfcConfig>> sharedNfc() async {
    final value = await _request('api/shared/nfc');
    return _listValue(value)
        .whereType<Map<String, dynamic>>()
        .map(NfcConfig.fromJson)
        .where((item) => item.isComplete)
        .toList(growable: false);
  }

  Future<void> uploadNfc(NfcConfig config) async {
    await _request(
      'api/shared/nfc',
      method: 'POST',
      body: {
        'name': config.name,
        'url': config.url,
        'packageName': config.packageName,
        'source': config.source,
      },
      withToken: false,
    );
  }

  Future<List<SharedSimulationConfig>> sharedSimulationConfigs({
    String query = '',
  }) async {
    final value = await _request(
      'api/shared/simulation-configs?q=${Uri.encodeQueryComponent(query)}',
      withToken: false,
    );
    return _listValue(value)
        .whereType<Map<String, dynamic>>()
        .map(SharedSimulationConfig.fromJson)
        .toList(growable: false);
  }

  Future<SharedSimulationConfig> sharedSimulationConfig(String id) async {
    final value = _objectValueAllowingData(
      await _request('api/shared/simulation-configs/$id', withToken: false),
    );
    return SharedSimulationConfig.fromJson(value);
  }

  Future<SharedSimulationConfig> uploadSimulationConfig(
    String name,
    SimulationConfig config,
  ) async {
    final value = await _request(
      'api/shared/simulation-configs',
      method: 'POST',
      body: {
        'name': name,
        'mode': config.mode.name,
        'speed': config.speed,
        'cadence': config.cadence,
        'loopCount': config.loops,
        'dynamicIntensityEnabled': config.dynamicIntensity,
        'intensityVariationRange': config.intensityRange,
        'intensityVariationFrequency': config.intensityFrequency,
        'naturalPathVariationEnabled': config.naturalPath,
        'pathVariationAmplitude': config.pathAmplitude,
        'naturalAltitudeVariationEnabled': config.naturalAltitude,
        'altitudeBaseMeters': config.altitudeBase,
        'altitudeVariationRange': config.altitudeRange,
        'altitudeVariationHeightCentimeters': config.altitudeHeight,
        'altitudeVariationProbability': config.altitudeProbability,
        'linkRatioNumerator': config.linkRatio,
        'stepsPerMeter': config.stepsPerMeter,
      },
      withToken: false,
    );
    return SharedSimulationConfig.fromJson(
      _objectValueAllowingData(value),
    );
  }

  Future<List<UsageTipSummary>> usageTips({
    String query = '',
    int page = 1,
    int pageSize = 50,
  }) async {
    final value = await _request(
      'api/tips?q=${Uri.encodeQueryComponent(query)}&page=$page&pageSize=$pageSize',
    );
    return _listValue(value)
        .whereType<Map<String, dynamic>>()
        .map(UsageTipSummary.fromJson)
        .toList(growable: false);
  }

  Future<UsageTipDetail> usageTip(String id) async {
    final value = _objectValueAllowingData(await _request('api/tips/$id'));
    return UsageTipDetail.fromJson(value);
  }

  Future<UsageTipDetail> saveUsageTip({
    String? id,
    required String title,
    required String htmlContent,
    String contributorQq = '',
    bool published = false,
  }) async {
    final value = await _request(
      id == null || id.isEmpty ? 'api/tips' : 'api/tips/$id',
      method: id == null || id.isEmpty ? 'POST' : 'PUT',
      body: {
        'title': title,
        'htmlContent': htmlContent,
        'contributorQq': contributorQq,
        'isPublished': published,
      },
    );
    return UsageTipDetail.fromJson(_objectValueAllowingData(value));
  }

  Future<void> deleteUsageTip(String id) async {
    await _request('api/tips/$id', method: 'DELETE');
  }

  Future<Map<String, String>> importWord({
    required List<int> bytes,
    String filename = 'tip.docx',
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request =
          await client.postUrl(Uri.parse('$baseUrl/api/tips/import-word'));
      final boundary = 'schoolrun-${DateTime.now().microsecondsSinceEpoch}';
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );
      request.headers.set('X-Client-Variant', _clientVariant);
      if (token.isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $token',
        );
      }
      final header = utf8.encode('--$boundary\r\n'
          'Content-Disposition: form-data; name="file"; filename="$filename"\r\n'
          'Content-Type: application/vnd.openxmlformats-officedocument.wordprocessingml.document\r\n\r\n');
      request.add(header);
      request.add(bytes);
      request.add(utf8.encode('\r\n--$boundary--\r\n'));
      final response = await request.close().timeout(
            const Duration(seconds: 30),
          );
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(_errorMessage(response.statusCode, text));
      }
      final decoded = jsonDecode(text);
      final value = decoded is Map<String, dynamic> ? decoded : null;
      if (value == null) {
        throw const FormatException('Word 导入响应格式不正确');
      }
      return {
        'htmlContent': value['htmlContent'] as String? ?? '',
        'plainText': value['plainText'] as String? ?? '',
      };
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    bool withToken = true,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.openUrl(method, Uri.parse('$baseUrl$path'));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set('X-Client-Variant', _clientVariant);
      if (withToken && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
            const Duration(seconds: 25),
          );
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 25));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(_errorMessage(response.statusCode, text));
      }
      if (text.trim().isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      return {'items': decoded};
    } finally {
      client.close(force: true);
    }
  }

  String _errorMessage(int statusCode, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final detail = decoded['detail'] ?? decoded['message'];
        if (detail is String && detail.trim().isNotEmpty) {
          return 'HTTP $statusCode · ${detail.trim()}';
        }
      }
    } catch (_) {
      // Fall through to raw body snippet.
    }
    final snippet = body.trim();
    return snippet.isEmpty
        ? 'HTTP $statusCode'
        : 'HTTP $statusCode · ${snippet.length > 200 ? snippet.substring(0, 200) : snippet}';
  }

  List<dynamic> _listValue(Map<String, dynamic> value) {
    final direct = value['items'] ?? value['list'];
    if (direct is List<dynamic>) return direct;
    final data = value['data'];
    if (data is Map<String, dynamic>) {
      final nested = data['items'] ?? data['list'];
      if (nested is List<dynamic>) return nested;
    }
    if (value['data'] is List<dynamic>) return value['data'] as List<dynamic>;
    return const [];
  }

  /// 详情响应可能是 `{data:{...}}`、`{item:{...}}` 或裸对象。
  Map<String, dynamic> _objectValueAllowingData(Map<String, dynamic> value) {
    for (final key in const ['data', 'item', 'route', 'nfc']) {
      final candidate = value[key];
      if (candidate is Map) {
        final nested = candidate['item'] ?? candidate['route'];
        if (nested is Map) return nested.cast<String, dynamic>();
        return candidate.cast<String, dynamic>();
      }
    }
    return value;
  }

  RouteDefinition _routeFromShared(
    Map<String, dynamic> json, {
    required String fallbackId,
    required String fallbackName,
  }) {
    final remoteId = '${json['id'] ?? fallbackId}';
    final now = DateTime.now();
    final rawPoints = json['points'] as List<dynamic>? ?? const [];
    return RouteDefinition(
      // 本地 id 与后端 id 分开：后端 id 记在 shareId，便于以后再次上传/定位。
      id: 'shared-$remoteId-${now.microsecondsSinceEpoch}',
      name: json['name'] as String? ??
          (fallbackName.trim().isEmpty ? '共享路线' : fallbackName),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num?)?.toInt() ?? now.millisecondsSinceEpoch,
      ),
      updatedAt: now,
      points: rawPoints
          .whereType<Map<String, dynamic>>()
          .map(RoutePoint.fromJson)
          .toList(growable: false),
      shared: true,
      privacyMode: json['privacyMode'] as bool? ?? false,
      downloadedFromShared: true,
      shareId: remoteId,
      sharedAt: now,
    );
  }
}
