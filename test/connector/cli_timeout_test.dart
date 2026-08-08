// #529 (epic #473): a repeater CLI command is a request-execute-reply exchange,
// but its timeout used calculateTimeout, which mirrors the firmware's
// calcDirectTimeoutMillisFor and models ONE-WAY delivery only.
//
// Measured against rpt-01: 27 commands, 12 replies, and 4 of those 12 arrived
// after the 4074 ms window had expired (6.17 s, 8.28 s, 15.52 s, 20.33 s;
// median 2.75 s). The same verb returned in both 2.31 s and 20.33 s. The tail
// is transmit scheduling on both radios, not command execution: on the 20.33 s
// case the repeater stamped its reply ~5 s in and the packet took another ~15 s
// to arrive, and `wifi on N` only sets a deadline before replying. So it is not
// a per-command constant that could be tabulated.
//
// These tests pin the budget's construction and, just as importantly, pin that
// the direct-message ACK path was NOT changed.

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
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

  // With no SELF_INFO parsed there are no radio params, so _estimateAirtimeMs
  // returns its 50 ms fallback and _physicsMaxTimeout(0, 50) is
  // 500 + ((50 * 6) + 250) = 1050. Every expectation below is derived from
  // that, not from a chosen number.
  const fallbackPhysicsMax0Hop = 1050;
  const retrievalBudget = 20000; // _queueSyncTimeoutMs 5000 * (3 retries + 1)

  group('retrieval budget', () {
    test('is derived from the sync constants, not restated', () {
      expect(connector.messageRetrievalBudgetMs, retrievalBudget);
    });
  });

  group('calculateCliTimeout', () {
    test('sums outbound, repeater hold, reply leg and retrieval', () {
      expect(
        connector.calculateCliTimeout(pathLength: 0),
        fallbackPhysicsMax0Hop +
            cliReplyDelayMs +
            fallbackPhysicsMax0Hop +
            retrievalBudget,
      );
    });

    test('is never below the retrieval budget it depends on (#530)', () {
      for (final path in [-1, 0, 1, 2, 5]) {
        expect(
          connector.calculateCliTimeout(pathLength: path),
          greaterThanOrEqualTo(connector.messageRetrievalBudgetMs),
          reason: 'path $path must not expire before the app can fetch a reply',
        );
      }
    });

    test('is always larger than the one-way delivery estimate', () {
      for (final path in [-1, 0, 1, 2, 5]) {
        expect(
          connector.calculateCliTimeout(pathLength: path),
          greaterThan(connector.calculateTimeout(pathLength: path)),
          reason: 'path $path',
        );
      }
    });

    test('covers the slowest round trip actually measured (20.33 s)', () {
      // The observed worst case on the owner's radio. The budget has to clear
      // it even in this test's degraded no-radio-params state, where the
      // physics terms are at their smallest.
      expect(connector.calculateCliTimeout(pathLength: 0), greaterThan(20330));
    });

    test('grows with path length', () {
      final direct = connector.calculateCliTimeout(pathLength: 0);
      final oneHop = connector.calculateCliTimeout(pathLength: 1);
      final twoHop = connector.calculateCliTimeout(pathLength: 2);
      expect(oneHop, greaterThan(direct));
      expect(twoHop, greaterThan(oneHop));
    });
  });

  group('the direct-message ACK path is unchanged', () {
    // Negative test. #529 must not move DM ACK behaviour, which legitimately
    // uses the one-way formula. If this breaks, the fix has leaked.
    test('calculateTimeout still returns the firmware formula', () {
      expect(connector.calculateTimeout(pathLength: 0), fallbackPhysicsMax0Hop);
    });

    test('calculateTimeout does not include the CLI reply delay', () {
      expect(
        connector.calculateTimeout(pathLength: 0),
        lessThan(cliReplyDelayMs + fallbackPhysicsMax0Hop),
      );
    });

    test('calculateTimeout stays well under the retrieval budget', () {
      // Not a requirement, an observation that pins the #530 mismatch: the DM
      // path is allowed to be shorter than retrieval because a DM ACK does not
      // depend on fetching a queued message. If this ever flips, the invariant
      // in calculateCliTimeout needs revisiting rather than silently holding.
      expect(
        connector.calculateTimeout(pathLength: 0),
        lessThan(connector.messageRetrievalBudgetMs),
      );
    });
  });
}
