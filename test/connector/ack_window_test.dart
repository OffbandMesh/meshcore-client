// #316: the ACK window was smaller than the median round trip.
//
// Upload OB-ZRNBY (2026-11-27) carries 24 completed round trips as measured by
// the radio: median 6771 ms, 90th percentile 12394 ms, against windows this
// code armed with a median of 4884 ms. Over half of all ACKs arrived after the
// attempt that earned them had timed out, and 83 DMs cost 311 transmissions.
//
// The owner ruled the 90th percentile rounded up, 12.5 s, with three attempts
// rather than five.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/models/app_settings.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MeshCoreConnector connector;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    connector = MeshCoreConnector();
  });

  group('the ACK window never drops below the measured 90th percentile', () {
    // 12500 is written as a literal on purpose. The owner ruled this number
    // from the OB-ZRNBY distribution, so a test that read it back off the
    // constant would keep passing if someone quietly changed the constant.
    test('the floor is the ruled 12.5 s', () {
      expect(MessageRetryService.minAckWindowMs, equals(12500));
    });

    // The airtime formula is deliberately NOT floored. It also feeds
    // calculateCliTimeout, and flooring it there added 11.5 s to every repeater
    // CLI command, which is a separate surface with its own budget arithmetic
    // and its own tests (#530/#533). These are the small values the field
    // capture armed, against measured round trips of 3.1 s to 16.3 s.
    test(
      'the formula itself is left alone, so the CLI budget is untouched',
      () {
        expect(
          connector.calculateTimeout(pathLength: -1, messageBytes: 7),
          lessThan(12500),
          reason: 'about 1.3 s for a flood',
        );
        expect(
          connector.calculateTimeout(pathLength: 0, messageBytes: 7),
          lessThan(12500),
          reason: 'about 1.05 s for a zero-hop direct send',
        );
      },
    );

    test('a long path still exceeds the floor: it is a minimum, not a cap', () {
      expect(
        connector.calculateTimeout(pathLength: 30, messageBytes: 100),
        greaterThan(12500),
      );
    });
  });

  group('three attempts, not five (#316)', () {
    test('the retry service defaults to 3', () {
      expect(MessageRetryService().maxRetries, equals(3));
    });

    test(
      'settings default to 3, and so does a stored blob without the key',
      () {
        expect(AppSettings().maxMessageRetries, equals(3));
        expect(AppSettings.fromJson(const {}).maxMessageRetries, equals(3));
      },
    );

    test('every attempt keeps a distinct ACK hash, unlike five', () {
      // The firmware masks `attempt & 3`, so attempt 4 reused attempt 0's hash
      // and the first and last attempts were indistinguishable. Three attempts
      // cannot collide.
      final senderKey = Uint8List.fromList(
        List<int>.generate(32, (i) => i + 1),
      );
      final hashes = List.generate(
        3,
        (i) => MessageRetryService.computeExpectedAckHash(
          1700000000,
          i,
          'Dm test',
          senderKey,
        ),
      );
      expect(hashes.toSet().length, equals(3));

      // And the collision five attempts had, shown rather than asserted from
      // memory: attempt 4 masks to the same value as attempt 0.
      expect(
        MessageRetryService.computeExpectedAckHash(
          1700000000,
          4,
          'Dm test',
          senderKey,
        ),
        equals(hashes.first),
      );
    });
  });
}
