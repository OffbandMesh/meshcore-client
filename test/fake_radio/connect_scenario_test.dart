import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_radio/fake_radio.dart';
import '../support/fake_radio/fake_radio_adapters.dart';
import '../support/fake_radio/fake_radio_codes.dart';
import '../support/fake_radio/fake_radio_seed.dart';

// #767 (A1 of #755): the real connector against a radio, over both the real
// TCP path and the in-process seam (#768).

FakeRadioSeed _seed() => FakeRadioSeed(
  channels: [FakeChannel(index: 0, name: 'Public')],
  contacts: [
    FakeContact.keyed(0x11, 'Alpha'),
    FakeContact.keyed(0x22, 'Bravo'),
  ],
);

Future<void> _until(bool Function() done, {String? what}) async {
  final sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > const Duration(seconds: 10)) {
      fail('timed out waiting for ${what ?? 'condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

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
  });

  tearDown(() async {
    await connector.disconnect();
    BlobStore.clearTestOverride();
    await db.close();
  });

  Future<void> expectSynced(FakeRadio radio) async {
    expect(connector.isConnected, isTrue);
    expect(connector.selfName, 'Fake Radio');
    await _until(
      () => connector.channels.any((c) => c.name == 'Public'),
      what: 'channels',
    );
    await _until(
      () => connector.contacts.map((c) => c.name).toSet().containsAll({
        'Alpha',
        'Bravo',
      }),
      what: 'contacts',
    );
    // The data came from the radio: the handshake really ran against it.
    final codes = radio.received.map((f) => f[0]).toSet();
    expect(
      codes,
      containsAll([
        fwCmdDeviceQuery,
        fwCmdAppStart,
        fwCmdSetDeviceTime,
        fwCmdGetChannel,
        fwCmdSyncNextMessage,
        fwCmdGetContacts,
      ]),
    );
  }

  test(
    'over TCP: connects, loads self info, channels and contacts',
    () async {
      final radio = FakeRadio(seed: _seed());
      final server = await FakeRadioTcpServer.start(radio);
      addTearDown(server.close);
      await connector.connectTcp(host: server.host, port: server.port);
      await expectSynced(radio);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'in-process: connects, loads self info, channels and contacts',
    () async {
      final radio = FakeRadio(seed: _seed());
      final link = await FakeRadioInProcess.connect(connector, radio);
      addTearDown(link.close);
      await expectSynced(radio);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
