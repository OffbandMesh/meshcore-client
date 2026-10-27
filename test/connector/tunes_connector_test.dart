// #970, #986, #987: the connector side of tunes and screen settings over 0xC5.
// Pins the gates (no bit, no frame), that state follows only the radio's
// replies, the chunked slot read and save, the one restart a displaced save
// gets, and that refusals land on the right surface.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/offband_device_ui.dart';
import 'package:meshcore_open/connector/offband_tones.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// RESP_CODE_DEVICE_INFO from an Offband radio, caps byte 2 at offset 84.
List<int> deviceInfo({required int caps2}) {
  final v = ascii.encode('1.5.0-1.17.0');
  final f = Uint8List(85);
  f[0] = 13;
  f[1] = 22;
  f.setRange(60, 60 + v.length, v);
  f[84] = caps2;
  return f;
}

void main() {
  late OffbandDatabase db;
  late MeshCoreConnector connector;
  late List<List<int>> sent;

  /// Replies the fake radio sends for each frame the client writes.
  List<List<int>> Function(List<int> frame)? radio;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    sent = [];
    radio = null;
    connector = MeshCoreConnector();
    connector.sendFrameOverrideForTest = (data) {
      final frame = data.toList();
      sent.add(frame);
      final replies = radio?.call(frame) ?? const [];
      // Replies arrive after the write returns, as they would over a link.
      scheduleMicrotask(() {
        for (final r in replies) {
          connector.handleFrameForTest(r);
        }
      });
    };
    connector.setConnectedForTest();
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  bool sentSub(Set<int> subs) => sent.any(
    (f) => f.length >= 2 && f[0] == cmdOffbandDeviceUi && subs.contains(f[1]),
  );

  group('gates', () {
    test('no 0x10: no tune frame of any kind', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x01));
      sent.clear();
      await connector.requestEventTones();
      await connector.setEventTone(ToneEvent.dm, 1);
      await connector.requestTuneSlots();
      expect(await connector.playTune(1), isNull);
      expect(await connector.readTuneSlot(0), isNull);
      expect(await connector.saveTuneSlot(0, 'x:d=4:c'), isFalse);
      expect(sentSub({0x09, 0x0A, 0x0F, 0x10, 0x11, 0x12}), isFalse);
    });

    test('no 0x40: no screen frame, and none on connect', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x10));
      await connector.setTimeZone(2);
      await connector.setScreenOff(60);
      expect(sentSub({0x13, 0x14, 0x15, 0x16, 0x17}), isFalse);
    });

    test('with 0x40 the settings are read on connect', () {
      connector.handleFrameForTest(deviceInfo(caps2: 0x40));
      expect(sent, contains(equals([0xC5, 0x13])));
    });
  });

  group('event tones', () {
    test('reads all six, and a write shows only once confirmed', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x10));
      sent.clear();
      await connector.requestEventTones();
      expect(sent, [
        for (var ev = 0; ev < 6; ev++) [0xC5, 0x0F, ev],
      ]);

      await connector.setEventTone(ToneEvent.room, 8);
      expect(connector.eventTone(ToneEvent.room), isNull);
      connector.handleFrameForTest([0xC5, 0x10, 2, 8, 8]);
      expect(connector.eventTone(ToneEvent.room)!.stored, 8);
    });

    test('a refused event tone is the event tone surface\'s', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x10));
      await connector.setEventTone(ToneEvent.dm, 9);
      connector.handleFrameForTest([0xC5, 0x7F, 0x05]);
      expect(connector.deviceUiErrorSurface, DeviceUiSurface.eventTone);
      expect(connector.eventTone(ToneEvent.dm), isNull);
    });
  });

  group('preview', () {
    test('returns the radio\'s result', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x10));
      radio = (f) => [
        [0xC5, 0x11, f[2], 2],
      ];
      expect(await connector.playTune(3), TunePlayResult.soundOff);
    });

    test('a refused id comes back null and is shown', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x10));
      radio = (f) => [
        [0xC5, 0x7F, 0x05],
      ];
      expect(await connector.playTune(12), isNull);
      expect(connector.deviceUiErrorSurface, DeviceUiSurface.tunePlay);
    });
  });

  group('slot read', () {
    test('follows more until the radio says done', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x10));
      final tune = ascii.encode('Mario:d=4,o=5,b=100:16e6,16e6,32p');
      radio = (f) {
        final offset = f[3];
        final end = (offset + 10).clamp(0, tune.length);
        return [
          [
            0xC5,
            0x12,
            f[2],
            offset,
            end < tune.length ? 1 : 0,
            ...tune.sublist(offset, end),
          ],
        ];
      };
      final progress = <int>[];
      final text = await connector.readTuneSlot(1, onProgress: progress.add);
      expect(text, ascii.decode(tune));
      expect(progress.last, tune.length);
      expect(connector.tuneSlotTransferActive, isFalse);
    });

    test('an empty slot reads as empty text', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x10));
      radio = (f) => [
        [0xC5, 0x12, f[2], 0, 0],
      ];
      expect(await connector.readTuneSlot(4), '');
    });

    test('a chunk that says more but carries nothing stops the read', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x10));
      radio = (f) => [
        [0xC5, 0x12, f[2], f[3], 1],
      ];
      expect(await connector.readTuneSlot(0), isNull);
      expect(connector.deviceUiErrorSurface, DeviceUiSurface.tuneSlot);
    });
  });

  group('slot save', () {
    /// A radio that assembles pushes the way firmware does, optionally
    /// displacing the first push after its first chunk.
    List<List<int>> Function(List<int>) assembler({bool displaceOnce = false}) {
      var held = <int>[];
      var displaced = !displaceOnce;
      return (f) {
        if (f[1] == 0x09) {
          return [
            [0xC5, 0x09, f[2], held.length, ...ascii.encode('Mario')],
          ];
        }
        if (f[1] != 0x0A) return const [];
        final offset = f[3];
        final more = f[4] != 0;
        if (offset == 0) held = [];
        if (offset != held.length) {
          return [
            [0xC5, 0x7F, 0x07, held.length],
          ];
        }
        held.addAll(f.sublist(5));
        if (!displaced && more) {
          displaced = true;
          held = [];
          return [
            [0xC5, 0x7F, 0x07, 0],
          ];
        }
        return [
          [0xC5, 0x0A, f[2], more ? held.length : 0],
        ];
      };
    }

    test('sends chunks with running offsets and commits on the last', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x10));
      radio = assembler();
      sent.clear();
      final tune = 'Mario:d=4,o=5,b=100:${List.filled(40, '8e6').join(',')}';
      final ok = await connector.saveTuneSlot(0, tune);
      expect(ok, isTrue);

      final pushes = sent.where((f) => f[1] == 0x0A).toList();
      expect(pushes.length, greaterThan(1));
      var expectOffset = 0;
      for (final p in pushes) {
        expect(p[3], expectOffset);
        expectOffset += p.length - 5;
      }
      expect(pushes.last[4], 0);
      expect(
        pushes.sublist(0, pushes.length - 1).every((p) => p[4] == 1),
        isTrue,
      );
      // Chunks respect the transport's frame budget.
      expect(
        pushes.every((p) => p.length <= connector.effectiveMaxFrameSize),
        isTrue,
      );
      // Re-read after the commit, and the list shows the radio's answer.
      expect(sent.last, equals([0xC5, 0x09, 0]));
      expect(connector.tuneSlots[0]!.length, tune.length);
    });

    test('a displaced push restarts from 0 once and succeeds', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x10));
      radio = assembler(displaceOnce: true);
      final tune = 'Mario:d=4,o=5,b=100:${List.filled(40, '8e6').join(',')}';
      expect(await connector.saveTuneSlot(0, tune), isTrue);
      final restarts = sent.where((f) => f[1] == 0x0A && f[3] == 0).length;
      expect(restarts, 2);
      expect(connector.deviceUiError, isNull);
    });

    test('displaced twice: stops and says so', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x10));
      radio = (f) => f[1] == 0x0A
          ? [
              [0xC5, 0x7F, 0x07, 0],
            ]
          : const [];
      final tune = 'Mario:d=4,o=5,b=100:${List.filled(40, '8e6').join(',')}';
      expect(await connector.saveTuneSlot(0, tune), isFalse);
      expect(sent.where((f) => f[1] == 0x0A).length, 2);
      expect(connector.deviceUiErrorSurface, DeviceUiSurface.tuneSlot);
      expect(connector.deviceUiError, ButtonConfigError.slotOffset.message);
    });

    test('clearing sends the one empty commit', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x10));
      radio = assembler();
      sent.clear();
      expect(await connector.saveTuneSlot(3, ''), isTrue);
      expect(sent.first, equals([0xC5, 0x0A, 3, 0, 0]));
    });

    test('a final reply that is not 0 is not a commit', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x10));
      radio = (f) => f[1] == 0x0A
          ? [
              [0xC5, 0x0A, f[2], 5],
            ]
          : const [];
      expect(await connector.saveTuneSlot(0, 'x:d=4:c'), isFalse);
      expect(connector.deviceUiErrorSurface, DeviceUiSurface.tuneSlot);
    });

    test('no preview is sent while a slot transfer is running', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x10));
      sent.clear();
      final read = connector.readTuneSlot(0);
      await Future<void>.delayed(Duration.zero);
      expect(connector.tuneSlotTransferActive, isTrue);
      expect(await connector.playTune(3), isNull);
      expect(sentSub({0x11}), isFalse);
      connector.handleFrameForTest([0xC5, 0x12, 0, 0, 0]);
      expect(await read, '');
    });

    test('a tune over 240 characters is never sent', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x10));
      sent.clear();
      expect(await connector.saveTuneSlot(0, 'x:${'c' * 240}'), isFalse);
      expect(sent, isEmpty);
    });
  });

  group('screen settings', () {
    List<int> reply(int sub, {int tz = 2}) => [
      0xC5, sub, 0, 1, 60, 0, 60, 0, tz, 0x36, 0x10, 0x36, 0x10, 0, //
    ];

    test('state follows the re-read reply', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x40));
      await connector.setTimeZone(9);
      expect(sent.last, equals([0xC5, 0x16, 9]));
      connector.handleFrameForTest(reply(0x16, tz: 9));
      expect(connector.screenSettings!.timeZone, 9);
    });

    test('a battery refusal keeps the radio\'s reason', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x40));
      connector.handleFrameForTest(reply(0x13));
      await connector.setBatteryFull(pin: true);
      connector.handleFrameForTest([0xC5, 0x7F, 0x09]);
      expect(connector.deviceUiErrorSurface, DeviceUiSurface.screenSettings);
      expect(
        connector.deviceUiError,
        ButtonConfigError.batteryNotCharged.message,
      );
      expect(connector.screenSettings!.batteryFullStored, 4150);
    });

    test('a new radio does not inherit the previous one\'s settings', () {
      connector.handleFrameForTest(deviceInfo(caps2: 0x50));
      connector.handleFrameForTest(reply(0x13));
      connector.handleFrameForTest([0xC5, 0x0F, 0, 1, 1]);
      connector.handleFrameForTest(deviceInfo(caps2: 0x50));
      expect(connector.screenSettings, isNull);
      expect(connector.eventTone(ToneEvent.dm), isNull);
    });
  });
}
