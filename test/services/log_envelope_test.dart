import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/log_envelope.dart';

List<int> _bytes(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Vectors made by tools/logs/make_envelope_vectors.py with Python's
/// `cryptography` library, an implementation independent of this app.
final _vectors =
    (jsonDecode(
              File(
                'test/fixtures/log_envelope_vectors.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>)['vectors']
        as List<dynamic>;

void main() {
  test('matches the independent reference byte for byte', () async {
    expect(_vectors, hasLength(3));
    for (final v in _vectors.cast<Map<String, dynamic>>()) {
      final ephemeral = await X25519().newKeyPairFromSeed(
        _bytes(v['ephemeralPrivate'] as String),
      );
      final sealed = await LogEnvelope.seal(
        _bytes(v['plaintext'] as String),
        _bytes(v['recipientPublic'] as String),
        ephemeral: ephemeral,
        nonce: _bytes(v['nonce'] as String),
      );
      expect(_hex(sealed), v['envelope']);
    }
  });

  test('a fresh package opens with the recipient key and no other', () async {
    final recipient = await X25519().newKeyPair();
    final recipientPublic = (await recipient.extractPublicKey()).bytes;
    final plaintext = utf8.encode('log package');
    final sealed = await LogEnvelope.seal(plaintext, recipientPublic);

    expect(sealed.sublist(0, 5), [...LogEnvelope.magic, LogEnvelope.version]);
    expect(sealed.sublist(5, 9), LogEnvelope.keyId(recipientPublic));
    expect(sealed.length, LogEnvelope.headerLength + plaintext.length + 16);
    expect(await _open(sealed, recipient), plaintext);
    await expectLater(
      _open(sealed, await X25519().newKeyPair()),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('two packages never share a key pair or a nonce', () async {
    final recipientPublic =
        (await (await X25519().newKeyPair()).extractPublicKey()).bytes;
    final a = await LogEnvelope.seal([1], recipientPublic);
    final b = await LogEnvelope.seal([1], recipientPublic);
    expect(a.sublist(9, 41), isNot(b.sublist(9, 41)));
    expect(a.sublist(41, 53), isNot(b.sublist(41, 53)));
  });

  test('refuses a public key of the wrong size', () {
    expect(
      () => LogEnvelope.seal([1], List.filled(31, 0)),
      throwsArgumentError,
    );
  });
}

Future<List<int>> _open(List<int> sealed, SimpleKeyPair recipient) async {
  final header = sealed.sublist(0, LogEnvelope.headerLength);
  final ephemeralPublic = header.sublist(9, 41);
  final recipientPublic = (await recipient.extractPublicKey()).bytes;
  final shared = await X25519().sharedSecretKey(
    keyPair: recipient,
    remotePublicKey: SimplePublicKey(ephemeralPublic, type: KeyPairType.x25519),
  );
  final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: shared,
    nonce: [...ephemeralPublic, ...recipientPublic],
    info: utf8.encode('offband-log-v1'),
  );
  final body = sealed.sublist(LogEnvelope.headerLength);
  return AesGcm.with256bits().decrypt(
    SecretBox(
      body.sublist(0, body.length - 16),
      nonce: header.sublist(41, 53),
      mac: Mac(body.sublist(body.length - 16)),
    ),
    secretKey: key,
    aad: header,
  );
}
