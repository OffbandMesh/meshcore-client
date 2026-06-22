// Provider wiring lock for the Observer config feature (#64 P1).
//
// main.dart provides the singleton MeshCoreConnector by value and creates
// ObserverConfigService with THAT SAME connector (main.dart:38 -> field -> the
// two providers). This pins the contract the feature depends on: the service is
// reachable through Provider AND shares the live connector, so the Observer
// settings gate (`supported`) reacts to device-info caps. A fresh-connector
// rewire (create: (_) => ObserverConfigService(MeshCoreConnector())) breaks it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/observer_config_client.dart';
import 'package:meshcore_open/services/observer_config_service.dart';

class _CapsConnector extends MeshCoreConnector {
  int? ver;
  int? caps;
  @override
  int? get firmwareVerCode => ver;
  @override
  int? get offbandCaps => caps;
}

void main() {
  testWidgets(
    'ObserverConfigService is provided and shares the live connector',
    (tester) async {
      final connector = _CapsConnector();
      late ObserverConfigService svc;

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<MeshCoreConnector>.value(value: connector),
            ChangeNotifierProvider(
              create: (_) => ObserverConfigService(connector),
            ),
          ],
          child: Builder(
            builder: (context) {
              svc = context.read<ObserverConfigService>();
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      // Unsupported until the shared connector reports a v14+ observer build.
      expect(svc.supported, isFalse);

      connector.ver = ObserverConfigClient.minVerCode;
      connector.caps = ObserverConfigClient.capWifiObserver;

      // The gate flips because the service reads through the SAME connector.
      expect(svc.supported, isTrue);
    },
  );
}
