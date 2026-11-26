import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';

class AppStore extends ChangeNotifier {
  static const _channel = MethodChannel('schoolrun/storage');

  List<RouteDefinition> routes = const [];
  List<HistoryEntry> history = const [];
  List<NfcConfig> nfcConfigs = const [];
  SimulationConfig simulation = const SimulationConfig();
  String nfcUrl = '';
  String nfcPackage = '';

  /// 「模拟 NFC」在模拟还没开始时只登记、不跳转，等「开始模拟」再真正触发。
  /// 这是内存字段，故意不持久化：落地会让用户几天后重开 app 点「开始模拟」时莫名跳走。
  bool nfcDispatchArmed = false;

  /// 路线模拟是否正在跑。跨页面共享——NFC 页要靠它决定立刻跳转还是登记待触发。
  /// 运行态不持久化：进程重启后模拟必然已停。
  bool simulationRunning = false;

  bool ptlEnabled = false;
  bool dynamicIntensity = true;
  bool naturalPath = false;
  bool naturalAltitude = false;
  double walkSpeed = 1.2;
  double runSpeed = 3.6;
  double bikeSpeed = 10;
  bool randomOffset = false;
  double latitudeOffset = 0;
  double longitudeOffset = 0;
  String shareBaseUrl = '';
  String authToken = '';
  String accountName = '';
  String testerTypeLabel = '';
  bool loaded = false;
  bool legalAccepted = false;
  bool logDisabled = false;
  int historyExpirationDays = 7;

  /// 稳定的设备标识（ANDROID_ID）。后端会把账号绑定到设备；
  /// 每次登录随机生成会导致旧设备被记 wrong-device 并触发风控，所以这里生成一次后持久化。
  String deviceId = '';
  String deviceName = '';

  /// 上一次运行的路线 id 与「完成待提示」标记。
  String lastRouteId = '';
  bool completionPending = false;

  /// 读到的 / 当前 NFC 数据的来源（manual / saved / nfc / shared）。
  String nfcSource = 'manual';

  /// 路线录制间隔（秒），默认 3s。
  int recordIntervalSeconds = 3;

  Future<void> load() async {
    try {
      final raw = await _channel.invokeMethod<String>('load');
      if (raw != null && raw.isNotEmpty)
        _apply(jsonDecode(raw) as Map<String, dynamic>);
    } on MissingPluginException {
      // The fallback keeps the UI usable in desktop previews and widget tests.
    } on PlatformException {
      // Treat unavailable native storage as an empty local workspace.
    } catch (_) {
      // Invalid cached data should not prevent the app from opening.
    }
    if (deviceId.isEmpty) {
      // 稳定设备标识：优先取原生 ANDROID_ID，拿不到再用持久化的 UUID。
      var resolvedId = '';
      var resolvedName = '';
      try {
        final info = await _channel
            .invokeMethod<Map<dynamic, dynamic>>('deviceInfo');
        resolvedId = info?['deviceId'] as String? ?? '';
        resolvedName = info?['deviceName'] as String? ?? '';
      } on MissingPluginException {
        // 桌面/测试环境没有原生桥接。
      } on PlatformException {
        // 忽略，退回 UUID。
      }
      deviceId = resolvedId.isEmpty
          ? DateTime.now().microsecondsSinceEpoch.toRadixString(16)
          : resolvedId;
      deviceName = resolvedName.isEmpty ? 'RunToolBox Flutter' : resolvedName;
      await _persist();
    }
    loaded = true;
    notifyListeners();
  }

  void _apply(Map<String, dynamic> json) {
    final rawRoutes = json['routes'] as List<dynamic>? ?? const [];
    routes = rawRoutes
        .whereType<Map<String, dynamic>>()
        .map(RouteDefinition.fromJson)
        .toList(growable: false);
    final rawHistory = json['history'] as List<dynamic>? ?? const [];
    history = rawHistory
        .whereType<Map<String, dynamic>>()
        .map(HistoryEntry.fromJson)
        .toList(growable: false);
    final rawNfc = json['nfcConfigs'] as List<dynamic>? ?? const [];
    nfcConfigs = rawNfc
        .whereType<Map<String, dynamic>>()
        .map(NfcConfig.fromJson)
        .where((item) => item.isComplete)
        .toList(growable: false);
    final rawSimulation = json['simulation'] as Map<String, dynamic>?;
    simulation = rawSimulation == null
        ? const SimulationConfig()
        : SimulationConfig.fromJson(rawSimulation);
    nfcUrl = json['nfcUrl'] as String? ?? '';
    nfcPackage = json['nfcPackage'] as String? ?? '';
    nfcSource = json['nfcSource'] as String? ?? 'manual';
    recordIntervalSeconds =
        ((json['recordIntervalSeconds'] as num?)?.toInt() ?? 3).clamp(1, 3600);
    ptlEnabled = json['ptlEnabled'] as bool? ?? false;
    dynamicIntensity = json['dynamicIntensity'] as bool? ?? true;
    naturalPath = json['naturalPath'] as bool? ?? false;
    naturalAltitude = json['naturalAltitude'] as bool? ?? false;
    walkSpeed = (json['walkSpeed'] as num?)?.toDouble() ?? 1.2;
    runSpeed = (json['runSpeed'] as num?)?.toDouble() ?? 3.6;
    bikeSpeed = (json['bikeSpeed'] as num?)?.toDouble() ?? 10;
    randomOffset = json['randomOffset'] as bool? ?? false;
    latitudeOffset = (json['latitudeOffset'] as num?)?.toDouble() ?? 0;
    longitudeOffset = (json['longitudeOffset'] as num?)?.toDouble() ?? 0;
    shareBaseUrl = json['shareBaseUrl'] as String? ?? '';
    authToken = json['authToken'] as String? ?? '';
    accountName = json['accountName'] as String? ?? '';
    testerTypeLabel = json['testerTypeLabel'] as String? ?? '';
    deviceId = json['deviceId'] as String? ?? '';
    deviceName = json['deviceName'] as String? ?? '';
    lastRouteId = json['lastRouteId'] as String? ?? '';
    completionPending = json['completionPending'] as bool? ?? false;
    legalAccepted = json['legalAccepted'] as bool? ?? false;
    logDisabled = json['logDisabled'] as bool? ?? false;
    historyExpirationDays =
        (json['historyExpirationDays'] as num?)?.toInt() ?? 7;
    final cutoff = DateTime.now().subtract(
      Duration(days: historyExpirationDays.clamp(1, 3650)),
    );
    history = history
        .where((item) => item.createdAt.isAfter(cutoff))
        .toList(growable: false);
  }

  Map<String, dynamic> _json() => {
        'routes': routes.map((route) => route.toJson()).toList(),
        'history': history.map((item) => item.toJson()).toList(),
        'nfcConfigs': nfcConfigs.map((item) => item.toJson()).toList(),
        'simulation': simulation.toJson(),
        'recordIntervalSeconds': recordIntervalSeconds,
        'nfcUrl': nfcUrl,
        'nfcPackage': nfcPackage,
        'nfcSource': nfcSource,
        'ptlEnabled': ptlEnabled,
        'dynamicIntensity': dynamicIntensity,
        'naturalPath': naturalPath,
        'naturalAltitude': naturalAltitude,
        'walkSpeed': walkSpeed,
        'runSpeed': runSpeed,
        'bikeSpeed': bikeSpeed,
        'randomOffset': randomOffset,
        'latitudeOffset': latitudeOffset,
        'longitudeOffset': longitudeOffset,
        'shareBaseUrl': shareBaseUrl,
        'authToken': authToken,
        'accountName': accountName,
        'testerTypeLabel': testerTypeLabel,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'lastRouteId': lastRouteId,
        'completionPending': completionPending,
        'legalAccepted': legalAccepted,
        'logDisabled': logDisabled,
        'historyExpirationDays': historyExpirationDays,
      };

  Future<void> _persist() async {
    try {
      await _channel.invokeMethod<void>('save', jsonEncode(_json()));
    } on MissingPluginException {
      // In-memory fallback for previews.
    } on PlatformException {
      // Keep state visible even if native storage is unavailable.
    }
  }

  Future<void> saveRoute(
    String name,
    List<RoutePoint> points, {
    String? id,
    bool privacyMode = false,
  }) async {
    final now = DateTime.now();
    final routeId = id ?? now.microsecondsSinceEpoch.toString();
    final existingIndex = routes.indexWhere((route) => route.id == routeId);
    final route = existingIndex >= 0
        ? routes[existingIndex].copyWith(
            name: name,
            points: points,
            updatedAt: now,
            privacyMode: privacyMode,
          )
        : RouteDefinition(
            id: routeId,
            name: name,
            createdAt: now,
            updatedAt: now,
            points: List.unmodifiable(points),
            privacyMode: privacyMode,
          );
    final next = List<RouteDefinition>.of(routes);
    if (existingIndex >= 0) {
      next[existingIndex] = route;
    } else {
      next.insert(0, route);
    }
    routes = List.unmodifiable(next);
    _addHistory(
      HistoryEntry(
        title: name,
        detail: '${points.length} 个路线点已保存',
        createdAt: now,
      ),
    );
    notifyListeners();
    await _persist();
  }

  Future<void> deleteRoute(RouteDefinition route) async {
    routes = List.unmodifiable(routes.where((item) => item.id != route.id));
    notifyListeners();
    await _persist();
  }

  Future<int> importRouteJson(String raw) async {
    final decoded = jsonDecode(raw);
    final values = decoded is Map<String, dynamic> && decoded['routes'] is List
        ? decoded['routes'] as List<dynamic>
        : decoded is List<dynamic>
            ? decoded
            : [decoded];
    final imported = values
        .whereType<Map<String, dynamic>>()
        .map(RouteDefinition.fromJson)
        .where((route) => route.points.length >= 2)
        .toList(growable: false);
    if (imported.isEmpty) return 0;
    final existingIds = routes.map((route) => route.id).toSet();
    final next = [
      ...imported.where((route) => !existingIds.contains(route.id)),
      ...routes,
    ];
    routes = List.unmodifiable(next);
    await recordHistory(
      title: '导入路线',
      detail: '成功导入 ${imported.length} 条路线',
      kind: 'route',
    );
    return imported.length;
  }

  /// 导出可跨端导入的格式：单条路线是对象，多条是数组；解析时两者都接受。
  String exportRouteJson() {
    final values = routes.map((route) => route.toJson()).toList();
    return jsonEncode(values.length == 1 ? values.first : values);
  }

  Future<void> setRouteShared(
    RouteDefinition route,
    bool shared, {
    String? shareId,
  }) async {
    final next = routes
        .map((item) => item.id == route.id
            ? item.copyWith(
                shared: shared,
                shareId: shareId ?? item.shareId,
                sharedAt: shared ? DateTime.now() : item.sharedAt,
              )
            : item)
        .toList(growable: false);
    routes = List.unmodifiable(next);
    notifyListeners();
    await _persist();
  }

  /// 把共享路线保存到本地（保留来源/隐私标记，供模拟时决定是否遮罩）。
  Future<RouteDefinition> addDownloadedRoute(RouteDefinition remote) async {
    final now = DateTime.now();
    final route = RouteDefinition(
      id: 'local-${now.microsecondsSinceEpoch}',
      name: remote.name,
      createdAt: now,
      updatedAt: now,
      points: remote.points,
      shared: true,
      privacyMode: remote.privacyMode,
      downloadedFromShared: true,
      shareId: remote.shareId,
      sharedAt: now,
    );
    routes = List.unmodifiable([route, ...routes]);
    _addHistory(HistoryEntry(
      title: remote.name,
      detail: '下载共享路线',
      createdAt: now,
      kind: 'route',
    ));
    notifyListeners();
    await _persist();
    return route;
  }

  Future<void> saveSimulation(SimulationConfig next) async {
    simulation = next;
    notifyListeners();
    await _persist();
  }

  Future<void> saveShareSession({
    required String baseUrl,
    required String token,
    required String account,
    String testerTypeLabel = '',
  }) async {
    shareBaseUrl = baseUrl.trim();
    authToken = token.trim();
    accountName = account.trim();
    this.testerTypeLabel = testerTypeLabel.trim();
    notifyListeners();
    await _persist();
  }

  Future<void> setShareBaseUrl(String baseUrl) async {
    shareBaseUrl = baseUrl.trim();
    notifyListeners();
    await _persist();
  }

  Future<void> clearShareSession() async {
    shareBaseUrl = '';
    authToken = '';
    accountName = '';
    testerTypeLabel = '';
    notifyListeners();
    await _persist();
  }

  Future<void> acceptLegal() async {
    legalAccepted = true;
    notifyListeners();
    await _persist();
  }

  Future<int> mergeSharedRoutes(List<RouteDefinition> sharedRoutes) async {
    final ids = routes.map((route) => route.id).toSet();
    final shareIds = routes.map((route) => route.shareId).toSet();
    final newRoutes = sharedRoutes
        .where((route) =>
            route.hasEnoughPoints &&
            !route.privacyMode &&
            !ids.contains(route.id) &&
            !shareIds.contains(route.shareId))
        .toList();
    routes = List.unmodifiable([...newRoutes, ...routes]);
    if (newRoutes.isNotEmpty) {
      _addHistory(HistoryEntry(
          title: '下载共享路线',
          detail: '下载 ${newRoutes.length} 条路线',
          createdAt: DateTime.now(),
          kind: 'route'));
    }
    notifyListeners();
    await _persist();
    return newRoutes.length;
  }

  Future<void> saveNfcFields({
    required String url,
    required String packageName,
    String? source,
  }) async {
    nfcUrl = url.trim();
    nfcPackage = packageName.trim();
    if (source != null) nfcSource = source.trim();
    notifyListeners();
    await _persist();
  }

  Future<void> setLastRoute(String routeId) async {
    lastRouteId = routeId;
    notifyListeners();
    await _persist();
  }

  Future<void> setRecordInterval(int seconds) async {
    recordIntervalSeconds = seconds.clamp(1, 3600);
    notifyListeners();
    await _persist();
  }

  Future<void> setCompletionPending(bool pending) async {
    completionPending = pending;
    notifyListeners();
    await _persist();
  }

  /// 登记 / 取消一次待触发的 NFC 跳转。模拟未开始时点「模拟 NFC」只走这里，
  /// 真正的跳转留给「开始模拟」——未运行时只登记待触发。
  /// 运行态，不落盘。
  void armNfcDispatch(bool armed) {
    if (nfcDispatchArmed == armed) return;
    nfcDispatchArmed = armed;
    notifyListeners();
  }

  void setSimulationRunning(bool running) {
    if (simulationRunning == running) return;
    simulationRunning = running;
    notifyListeners();
  }

  Future<void> saveNfcTemplate(NfcConfig config) async {
    if (!config.isComplete) return;
    final next = List<NfcConfig>.of(nfcConfigs);
    final index = next.indexWhere(
      (item) => item.name.toLowerCase() == config.name.toLowerCase(),
    );
    if (index >= 0) {
      next[index] = config;
    } else {
      next.insert(0, config);
    }
    nfcConfigs = List.unmodifiable(next);
    notifyListeners();
    await _persist();
  }

  Future<void> deleteNfcTemplate(NfcConfig config) async {
    nfcConfigs = List.unmodifiable(
      nfcConfigs.where((item) => item.name != config.name),
    );
    notifyListeners();
    await _persist();
  }

  Future<void> updateSettings({
    bool? ptl,
    bool? intensity,
    bool? path,
    bool? altitude,
    double? walk,
    double? run,
    double? bike,
    bool? random,
    double? latitudeOffsetValue,
    double? longitudeOffsetValue,
    bool? logsOff,
    int? historyDays,
  }) async {
    ptlEnabled = ptl ?? ptlEnabled;
    dynamicIntensity = intensity ?? dynamicIntensity;
    naturalPath = path ?? naturalPath;
    naturalAltitude = altitude ?? naturalAltitude;
    walkSpeed = walk ?? walkSpeed;
    runSpeed = run ?? runSpeed;
    bikeSpeed = bike ?? bikeSpeed;
    randomOffset = random ?? randomOffset;
    latitudeOffset = latitudeOffsetValue ?? latitudeOffset;
    longitudeOffset = longitudeOffsetValue ?? longitudeOffset;
    logDisabled = logsOff ?? logDisabled;
    historyExpirationDays =
        (historyDays ?? historyExpirationDays).clamp(1, 3650);
    simulation = simulation.copyWith(
      dynamicIntensity: dynamicIntensity,
      naturalPath: naturalPath,
      naturalAltitude: naturalAltitude,
    );
    notifyListeners();
    await _persist();
  }

  Future<void> recordHistory({
    required String title,
    required String detail,
    String kind = 'route',
    double? latitude,
    double? longitude,
  }) async {
    _addHistory(
      HistoryEntry(
        title: title,
        detail: detail,
        createdAt: DateTime.now(),
        kind: kind,
        latitude: latitude,
        longitude: longitude,
      ),
    );
    notifyListeners();
    await _persist();
  }

  Future<void> clearHistory() async {
    history = const [];
    notifyListeners();
    await _persist();
  }

  Future<void> renameHistory(HistoryEntry entry, String title) async {
    final index = history.indexOf(entry);
    if (index < 0 || title.trim().isEmpty) return;
    final next = List<HistoryEntry>.of(history);
    next[index] = entry.copyWith(title: title.trim());
    history = List.unmodifiable(next);
    notifyListeners();
    await _persist();
  }

  Future<void> deleteHistory(HistoryEntry entry) async {
    history = List.unmodifiable(history.where((item) => item != entry));
    notifyListeners();
    await _persist();
  }

  void _addHistory(HistoryEntry entry) {
    history = List.unmodifiable([entry, ...history].take(30));
  }
}
