// Epic #814 T B1: region discovery lifecycle service.
// Uses an injected discoverer function as the seam, so no live connector or
// drift codegen is needed to exercise every state.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/region.dart';
import 'package:meshcore_open/services/region_discovery_service.dart';

void main() {
  final pub = Uint8List(32);
  RegionsReply reply(List<String> names) =>
      RegionsReply(tag: 1, clock: 42, regionNames: names);

  test('success exposes deduped regions in order', () async {
    final svc = RegionDiscoveryService(
      (_, _) async => reply(['oki', 'test', 'oki']),
    );
    await svc.discover(pub);
    expect(svc.status, RegionDiscoveryStatus.success);
    expect(svc.regions, const [Region('oki'), Region('test')]);
    expect(svc.clock, 42);
  });

  test('empty reply surfaces empty, never success', () async {
    final svc = RegionDiscoveryService((_, _) async => reply([]));
    await svc.discover(pub);
    expect(svc.status, RegionDiscoveryStatus.empty);
    expect(svc.regions, isEmpty);
  });

  test('null reply surfaces timeout', () async {
    final svc = RegionDiscoveryService((_, _) async => null);
    await svc.discover(pub);
    expect(svc.status, RegionDiscoveryStatus.timeout);
  });

  test('a thrown error (e.g. unsupported firmware) surfaces error', () async {
    final svc = RegionDiscoveryService(
      (_, _) async =>
          throw StateError('firmware does not support region scoping'),
    );
    await svc.discover(pub);
    expect(svc.status, RegionDiscoveryStatus.error);
    expect(svc.errorMessage, contains('region scoping'));
  });

  test(
    'status is loading synchronously and notifies on start + finish',
    () async {
      var notifications = 0;
      final svc = RegionDiscoveryService((_, _) async => reply(['x']));
      svc.addListener(() => notifications++);
      final future = svc.discover(pub);
      expect(svc.status, RegionDiscoveryStatus.loading);
      await future;
      expect(svc.status, RegionDiscoveryStatus.success);
      expect(notifications, greaterThanOrEqualTo(2));
    },
  );

  test('a second discover while loading is ignored', () async {
    var calls = 0;
    final svc = RegionDiscoveryService((_, _) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return reply(['a']);
    });
    final first = svc.discover(pub);
    await svc.discover(pub); // no-op while the first is in flight
    await first;
    expect(calls, 1);
  });

  test('reset returns to idle', () async {
    final svc = RegionDiscoveryService((_, _) async => reply(['a']));
    await svc.discover(pub);
    svc.reset();
    expect(svc.status, RegionDiscoveryStatus.idle);
    expect(svc.regions, isEmpty);
  });

  test('does not notify after dispose (screen popped mid-discovery)', () async {
    final gate = Completer<RegionsReply?>();
    final svc = RegionDiscoveryService((_, _) => gate.future);
    final future = svc.discover(pub);
    svc.dispose();
    gate.complete(reply(['a']));
    await future; // must complete without notifying the disposed notifier
  });
}
