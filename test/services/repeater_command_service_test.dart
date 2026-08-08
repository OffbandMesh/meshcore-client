// #528 (epic #473): a repeater CLI reply that arrives with no command waiting
// for it used to hit `if (commandId.isEmpty) return;` and vanish. No log, no
// UI, nothing. Since a command's window can close before the app has even
// finished fetching the message (MSG_WAITING then SYNC_NEXT_MESSAGE), that
// made "the command ran but the response was never reported" the normal
// outcome rather than an edge case.
//
// These tests pin the contract that no reply is ever dropped silently.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/services/repeater_command_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Contact _repeater() => Contact(
  publicKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
  name: 'Test Repeater',
  type: 2,
  pathLength: 0,
  path: Uint8List(0),
  lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RepeaterCommandService service;
  late Contact repeater;
  late List<UnmatchedRepeaterResponse> surfaced;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();

    service = RepeaterCommandService(MeshCoreConnector());
    repeater = _repeater();
    surfaced = [];
    service.onUnmatchedResponse = surfaced.add;
  });

  tearDown(() => service.dispose());

  test('a reply with no pending command is surfaced, not discarded', () {
    service.handleResponse(repeater, 'Version: 1.2.3');

    expect(surfaced, hasLength(1));
    expect(surfaced.single.response, 'Version: 1.2.3');
    expect(surfaced.single.repeaterKeyHex, repeater.publicKeyHex);
  });

  test('a reply for a command that already timed out names that command', () {
    service.recordExpiredCommandForTest('A3|', 'ver');

    service.handleResponse(repeater, 'A3|Version: 1.2.3');

    expect(surfaced, hasLength(1));
    final reply = surfaced.single;
    expect(reply.isLateReply, isTrue);
    expect(reply.command, 'ver');
    expect(reply.response, 'Version: 1.2.3', reason: 'prefix must be stripped');
    expect(reply.sinceTimeout, isNotNull);
  });

  test('an unattributable reply is still surfaced, just without a command', () {
    service.handleResponse(repeater, 'ZZ|unsolicited chatter');

    expect(surfaced, hasLength(1));
    expect(surfaced.single.isLateReply, isFalse);
    expect(surfaced.single.command, isNull);
    expect(surfaced.single.response, 'unsolicited chatter');
  });

  test('an expired command is only consumed once', () {
    service.recordExpiredCommandForTest('A3|', 'ver');

    service.handleResponse(repeater, 'A3|first');
    service.handleResponse(repeater, 'A3|second');

    expect(surfaced, hasLength(2));
    expect(surfaced[0].command, 'ver');
    expect(
      surfaced[1].command,
      isNull,
      reason: 'the record is consumed by the first reply that claims it',
    );
  });

  test('a reply is never swallowed when no callback is wired', () {
    service.onUnmatchedResponse = null;

    // The contract is that this cannot throw and cannot hang. The logging path
    // still runs; the absence of a listener must not resurrect the silent drop
    // as an unhandled error.
    expect(
      () => service.handleResponse(repeater, 'orphan reply'),
      returnsNormally,
    );
  });

  test('dispose clears the late-reply records', () {
    service.recordExpiredCommandForTest('A3|', 'ver');
    service.dispose();

    // Re-arm a listener on the disposed service and confirm the stale record is
    // gone, so a reply after disposal cannot be mis-attributed to it.
    final seen = <UnmatchedRepeaterResponse>[];
    service.onUnmatchedResponse = seen.add;
    service.handleResponse(repeater, 'A3|Version: 1.2.3');

    expect(seen.single.command, isNull);
  });

  group('timeout reporting (#531)', () {
    // The old message printed (timeoutMs / 1000).ceil(), so every window in
    // (4000, 5000] announced "5 seconds" and the figure shown was never the
    // one armed. The owner's 0-hop window was 4074 ms and it claimed 5.
    test('reports the armed window to one decimal, not rounded up', () {
      const e = RepeaterCommandTimeout(command: 'ver', timeoutMs: 4074);
      expect(e.secondsText, '4.1');
      expect(e.toString(), 'Command timed out after 4.1 seconds');
    });

    test('does not round a sub-second remainder up to the next second', () {
      // 28748 ms is the new CLI budget on the owner's preset. ceil() would say
      // 29; the armed window is 28.7.
      const e = RepeaterCommandTimeout(command: 'status', timeoutMs: 28748);
      expect(e.secondsText, '28.7');
    });

    test('distinct windows in the same second are distinguishable', () {
      // The defect's signature: 4001 and 4999 both printed "5 seconds".
      const a = RepeaterCommandTimeout(command: 'a', timeoutMs: 4001);
      const b = RepeaterCommandTimeout(command: 'b', timeoutMs: 4999);
      expect(a.secondsText, isNot(b.secondsText));
    });

    test('carries the command so a caller can name what timed out', () {
      const e = RepeaterCommandTimeout(command: 'get tx', timeoutMs: 1234);
      expect(e.command, 'get tx');
      expect(e.timeoutMs, 1234);
    });
  });
}
