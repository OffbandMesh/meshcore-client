import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

// #767 (A1 of #755): the real connector, over its real TCP path, against a
// radio. Today the only radio a test can stand up never answers, so the
// handshake times out and nothing past "connected" can be exercised.
void main() {
  late OffbandDatabase db;
  late MeshCoreConnector connector;
  late ServerSocket radio;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    connector = MeshCoreConnector();
    radio = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    radio.listen((socket) => socket.listen((_) {}));
  });

  tearDown(() async {
    await connector.disconnect();
    await radio.close();
    BlobStore.clearTestOverride();
    await db.close();
  });

  test(
    'connects, loads self info, channels and contacts',
    () async {
      await connector.connectTcp(
        host: InternetAddress.loopbackIPv4.address,
        port: radio.port,
      );

      expect(connector.isConnected, isTrue);
      expect(connector.selfName, 'Fake Radio');
      expect(connector.channels.map((c) => c.name), contains('Public'));
      expect(connector.contacts.map((c) => c.name), contains('Alpha'));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
