import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

import '../support/fake_radio/fake_radio.dart';
import '../support/fake_radio/fake_radio_codes.dart';
import '../support/fake_radio/fake_radio_seed.dart';
import '../support/fake_radio/fake_remote_node.dart';

// #774 (B3 of #755): repeaters, room servers and sensors over the mesh,
// driven by the client's own login and CLI frames.

void main() {
  final repeater = FakeContact.keyed(0x51, 'Rpt', type: fwAdvTypeRepeater);

  (FakeRadio, FakeRemoteNode, List<Uint8List>) setUpNode({
    bool offband = true,
  }) {
    final radio = FakeRadio();
    final node = radio.addRemoteNode(
      FakeRemoteNode(
        contact: repeater,
        guestPassword: 'guest',
        offband: offband,
      ),
    );
    final pushes = <Uint8List>[];
    radio.pushes.listen(pushes.add);
    return (radio, node, pushes);
  }

  void login(FakeRadio radio, String password) {
    radio.handle(buildSendLoginFrame(repeater.publicKey, password));
    radio.clock.advance(const Duration(seconds: 1));
  }

  /// Sends one CLI command and returns the node's reply text, or null.
  String? cli(FakeRadio radio, String command) {
    radio.offlineQueue.clear();
    radio.handle(buildSendCliCommandFrame(repeater.publicKey, command));
    radio.clock.advance(const Duration(seconds: 1));
    if (radio.offlineQueue.isEmpty) return null;
    final f = radio.offlineQueue.single;
    expect(f[0], fwRespContactMsgRecvV3);
    expect(f.sublist(4, 10), repeater.publicKey.sublist(0, 6));
    expect(f[11], fwTxtTypeCliData);
    return utf8.decode(f.sublist(16));
  }

  group('login', () {
    test('admin: SENT tagged with the key, then LOGIN_SUCCESS as admin', () {
      final (radio, _, pushes) = setUpNode();
      final sent = radio
          .handle(buildSendLoginFrame(repeater.publicKey, 'password'))
          .single;
      expect(sent[0], fwRespSent);
      expect(sent.sublist(2, 6), repeater.publicKey.sublist(0, 4));
      expect(pushes, isEmpty);
      radio.clock.advance(const Duration(seconds: 1));
      final ok = pushes.single;
      expect(ok[0], fwPushLoginSuccess);
      expect(ok[1], 1); // is_admin
      expect(ok.sublist(2, 8), repeater.publicKey.sublist(0, 6));
      expect(ok[12], 3); // PERM_ACL_ADMIN
      expect(ok.length, 14);
    });

    test('guest: success, not admin, and CLI is ignored', () {
      final (radio, _, pushes) = setUpNode();
      login(radio, 'guest');
      expect(pushes.single[1], 0);
      expect(pushes.single[12], 0);
      expect(cli(radio, 'get radio'), isNull);
    });

    test('a wrong password gets no answer at all', () {
      final (radio, _, pushes) = setUpNode();
      login(radio, 'nope');
      radio.clock.advance(const Duration(minutes: 1));
      expect(pushes, isEmpty);
    });

    test('without logging in, CLI is ignored', () {
      final (radio, _, _) = setUpNode();
      expect(cli(radio, 'get radio'), isNull);
    });
  });

  group('CLI as admin', () {
    test('get radio, tx and path hash mode', () {
      final (radio, _, _) = setUpNode();
      login(radio, 'password');
      expect(cli(radio, 'get radio'), '> 910.525,62.5,7,5');
      expect(cli(radio, 'get tx'), '> 20');
      expect(cli(radio, 'get path.hash.mode'), '> 0');
    });

    test('set radio saves for after reboot; bad values are refused', () {
      final (radio, node, _) = setUpNode();
      login(radio, 'password');
      expect(cli(radio, 'set radio 909.75,500,10,5'), 'OK - reboot to apply');
      expect(node.freqMhz, 909.75);
      expect(cli(radio, 'get radio'), '> 909.75,500,10,5');
      expect(
        cli(radio, 'set radio 909.75,600,10,5'),
        'Error, invalid radio params',
      );
    });

    test('set radio with a fifth part: Offband refuses, stock ignores it', () {
      var (radio, _, _) = setUpNode();
      login(radio, 'password');
      expect(
        cli(radio, 'set radio 909.75,500,10,5,9'),
        'Error, too many params (expected freq,bw,sf,cr)',
      );
      (radio, _, _) = setUpNode(offband: false);
      login(radio, 'password');
      expect(cli(radio, 'set radio 909.75,500,10,5,9'), 'OK - reboot to apply');
    });

    test('tempradio applies 2 s after the reply and reverts on time', () {
      final (radio, node, _) = setUpNode();
      login(radio, 'password');
      expect(
        cli(radio, 'tempradio 909.750,500.0,10,5,60'),
        'OK - temp params for 60 mins',
      );
      expect(node.tempRadio, isNull);
      radio.clock.advance(const Duration(seconds: 2));
      expect(node.tempRadio?.freqMhz, 909.75);
      expect(node.freqMhz, 910.525); // saved settings untouched
      radio.clock.advance(const Duration(minutes: 59, seconds: 59));
      expect(node.tempRadio, isNotNull);
      radio.clock.advance(const Duration(seconds: 1));
      expect(node.tempRadio, isNull);
    });

    test('tempradio needs a positive duration and valid params', () {
      final (radio, _, _) = setUpNode();
      login(radio, 'password');
      expect(
        cli(radio, 'tempradio 909.75,500,10,5,0'),
        'Error, invalid params',
      );
      expect(
        cli(radio, 'tempradio 909.75,500,10,4,60'),
        'Error, invalid params',
      );
    });

    test('set path.hash.mode 0-2 and set tx', () {
      final (radio, node, _) = setUpNode();
      login(radio, 'password');
      expect(cli(radio, 'set path.hash.mode 1'), 'OK');
      expect(node.pathHashMode, 1);
      expect(cli(radio, 'set path.hash.mode 3'), 'Error, must be 0,1, or 2');
      expect(cli(radio, 'set tx 14'), 'OK');
      expect(cli(radio, 'get tx'), '> 14');
    });

    test(
      'ver everywhere; version is Offband-only, stock answers it as ver',
      () {
        var (radio, _, _) = setUpNode();
        login(radio, 'password');
        expect(cli(radio, 'ver'), 'v1.17.0 (Build: 1 Oct 2026)');
        expect(cli(radio, 'version'), startsWith('Upstream MeshCore: v1.17.0'));
        (radio, _, _) = setUpNode(offband: false);
        login(radio, 'password');
        expect(cli(radio, 'version'), 'v1.17.0 (Build: 1 Oct 2026)');
      },
    );

    test('an "XX|" prefix from the companion is reflected in the reply', () {
      final (radio, node, _) = setUpNode();
      login(radio, 'password');
      expect(cli(radio, '0A|get tx'), '0A|> 20');
      expect(cli(radio, '  1F|ver'), '1F|v1.17.0 (Build: 1 Oct 2026)');
      expect(node.commands.last, 'ver');
    });

    test('anything else is an unknown command', () {
      final (radio, _, _) = setUpNode();
      login(radio, 'password');
      expect(cli(radio, 'frobnicate'), 'Unknown command');
    });
  });
}
