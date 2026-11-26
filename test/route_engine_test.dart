import 'package:flutter_test/flutter_test.dart';

import 'package:schoolrun_flutter/models.dart';
import 'package:schoolrun_flutter/route_engine.dart';

void main() {
  final route = [
    const RoutePoint(longitude: 117.0, latitude: 36.0),
    const RoutePoint(longitude: 117.001, latitude: 36.0),
    const RoutePoint(longitude: 117.002, latitude: 36.001),
  ];

  test('calculates route distance and inserts points in route order', () {
    expect(totalDistanceMeters(route), greaterThan(100));
    final expanded = insertEvenlySpacedPoints(route, 4);
    expect(expanded, hasLength(7));
    expect(expanded.first.longitude, route.first.longitude);
    expect(expanded.last.latitude, route.last.latitude);
  });

  test('removes interior points while preserving endpoints', () {
    final expanded = insertEvenlySpacedPoints(route, 8);
    final reduced = removeEvenlySpacedNonKeyPoints(expanded, 3);
    expect(reduced.first.longitude, route.first.longitude);
    expect(reduced.last.latitude, route.last.latitude);
    expect(reduced.length, lessThan(expanded.length));
  });

  test('simulation advances and finishes after configured loops', () {
    final definition = RouteDefinition(
      id: 'test',
      name: 'test route',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      points: route,
    );
    final engine = RouteSimulationEngine(definition,
        const SimulationConfig(speed: 30, loops: 1, tickMillis: 1000));
    var frame = engine.next();
    for (var index = 0; index < 20 && !frame.finished; index++) {
      frame = engine.next();
    }
    expect(frame.finished, isTrue);
    expect(frame.progress, 1);
  });

  test('simulation applies natural speed, path and altitude variation', () {
    final definition = RouteDefinition(
      id: 'natural',
      name: 'natural route',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      points: route,
    );
    final engine = RouteSimulationEngine(
      definition,
      const SimulationConfig(
        speed: 30,
        loops: 1,
        tickMillis: 1000,
        dynamicIntensity: true,
        naturalPath: true,
        naturalAltitude: true,
      ),
    );
    final frame = engine.next();
    expect(frame.point.altitude, isNot(55));
  });

  test('step-linked simulation advances by the configured step ratio', () {
    final definition = RouteDefinition(
      id: 'steps',
      name: 'step route',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      points: route,
    );
    final engine = RouteSimulationEngine(
      definition,
      const SimulationConfig(
        loops: 1,
        stepsPerMeter: 2,
        linkRatio: 1,
      ),
    );
    final frame = engine.nextForSteps(20);
    expect(frame.progress, greaterThan(0));
    expect(frame.point.longitude, greaterThan(route.first.longitude));
  });
}
