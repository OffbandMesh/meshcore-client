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
import '../support/fake_radio/fake_radio_profile.dart';
import '../support/fake_radio/fake_radio_seed.dart';

// #767 (A1 of #755): the real connector against a radio, over both the real
// TCP path and the in-process seam (#768), under both firmware profiles
// (#769). Epic A verification (#771) adds the determinism run.

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

  Future<void> freshConnector() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    connector = MeshCoreConnector();
  }

  Future<void> dropConnector() async {
    await connector.disconnect();
    BlobStore.clearTestOverride();
    await db.close();
  }

  setUp(freshConnector);
  tearDown(dropConnector);

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
    // Waited for, not sampled: over TCP a sent frame is only queued, so the
    // closing SET_DEVICE_TIME can land just after the sync data does.
    const handshake = [
      fwCmdDeviceQuery,
      fwCmdAppStart,
      fwCmdSetDeviceTime,
      fwCmdGetChannel,
      fwCmdSyncNextMessage,
      fwCmdGetContacts,
    ];
    await _until(
      () => radio.received.map((f) => f[0]).toSet().containsAll(handshake),
      what: 'the handshake commands at the radio',
    );
    final codes = radio.received.map((f) => f[0]).toSet();
    // What the client concluded about the firmware matches the profile.
    if (radio.profile.offband) {
      expect(connector.offbandCaps, radio.profile.offbandCaps);
      expect(connector.offbandCaps2, radio.profile.offbandCaps2);
    } else {
      expect(connector.offbandCaps, isNull);
      expect(connector.offbandCaps2, isNull);
      expect(codes.where((c) => c >= fwOffbandConfig && c <= 0xCF), isEmpty);
    }
  }

  final profiles = {
    'Offband': FakeRadioProfile.offband,
    'stock': FakeRadioProfile.stock,
  };

  for (final entry in profiles.entries) {
    group(entry.key, () {
      test(
        'over TCP: connects, loads self info, channels and contacts',
        () async {
          final radio = FakeRadio(seed: _seed(), profile: entry.value());
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
          final radio = FakeRadio(seed: _seed(), profile: entry.value());
          final link = await FakeRadioInProcess.connect(connector, radio);
          addTearDown(link.close);
          await expectSynced(radio);
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );
    });
  }

  test(
    'same seed, same result over 20 connects (#771)',
    () async {
      String outcome() => [
        connector.selfName,
        connector.offbandCaps,
        (connector.channels.map((c) => c.name).toList()..sort()).join(','),
        (connector.contacts.map((c) => c.name).toList()..sort()).join(','),
      ].join('|');

      String? first;
      for (var run = 0; run < 20; run++) {
        if (run > 0) {
          await dropConnector();
          await freshConnector();
        }
        final radio = FakeRadio(seed: _seed());
        final link = await FakeRadioInProcess.connect(connector, radio);
        await expectSynced(radio);
        final now = outcome();
        first ??= now;
        expect(now, first, reason: 'run $run differed');
        await link.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
