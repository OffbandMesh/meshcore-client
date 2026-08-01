import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';

/// Cross-repo contract tests for the `@[name]` self-mention rule (client #486,
/// firmware #510). Firmware implements the identical rule, so any change that
/// breaks one of these breaks agreement with the device and must ship in an
/// aligned build pair.
void main() {
  group('@[name] matching', () {
    test('matches the canonical bracketed form', () {
      expect(
        MeshCoreConnector.mentionsName('hey @[Ben] you there', 'Ben'),
        isTrue,
      );
    });

    test('bare @name does not match', () {
      expect(
        MeshCoreConnector.mentionsName('hey @Ben you there', 'Ben'),
        isFalse,
      );
    });

    test('matches as a plain substring, not anchored or word-bounded', () {
      // Deliberate: the rule is `contains`, and firmware must agree.
      expect(MeshCoreConnector.mentionsName('x@[Ben]y', 'Ben'), isTrue);
    });

    test('the name is compared VERBATIM, whitespace included (#497)', () {
      // Owner ruling 2026-08-01: @[name] is a wire token carrying the advert
      // name byte-for-byte. A name with surrounding spaces is a DIFFERENT
      // name, and trimming it here is what stopped mentions beeping.
      expect(MeshCoreConnector.mentionsName('yo @[Ben]', '  Ben  '), isFalse);
      expect(
        MeshCoreConnector.mentionsName('yo @[  Ben  ]', '  Ben  '),
        isTrue,
      );
      expect(MeshCoreConnector.mentionsName('yo @[Ben ]', 'Ben '), isTrue);
      expect(MeshCoreConnector.mentionsName('yo @[Ben]', 'Ben '), isFalse);
    });

    test('empty or whitespace-only self-name matches nothing', () {
      expect(MeshCoreConnector.mentionsName('yo @[Ben]', ''), isFalse);
      expect(MeshCoreConnector.mentionsName('yo @[Ben]', '   '), isFalse);
      expect(MeshCoreConnector.mentionsName('yo @[Ben]', null), isFalse);
    });

    test('a name that is not mentioned does not match', () {
      expect(MeshCoreConnector.mentionsName('yo @[Alice]', 'Ben'), isFalse);
      expect(
        MeshCoreConnector.mentionsName('no mentions here', 'Ben'),
        isFalse,
      );
    });
  });

  group('ASCII-only case folding (owner decision 2026-07-31, #486)', () {
    test('ASCII names match case-insensitively in both directions', () {
      expect(MeshCoreConnector.mentionsName('yo @[BEN]', 'ben'), isTrue);
      expect(MeshCoreConnector.mentionsName('yo @[ben]', 'BEN'), isTrue);
      expect(MeshCoreConnector.mentionsName('yo @[BeN]', 'bEn'), isTrue);
    });

    test('non-ASCII names compare case-sensitively', () {
      // The deliberate divergence from String.toLowerCase(): firmware folds
      // bytes and cannot do Unicode case mapping, so the client must not
      // either, or the two sides disagree on the same message.
      expect(MeshCoreConnector.mentionsName('yo @[Érik]', 'Érik'), isTrue);
      expect(MeshCoreConnector.mentionsName('yo @[érik]', 'Érik'), isFalse);
      expect(MeshCoreConnector.mentionsName('yo @[ÉRIK]', 'érik'), isFalse);
    });

    test('ASCII folding still applies around non-ASCII characters', () {
      // "Ben-Érik": the ASCII half folds, the accented character does not.
      expect(
        MeshCoreConnector.mentionsName('yo @[BEN-Érik]', 'ben-Érik'),
        isTrue,
      );
      expect(
        MeshCoreConnector.mentionsName('yo @[BEN-érik]', 'ben-Érik'),
        isFalse,
      );
    });

    test('non-letter ASCII is untouched by the fold', () {
      expect(MeshCoreConnector.mentionsName('yo @[Node_7]', 'node_7'), isTrue);
      expect(MeshCoreConnector.mentionsName('yo @[N0DE-7]', 'n0de-7'), isTrue);
    });

    test(
      'names containing spaces work, which bare @name could not delimit',
      () {
        expect(
          MeshCoreConnector.mentionsName('yo @[Base Station]', 'base station'),
          isTrue,
        );
      },
    );
  });
}
