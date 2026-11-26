import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/cli_command_codec.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/connector/observer_config_client.dart';
import 'package:meshcore_open/services/ble_debug_log_service.dart';
import 'package:meshcore_open/utils/log_redactor.dart';

final _peer = Uint8List.fromList(List.generate(32, (i) => 0xA0 + i));

String _ascii(Uint8List f, int start) =>
    latin1.decode(f.sublist(start).takeWhile((b) => b != 0).toList());

Uint8List _cliReplyV3(String text, {int txtType = txtTypeCliData}) =>
    Uint8List.fromList([
      respCodeContactMsgRecvV3,
      0,
      0,
      0,
      ..._peer.sublist(0, 6),
      0xFF,
      txtType,
      1,
      2,
      3,
      4,
      ...latin1.encode(text),
      0,
    ]);

Uint8List _cliReplyV2(String text) => Uint8List.fromList([
  respCodeContactMsgRecv,
  ..._peer.sublist(0, 6),
  0xFF,
  txtTypeCliData,
  1,
  2,
  3,
  4,
  ...latin1.encode(text),
  0,
]);

Uint8List _localReply(String text) =>
    Uint8List.fromList([respCodeCliReply, ...latin1.encode(text)]);

Uint8List _configReply(int sub, List<int> head, String text) =>
    Uint8List.fromList([
      ObserverConfigClient.respConfig,
      sub,
      ...head,
      ...latin1.encode(text),
      0,
    ]);

void main() {
  late LogRedactor r;
  setUp(() => r = LogRedactor());

  Uint8List tx(Uint8List f) => r.frame(f, outgoing: true);
  Uint8List rx(Uint8List f) => r.frame(f, outgoing: false);

  group('passwords and PINs in sent frames', () {
    test('a login keeps the key and loses the password', () {
      final sent = buildSendLoginFrame(_peer, 'hunter2');
      final logged = tx(sent);
      expect(logged.sublist(0, 33), sent.sublist(0, 33));
      expect(_ascii(logged, 33), '*******');
      expect(logged.length, sent.length);
    });

    test('the device PIN is blanked', () {
      final logged = tx(buildSetDevicePinFrame(123456));
      expect(logged, [cmdSetDevicePin, 0x2A, 0x2A, 0x2A, 0x2A]);
    });

    test('an imported private key keeps its first 3 bytes only', () {
      final key = Uint8List.fromList(List.generate(64, (i) => i + 1));
      final logged = tx(buildImportPrivateKeyFrame(key));
      expect(logged.sublist(1, 4), [1, 2, 3]);
      expect(logged.sublist(4), List.filled(61, 0x2A));
    });

    for (final (command, kept) in [
      ('password hunter2', 'password '),
      ('set guest.password two words', 'set guest.password '),
      ('SET Wifi.Pwd hunter2', 'SET Wifi.Pwd '),
      ('set bridge.secret abc', 'set bridge.secret '),
      ('set pin 123456', 'set pin '),
      ('set mqtt.broker.3.password pw', 'set mqtt.broker.3.password '),
    ]) {
      test('remote CLI "$command" keeps only "$kept"', () {
        final logged = tx(buildSendCliCommandFrame(_peer, 'a1|$command'));
        final text = _ascii(logged, 13);
        expect(text, 'a1|$kept${'*' * (command.length - kept.length)}');
      });

      test('local CLI "$command" keeps only "$kept"', () {
        final logged = tx(buildRunCliCommandFrame(command));
        expect(_ascii(logged, 1), kept + '*' * (command.length - kept.length));
      });
    }

    test('ordinary CLI commands are kept', () {
      for (final command in ['set name base', 'get name', 'ver', 'neighbors']) {
        final sent = buildSendCliCommandFrame(_peer, command);
        expect(tx(sent), sent);
      }
    });

    test('a plain message that mentions a password is a message, kept', () {
      final sent = buildSendCliCommandFrame(
        _peer,
        'password hunter2',
        txtType: txtTypePlain,
      );
      expect(tx(sent), sent);
    });

    test('observer config SETs lose the Wi-Fi and broker passwords', () {
      final wifi = tx(ObserverConfigClient.buildSet('wifi.pwd', 'hunter2'));
      expect(_ascii(wifi, 2), 'wifi.pwd *******');
      final broker = tx(
        ObserverConfigClient.buildBrokerFieldSet(2, 'password', 'pw'),
      );
      expect(_ascii(broker, 2), 'mqtt.broker.2.password **');
      final url = ObserverConfigClient.buildBrokerFieldSet(2, 'url', 'host');
      expect(tx(url), url);
    });

    test('channel keys are kept', () {
      final psk = Uint8List.fromList(List.generate(16, (i) => i));
      final sent = buildSetChannelFrame(1, 'Ops', psk);
      expect(tx(sent), sent);
    });

    test('a code nobody classified loses its whole payload', () {
      expect(tx(Uint8List.fromList([0x77, 1, 2, 3])), [0x77, 0x2A, 0x2A, 0x2A]);
    });
  });

  group('passwords and PINs in received frames', () {
    test('the exported private key keeps its first 3 bytes only', () {
      final reply = Uint8List.fromList([
        respCodePrivateKey,
        ...List.generate(64, (i) => i + 1),
      ]);
      final logged = rx(reply);
      expect(logged.sublist(1, 4), [1, 2, 3]);
      expect(logged.sublist(4), List.filled(61, 0x2A));
    });

    test('device info loses the BLE PIN and keeps the rest', () {
      final info = Uint8List.fromList(List.generate(90, (i) => i));
      info[0] = respCodeDeviceInfo;
      final logged = rx(info);
      expect(logged.sublist(4, 8), List.filled(4, 0x2A));
      expect(logged.sublist(0, 4), info.sublist(0, 4));
      expect(logged.sublist(8), info.sublist(8));
    });

    test('the password echo is blanked in every CLI reply form', () {
      for (final frame in [
        _cliReplyV3('a1|password now: newpw'),
        _cliReplyV2('password now: newpw'),
        _localReply('b2|password now: newpw'),
      ]) {
        expect(latin1.decode(rx(frame)), contains('password now: *****'));
      }
    });

    test('the reply to a secret get is blanked, matched by its prefix', () {
      tx(buildRunCliCommandFrame('get guest.password', prefix: 'b2|'));
      expect(_ascii(rx(_localReply('c3|> other')), 1), 'c3|> other');
      expect(_ascii(rx(_localReply('b2|> hunter2')), 1), 'b2|*********');
      expect(_ascii(rx(_localReply('b2|> again')), 1), 'b2|> again');
    });

    test('an unprefixed secret get is paired in order, not with any reply', () {
      tx(buildRunCliCommandFrame('get pin'));
      tx(buildSendCliCommandFrame(_peer, 'aa|get wifi.pwd'));
      tx(buildRunCliCommandFrame('ver'));
      expect(_ascii(rx(_localReply('aa|> wifipw')), 1), 'aa|********');
      expect(_ascii(rx(_localReply('> 123456')), 1), '********');
      expect(_ascii(rx(_localReply('> v1.2')), 1), '> v1.2');
    });

    test('a prefixed reply never uses up an unprefixed secret get', () {
      tx(buildRunCliCommandFrame('get pin'));
      expect(_ascii(rx(_localReply('aa|OK')), 1), 'aa|OK');
      expect(_ascii(rx(_localReply('> 123456')), 1), '********');
    });

    test('a NUL inside a secret does not leave its tail behind', () {
      final login = buildSendLoginFrame(_peer, 'hunter2');
      final sneaky = Uint8List.fromList([
        ...login.sublist(0, 36),
        0,
        ...latin1.encode('two'),
        0,
      ]);
      final logged = tx(sneaky);
      expect(logged.sublist(33, logged.length - 1), everyElement(0x2A));
      final cli = Uint8List.fromList([
        cmdRunCliCommand,
        ...latin1.encode('set pin 12'),
        0,
        ...latin1.encode('3456'),
      ]);
      expect(tx(cli).sublist(9), everyElement(0x2A));
    });

    test('a config password containing a newline is still blanked', () {
      final logged = tx(ObserverConfigClient.buildSet('wifi.pwd', 'a\nb'));
      expect(_ascii(logged, 2), 'wifi.pwd ***');
    });

    test('a remote secret get blanks the repeater reply', () {
      tx(buildSendCliCommandFrame(_peer, 'c3|get pin'));
      expect(_ascii(rx(_cliReplyV3('c3|> 123456')), 16), 'c3|********');
    });

    test('a secret get reply that comes too late is not guessed at', () {
      var now = DateTime(2026, 11, 25, 12);
      r = LogRedactor(now: () => now);
      tx(buildRunCliCommandFrame('get wifi.pwd', prefix: 'd4|'));
      now = now.add(const Duration(seconds: 61));
      expect(_ascii(rx(_localReply('d4|> late')), 1), 'd4|> late');
    });

    test('observer config values for secret keys are blanked', () {
      final value = rx(
        _configReply(ObserverConfigClient.rValue, [], 'wifi.pwd = x1'),
      );
      expect(_ascii(value, 2), 'wifi.pwd = **');
      final presence = _configReply(ObserverConfigClient.rBrokerKv, [
        0,
      ], 'password=(set)');
      expect(rx(presence), presence);
    });

    test('a plain DM and an unknown incoming code are kept raw', () {
      final dm = _cliReplyV3('password now: x', txtType: txtTypePlain);
      expect(rx(dm), dm);
      final unknown = Uint8List.fromList([0x99, 1, 2, 3, 4, 5, 6, 7, 8]);
      expect(rx(unknown), unknown);
    });
  });

  group('CLI text in the app log', () {
    test('commands lose secret values', () {
      expect(
        LogRedactor.cliCommandText('password hunter2'),
        'password *******',
      );
      expect(LogRedactor.cliCommandText('get name'), 'get name');
    });

    test('replies to secret gets and password echoes are blanked', () {
      expect(LogRedactor.cliReplyText('get guest.password', '> pw'), '****');
      expect(
        LogRedactor.cliReplyText(null, 'password now: pw'),
        'password now: **',
      );
      expect(LogRedactor.cliReplyText('ver', '> 1.2'), '> 1.2');
    });
  });

  test('the frame log stores the redacted frame', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final log = BleDebugLogService();
    log.logFrame(buildSendLoginFrame(_peer, 'hunter2'), outgoing: true);
    expect(_ascii(log.entries.single.payload, 33), '*******');
  });
}
