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
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/services/timeout_prediction_service.dart';
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

  group('flood is a single firmware value, not a range (#533)', () {
    // The flood branch used to be written as "trust ML, only enforce the
    // firmware formula as floor". It never did that: _physicsMinTimeout and
    // _physicsMaxTimeout return the identical expression for pathLength < 0,
    // so a clamp between them discards any prediction. The branch was removed
    // and the constraint stated instead, with behaviour unchanged.
    //
    // These tests pin the equality the simplification depends on. If a future
    // change makes the flood floor and ceiling differ, the removed branch would
    // no longer have been equivalent, and this fails loudly rather than
    // silently altering flood timeouts.

    // firmware calcFloodTimeoutMillisFor: SEND_TIMEOUT_BASE_MILLIS 500 +
    // FLOOD_SEND_TIMEOUT_FACTOR 16 * airtime, with the 50 ms fallback airtime.
    const floodFirmwareValue = 500 + (16 * 50); // 1300

    test('flood returns the firmware formula exactly', () {
      expect(connector.calculateTimeout(pathLength: -1), floodFirmwareValue);
    });

    test('flood does not scale with hop count the way direct does', () {
      // Direct grows per hop; flood has no hop term at all.
      expect(
        connector.calculateTimeout(pathLength: -1),
        isNot(connector.calculateTimeout(pathLength: 0)),
      );
      expect(
        connector.calculateTimeout(pathLength: 1),
        greaterThan(connector.calculateTimeout(pathLength: 0)),
      );
    });

    test('the CLI budget still covers flood through both of its legs', () {
      // calculateCliTimeout takes the flood branch in the outbound term and in
      // the reply term, so no flood-specific handling is needed there.
      expect(
        connector.calculateCliTimeout(pathLength: -1),
        floodFirmwareValue +
            cliReplyDelayMs +
            floodFirmwareValue +
            connector.messageRetrievalBudgetMs,
      );
    });
  });

  group('flood ignores the model even when one exists (#533)', () {
    // The group above only exercises the no-model path. The actual claim is
    // about what happens when predictTimeout returns a value: for flood it can
    // never survive, because the floor and the ceiling are the same number.
    //
    // This attaches a real predictor, trains it on deliberately huge delivery
    // times so any prediction is far from the firmware constant, and asserts
    // flood is unmoved. Verified to pass against the pre-#533 code as well,
    // which is what makes the branch removal a simplification rather than a
    // behaviour change.

    late TimeoutPredictionService prediction;

    setUp(() {
      prediction = TimeoutPredictionService.noStorage();
      connector.initialize(
        retryService: MessageRetryService(),
        pathHistoryService: PathHistoryService(StorageService()),
        timeoutPredictionService: prediction,
      );
      // minObservations is 10; vary the features so training does not discard
      // them all for zero variance, and make deliveryMs enormous so any
      // prediction lands nowhere near 1300.
      for (var i = 0; i < 12; i++) {
        prediction.recordObservation(
          contactKey: 'contact$i',
          pathLength: i.isEven ? -1 : (i % 4),
          messageBytes: 40 + (i * 12),
          tripTimeMs: 40000 + (i * 1500),
        );
      }
    });

    test('the predictor is actually trained, so the test is not vacuous', () {
      expect(prediction.hasModel, isTrue);
      final predicted = prediction.predictTimeout(
        pathLength: -1,
        messageBytes: 172,
      );
      expect(predicted, isNotNull);
      expect(
        predicted,
        greaterThan(1300),
        reason:
            'the prediction must differ from the flood constant, or this '
            'group proves nothing',
      );
    });

    test('flood still returns the firmware constant', () {
      expect(connector.calculateTimeout(pathLength: -1), 500 + (16 * 50));
    });

    test('direct is still clamped to its ceiling, so the clamp is live', () {
      // Contrast: on a direct path the prediction IS consulted and then
      // clamped. If this returned the raw prediction the clamp would be broken.
      expect(connector.calculateTimeout(pathLength: 0), 1050);
    });
  });
}
