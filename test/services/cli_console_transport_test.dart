// #999: the CLI console must drive a remote companion the same way it drives
// the local device - one run()->CliReply call, one timeout type. These pin the
// remote transport's wiring (send type-3, correlate the reflected-prefix
// reply), its sender filtering (another contact's reply must not complete our
// command), and that both transports map their service's timeout to the single
// CliConsoleTimeout the console catches.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/cli_command_codec.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/services/cli_console_transport.dart';
import 'package:meshcore_open/services/local_cli_service.dart';
import 'package:meshcore_open/services/repeater_command_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Contact _companion() => Contact(
  publicKey: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
  receivedName: 'Companion',
  type: advTypeChat,
  pathLength: 0,
  path: Uint8List(0),
  lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
);

/// A contact-message reply frame carrying [text] from [senderPrefix]:
/// [respCodeContactMsgRecv][prefix x6][path_len][txt_type][ts x4][text][0].
Uint8List _replyFrame({
  required Uint8List senderPrefix,
  required String text,
  int txtType = txtTypeCliData,
}) {
  final b = BytesBuilder();
  b.addByte(respCodeContactMsgRecv);
  b.add(senderPrefix.sublist(0, 6));
  b.addByte(0); // path_len
  b.addByte(txtType); // CLI_DATA is the reply type a companion answers with
  b.add([0, 0, 0, 0]); // timestamp
  b.add(ascii.encode(text));
  b.addByte(0);
  return b.toBytes();
}

/// Throws a timeout from sendCommand so the mapping can be tested without
/// waiting out a real mesh window.
class _TimingOutRemoteService extends RepeaterCommandService {
  _TimingOutRemoteService(super.connector);

  @override
  Future<String> sendCommand(
    Contact repeater,
    String command, {
    Function(String)? onResponse,
    Function(int)? onAttempt,
    int retries = RepeaterCommandService.maxRetries,
  }) async {
    throw RepeaterCommandTimeout(command: command, timeoutMs: 4300);
  }
}

/// Throws a local timeout from run() so LocalCliTransport's mapping can be
/// tested in isolation.
class _TimingOutLocalService extends LocalCliService {
  _TimingOutLocalService(super.connector);

  @override
  Future<CliReply> run(String command, {Duration? timeout}) async {
    throw LocalCliTimeout(
      command: command,
      timeout: const Duration(seconds: 10),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  group('RemoteCliTransport', () {
    test(
      'sends a type-3 command and completes with the correlated reply',
      () async {
        final connector = MeshCoreConnector();
        final companion = _companion();
        final sent = <Uint8List>[];
        final cliSent = Completer<Uint8List>();
        connector.sendFrameOverrideForTest = (f) {
          sent.add(f);
          if (!cliSent.isCompleted && f.isNotEmpty && f[0] == cmdSendTxtMsg) {
            cliSent.complete(f);
          }
        };
        connector.setConnectedForTest();
        connector.contactsForTest.add(companion);

        final transport = RemoteCliTransport(connector, companion);
        final future = transport.run('get radio');

        final frame = await cliSent.future;
        // Frame: [cmd][type][attempt][ts x4][pubKey x6][cc| prefix ...].
        expect(frame[1], txtTypeCliCommand, reason: 'a companion gets type 3');
        final prefix = ascii.decode(frame.sublist(13, 16));

        connector.handleFrameForTest(
          _replyFrame(
            senderPrefix: companion.publicKey,
            text: '${prefix}radio ok',
          ),
        );

        final reply = await future;
        expect(reply.text, 'radio ok');
        // No auto-retry: exactly one CLI send frame went out (#999/#891).
        expect(
          sent.where((f) => f.isNotEmpty && f[0] == cmdSendTxtMsg),
          hasLength(1),
        );
        transport.dispose();
      },
    );

    test(
      'a plain or type-3 message from the target does not complete the command',
      () async {
        final connector = MeshCoreConnector();
        final companion = _companion();
        final cliSent = Completer<Uint8List>();
        connector.sendFrameOverrideForTest = (f) {
          if (!cliSent.isCompleted && f.isNotEmpty && f[0] == cmdSendTxtMsg) {
            cliSent.complete(f);
          }
        };
        connector.setConnectedForTest();
        connector.contactsForTest.add(companion);

        final transport = RemoteCliTransport(connector, companion);
        final future = transport.run('get radio');
        final frame = await cliSent.future;
        final prefix = ascii.decode(frame.sublist(13, 16));

        // A companion is a human chat node. A plain chat message (no prefix)
        // must NOT complete the command via the unprefixed sole-pending
        // fallback, and neither must an inbound type-3 command from them.
        connector.handleFrameForTest(
          _replyFrame(
            senderPrefix: companion.publicKey,
            text: 'hey, you there?',
            txtType: txtTypePlain,
          ),
        );
        connector.handleFrameForTest(
          _replyFrame(
            senderPrefix: companion.publicKey,
            text: 'run this on me',
            txtType: txtTypeCliCommand,
          ),
        );
        // Only the real CLI_DATA reply completes it.
        connector.handleFrameForTest(
          _replyFrame(
            senderPrefix: companion.publicKey,
            text: '${prefix}radio ok',
          ),
        );

        final reply = await future;
        expect(reply.text, 'radio ok');
        transport.dispose();
      },
    );

    test(
      'a reply from another contact does not complete our command',
      () async {
        final connector = MeshCoreConnector();
        final companion = _companion();
        final cliSent = Completer<Uint8List>();
        connector.sendFrameOverrideForTest = (f) {
          if (!cliSent.isCompleted && f.isNotEmpty && f[0] == cmdSendTxtMsg) {
            cliSent.complete(f);
          }
        };
        connector.setConnectedForTest();
        connector.contactsForTest.add(companion);

        final transport = RemoteCliTransport(connector, companion);
        final future = transport.run('get radio');
        final frame = await cliSent.future;
        final prefix = ascii.decode(frame.sublist(13, 16));

        // A different contact reflects the same prefix - must be ignored.
        final otherKey = Uint8List.fromList(List<int>.filled(32, 0xEE));
        connector.handleFrameForTest(
          _replyFrame(senderPrefix: otherKey, text: '${prefix}WRONG'),
        );
        // The real target's reply must be the one that completes it.
        connector.handleFrameForTest(
          _replyFrame(
            senderPrefix: companion.publicKey,
            text: '${prefix}RIGHT',
          ),
        );

        final reply = await future;
        expect(reply.text, 'RIGHT');
        transport.dispose();
      },
    );

    test('a timed-out send surfaces as CliConsoleTimeout', () async {
      final connector = MeshCoreConnector();
      final transport = RemoteCliTransport(
        connector,
        _companion(),
        service: _TimingOutRemoteService(connector),
      );
      await expectLater(
        transport.run('get radio'),
        throwsA(
          isA<CliConsoleTimeout>().having(
            (e) => e.secondsText,
            'secondsText',
            '4.3',
          ),
        ),
      );
      transport.dispose();
    });
  });

  group('fail fast when the connected radio refuses the send (#999)', () {
    // A pre-1.18 companion answers CMD_SEND_TXT_MSG carrying type 3 with
    // ERR_CODE_UNSUPPORTED_CMD (companion-v1.17.1 MyMesh.cpp). The command
    // never went out, so waiting out the mesh timeout would end in a row that
    // blames the target.
    final errUnsupported = Uint8List.fromList([
      respCodeErr,
      errCodeUnsupportedCmd,
    ]);
    // [RESP_CODE_SENT][is_flood][expected_ack x4][est timeout x4]. 1.18 sends a
    // CLI command with no ack expected, so OUR send's SENT carries ack 0; a
    // plain DM's SENT carries a real ack hash.
    Uint8List sent(List<int> ack) =>
        Uint8List.fromList([respCodeSent, 0, ...ack, 0x10, 0x27, 0, 0]);
    final commandSent = sent([0, 0, 0, 0]);
    final dmSent = sent([0xDE, 0xAD, 0xBE, 0xEF]);

    Future<
      ({
        MeshCoreConnector connector,
        Contact companion,
        Future<CliReply> run,
        String prefix,
        RemoteCliTransport transport,
      })
    >
    startRun() async {
      final connector = MeshCoreConnector();
      final companion = _companion();
      final cliSent = Completer<Uint8List>();
      connector.sendFrameOverrideForTest = (f) {
        if (!cliSent.isCompleted && f.isNotEmpty && f[0] == cmdSendTxtMsg) {
          cliSent.complete(f);
        }
      };
      connector.setConnectedForTest();
      connector.contactsForTest.add(companion);
      final transport = RemoteCliTransport(connector, companion);
      final run = transport.run('get radio');
      final frame = await cliSent.future;
      return (
        connector: connector,
        companion: companion,
        run: run,
        prefix: ascii.decode(frame.sublist(13, 16)),
        transport: transport,
      );
    }

    test('an unsupported-command error fails the command at once', () async {
      final s = await startRun();
      s.connector.handleFrameForTest(errUnsupported);
      await expectLater(
        s.run.timeout(const Duration(seconds: 1)),
        throwsA(isA<CliConsoleUnsupported>()),
      );
      s.transport.dispose();
    });

    test('a different error code does not fail the command', () async {
      final s = await startRun();
      s.connector.handleFrameForTest(
        Uint8List.fromList([respCodeErr, errCodeNotFound]),
      );
      s.connector.handleFrameForTest(
        _replyFrame(
          senderPrefix: s.companion.publicKey,
          text: '${s.prefix}radio ok',
        ),
      );
      expect((await s.run).text, 'radio ok');
      s.transport.dispose();
    });

    test('an error after the radio accepted the send is not ours', () async {
      final s = await startRun();
      s.connector.handleFrameForTest(commandSent);
      s.connector.handleFrameForTest(errUnsupported);
      s.connector.handleFrameForTest(
        _replyFrame(
          senderPrefix: s.companion.publicKey,
          text: '${s.prefix}radio ok',
        ),
      );
      expect((await s.run).text, 'radio ok');
      s.transport.dispose();
    });

    test('a DM\'s SENT does not close the window early', () async {
      // An earlier in-flight DM's acknowledgement (real ack hash) must not be
      // mistaken for ours, or a refusal after it would be missed.
      final s = await startRun();
      s.connector.handleFrameForTest(dmSent);
      s.connector.handleFrameForTest(errUnsupported);
      await expectLater(
        s.run.timeout(const Duration(seconds: 1)),
        throwsA(isA<CliConsoleUnsupported>()),
      );
      s.transport.dispose();
    });

    test('an error before the text frame is written is not ours', () async {
      // The window arms only at the write. An unrelated refusal that lands
      // while the path update is still in progress must not fail the command.
      final connector = MeshCoreConnector();
      final companion = _companion();
      final cliSent = Completer<Uint8List>();
      connector.sendFrameOverrideForTest = (f) {
        if (!cliSent.isCompleted && f.isNotEmpty && f[0] == cmdSendTxtMsg) {
          cliSent.complete(f);
        }
      };
      connector.setConnectedForTest();
      connector.contactsForTest.add(companion);
      final transport = RemoteCliTransport(connector, companion);
      final run = transport.run('get radio');
      // run() has yielded inside the path update; nothing is armed yet.
      connector.handleFrameForTest(errUnsupported);
      final frame = await cliSent.future;
      final prefix = ascii.decode(frame.sublist(13, 16));
      connector.handleFrameForTest(
        _replyFrame(
          senderPrefix: companion.publicKey,
          text: '${prefix}radio ok',
        ),
      );
      expect((await run).text, 'radio ok');
      transport.dispose();
    });

    test('dispose with a command in flight does not hang its run()', () async {
      final s = await startRun();
      s.transport.dispose();
      await expectLater(
        s.run.timeout(const Duration(seconds: 1)),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('LocalCliTransport', () {
    test('a local timeout surfaces as CliConsoleTimeout', () async {
      final connector = MeshCoreConnector();
      final transport = LocalCliTransport(
        connector,
        service: _TimingOutLocalService(connector),
      );
      await expectLater(
        transport.run('get radio'),
        throwsA(
          isA<CliConsoleTimeout>().having(
            (e) => e.secondsText,
            'secondsText',
            '10.0',
          ),
        ),
      );
      transport.dispose();
    });
  });
}
