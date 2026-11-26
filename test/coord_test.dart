import 'package:flutter_test/flutter_test.dart';
import 'package:schoolrun_flutter/coord.dart';
import 'package:schoolrun_flutter/models.dart';
import 'package:schoolrun_flutter/route_engine.dart';

void main() {
  test('BD-09 与 WGS-84 往返转换误差在米级', () {
    const bdLng = 116.397428;
    const bdLat = 39.90923;
    final wgs = bd09ToWgs84(bdLng, bdLat);
    // 百度坐标在国内偏移约 500m 量级，转换后不能等于原值。
    expect(
      distanceMeters(
        const RoutePoint(longitude: bdLng, latitude: bdLat),
        RoutePoint(longitude: wgs.longitude, latitude: wgs.latitude),
      ),
      greaterThan(100),
    );
    final back = wgs84ToBd09(wgs.longitude, wgs.latitude);
    expect((back.longitude - bdLng).abs(), lessThan(0.00001));
    expect((back.latitude - bdLat).abs(), lessThan(0.00001));
  });

  test('路线点 JSON 同时写 BD-09 与 WGS-84，并能只按 WGS 反算', () {
    const point = RoutePoint(longitude: 116.397428, latitude: 39.90923);
    final json = point.toJson();
    expect(json['bdLongitude'], 116.397428);
    expect(json['bdLatitude'], 39.90923);
    expect((json['wgsLongitude'] as double), isNot(116.397428));

    final fromWgs = RoutePoint.fromJson({
      'wgsLongitude': json['wgsLongitude'],
      'wgsLatitude': json['wgsLatitude'],
      'altitude': 60,
    });
    expect((fromWgs.longitude - point.longitude).abs(), lessThan(0.00001));
    expect((fromWgs.latitude - point.latitude).abs(), lessThan(0.00001));
    expect(fromWgs.altitude, 60);
  });

  test('关键点判定与减点保留端点', () {
    final points = [
      const RoutePoint(longitude: 116.3970, latitude: 39.9090),
      const RoutePoint(longitude: 116.3972, latitude: 39.9090),
      const RoutePoint(longitude: 116.3974, latitude: 39.9090),
      const RoutePoint(longitude: 116.3976, latitude: 39.9090),
      const RoutePoint(longitude: 116.3978, latitude: 39.9090),
    ];
    expect(countKeyRoutePoints(points), 2);
    expect(countRemovableRoutePoints(points), 3);
    final reduced = removeEvenlySpacedNonKeyPoints(points, 2);
    expect(reduced.length, 3);
    expect(reduced.first.longitude, points.first.longitude);
    expect(reduced.last.longitude, points.last.longitude);
  });

  test('防直角只处理 85°~95°，并保留首尾点', () {
    final points = [
      const RoutePoint(longitude: 116.3970, latitude: 39.9090),
      const RoutePoint(longitude: 116.3970, latitude: 39.9095),
      const RoutePoint(longitude: 116.3975, latitude: 39.9095),
    ];
    final smoothed = smoothRightAngles(points, 3);
    expect(smoothed.length, greaterThan(points.length));
    expect(smoothed.first.longitude, points.first.longitude);
    expect(smoothed.last.longitude, points.last.longitude);

    final straight = [
      const RoutePoint(longitude: 116.3970, latitude: 39.9090),
      const RoutePoint(longitude: 116.3972, latitude: 39.9090),
      const RoutePoint(longitude: 116.3974, latitude: 39.9090),
    ];
    expect(smoothRightAngles(straight, 3).length, straight.length);
  });

  test('模拟引擎：速度 15m/s、1 秒节拍、2 圈后结束', () {
    final route = RouteDefinition(
      id: 'route',
      name: 'test',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      points: const [
        RoutePoint(longitude: 116.3970, latitude: 39.9090),
        RoutePoint(longitude: 116.3980, latitude: 39.9090),
      ],
    );
    final engine = RouteSimulationEngine(
      route,
      const SimulationConfig(
        speed: 15,
        loops: 2,
        dynamicIntensity: false,
        tickMillis: 1000,
      ),
    );
    // 100m 的路线在 15m/s 下需要约 7 帧走完一圈。
    var frames = 0;
    SimulationFrame frame = engine.next();
    while (!frame.finished && frames < 1000) {
      expect(frame.speed, closeTo(15, 0.001));
      frame = engine.next();
      frames++;
    }
    expect(frame.finished, isTrue);
    expect(frames, inInclusiveRange(8, 16));
    expect(frame.progress, 1);
  });

  test('真实步数联动按 linkRatio 累计后才推进一帧', () {
    final route = RouteDefinition(
      id: 'route',
      name: 'test',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      points: const [
        RoutePoint(longitude: 116.3970, latitude: 39.9090),
        RoutePoint(longitude: 116.3980, latitude: 39.9090),
      ],
    );
    final engine = RouteSimulationEngine(
      route,
      const SimulationConfig(
        speed: 15,
        loops: 100,
        tickMillis: 1000,
        linkRatio: 2,
        stepsPerMeter: 1,
      ),
    );
    final before = engine.distanceTraveled;
    engine.nextForSteps(1);
    expect(engine.distanceTraveled, before);
    engine.nextForSteps(1);
    expect(engine.distanceTraveled, greaterThan(before));
  });
}
