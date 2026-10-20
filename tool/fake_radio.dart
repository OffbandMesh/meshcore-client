// A fake MeshCore companion radio on TCP, for using the desktop app with no
// hardware (#780, Feature #755). Run from the repo root:
//
//   dart run tool/fake_radio.dart --profile offband --port 5000
//   dart run tool/fake_radio.dart --profile stock --seed my-mesh.json
//   dart run tool/fake_radio.dart --seed test/fake_radio/traces/rak.json
//
// Then in the app: connect over TCP to this PC's address, port 5000. Seed
// files and console commands: tool/fake_radio/README.md. Test code only: it
// lives under test/ and tool/ and never ships in the app.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../test/support/fake_radio/fake_radio_runner.dart';

Future<void> main(List<String> args) async {
  var profile = 'offband';
  var port = 5000;
  String? seed;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--profile' when i + 1 < args.length:
        profile = args[++i];
      case '--port' when i + 1 < args.length:
        port = int.parse(args[++i]);
      case '--seed' when i + 1 < args.length:
        seed = args[++i];
      default:
        stderr.writeln(
          'usage: dart run tool/fake_radio.dart '
          '[--profile offband|stock] [--port 5000] [--seed file.json]',
        );
        exit(64);
    }
  }

  final radio = fakeRadioFromFile(seed, profile: profile);
  final runner = await FakeRadioRunner.start(radio: radio, port: port);
  stdout.writeln(
    'Fake radio "${radio.name}" (${radio.profile.name}) on port '
    '${runner.server.port}. ${radio.contacts.length} contact(s), '
    '${radio.channels.length} channel(s). Type "help" for commands.',
  );

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim() == 'quit') break;
    final out = runner.command(line);
    if (out.isNotEmpty) stdout.writeln(out);
  }
  await runner.close();
}
