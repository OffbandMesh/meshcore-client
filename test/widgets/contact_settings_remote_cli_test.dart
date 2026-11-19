// #1157 (Epic #1155): the contact's Remote CLI switch (flag 0x10) shows only
// when the connected radio honors it: stock 1.18+, or Offband advertising tag
// 0x07. It was shown on every radio, including ones that ignore the flag.

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/connector/offband_capability_advert.dart';
import 'package:meshcore_open/connector/offband_device_ui.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/widgets/contact_settings_dialog.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List deviceInfo({
  required int length,
  required int verCode,
  required String version,
}) {
  final v = ascii.encode(version);
  final f = Uint8List(length);
  f[0] = 13;
  f[1] = verCode;
  f.setRange(60, 60 + v.length, v);
  return f;
}

Uint8List advert(List<int> tags) => Uint8List.fromList([
  cmdOffbandDeviceUi,
  offbandUiInfoGet,
  for (final t in tags) ...[t, 0x00],
]);

final contact = Contact(
  publicKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
  receivedName: 'Peer',
  type: advTypeChat,
  pathLength: 0,
  path: Uint8List(0),
  lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
);

void main() {
  late OffbandDatabase db;
  late MeshCoreConnector connector;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    connector = MeshCoreConnector();
    connector.sendFrameOverrideForTest = (_) {};
    connector.setConnectedForTest();
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  Future<void> openDialog(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MeshCoreConnector>.value(value: connector),
          ChangeNotifierProvider<AppSettingsService>(
            create: (_) => AppSettingsService(),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showContactSettingsDialog(context, contact),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('stock 1.18 radio: the switch shows', (tester) async {
    connector.handleFrameForTest(
      deviceInfo(length: 82, verCode: 14, version: 'v1.18.0'),
    );
    await openDialog(tester);
    expect(find.text('Remote CLI'), findsOneWidget);
  });

  testWidgets('Offband radio advertising 0x07: the switch shows', (
    tester,
  ) async {
    connector.handleFrameForTest(
      deviceInfo(length: 85, verCode: 22, version: '1.8.0-1.18.0'),
    );
    connector.handleFrameForTest(advert([offbandInfoTagCliRemote]));
    await openDialog(tester);
    expect(find.text('Remote CLI'), findsOneWidget);
  });

  testWidgets('Offband radio advertising only 0x06: no switch', (tester) async {
    connector.handleFrameForTest(
      deviceInfo(length: 85, verCode: 22, version: '1.8.0-1.18.0'),
    );
    connector.handleFrameForTest(advert([offbandInfoTagCliLocal]));
    await openDialog(tester);
    expect(find.text('Remote CLI'), findsNothing);
  });

  testWidgets('Offband radio with no advert answer: no switch', (tester) async {
    connector.handleFrameForTest(
      deviceInfo(length: 85, verCode: 22, version: '1.4.0-1.17.0'),
    );
    await openDialog(tester);
    expect(find.text('Remote CLI'), findsNothing);
  });

  testWidgets('stock radio below 1.18: no switch', (tester) async {
    connector.handleFrameForTest(
      deviceInfo(length: 82, verCode: 13, version: 'v1.17.1'),
    );
    await openDialog(tester);
    expect(find.text('Remote CLI'), findsNothing);
  });
}
