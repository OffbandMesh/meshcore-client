import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

/// Encrypts a log package so only Offband can read it (#1208). The format
/// matches `OffbandMesh/log-intake` README and `tools/logs/offband_logs.py`:
///
/// `OBLG` | version 1 | key id (4) | ephemeral X25519 public (32) | nonce (12)
/// | AES-256-GCM ciphertext + 16-byte tag, with the 53-byte header as AAD.
///
/// The key is HKDF-SHA256 of the X25519 secret, salted with the ephemeral
/// and recipient public keys, info `offband-log-v1`. Every package gets a
/// fresh ephemeral key pair, so the app holds only Offband's public key and
/// needs nothing back from anyone.
class LogEnvelope {
  const LogEnvelope._();

  static const List<int> magic = [0x4F, 0x42, 0x4C, 0x47];
  static const int version = 1;
  static const int headerLength = 53;
  static const int keyLength = 32;
  static const int nonceLength = 12;
  static final List<int> _info = utf8.encode('offband-log-v1');

  /// First 4 bytes of SHA-256 of [publicKey]: which key an upload was sealed
  /// for, so the key can be rotated without guessing.
  static List<int> keyId(List<int> publicKey) =>
      crypto.sha256.convert(publicKey).bytes.sublist(0, 4);

  /// Throws [ArgumentError] when [recipientPublicKey] is not a 32-byte key:
  /// a package sealed to the wrong key could never be read.
  static Future<Uint8List> seal(
    List<int> plaintext,
    List<int> recipientPublicKey, {
    SimpleKeyPair? ephemeral,
    List<int>? nonce,
  }) async {
    if (recipientPublicKey.length != keyLength) {
      throw ArgumentError.value(
        recipientPublicKey.length,
        'recipientPublicKey',
        'must be $keyLength bytes',
      );
    }
    final x25519 = X25519();
    final pair = ephemeral ?? await x25519.newKeyPair();
    final ephemeralPublic = (await pair.extractPublicKey()).bytes;
    final shared = await x25519.sharedSecretKey(
      keyPair: pair,
      remotePublicKey: SimplePublicKey(
        recipientPublicKey,
        type: KeyPairType.x25519,
      ),
    );
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: [...ephemeralPublic, ...recipientPublicKey],
      info: _info,
    );
    final aes = AesGcm.with256bits();
    final iv = nonce ?? aes.newNonce();
    final header = [
      ...magic,
      version,
      ...keyId(recipientPublicKey),
      ...ephemeralPublic,
      ...iv,
    ];
    final box = await aes.encrypt(
      plaintext,
      secretKey: key,
      nonce: iv,
      aad: header,
    );
    return Uint8List.fromList([...header, ...box.cipherText, ...box.mac.bytes]);
  }
}
