import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/message.dart';
import 'package:meshcore_open/services/message_retry_service.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Replicates the SHA-256 computation from [MessageRetryService.computeExpectedAckHash]
/// so tests can cross-check without calling the real implementation twice.
int _manualAckHash(
  int timestampSeconds,
  int attemptMasked, // already masked to 0x03
  String text,
  Uint8List senderPubKey,
) {
  final textBytes = utf8.encode(text);
  final buffer = Uint8List(4 + 1 + textBytes.length + senderPubKey.length);
  int offset = 0;

  buffer[offset++] = timestampSeconds & 0xFF;
  buffer[offset++] = (timestampSeconds >> 8) & 0xFF;
  buffer[offset++] = (timestampSeconds >> 16) & 0xFF;
  buffer[offset++] = (timestampSeconds >> 24) & 0xFF;
  buffer[offset++] = attemptMasked & 0xFF;

  buffer.setRange(offset, offset + textBytes.length, textBytes);
  offset += textBytes.length;
  buffer.setRange(offset, offset + senderPubKey.length, senderPubKey);

  final hash = sha256.convert(buffer);
  final bytes = Uint8List.fromList(hash.bytes.sublist(0, 4));
  return (bytes[3] << 24) | (bytes[2] << 16) | (bytes[1] << 8) | bytes[0];
}

Uint8List _makeKey(int seed) {
  final key = Uint8List(32);
  for (int i = 0; i < 32; i++) {
    key[i] = (seed + i) & 0xFF;
  }
  return key;
}

Uint8List _makeRecipientKey() {
  final key = Uint8List(32);
  for (int i = 0; i < 32; i++) {
    key[i] = (0xAA + i) & 0xFF;
  }
  return key;
}

Contact _makeContact({
  required Uint8List publicKey,
  int pathLength = -1,
  List<int> path = const [],
}) {
  return Contact(
    publicKey: publicKey,
    name: 'Test',
    type: 1,
    pathLength: pathLength,
    path: Uint8List.fromList(path),
    lastSeen: DateTime.now(),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // Fixed inputs reused across groups
  const int fixedTs = 1700000000;
  const String fixedText = 'Hello mesh';
  final Uint8List fixedKey = _makeKey(0x11);
  final Uint8List recipientKey = _makeRecipientKey();

  // -------------------------------------------------------------------------
  group('computeExpectedAckHash, attempt masking', () {
    test('attempts 0–3 all produce different hashes', () {
      final hashes = List.generate(
        4,
        (i) => MessageRetryService.computeExpectedAckHash(
          fixedTs,
          i,
          fixedText,
          fixedKey,
        ),
      );

      // All four must be pairwise distinct
      for (int i = 0; i < hashes.length; i++) {
        for (int j = i + 1; j < hashes.length; j++) {
          expect(
            hashes[i],
            isNot(equals(hashes[j])),
            reason: 'attempt $i and attempt $j should produce different hashes',
          );
        }
      }
    });

    test('attempt 4 produces same hash as attempt 0 (4 & 0x03 == 0)', () {
      final hash0 = MessageRetryService.computeExpectedAckHash(
        fixedTs,
        0,
        fixedText,
        fixedKey,
      );
      final hash4 = MessageRetryService.computeExpectedAckHash(
        fixedTs,
        4,
        fixedText,
        fixedKey,
      );
      expect(hash4, equals(hash0));
    });

    test('attempt 5 produces same hash as attempt 1 (5 & 0x03 == 1)', () {
      final hash1 = MessageRetryService.computeExpectedAckHash(
        fixedTs,
        1,
        fixedText,
        fixedKey,
      );
      final hash5 = MessageRetryService.computeExpectedAckHash(
        fixedTs,
        5,
        fixedText,
        fixedKey,
      );
      expect(hash5, equals(hash1));
    });

    test('attempt 7 produces same hash as attempt 3 (7 & 0x03 == 3)', () {
      final hash3 = MessageRetryService.computeExpectedAckHash(
        fixedTs,
        3,
        fixedText,
        fixedKey,
      );
      final hash7 = MessageRetryService.computeExpectedAckHash(
        fixedTs,
        7,
        fixedText,
        fixedKey,
      );
      expect(hash7, equals(hash3));
    });

    test('same inputs always produce the same hash (deterministic)', () {
      final first = MessageRetryService.computeExpectedAckHash(
        fixedTs,
        2,
        fixedText,
        fixedKey,
      );
      final second = MessageRetryService.computeExpectedAckHash(
        fixedTs,
        2,
        fixedText,
        fixedKey,
      );
      expect(first, equals(second));
    });

    test('hash matches manual SHA-256 computation', () {
      for (int attempt = 0; attempt < 4; attempt++) {
        final actual = MessageRetryService.computeExpectedAckHash(
          fixedTs,
          attempt,
          fixedText,
          fixedKey,
        );
        final expected = _manualAckHash(fixedTs, attempt, fixedText, fixedKey);
        expect(
          actual,
          equals(expected),
          reason: 'mismatch at attempt $attempt',
        );
      }
    });

    test('different timestamps produce different hashes', () {
      final hashA = MessageRetryService.computeExpectedAckHash(
        1700000000,
        0,
        fixedText,
        fixedKey,
      );
      final hashB = MessageRetryService.computeExpectedAckHash(
        1700000001,
        0,
        fixedText,
        fixedKey,
      );
      expect(hashA, isNot(equals(hashB)));
    });

    test('different texts produce different hashes', () {
      final hashA = MessageRetryService.computeExpectedAckHash(
        fixedTs,
        0,
        'Hello mesh',
        fixedKey,
      );
      final hashB = MessageRetryService.computeExpectedAckHash(
        fixedTs,
        0,
        'Hello mesh!',
        fixedKey,
      );
      expect(hashA, isNot(equals(hashB)));
    });

    test('different sender keys produce different hashes', () {
      final keyA = _makeKey(0x01);
      final keyB = _makeKey(0x02);
      final hashA = MessageRetryService.computeExpectedAckHash(
        fixedTs,
        0,
        fixedText,
        keyA,
      );
      final hashB = MessageRetryService.computeExpectedAckHash(
        fixedTs,
        0,
        fixedText,
        keyB,
      );
      expect(hashA, isNot(equals(hashB)));
    });
  });

  // -------------------------------------------------------------------------
  group('buildSendTextMsgFrame, attempt encoding', () {
    // Frame layout: [cmd(1)][txtType(1)][attempt(1)][timestamp(4)][pubKeyPrefix(6)][text][null(1)]
    // So byte index 2 carries the raw attempt & 0xFF.

    test('attempt 0 → byte[2] is 0', () {
      final frame = buildSendTextMsgFrame(
        recipientKey,
        'hi',
        attempt: 0,
        timestampSeconds: fixedTs,
      );
      expect(frame[2], equals(0));
    });

    test('attempt 3 → byte[2] is 3', () {
      final frame = buildSendTextMsgFrame(
        recipientKey,
        'hi',
        attempt: 3,
        timestampSeconds: fixedTs,
      );
      expect(frame[2], equals(3));
    });

    test('attempt 4 → byte[2] is 4 (raw value, not clamped to 3)', () {
      final frame = buildSendTextMsgFrame(
        recipientKey,
        'hi',
        attempt: 4,
        timestampSeconds: fixedTs,
      );
      expect(frame[2], equals(4));
    });

    test('attempt 255 → byte[2] is 255', () {
      final frame = buildSendTextMsgFrame(
        recipientKey,
        'hi',
        attempt: 255,
        timestampSeconds: fixedTs,
      );
      expect(frame[2], equals(255));
    });

    test('attempt 256 → byte[2] is 255 (clamped, not wrapped)', () {
      final frame = buildSendTextMsgFrame(
        recipientKey,
        'hi',
        attempt: 256,
        timestampSeconds: fixedTs,
      );
      expect(frame[2], equals(255));
    });

    test('byte[0] is cmdSendTxtMsg (2)', () {
      final frame = buildSendTextMsgFrame(
        recipientKey,
        'hi',
        attempt: 0,
        timestampSeconds: fixedTs,
      );
      expect(frame[0], equals(cmdSendTxtMsg));
    });

    test('byte[1] is txtTypePlain (0)', () {
      final frame = buildSendTextMsgFrame(
        recipientKey,
        'hi',
        attempt: 0,
        timestampSeconds: fixedTs,
      );
      expect(frame[1], equals(txtTypePlain));
    });

    test('timestamp bytes[3..6] are little-endian encoded', () {
      final frame = buildSendTextMsgFrame(
        recipientKey,
        'hi',
        attempt: 0,
        timestampSeconds: fixedTs,
      );
      final decoded =
          frame[3] | (frame[4] << 8) | (frame[5] << 16) | (frame[6] << 24);
      expect(decoded, equals(fixedTs));
    });

    test(
      'pub key prefix (bytes 7..12) matches first 6 bytes of recipient key',
      () {
        final frame = buildSendTextMsgFrame(
          recipientKey,
          'hi',
          attempt: 0,
          timestampSeconds: fixedTs,
        );
        expect(frame.sublist(7, 13), equals(recipientKey.sublist(0, 6)));
      },
    );

    test('frame is null-terminated after text', () {
      final frame = buildSendTextMsgFrame(
        recipientKey,
        'hi',
        attempt: 0,
        timestampSeconds: fixedTs,
      );
      expect(frame.last, equals(0));
    });
  });

  // -------------------------------------------------------------------------
  group(
    'ACK hash consistency between computeExpectedAckHash and firmware behavior',
    () {
      // The firmware reads the raw attempt byte from the frame, then masks it
      // with & 3 when computing the ACK hash.  Flutter does the same masking
      // inside computeExpectedAckHash.  So the two sides must agree.

      test('attempt 4: flutter hash (4 & 3 = 0) equals hash for attempt 0', () {
        // Flutter sends raw byte 4 in the frame, but computes hash with 4&3=0.
        // Firmware reads 4, masks to 0, computes same hash → they match.
        final hashFor4 = MessageRetryService.computeExpectedAckHash(
          fixedTs,
          4,
          fixedText,
          fixedKey,
        );
        final hashFor0 = MessageRetryService.computeExpectedAckHash(
          fixedTs,
          0,
          fixedText,
          fixedKey,
        );
        expect(hashFor4, equals(hashFor0));

        // Also confirm the frame byte is raw 4, not 0
        final frame = buildSendTextMsgFrame(
          recipientKey,
          fixedText,
          attempt: 4,
          timestampSeconds: fixedTs,
        );
        expect(frame[2], equals(4), reason: 'frame carries raw attempt byte');
      });

      test(
        'attempt 3: flutter hash equals hash computed directly for attempt 3',
        () {
          // 3 & 3 == 3, so no wrapping, both sides agree.
          final hashFor3 = MessageRetryService.computeExpectedAckHash(
            fixedTs,
            3,
            fixedText,
            fixedKey,
          );
          final hashFor3Direct = _manualAckHash(
            fixedTs,
            3,
            fixedText,
            fixedKey,
          );
          expect(hashFor3, equals(hashFor3Direct));

          final frame = buildSendTextMsgFrame(
            recipientKey,
            fixedText,
            attempt: 3,
            timestampSeconds: fixedTs,
          );
          expect(frame[2], equals(3));
        },
      );

      test(
        'attempt 3 and attempt 4 produce DIFFERENT hashes (3&3=3 vs 4&3=0)',
        () {
          final hash3 = MessageRetryService.computeExpectedAckHash(
            fixedTs,
            3,
            fixedText,
            fixedKey,
          );
          final hash4 = MessageRetryService.computeExpectedAckHash(
            fixedTs,
            4,
            fixedText,
            fixedKey,
          );
          expect(hash3, isNot(equals(hash4)));
        },
      );

      test('attempt 8 (8&3=0) produces the same hash as attempt 0', () {
        final hash8 = MessageRetryService.computeExpectedAckHash(
          fixedTs,
          8,
          fixedText,
          fixedKey,
        );
        final hash0 = MessageRetryService.computeExpectedAckHash(
          fixedTs,
          0,
          fixedText,
          fixedKey,
        );
        expect(hash8, equals(hash0));
      });

      test(
        'hash cycle repeats every 4 attempts (modular arithmetic holds)',
        () {
          for (int base = 0; base < 4; base++) {
            final hashBase = MessageRetryService.computeExpectedAckHash(
              fixedTs,
              base,
              fixedText,
              fixedKey,
            );
            final hashPlus4 = MessageRetryService.computeExpectedAckHash(
              fixedTs,
              base + 4,
              fixedText,
              fixedKey,
            );
            final hashPlus8 = MessageRetryService.computeExpectedAckHash(
              fixedTs,
              base + 8,
              fixedText,
              fixedKey,
            );
            expect(
              hashPlus4,
              equals(hashBase),
              reason: 'attempt ${base + 4} should match attempt $base',
            );
            expect(
              hashPlus8,
              equals(hashBase),
              reason: 'attempt ${base + 8} should match attempt $base',
            );
          }
        },
      );
    },
  );

  // -------------------------------------------------------------------------
  group('_AckHashMapping.attemptIndex, indirect verification via public API', () {
    // _AckHashMapping is private; we validate its purpose indirectly: that
    // computeExpectedAckHash records the correct per-attempt hash so that the
    // right hash is matched when an ACK arrives.

    test('each attempt index 0–3 produces a distinct 4-byte hash', () {
      final hashes = <String, int>{};
      for (int attempt = 0; attempt < 4; attempt++) {
        final hash = MessageRetryService.computeExpectedAckHash(
          fixedTs,
          attempt,
          fixedText,
          fixedKey,
        );
        final hex = hash.toRadixString(16).padLeft(8, '0');
        expect(
          hashes.containsKey(hex),
          isFalse,
          reason: 'attempt $attempt collides with attempt ${hashes[hex]}',
        );
        hashes[hex] = attempt;
      }
      expect(hashes.length, equals(4));
    });

    test(
      'attempt index wraps: hash for attempt 4 matches stored hash for attempt 0',
      () {
        final storedHash = MessageRetryService.computeExpectedAckHash(
          fixedTs,
          0,
          fixedText,
          fixedKey,
        );
        // Simulates firmware reading raw attempt=4 and masking to 0 for hash.
        final firmwareComputedHash = _manualAckHash(
          fixedTs,
          4 & 0x03, // firmware masks here
          fixedText,
          fixedKey,
        );
        expect(firmwareComputedHash, equals(storedHash));
      },
    );

    test(
      'attempt index 1 and 5 map to the same slot, ACK from either retry is matched',
      () {
        final hashForAttempt1 = MessageRetryService.computeExpectedAckHash(
          fixedTs,
          1,
          fixedText,
          fixedKey,
        );
        final hashForAttempt5 = MessageRetryService.computeExpectedAckHash(
          fixedTs,
          5,
          fixedText,
          fixedKey,
        );
        // Both should produce the identical bytes, confirming the service
        // would record and match the correct attempt index.
        expect(hashForAttempt5, equals(hashForAttempt1));
      },
    );
  });

  group('sendMessageWithRetry, auto path fallback', () {
    test(
      'preserves the contact path when auto-selection returns null',
      () async {
        final retryService = MessageRetryService();
        Message? addedMessage;
        final contact = _makeContact(
          publicKey: recipientKey,
          pathLength: 2,
          path: const [0x10, 0x20],
        );

        retryService.initialize(
          RetryServiceConfig(
            sendMessage: (_, _, _, _) async {},
            addMessage: (_, message) => addedMessage = message,
            updateMessage: (_) {},
            clearContactPath: (_) {},
            setContactPath: (_, _, _) {},
            selectRetryPath: (_, _, _, _) => null,
          ),
        );

        await retryService.sendMessageWithRetry(
          contact: contact,
          text: 'hello',
        );

        expect(addedMessage, isNotNull);
        expect(addedMessage!.pathLength, equals(2));
        expect(
          addedMessage!.pathBytes,
          equals(Uint8List.fromList([0x10, 0x20])),
        );
      },
    );

    test('uses flood when contact is in flood mode', () async {
      final retryService = MessageRetryService();
      Message? addedMessage;
      final contact = _makeContact(
        publicKey: recipientKey,
        pathLength: -1,
        path: const [],
      );

      retryService.initialize(
        RetryServiceConfig(
          sendMessage: (_, _, _, _) async {},
          addMessage: (_, message) => addedMessage = message,
          updateMessage: (_) {},
          clearContactPath: (_) {},
          setContactPath: (_, _, _) {},
        ),
      );

      await retryService.sendMessageWithRetry(contact: contact, text: 'hello');

      expect(addedMessage, isNotNull);
      expect(addedMessage!.pathLength, equals(-1));
      expect(addedMessage!.pathBytes, isEmpty);
    });
  });

  group('MTU-aware message size caps (#395)', () {
    test('maxContactMessageBytes shrinks with a smaller frame budget and the '
        'built frame fits the budget', () {
      // Omitting the budget matches passing maxFrameSize explicitly.
      expect(
        maxContactMessageBytes(),
        equals(maxContactMessageBytes(maxFrameBytes: maxFrameSize)),
      );
      // A 169-byte writable budget (ATT_MTU 172 - 3) caps below the default.
      final cap169 = maxContactMessageBytes(maxFrameBytes: 169);
      expect(cap169, lessThan(maxContactMessageBytes()));
      // Real DM frame overhead is 14 bytes; the built frame must fit 169.
      expect(14 + cap169, lessThanOrEqualTo(169));
    });

    test(
      'maxChannelMessageBytes subtracts the sender prefix so the frame never '
      'exceeds a small budget',
      () {
        const name = 'Bob';
        const budget = 120;
        final cap = maxChannelMessageBytes(name, maxFrameBytes: budget);
        expect(cap, lessThan(maxChannelMessageBytes(name)));
        // Wire text = "Bob: " (5 bytes) + userText; real channel overhead = 8.
        const realOverhead = 8;
        const prefix = 5; // "Bob: "
        expect(realOverhead + prefix + cap, lessThanOrEqualTo(budget));
      },
    );
  });

  group('send failure does not wedge the contact queue (#395)', () {
    test(
      'a throwing send marks the message failed and lets later sends proceed',
      () async {
        final retryService = MessageRetryService();
        final contact = _makeContact(
          publicKey: recipientKey,
          pathLength: 2,
          path: const [0x10, 0x20],
        );
        final updates = <Message>[];
        var sendCalls = 0;
        var failNext = true;

        retryService.initialize(
          RetryServiceConfig(
            sendMessage: (_, _, _, _) async {
              sendCalls++;
              if (failNext) {
                failNext = false;
                throw Exception(
                  'data longer than allowed, datalen: 170 > max: 169',
                );
              }
            },
            addMessage: (_, _) {},
            updateMessage: updates.add,
            clearContactPath: (_) {},
            setContactPath: (_, _, _) {},
          ),
        );

        await retryService.sendMessageWithRetry(
          contact: contact,
          text: 'too long',
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          updates.any((m) => m.status == MessageStatus.failed),
          isTrue,
          reason: 'a failed send must mark the message failed, not swallow it',
        );

        // The prior failure must not block a later DM to the same contact.
        await retryService.sendMessageWithRetry(
          contact: contact,
          text: 'ok now',
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          sendCalls,
          greaterThanOrEqualTo(2),
          reason: 'the per-contact queue must drain after a failed send',
        );

        retryService.dispose();
      },
    );
  });

  group('RESP_CODE_SENT correlation uses the radio hash (#449/#581)', () {
    // The radio is authoritative for the expected-ACK hash. Firmware forks
    // (Wadamesh on the HV4 TFT, in the #449 capture) build the payload
    // differently, so the client's locally recomputed hash can disagree while
    // delivery works perfectly. Correlation must not depend on that guess.
    const int radioHash = 0xDEADBEEF; // deliberately not the client's value

    test('a RESP_CODE_SENT hash the client did not predict still marks the '
        'message sent, and its ACK still marks it delivered', () async {
      final retryService = MessageRetryService();
      final contact = _makeContact(
        publicKey: recipientKey,
        pathLength: 2,
        path: const [0x10, 0x20],
      );
      final updates = <Message>[];

      retryService.initialize(
        RetryServiceConfig(
          sendMessage: (_, _, _, _) async {},
          addMessage: (_, _) {},
          updateMessage: updates.add,
          getSelfPublicKey: () => fixedKey,
        ),
      );

      await retryService.sendMessageWithRetry(
        contact: contact,
        text: 'Weird that I am getting errors though.',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final matched = retryService.updateMessageFromSent(radioHash, 4884);

      expect(
        matched,
        isTrue,
        reason:
            'the radio replied to our own CMD_SEND_TXT_MSG, so it must be '
            'correlated even though the hash is not the one we predicted',
      );
      expect(
        updates.last.status,
        equals(MessageStatus.sent),
        reason:
            'an unpredicted hash must not leave the message pending, '
            'because the 8s watchdog would then mark a delivered DM failed',
      );

      // The real ACK carries the radio's hash, not ours.
      retryService.handleAckReceived(radioHash, 7354);

      expect(
        updates.last.status,
        equals(MessageStatus.delivered),
        reason: 'the ACK must resolve against the radio-supplied hash',
      );

      retryService.dispose();
    });

    test('an unpredicted hash is not adopted while two sends are awaiting '
        'confirmation, because the correlation would be a guess', () async {
      final retryService = MessageRetryService();
      final contactA = _makeContact(publicKey: recipientKey, pathLength: 2);
      final contactB = _makeContact(publicKey: _makeKey(0x55), pathLength: 2);
      final updates = <Message>[];

      retryService.initialize(
        RetryServiceConfig(
          sendMessage: (_, _, _, _) async {},
          addMessage: (_, _) {},
          updateMessage: updates.add,
          getSelfPublicKey: () => fixedKey,
        ),
      );

      // Per-contact queues, so two contacts means two in flight at once.
      await retryService.sendMessageWithRetry(contact: contactA, text: 'a');
      await retryService.sendMessageWithRetry(contact: contactB, text: 'b');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        retryService.updateMessageFromSent(radioHash, 4884),
        isFalse,
        reason:
            'with two candidates the owner would rather keep the old '
            'behaviour than attach the confirmation to the wrong message',
      );

      retryService.dispose();
    });

    test('an unpredicted hash is not adopted while a channel send is also '
        'awaiting confirmation, because that frame could be either', () async {
      final retryService = MessageRetryService();
      final contact = _makeContact(publicKey: recipientKey, pathLength: 2);
      final updates = <Message>[];

      retryService.initialize(
        RetryServiceConfig(
          sendMessage: (_, _, _, _) async {},
          addMessage: (_, _) {},
          updateMessage: updates.add,
          getSelfPublicKey: () => fixedKey,
        ),
      );

      await retryService.sendMessageWithRetry(contact: contact, text: 'dm');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The connector passes false while _pendingChannelSentQueue is not
      // empty. Adopting here would attach a channel message's confirmation
      // to this DM and lose both.
      expect(
        retryService.updateMessageFromSent(
          radioHash,
          4884,
          allowUnpredictedAdoption: false,
        ),
        isFalse,
      );
      expect(
        updates.every((m) => m.status != MessageStatus.sent),
        isTrue,
        reason: 'the DM must not be marked sent off an ambiguous frame',
      );

      retryService.dispose();
    });

    test(
      'an unpredicted hash with nothing awaiting confirmation is ignored',
      () {
        final retryService = MessageRetryService();

        retryService.initialize(
          RetryServiceConfig(
            sendMessage: (_, _, _, _) async {},
            addMessage: (_, _) {},
            updateMessage: (_) {},
            getSelfPublicKey: () => fixedKey,
          ),
        );

        expect(
          retryService.updateMessageFromSent(radioHash, 4884),
          isFalse,
          reason:
              'with no send in flight the frame must fall through to the '
              'channel handler, not be swallowed',
        );

        retryService.dispose();
      },
    );

    test(
      'a late stray frame is not adopted once the message has resolved',
      () async {
        final retryService = MessageRetryService();
        final contact = _makeContact(publicKey: recipientKey, pathLength: 2);
        final updates = <Message>[];

        retryService.initialize(
          RetryServiceConfig(
            sendMessage: (_, _, _, _) async {},
            addMessage: (_, _) {},
            updateMessage: updates.add,
            getSelfPublicKey: () => fixedKey,
          ),
        );

        await retryService.sendMessageWithRetry(contact: contact, text: 'one');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(retryService.updateMessageFromSent(radioHash, 4884), isTrue);
        retryService.handleAckReceived(radioHash, 5000);
        expect(updates.last.status, equals(MessageStatus.delivered));

        // A second, unrelated unpredicted frame arrives afterwards. Nothing is
        // awaiting confirmation now, so it must not be attached to anything.
        expect(
          retryService.updateMessageFromSent(0xFEEDFACE, 4884),
          isFalse,
          reason: 'a stray frame must not be adopted by a resolved message',
        );

        retryService.dispose();
      },
    );

    test(
      'a hash the client did predict still matches on the fast path',
      () async {
        final retryService = MessageRetryService();
        final contact = _makeContact(publicKey: recipientKey, pathLength: 2);
        final updates = <Message>[];
        int? sentTs;
        int? sentAttempt;

        retryService.initialize(
          RetryServiceConfig(
            sendMessage: (_, _, attempt, ts) async {
              sentAttempt = attempt;
              sentTs = ts;
            },
            addMessage: (_, _) {},
            updateMessage: updates.add,
            getSelfPublicKey: () => fixedKey,
          ),
        );

        await retryService.sendMessageWithRetry(contact: contact, text: 'Yep.');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final predicted = _manualAckHash(
          sentTs!,
          sentAttempt! & 0x03,
          'Yep.',
          fixedKey,
        );

        expect(retryService.updateMessageFromSent(predicted, 3252), isTrue);
        expect(updates.last.status, equals(MessageStatus.sent));

        retryService.handleAckReceived(predicted, 1200);
        expect(updates.last.status, equals(MessageStatus.delivered));

        retryService.dispose();
      },
    );
  });
}
