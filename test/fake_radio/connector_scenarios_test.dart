import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/helpers/remote_radio_commands.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/message.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/repeater_command_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_radio/fake_radio.dart';
import '../support/fake_radio/fake_radio_adapters.dart';
import '../support/fake_radio/fake_radio_codes.dart';
import '../support/fake_radio/fake_radio_profile.dart';
import '../support/fake_radio/fake_radio_seed.dart';
import '../support/fake_radio/fake_remote_node.dart';

// #778 (C1 of #755): the app's real connector, retry service and repeater
// command service against the fake radio, under both firmware profiles.

const _remoteTypes = {
  'repeater': fwAdvTypeRepeater,
  'room server': fwAdvTypeRoom,
  'sensor': fwAdvTypeSensor,
};

void main() {
  // The connector starts store reloads it doesn't await (a SELF_INFO after
  // refreshDeviceInfo triggers one); they can outlive a test, so each test's
  // in-memory database stays open until the file is done.
  final databases = <OffbandDatabase>[];
  tearDownAll(() async {
    for (final d in databases) {
      await d.close();
    }
  });

  for (final profileFor in [FakeRadioProfile.offband, FakeRadioProfile.stock]) {
    final profileName = profileFor().name;

    group('$profileName companion', () {
      late OffbandDatabase db;
      late MeshCoreConnector connector;
      late FakeRadio radio;
      late FakeRadioInProcess link;
      final nodes = <String, FakeRemoteNode>{};

      setUp(() async {
        SharedPreferences.setMockInitialValues({});
        PrefsManager.reset();
        await PrefsManager.initialize();
        db = OffbandDatabase(NativeDatabase.memory());
        databases.add(db);
        BlobStore.overrideForTest(BlobStore(db));
        connector = MeshCoreConnector()
          ..initialize(
            retryService: MessageRetryService(),
            pathHistoryService: PathHistoryService(StorageService()),
          );
        radio = FakeRadio(
          profile: profileFor(),
          seed: FakeRadioSeed(
            contacts: [FakeContact.keyed(0x11, 'Alpha')],
            channels: [FakeChannel(index: 0, name: 'Public')],
          ),
        )..ackDelay = const Duration(milliseconds: 500);
        var key = 0x51;
        _remoteTypes.forEach((label, type) {
          nodes[label] = radio.addRemoteNode(
            FakeRemoteNode(
              contact: FakeContact.keyed(key++, label, type: type),
              replyDelay: const Duration(milliseconds: 500),
            ),
          );
        });
        link = await FakeRadioInProcess.connect(connector, radio);
        await _until(
          radio,
          () => connector.contacts.length == 1 + _remoteTypes.length,
          'contacts',
        );
      });

      tearDown(() async {
        await link.close();
        await connector.disconnect();
      });

      Contact contact(String name) =>
          connector.contacts.firstWhere((c) => c.name == name);

      test('connect: identity, channels and the firmware it reports', () {
        expect(connector.selfName, 'Fake Radio');
        expect(connector.channels.map((c) => c.name), contains('Public'));
        if (radio.profile.offband) {
          expect(connector.supportsOffbandBlock, isTrue);
          expect(connector.offbandCaps, radio.profile.offbandCaps);
        } else {
          expect(connector.supportsOffbandBlock, isFalse);
          expect(connector.offbandCaps, isNull);
          // No Offband feature offered means no Offband command sent.
          expect(
            radio.received.where(
              (f) => f[0] >= fwOffbandConfig && f[0] <= 0xCF,
            ),
            isEmpty,
          );
        }
      });

      test('DM: sent, then delivered when the ACK comes back', () async {
        final alpha = contact('Alpha');
        await connector.sendMessage(alpha, 'hello mesh');
        await _until(
          radio,
          () => connector
              .getMessages(alpha)
              .any(
                (m) =>
                    m.text == 'hello mesh' &&
                    m.status == MessageStatus.delivered,
              ),
          'delivered',
        );
        expect(radio.sentDirect.single.text, 'hello mesh');
      });

      test(
        'DM: a lost ACK is retried, then delivered',
        () async {
          radio.acksToDrop = 1;
          final alpha = contact('Alpha');
          await connector.sendMessage(alpha, 'second try');
          await _until(
            radio,
            () => connector
                .getMessages(alpha)
                .any(
                  (m) =>
                      m.text == 'second try' &&
                      m.status == MessageStatus.delivered,
                ),
            'delivered after a retry',
            limit: const Duration(seconds: 90),
          );
          final sends = radio.sentDirect.where((s) => s.text == 'second try');
          expect(sends.length, greaterThanOrEqualTo(2));
          expect(sends.first.attempt, 0);
          expect(sends.last.attempt, greaterThan(0));
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test('channel send reaches the radio', () async {
        final public = connector.channels.firstWhere((c) => c.name == 'Public');
        await connector.sendChannelMessage(public, 'hi all');
        await _until(
          radio,
          () => radio.sentChannel.any((s) => s.text == 'hi all'),
          'channel send',
        );
        expect(radio.sentChannel.single.index, 0);
      });

      test('Companion preset (#647): radio, TX power, path hash', () async {
        // The OKI 500 kHz test preset with a 2-byte path hash (mode 1), sent
        // the way settings_screen.dart applies a preset.
        await connector.sendFrame(
          buildSetRadioParamsFrame(909750, 500000, 10, 5),
        );
        await connector.sendFrame(buildSetRadioTxPowerFrame(20));
        await connector.setPathHashMode(1);
        await connector.refreshDeviceInfo();
        await _until(
          radio,
          () =>
              connector.currentFreqHz == 909750 &&
              connector.pathHashByteWidth == 2,
          'settings reported back',
        );
        expect(connector.currentBwHz, 500000);
        expect(connector.currentSf, 10);
        expect(connector.currentCr, 5);
        expect(connector.currentTxPower, 20);
        expect(
          [radio.freqKhz, radio.bwHz, radio.sf, radio.pathHashMode],
          [909750, 500000, 10, 1],
        );
      });

      for (final label in _remoteTypes.keys) {
        group('remote preset on a $label', () {
          Future<List<String>> apply({required bool temporary}) async {
            final node = nodes[label]!;
            final target = contact(label);
            await connector.sendFrame(
              buildSendLoginFrame(target.publicKey, node.adminPassword),
            );
            await _until(radio, () => radio.hasAdminSession(node), 'login');
            // Built as repeater_settings_screen.dart builds a preset save.
            final pending = [
              temporary
                  ? tempRadioCommand('909.750', 500000, 10, 5, 60)
                  : setRadioCommand('909.750', 500000, 10, 5),
              'set tx 20',
              if (sendsPresetPathHash(
                temporaryRadio: temporary,
                pathHashFromPreset: true,
              ))
                setPathHashModeCommand(1),
            ];
            final service = RepeaterCommandService(connector);
            addTearDown(service.dispose);
            // Wired as repeater_settings_screen.dart wires it: CLI replies
            // from this node's key prefix go to the command service.
            final sub = connector.receivedFrames.listen((frame) {
              if (frame.isEmpty ||
                  (frame[0] != respCodeContactMsgRecv &&
                      frame[0] != respCodeContactMsgRecvV3)) {
                return;
              }
              final parsed = parseContactMessageText(frame);
              if (parsed == null) return;
              for (var i = 0; i < 6; i++) {
                if (parsed.senderPrefix[i] != target.publicKey[i]) return;
              }
              service.handleResponse(target, parsed.text);
            });
            addTearDown(sub.cancel);
            final replies = <String>[];
            for (final command in withRetuneLast(pending, isRetuneCommand)) {
              replies.add(
                await _pump(
                  radio,
                  service.sendCommand(target, command, retries: 1),
                ),
              );
            }
            return replies;
          }

          test('saved: set radio, tx, path hash; reboot to apply', () async {
            final replies = await apply(temporary: false);
            expect(replies, [
              contains('OK - reboot to apply'),
              contains('OK'),
              contains('OK'),
            ]);
            final node = nodes[label]!;
            expect(
              [node.freqMhz, node.bwKhz, node.sf, node.cr],
              [909.75, 500.0, 10, 5],
            );
            expect(node.pathHashMode, 1);
            expect(node.txPowerDbm, 20);
            // #748: no error text on a good save...
            expect(replies.where((r) => r.contains('Error')), isEmpty);
          });

          test('a bad value comes back as the firmware error (#748)', () async {
            final node = nodes[label]!;
            final target = contact(label);
            await connector.sendFrame(
              buildSendLoginFrame(target.publicKey, node.adminPassword),
            );
            await _until(radio, () => radio.hasAdminSession(node), 'login');
            final service = RepeaterCommandService(connector);
            addTearDown(service.dispose);
            final sub = connector.receivedFrames.listen((frame) {
              final parsed =
                  frame.isNotEmpty &&
                      (frame[0] == respCodeContactMsgRecv ||
                          frame[0] == respCodeContactMsgRecvV3)
                  ? parseContactMessageText(frame)
                  : null;
              if (parsed != null) service.handleResponse(target, parsed.text);
            });
            addTearDown(sub.cancel);
            // ...and the firmware's error text when the save is refused.
            final reply = await _pump(
              radio,
              service.sendCommand(
                target,
                setRadioCommand('909.750', 600000, 10, 5),
                retries: 1,
              ),
            );
            expect(reply, contains('Error, invalid radio params'));
            expect(node.freqMhz, 910.525);
          });

          test('temporary: tempradio goes last, path hash held back', () async {
            final replies = await apply(temporary: true);
            final node = nodes[label]!;
            expect(node.commands, [
              'set tx 20',
              'tempradio 909.750,500.0,10,5,60',
            ]);
            expect(replies.last, contains('OK - temp params for 60 mins'));
            expect(node.pathHashMode, 0); // held back (#735)
            expect(node.freqMhz, 910.525); // saved settings untouched
            radio.clock.advance(const Duration(seconds: 2));
            expect(node.tempRadio?.freqMhz, 909.75);
          });
        });
      }
    });
  }
}

/// Waits for [done], advancing the fake radio's clock as real time passes so
/// ACKs and remote replies arrive.
Future<void> _until(
  FakeRadio radio,
  bool Function() done,
  String what, {
  Duration limit = const Duration(seconds: 20),
}) async {
  final sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > limit) fail('timed out waiting for $what');
    radio.clock.advance(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Awaits [future] while advancing the fake clock, so its reply can arrive.
Future<T> _pump<T>(FakeRadio radio, Future<T> future) async {
  var done = false;
  late T value;
  Object? error;
  unawaited(
    future.then(
      (v) {
        value = v;
        done = true;
      },
      onError: (Object e) {
        error = e;
        done = true;
      },
    ),
  );
  await _until(radio, () => done, 'reply');
  if (error != null) throw error!;
  return value;
}
