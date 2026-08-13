// #578 (epic #568): node identity export/import and the auto-add hop limit.
//
// The identity commands are behind firmware build flags, so a device can
// legitimately answer RESP_CODE_DISABLED. These tests pin that "this radio was
// built without the feature" stays distinguishable from "that request failed",
// because the export UI has to degrade rather than offer a retry that can never
// succeed.
//
// No key material here is real.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List fakeIdentity([int fill = 0x11]) =>
    Uint8List.fromList(List<int>.filled(privateKeySize, fill));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('frame construction', () {
    test('the export request is a bare one-byte command', () {
      expect(buildExportPrivateKeyFrame(), [cmdExportPrivateKey]);
    });

    test('the import request carries the command then 64 key bytes', () {
      final frame = buildImportPrivateKeyFrame(fakeIdentity(0xAB));

      // Firmware requires len >= 65 before it will even parse the command.
      expect(frame, hasLength(1 + privateKeySize));
      expect(frame[0], cmdImportPrivateKey);
      expect(frame.sublist(1), everyElement(0xAB));
    });

    test(
      'an identity of the wrong size is refused before it reaches the wire',
      () {
        expect(
          () => buildImportPrivateKeyFrame(Uint8List(32)),
          throwsA(isA<ArgumentError>()),
        );
      },
    );
  });

  group('auto-add hop limit', () {
    test(
      'omitting the limit keeps the frame two bytes, as firmware expects',
      () {
        // Firmware applies the third byte only when present, so a two-byte frame
        // leaves the device's existing limit alone. Older behavior must not
        // change just because the parameter now exists.
        final frame = buildSetAutoAddConfigFrame(
          autoAddChat: true,
          autoAddRepeater: false,
          autoAddRoomServer: false,
          autoAddSensor: false,
          overwriteOldest: false,
        );

        expect(frame, hasLength(2));
        expect(frame[0], cmdSetAutoAddConfig);
        expect(frame[1], autoAddChatFlag);
      },
    );

    test('supplying the limit appends it as a third byte', () {
      final frame = buildSetAutoAddConfigFrame(
        autoAddChat: false,
        autoAddRepeater: false,
        autoAddRoomServer: false,
        autoAddSensor: false,
        overwriteOldest: true,
        maxHops: 5,
      );

      expect(frame, hasLength(3));
      expect(frame[1], autoAddOverwriteOldestFlag);
      expect(frame[2], 5);
    });

    test('the limit is clamped to what firmware will accept', () {
      final frame = buildSetAutoAddConfigFrame(
        autoAddChat: false,
        autoAddRepeater: false,
        autoAddRoomServer: false,
        autoAddSensor: false,
        overwriteOldest: false,
        maxHops: 250,
      );

      expect(frame[2], autoAddMaxHopsLimit);
    });
  });

  group('connector', () {
    late MeshCoreConnector connector;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      PrefsManager.reset();
      await PrefsManager.initialize();
      connector = MeshCoreConnector();
    });

    test(
      'exporting while disconnected reports no reply, not a refusal',
      () async {
        final result = await connector.exportPrivateKey();

        expect(result.outcome, IdentityTransfer.noReply);
        expect(result.identity, isNull);
      },
    );

    test('importing while disconnected reports no reply', () async {
      expect(
        await connector.importPrivateKey(fakeIdentity()),
        IdentityTransfer.noReply,
      );
    });

    test('importing a wrongly sized identity throws before any I/O', () async {
      expect(
        () => connector.importPrivateKey(Uint8List(10)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the hop limit defaults to no limit until a device reports one', () {
      expect(connector.autoAddMaxHops, 0);
    });

    test('a three-byte auto-add reply sets the hop limit', () {
      connector.handleFrameForTest([
        respCodeAutoAddConfig,
        autoAddChatFlag | autoAddOverwriteOldestFlag,
        7,
      ]);

      expect(connector.autoAddMaxHops, 7);
      expect(connector.autoAddUsers, isTrue);
      expect(connector.autoAddOverwriteOldest, isTrue);
      expect(connector.autoAddRepeaters, isFalse);
    });

    test(
      'a two-byte auto-add reply from older firmware leaves the limit alone',
      () {
        connector.handleFrameForTest([
          respCodeAutoAddConfig,
          autoAddChatFlag,
          9,
        ]);
        connector.handleFrameForTest([respCodeAutoAddConfig, autoAddChatFlag]);

        expect(connector.autoAddMaxHops, 9);
      },
    );
  });
}
