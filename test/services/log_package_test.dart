import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/cli_command_codec.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/services/log_package.dart';
import 'package:meshcore_open/utils/log_redactor.dart';

final _peer = Uint8List.fromList(List.generate(32, (i) => 0xA0 + i));

String _hex(Uint8List f) =>
    f.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

String _frameLine(String dir, String label, Uint8List f) =>
    '2026-11-25T10:00:00.000 $dir $label  ${_hex(f)}';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('logpkg'));
  tearDown(() async => tmp.delete(recursive: true));

  Future<File> write(String name, List<String> lines) =>
      File('${tmp.path}/$name').writeAsString('${lines.join('\n')}\n');

  test('lines written before the redactor lose their passwords', () async {
    final login = _frameLine(
      'TX',
      'CMD_SEND_LOGIN',
      buildSendLoginFrame(_peer, 'hunter2'),
    );
    final get = _frameLine(
      'TX',
      'CODE_66',
      buildRunCliCommandFrame('get guest.password', prefix: 'b2|'),
    );
    final reply = _frameLine(
      'RX',
      'CODE_29',
      Uint8List.fromList([respCodeCliReply, ...latin1.encode('b2|> secret')]),
    );
    const late =
        '2026-11-25T10:00:01.000 [WARN/RepeaterCommand] Late reply to '
        '"password hunter2" from abcd arrived 900ms after its window closed: '
        'password now: hunter2';
    const ordinary = '2026-11-25T10:00:02.000 [INFO/App] connected';

    final older = await write('offband.1.log', [login, get]);
    final newer = await write('offband.log', [reply, late, ordinary]);
    final out = await Directory('${tmp.path}/out').create();
    final package = await LogPackage.build(
      logs: [newer, older],
      traces: const [],
      into: out,
    );

    final text = [
      for (final f in package.files.skip(1)) await f.readAsString(),
    ].join();
    expect(text, isNot(contains(_hex(latin1.encode('hunter2')))));
    expect(text, isNot(contains('hunter2')));
    expect(text, isNot(contains(_hex(latin1.encode('secret')))));
    expect(text, contains(ordinary));
    expect(text, contains('password now: *******'));
    expect(package.files.skip(1).map((f) => f.uri.pathSegments.last), [
      'offband.1.log',
      'offband.log',
    ]);
  });

  test('frame lines without secrets come out byte for byte', () {
    final r = LogRedactor();
    final psk = Uint8List.fromList(List.generate(16, (i) => i));
    final line = _frameLine(
      'TX',
      'CMD_SET_CHANNEL',
      buildSetChannelFrame(2, 'Ops', psk),
    );
    expect(r.line(line), line);
    final redacted = r.line(
      _frameLine('TX', 'CMD_SEND_LOGIN', buildSendLoginFrame(_peer, 'x')),
    );
    expect(r.line(redacted), redacted);
  });

  test('the web package zips the in-memory log, redacted', () {
    final text = [
      _frameLine('TX', 'CMD_SEND_LOGIN', buildSendLoginFrame(_peer, 'hunter2')),
      '[12:00:00.000] [INFO] [App] connected',
    ].join('\n');
    final zip = ZipDecoder().decodeBytes(LogPackage.textPackageZip(text));
    expect(zip.files.map((f) => f.name), [
      LogPackage.manifestName,
      'offband-log.txt',
    ]);
    final log = utf8.decode(zip.files[1].content as List<int>);
    expect(log, isNot(contains(_hex(latin1.encode('hunter2')))));
    expect(log, contains('[App] connected'));
    final manifest =
        jsonDecode(utf8.decode(zip.files[0].content as List<int>))
            as Map<String, dynamic>;
    expect(manifest['files'], ['offband-log.txt']);
  });

  test('the manifest names the files, and the zip holds them all', () async {
    final log = await write('offband.log', ['one']);
    final trace = await write('anr-1.txt', ['trace']);
    final out = await Directory('${tmp.path}/out').create();
    final package = await LogPackage.build(
      logs: [log, File('${tmp.path}/gone.log')],
      traces: [trace],
      into: out,
      now: () => DateTime.utc(2026, 11, 25, 12),
    );

    final manifest =
        jsonDecode(await package.files.first.readAsString())
            as Map<String, dynamic>;
    expect(manifest['format'], 1);
    expect(manifest['createdAt'], '2026-11-25T12:00:00.000Z');
    expect(manifest['files'], ['offband.log', 'traces/anr-1.txt']);
    expect(manifest.keys, containsAll(['app', 'commit', 'platform', 'os']));

    final zip = ZipDecoder().decodeBytes(await package.zip());
    expect(zip.files.map((f) => f.name), [
      LogPackage.manifestName,
      'offband.log',
      'traces/anr-1.txt',
    ]);
  });
}
