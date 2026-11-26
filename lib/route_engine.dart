import 'dart:math' as math;

import 'models.dart';

const double _earthRadiusMeters = 6371000;
const double _estimatedStepLengthMeters = 0.8;
const double _minimumSimulationSpeed = 0.5;
const double _minimumDynamicSpeedRatio = 0.35;
const double _intensitySettleEpsilon = 0.05;
const double _pathSettleEpsilon = 0.05;
const double _altitudeSettleEpsilon = 0.03;
const double _minimumSegmentDistance = 0.01;
const double _keyPointMaxStraightAngle = 170;

double distanceMeters(RoutePoint a, RoutePoint b) {
  final lat1 = a.latitude * math.pi / 180;
  final lat2 = b.latitude * math.pi / 180;
  final dLat = (b.latitude - a.latitude) * math.pi / 180;
  final dLon = (b.longitude - a.longitude) * math.pi / 180;
  final haversine = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  final clamped = haversine.clamp(0.0, 1.0);
  final c = 2 * math.atan2(math.sqrt(clamped), math.sqrt(1 - clamped));
  return _earthRadiusMeters * c;
}

double totalDistanceMeters(List<RoutePoint> points) {
  var total = 0.0;
  for (var index = 1; index < points.length; index++) {
    total += distanceMeters(points[index - 1], points[index]);
  }
  return total;
}

List<double> _cumulativeDistances(List<RoutePoint> points) {
  final values = <double>[0];
  var total = 0.0;
  for (var index = 1; index < points.length; index++) {
    total += distanceMeters(points[index - 1], points[index]);
    values.add(total);
  }
  return values;
}

/// 按总里程均匀插入 [count] 个点。
///
/// 先算累计里程，再依次插入，排序键为「距起点距离 → 原始点优先 → 序号」，
/// 距离相同时不会把新点排到原顶点前面。
List<RoutePoint> insertEvenlySpacedPoints(List<RoutePoint> source, int count) {
  final points = List<RoutePoint>.of(source);
  if (points.length < 2 || count <= 0) return points;
  final cumulative = _cumulativeDistances(points);
  final total = cumulative.last;
  if (total <= 0) return points;

  final placements = <_PointPlacement>[];
  for (var index = 0; index < points.length; index++) {
    placements
        .add(_PointPlacement(cumulative[index], points[index], index, true));
  }
  for (var insertIndex = 1; insertIndex <= count; insertIndex++) {
    final target = total * (insertIndex / (count + 1));
    final segment = _findSegmentIndex(cumulative, target);
    final start = cumulative[segment];
    final end = cumulative[segment + 1];
    final segmentDistance = math.max(0.000001, end - start);
    final ratio = ((target - start) / segmentDistance).clamp(0.0, 1.0);
    placements.add(_PointPlacement(
      target,
      points[segment].lerp(points[segment + 1], ratio),
      insertIndex,
      false,
    ));
  }
  placements.sort((a, b) {
    final byDistance = a.distance.compareTo(b.distance);
    if (byDistance != 0) return byDistance;
    if (a.original != b.original) return a.original ? -1 : 1;
    return a.sequence.compareTo(b.sequence);
  });
  return placements.map((placement) => placement.point).toList(growable: false);
}

int _findSegmentIndex(List<double> cumulative, double target) {
  for (var index = 0; index < cumulative.length - 1; index++) {
    if (target <= cumulative[index + 1]) return index;
  }
  return math.max(0, cumulative.length - 2);
}

bool _isKeyRoutePoint(List<RoutePoint> points, int index) {
  if (points.isEmpty) return false;
  if (index <= 0 || index >= points.length - 1) {
    return index >= 0 && index < points.length;
  }
  final angle = _estimateAngleDegrees(
    points[index - 1],
    points[index],
    points[index + 1],
  );
  return angle < _keyPointMaxStraightAngle;
}

int countKeyRoutePoints(List<RoutePoint> points) {
  var count = 0;
  for (var index = 0; index < points.length; index++) {
    if (_isKeyRoutePoint(points, index)) count++;
  }
  return count;
}

int countRemovableRoutePoints(List<RoutePoint> points) =>
    math.max(0, points.length - countKeyRoutePoints(points));

List<RoutePoint> removeEvenlySpacedNonKeyPoints(
  List<RoutePoint> source,
  int count,
) {
  final points = List<RoutePoint>.of(source);
  if (points.length < 3 || count <= 0) return points;
  final removable = <int>[];
  for (var index = 0; index < points.length; index++) {
    if (!_isKeyRoutePoint(points, index)) removable.add(index);
  }
  if (removable.isEmpty) return points;
  final remove = List<bool>.filled(points.length, false);
  final clamped = math.min(count, removable.length);
  if (clamped == removable.length) {
    for (final index in removable) {
      remove[index] = true;
    }
  } else {
    var previousPosition = -1;
    for (var removalIndex = 1; removalIndex <= clamped; removalIndex++) {
      var position =
          (removalIndex * ((removable.length + 1) / (clamped + 1))).floor() - 1;
      position = math.max(
        previousPosition + 1,
        math.min(removable.length - 1, position),
      );
      remove[removable[position]] = true;
      previousPosition = position;
    }
  }
  return [
    for (var index = 0; index < points.length; index++)
      if (!remove[index]) points[index],
  ];
}

/// 把 85°~95° 的近直角替换成圆角过渡。
///
/// 入口点、二次贝塞尔中点、出口点共 3 个点，trim 距离取 `min(radius, 段长/2.5)`。
List<RoutePoint> smoothRightAngles(
  List<RoutePoint> source,
  double radiusMeters, {
  double minAngleDegrees = 85,
  double maxAngleDegrees = 95,
}) {
  final points = List<RoutePoint>.of(source);
  if (points.length < 3 || radiusMeters <= 0) return points;
  final result = <RoutePoint>[points.first];
  for (var index = 1; index < points.length - 1; index++) {
    final previous = points[index - 1];
    final current = points[index];
    final next = points[index + 1];
    final angle = _estimateAngleDegrees(previous, current, next);
    final previousDistance = distanceMeters(previous, current);
    final nextDistance = distanceMeters(current, next);
    if (angle >= minAngleDegrees &&
        angle <= maxAngleDegrees &&
        previousDistance > 0.5 &&
        nextDistance > 0.5) {
      final trimPrevious = math.min(radiusMeters, previousDistance / 2.5);
      final trimNext = math.min(radiusMeters, nextDistance / 2.5);
      final entry = previous.lerp(
        current,
        ((previousDistance - trimPrevious) / previousDistance).clamp(0.0, 1.0),
      );
      final exit = current.lerp(
        next,
        (trimNext / nextDistance).clamp(0.0, 1.0),
      );
      result.add(entry);
      result.add(_quadraticBezier(entry, current, exit, 0.5));
      result.add(exit);
    } else {
      result.add(current);
    }
  }
  result.add(points.last);
  return result;
}

RoutePoint _quadraticBezier(
  RoutePoint start,
  RoutePoint control,
  RoutePoint end,
  double t,
) {
  final oneMinusT = 1 - t;
  double blend(double a, double b, double c) =>
      oneMinusT * oneMinusT * a + 2 * oneMinusT * t * b + t * t * c;
  return RoutePoint(
    longitude: blend(start.longitude, control.longitude, end.longitude),
    latitude: blend(start.latitude, control.latitude, end.latitude),
    altitude: blend(start.altitude, control.altitude, end.altitude),
  );
}

double _estimateAngleDegrees(
  RoutePoint previous,
  RoutePoint current,
  RoutePoint next,
) {
  final incoming = _deltaMeters(current, previous);
  final outgoing = _deltaMeters(current, next);
  final incomingLength = math.sqrt(
    incoming.eastMeters * incoming.eastMeters +
        incoming.northMeters * incoming.northMeters,
  );
  final outgoingLength = math.sqrt(
    outgoing.eastMeters * outgoing.eastMeters +
        outgoing.northMeters * outgoing.northMeters,
  );
  if (incomingLength <= 0.000001 || outgoingLength <= 0.000001) return 180;
  final dot = incoming.eastMeters * outgoing.eastMeters +
      incoming.northMeters * outgoing.northMeters;
  final normalized = (dot / (incomingLength * outgoingLength)).clamp(-1.0, 1.0);
  return math.acos(normalized) * 180 / math.pi;
}

({double eastMeters, double northMeters}) _deltaMeters(
  RoutePoint origin,
  RoutePoint target,
) {
  final latitudeRadians = origin.latitude * math.pi / 180;
  final north =
      (target.latitude - origin.latitude) * math.pi / 180 * _earthRadiusMeters;
  final east = (target.longitude - origin.longitude) *
      math.pi /
      180 *
      _earthRadiusMeters *
      math.cos(latitudeRadians);
  return (eastMeters: east, northMeters: north);
}

class ProjectionResult {
  const ProjectionResult({
    required this.segmentStartIndex,
    required this.point,
    required this.segmentRatio,
    required this.distanceToRouteMeters,
  });

  const ProjectionResult.empty()
      : segmentStartIndex = -1,
        point = null,
        segmentRatio = 0,
        distanceToRouteMeters = double.maxFinite;

  final int segmentStartIndex;
  final RoutePoint? point;
  final double segmentRatio;
  final double distanceToRouteMeters;

  bool get isValid => segmentStartIndex >= 0 && point != null;
}

ProjectionResult projectPointOntoRoute(
  List<RoutePoint> points,
  RoutePoint target,
) {
  if (points.length < 2) return const ProjectionResult.empty();
  var best = const ProjectionResult.empty();
  for (var index = 0; index < points.length - 1; index++) {
    final start = points[index];
    final end = points[index + 1];
    final segment = _deltaMeters(start, end);
    final vector = _deltaMeters(start, target);
    final lengthSquared = segment.eastMeters * segment.eastMeters +
        segment.northMeters * segment.northMeters;
    if (lengthSquared <= 0.000001) continue;
    final rawRatio = (vector.eastMeters * segment.eastMeters +
            vector.northMeters * segment.northMeters) /
        lengthSquared;
    final ratio = rawRatio.clamp(0.0, 1.0);
    final projected = start.lerp(end, ratio);
    final distance = distanceMeters(projected, target);
    if (!best.isValid || distance < best.distanceToRouteMeters) {
      best = ProjectionResult(
        segmentStartIndex: index,
        point: projected,
        segmentRatio: ratio,
        distanceToRouteMeters: distance,
      );
    }
  }
  return best;
}

List<RoutePoint> insertPointOnRoute(
  List<RoutePoint> points,
  ProjectionResult projection,
) {
  if (!projection.isValid || points.length < 2) return List.of(points);
  final insertIndex =
      (projection.segmentStartIndex + 1).clamp(0, points.length);
  final result = List<RoutePoint>.of(points);
  result.insert(insertIndex, projection.point!);
  return result;
}

/// 一帧模拟结果：点、航向、速度、是否结束、已完成圈数、已走里程。
class SimulationFrame {
  const SimulationFrame({
    required this.point,
    required this.progress,
    required this.loop,
    required this.finished,
    this.bearing = 0,
    this.speed = 0,
    this.distanceTraveled = 0,
  });

  final RoutePoint point;
  final double progress;
  final int loop;
  final bool finished;
  final double bearing;
  final double speed;
  final double distanceTraveled;
}

/// 路线模拟引擎。
///
/// - 每帧推进 `speed * tickMillis / 1000` 米（默认 tick=1000ms，即 1 秒行程）；
/// - 动态强度是「随机游走 + 平滑」，不是正弦；
/// - 自然轨迹是沿航向 ±90° 的**米制**横向偏移；
/// - 海拔 = 海拔基线 + 身高(cm→m) + 平滑随机游走；
/// - 步频模式按平均速度换算（0.8m 步长）。
class RouteSimulationEngine {
  RouteSimulationEngine(this.route, this.config)
      : _points = List<RoutePoint>.of(route.points),
        _random = math.Random() {
    if (_points.length < 2) {
      throw ArgumentError('Route must contain at least two points');
    }
    _routeDistanceMeters = totalDistanceMeters(_points);
    _cumulative = _cumulativeDistances(_points);
  }

  RouteDefinition route;
  SimulationConfig config;
  final List<RoutePoint> _points;
  final math.Random _random;
  late double _routeDistanceMeters;
  late List<double> _cumulative;

  int _segmentIndex = 0;
  double _progressInSegmentMeters = 0;
  int _completedLoops = 0;
  bool _finished = false;
  double _currentIntensityOffset = 0;
  double _targetIntensityOffset = 0;
  double _currentPathOffsetMeters = 0;
  double _targetPathOffsetMeters = 0;
  double _currentAltitudeOffsetMeters = 0;
  double _targetAltitudeOffsetMeters = 0;
  double _pendingLinkedDistanceMeters = 0;

  bool get finished => _finished;
  int get completedLoops => _completedLoops;
  double get routeDistanceMeters => _routeDistanceMeters;
  int get segmentIndex => _segmentIndex;
  double get progressInSegmentMeters => _progressInSegmentMeters;

  double get _distanceTraveledInLoop =>
      _cumulative[_segmentIndex] + _progressInSegmentMeters;

  double get distanceTraveled =>
      _completedLoops * _routeDistanceMeters + _distanceTraveledInLoop;

  /// 总进度 0~1，供 UI 进度条使用。
  double get progress {
    if (_routeDistanceMeters <= 0) return _finished ? 1 : 0;
    final total = _routeDistanceMeters * config.loops.clamp(1, 100000);
    final raw = distanceTraveled / total;
    return _finished ? 1 : raw.clamp(0.0, 1.0);
  }

  double _resolveCurrentSpeedMetersPerSecond() {
    final baseSpeed = config.mode == SimulationMode.cadence
        ? _resolveCadenceSpeedMetersPerSecond()
        : config.speed;
    if (baseSpeed <= 0) return 0;
    if (!config.dynamicIntensity ||
        config.intensityRange <= 0 ||
        config.intensityFrequency <= 0) {
      _currentIntensityOffset = 0;
      _targetIntensityOffset = 0;
      return baseSpeed;
    }
    final range = config.intensityRange;
    final frequency = config.intensityFrequency.clamp(0.0, 1.0);
    if ((_targetIntensityOffset - _currentIntensityOffset).abs() <=
            _intensitySettleEpsilon ||
        _random.nextDouble() < frequency) {
      _targetIntensityOffset = _randomInRange(range);
    }
    final smoothing = 0.15 + frequency * 0.55;
    _currentIntensityOffset +=
        (_targetIntensityOffset - _currentIntensityOffset) * smoothing;
    _currentIntensityOffset = _currentIntensityOffset.clamp(-range, range);
    final minimumSpeed = math.max(
        _minimumSimulationSpeed, baseSpeed * _minimumDynamicSpeedRatio);
    return (baseSpeed + _currentIntensityOffset)
        .clamp(minimumSpeed, baseSpeed + range);
  }

  double _resolveCadenceSpeedMetersPerSecond() {
    final totalDistance = _routeDistanceMeters * config.loops;
    if (totalDistance <= 0) return 0;
    final totalSteps = totalDistance / _estimatedStepLengthMeters;
    final totalMinutes = totalSteps / config.cadence;
    if (totalMinutes <= 0) return 0;
    return totalDistance / (totalMinutes * 60);
  }

  /// 推进一帧（一个 tick 的行程）。
  SimulationFrame next() {
    final speed = _resolveCurrentSpeedMetersPerSecond();
    var distanceStep = speed * (config.tickMillis / 1000.0);
    while (distanceStep >= 0 && !_finished) {
      final currentPoint = _points[_segmentIndex];
      final nextPoint = _points[_segmentIndex + 1];
      final segmentDistance = distanceMeters(currentPoint, nextPoint);
      if (segmentDistance <= _minimumSegmentDistance) {
        _advanceSegment();
        if (_finished) break;
        continue;
      }
      final remainingInSegment = segmentDistance - _progressInSegmentMeters;
      if (distanceStep < remainingInSegment) {
        _progressInSegmentMeters += distanceStep;
        final ratio =
            (_progressInSegmentMeters / segmentDistance).clamp(0.0, 1.0);
        final interpolated = currentPoint.lerp(nextPoint, ratio);
        final bearing = _bearingDegrees(currentPoint, nextPoint);
        final simulated = _applyNaturalAltitudeVariation(
          _applyNaturalPathVariation(interpolated, bearing),
        );
        return SimulationFrame(
          point: simulated,
          progress: progress,
          loop: _completedLoops,
          finished: false,
          bearing: bearing,
          speed: speed,
          distanceTraveled: distanceTraveled,
        );
      }
      distanceStep -= remainingInSegment;
      _advanceSegment();
    }
    return SimulationFrame(
      point: _applyNaturalAltitudeVariation(_points.last),
      progress: 1,
      loop: _completedLoops,
      finished: true,
      bearing: 0,
      speed: 0,
      distanceTraveled: distanceTraveled,
    );
  }

  /// 真实步数联动：每累计 `stepsPerMeter` 步折算 1 米，累计到 linkRatio 米推进一帧。
  ///
  /// 里程累计达到阈值才推进「一整个 tick」，而不是把步数直接换算成前近距离。
  /// 阈值默认 1 米。
  SimulationFrame nextForSteps(int steps) {
    if (steps <= 0) {
      return SimulationFrame(
        point: _points[_segmentIndex],
        progress: progress,
        loop: _completedLoops,
        finished: _finished,
      );
    }
    final stepsPerMeter =
        config.stepsPerMeter <= 0 ? 1.0 : config.stepsPerMeter;
    _pendingLinkedDistanceMeters += steps / stepsPerMeter;
    final threshold = config.linkRatio <= 0 ? 1.0 : config.linkRatio;
    if (_pendingLinkedDistanceMeters < threshold) {
      return SimulationFrame(
        point: _points[_segmentIndex],
        progress: progress,
        loop: _completedLoops,
        finished: _finished,
      );
    }
    _pendingLinkedDistanceMeters -= threshold;
    return next();
  }

  void updateConfig(SimulationConfig next) {
    config = next;
    if (!next.dynamicIntensity) {
      _currentIntensityOffset = 0;
      _targetIntensityOffset = 0;
    }
    if (!next.naturalPath) {
      _currentPathOffsetMeters = 0;
      _targetPathOffsetMeters = 0;
    }
    if (!next.naturalAltitude) {
      _currentAltitudeOffsetMeters = 0;
      _targetAltitudeOffsetMeters = 0;
    }
    if (_completedLoops >= next.loops) _finished = true;
  }

  void updateRoute(RouteDefinition nextRoute) {
    if (nextRoute.points.length < 2) {
      _finished = true;
      return;
    }
    final traveled = _distanceTraveledInLoop;
    route = nextRoute;
    _points
      ..clear()
      ..addAll(nextRoute.points);
    _routeDistanceMeters = totalDistanceMeters(_points);
    _cumulative = _cumulativeDistances(_points);
    _realignProgress(traveled);
  }

  void _realignProgress(double traveled) {
    if (_points.length < 2) {
      _finished = true;
      return;
    }
    _segmentIndex = 0;
    _progressInSegmentMeters = 0;
    var remaining = math.max(0.0, traveled);
    for (var index = 0; index < _points.length - 1; index++) {
      final segmentDistance =
          distanceMeters(_points[index], _points[index + 1]);
      if (index == _points.length - 2) {
        _segmentIndex = index;
        _progressInSegmentMeters = math.min(remaining, segmentDistance);
        return;
      }
      if (remaining <= segmentDistance) {
        _segmentIndex = index;
        _progressInSegmentMeters = remaining;
        return;
      }
      remaining -= segmentDistance;
    }
  }

  void _advanceSegment() {
    _progressInSegmentMeters = 0;
    if (_segmentIndex < _points.length - 2) {
      _segmentIndex++;
      return;
    }
    _completedLoops++;
    if (_completedLoops >= config.loops) {
      _finished = true;
      return;
    }
    _segmentIndex = 0;
  }

  RoutePoint _applyNaturalPathVariation(RoutePoint basePoint, double bearing) {
    if (!config.naturalPath || config.pathAmplitude <= 0) {
      _currentPathOffsetMeters = 0;
      _targetPathOffsetMeters = 0;
      return basePoint;
    }
    final amplitude = config.pathAmplitude;
    if ((_targetPathOffsetMeters - _currentPathOffsetMeters).abs() <=
            _pathSettleEpsilon ||
        _random.nextDouble() < 0.25) {
      _targetPathOffsetMeters = _randomInRange(amplitude);
    }
    _currentPathOffsetMeters +=
        (_targetPathOffsetMeters - _currentPathOffsetMeters) * 0.18;
    _currentPathOffsetMeters =
        _currentPathOffsetMeters.clamp(-amplitude, amplitude);
    if (_currentPathOffsetMeters.abs() <= _pathSettleEpsilon) return basePoint;
    final offset = _offsetCoordinate(
      basePoint.latitude,
      basePoint.longitude,
      _currentPathOffsetMeters,
      bearing + 90,
    );
    return RoutePoint(
      longitude: offset.longitude,
      latitude: offset.latitude,
      altitude: basePoint.altitude,
    );
  }

  RoutePoint _applyNaturalAltitudeVariation(RoutePoint basePoint) {
    if (!config.naturalAltitude) {
      _currentAltitudeOffsetMeters = 0;
      _targetAltitudeOffsetMeters = 0;
      return basePoint;
    }
    final baseAltitude = config.altitudeBase + config.altitudeHeight / 100;
    final range = config.altitudeRange;
    final probability = config.altitudeProbability.clamp(0.0, 1.0);
    if (range <= 0 || probability <= 0) {
      _currentAltitudeOffsetMeters = 0;
      _targetAltitudeOffsetMeters = 0;
      return RoutePoint(
        longitude: basePoint.longitude,
        latitude: basePoint.latitude,
        altitude: baseAltitude,
      );
    }
    if ((_targetAltitudeOffsetMeters - _currentAltitudeOffsetMeters).abs() <=
            _altitudeSettleEpsilon ||
        _random.nextDouble() < probability) {
      _targetAltitudeOffsetMeters = _randomInRange(range);
    }
    final smoothing = 0.12 + probability * 0.55;
    _currentAltitudeOffsetMeters +=
        (_targetAltitudeOffsetMeters - _currentAltitudeOffsetMeters) *
            smoothing;
    _currentAltitudeOffsetMeters =
        _currentAltitudeOffsetMeters.clamp(-range, range);
    return RoutePoint(
      longitude: basePoint.longitude,
      latitude: basePoint.latitude,
      altitude: baseAltitude + _currentAltitudeOffsetMeters,
    );
  }

  double _randomInRange(double maxAbsoluteValue) =>
      (_random.nextDouble() * 2 - 1) * maxAbsoluteValue;

  double _bearingDegrees(RoutePoint start, RoutePoint end) {
    final startLat = start.latitude * math.pi / 180;
    final endLat = end.latitude * math.pi / 180;
    final deltaLon = (end.longitude - start.longitude) * math.pi / 180;
    final y = math.sin(deltaLon) * math.cos(endLat);
    final x = math.cos(startLat) * math.sin(endLat) -
        math.sin(startLat) * math.cos(endLat) * math.cos(deltaLon);
    var bearing = math.atan2(y, x) * 180 / math.pi;
    if (bearing < 0) bearing += 360;
    return bearing;
  }

  ({double longitude, double latitude}) _offsetCoordinate(
    double latitude,
    double longitude,
    double offsetMeters,
    double bearingDegrees,
  ) {
    final headingRadians = bearingDegrees * math.pi / 180;
    final deltaNorth = offsetMeters * math.cos(headingRadians);
    final deltaEast = offsetMeters * math.sin(headingRadians);
    final latitudeRadians = latitude * math.pi / 180;
    final deltaLatitude = deltaNorth / _earthRadiusMeters * 180 / math.pi;
    final eastWestRadius = _earthRadiusMeters * math.cos(latitudeRadians);
    final deltaLongitude = eastWestRadius.abs() < 0.000001
        ? 0.0
        : deltaEast / eastWestRadius * 180 / math.pi;
    return (
      longitude: longitude + deltaLongitude,
      latitude: latitude + deltaLatitude,
    );
  }
}

class _PointPlacement {
  const _PointPlacement(
      this.distance, this.point, this.sequence, this.original);

  final double distance;
  final RoutePoint point;
  final int sequence;
  final bool original;
}
