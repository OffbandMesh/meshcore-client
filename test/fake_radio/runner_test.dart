import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_radio/fake_radio.dart';
import '../support/fake_radio/fake_radio_codes.dart';
import '../support/fake_radio/fake_radio_profile.dart';
import '../support/fake_radio/fake_radio_runner.dart';
import '../support/fake_radio/fake_radio_trace.dart';

// #780 (C3 of #755): the manual runner, its seed files and its console.

/// The example seed in tool/fake_radio/README.md, so the docs stay valid.
Map<String, dynamic> _readmeSeed() {
  final readme = File('tool/fake_radio/README.md').readAsStringSync();
  final block = RegExp(r'```json\r?\n([\s\S]*?)\r?\n```').firstMatch(readme)!;
  return jsonDecode(block.group(1)!) as Map<String, dynamic>;
}

void main() {
  group('seed files', () {
    test('the README example parses into the radio it describes', () {
      final radio = parseFakeRadioSeedFile(
        _readmeSeed(),
        profile: FakeRadioProfile.offband(),
      );
      expect(radio.contacts.map((c) => c.name), ['Alpha', 'Routed', 'Hilltop']);
      expect(radio.contacts[1].outPathLength, 1);
      expect(radio.contacts[2].type, fwAdvTypeRepeater);
      expect(radio.channels.keys, [0, 1]);
      expect(radio.channels[1]!.secret, List<int>.filled(16, 0x5A));
      expect(radio.remoteNodes.single.contact.name, 'Hilltop');
    });

    test('a wrong format, a bad type, or an unknown node is refused', () {
      final p = FakeRadioProfile.offband();
      expect(
        () => parseFakeRadioSeedFile({'format': 'x'}, profile: p),
        throwsFormatException,
      );
      final badType = _readmeSeed()
        ..['contacts'] = [
          {'name': 'X', 'key': '11', 'type': 'toaster'},
        ];
      expect(
        () => parseFakeRadioSeedFile(badType, profile: p),
        throwsFormatException,
      );
      final badNode = _readmeSeed()
        ..['remote_nodes'] = [
          {'contact': 'Nobody'},
        ];
      expect(
        () => parseFakeRadioSeedFile(badNode, profile: p),
        throwsFormatException,
      );
    });

    test('a captured trace works as a seed', () {
      final source = FakeRadio(profile: FakeRadioProfile.stock());
      final file =
          File('${Directory.systemTemp.createTempSync('trace').path}/t.json')
            ..writeAsStringSync(
              FakeRadioTrace.record(source, captureRequests()).toJson(),
            );
      final radio = fakeRadioFromFile(file.path, profile: 'offband');
      expect(radio.profile.offband, isFalse); // the trace decides
      expect(radio.name, source.name);
    });
  });

  group('runner against the real connector', () {
    late OffbandDatabase db;
    late MeshCoreConnector connector;
    late FakeRadioRunner runner;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      PrefsManager.reset();
      await PrefsManager.initialize();
      db = OffbandDatabase(NativeDatabase.memory());
      BlobStore.overrideForTest(BlobStore(db));
      connector = MeshCoreConnector();
      runner = await FakeRadioRunner.start(
        radio: parseFakeRadioSeedFile(
          _readmeSeed(),
          profile: FakeRadioProfile.offband(),
        ),
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
    });

    tearDown(() async {
      await connector.disconnect();
      await runner.close();
      BlobStore.clearTestOverride();
      await db.close();
    });

    Future<void> until(bool Function() done, String what) async {
      final sw = Stopwatch()..start();
      while (!done()) {
        if (sw.elapsed > const Duration(seconds: 10)) fail('timed out: $what');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test(
      'the app connects over TCP and console "dm" delivers',
      () async {
        await connector.connectTcp(
          host: InternetAddress.loopbackIPv4.address,
          port: runner.server.port,
        );
        await until(() => connector.contacts.length == 3, 'contacts');
        expect(runner.command('dm Alpha from the console'), contains('queued'));
        final alpha = connector.contacts.firstWhere((c) => c.name == 'Alpha');
        await until(
          () => connector
              .getMessages(alpha)
              .any((m) => m.text == 'from the console'),
          'the console DM',
        );
        expect(runner.command('status'), contains('1 client(s)'));
        expect(runner.command('dm Nobody hi'), contains('no contact'));
        expect(runner.command('frob'), contains('unknown'));
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  test(
    'capture_trace.py records the runner, and the capture replays',
    () async {
      final python = Platform.isWindows ? 'python' : 'python3';
      try {
        await Process.run(python, ['--version']);
      } on ProcessException {
        markTestSkipped('$python not available');
        return;
      }
      final runner = await FakeRadioRunner.start(
        radio: parseFakeRadioSeedFile(
          _readmeSeed(),
          profile: FakeRadioProfile.offband(),
        )..blockedKeys.add(Uint8List.fromList(List<int>.filled(32, 0x77))),
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      addTearDown(runner.close);
      final out = '${Directory.systemTemp.createTempSync('cap').path}/c.json';
      final result = await Process.run(python, [
        'tool/fake_radio/capture_trace.py',
        '--tcp',
        '127.0.0.1:${runner.server.port}',
        '--label',
        'runner self-check',
        '--out',
        out,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');

      final trace = FakeRadioTrace.load(out);
      // Every request got its replies, the Offband ones included.
      expect(trace.steps.every((s) => s.replies.isNotEmpty), isTrue);
      expect(trace.blockedKeys().single, List<int>.filled(32, 0x77));
      expect(trace.seed().contacts.map((c) => c.name), [
        'Alpha',
        'Routed',
        'Hilltop',
      ]);
      // A fake seeded from the capture reproduces it.
      expect(trace.replay(trace.radio()), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    '`dart run tool/fake_radio.dart` serves a client and quits',
    () async {
      final root = Platform.environment['FLUTTER_ROOT'];
      if (root == null) {
        markTestSkipped('FLUTTER_ROOT not set: not under flutter test');
        return;
      }
      final dart = '$root/bin/dart${Platform.isWindows ? '.bat' : ''}';
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();

      final proc = await Process.start(dart, [
        'run',
        'tool/fake_radio.dart',
        '--profile',
        'stock',
        '--port',
        '$port',
      ], runInShell: Platform.isWindows);
      addTearDown(proc.kill);
      final out = proc.stdout.transform(utf8.decoder).asBroadcastStream();
      await out
          .firstWhere((l) => l.contains('on port $port'))
          .timeout(const Duration(seconds: 60));

      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      addTearDown(socket.destroy);
      final reply = Completer<List<int>>();
      final buf = <int>[];
      socket.listen((data) {
        buf.addAll(data);
        if (buf.length >= 3 && buf.length >= 3 + (buf[1] | buf[2] << 8)) {
          if (!reply.isCompleted) reply.complete(buf.sublist(3));
        }
      });
      socket.add(Uint8List.fromList([0x3c, 2, 0, fwCmdDeviceQuery, 3]));
      final info = await reply.future.timeout(const Duration(seconds: 20));
      expect(info[0], fwRespDeviceInfo);
      expect(info[1], 13); // stock profile

      proc.stdin.writeln('quit');
      expect(await proc.exitCode.timeout(const Duration(seconds: 20)), 0);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
