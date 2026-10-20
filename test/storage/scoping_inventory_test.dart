import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/scoping_inventory.dart';

/// #936: the scoping verdict for every persistence surface, enforced.
///
/// Feature #853's acceptance bar is that every store has a verified scoping
/// verdict and no hole remains. Before this test, "verified" meant a human
/// re-reading an audit in an issue body, which is how three separate bleeds
/// (#754, #854, #856) survived earlier rounds of bleed fixes.
///
/// The scan deliberately covers one shape: a `const String` whose value is
/// lower snake_case, which is the shape every storage key in this repo uses.
/// What it would miss, stated plainly so nobody mistakes it for total: a key
/// built inline at the call site without a constant, and a key that is not
/// snake_case. Covering every string literal in `lib/` was tried and rejected:
/// it fires on asset paths and log tags, and a check that cries wolf gets
/// worked around, which is the #927 lesson.
void main() {
  final declaredKeys = {for (final s in storageSurfaces) s.key};

  group('inventory is internally coherent', () {
    test('no surface is declared twice', () {
      expect(
        declaredKeys.length,
        storageSurfaces.length,
        reason: 'a duplicated key means two verdicts for one surface',
      );
    });

    test('every verdict carries a reason', () {
      for (final s in storageSurfaces) {
        expect(
          s.reason.trim(),
          isNotEmpty,
          reason:
              '${s.key} has no reason. An unexplained verdict is how a '
              'surface gets re-opened as a hole later',
        );
        expect(s.owner.trim(), isNotEmpty, reason: '${s.key} has no owner');
      }
    });

    test('every known hole names its issue', () {
      final holes = storageSurfaces.where(
        (s) => s.verdict == ScopingVerdict.knownHole,
      );
      expect(holes, isNotEmpty, reason: 'sanity: the holes are the point');
      for (final s in holes) {
        expect(
          s.issue,
          isNotNull,
          reason: '${s.key} is a hole with no tracking issue',
        );
      }
    });

    test('nothing is both a surface and a non-storage constant', () {
      final overlap = declaredKeys.intersection(
        nonStorageConstants.keys.toSet(),
      );
      expect(
        overlap,
        isEmpty,
        reason: 'a key cannot be both a storage surface and not one',
      );
    });

    test('the known holes are exactly the ones Epic B fixes', () {
      // Pins the set. A NEW hole cannot hide among the known ones, and a hole
      // fixed in Epic B cannot be left mislabelled here.
      final holes = {
        for (final s in storageSurfaces)
          if (s.verdict == ScopingVerdict.knownHole) s.issue!,
      };
      expect(holes, {854, 855, 856});
    });
  });

  group('source scan', () {
    test('every candidate key in lib/ is classified', () {
      final found = _scanLibForCandidateKeys();

      expect(
        found,
        isNotEmpty,
        reason: 'the scan found nothing, so it is broken, not clean',
      );

      final unclassified =
          found.keys
              .where((k) => !declaredKeys.contains(k))
              .where((k) => !nonStorageConstants.containsKey(k))
              .toList()
            ..sort();

      expect(
        unclassified,
        isEmpty,
        reason:
            'undeclared candidate keys:\n'
            '${unclassified.map((k) => '  $k  (${found[k]})').join('\n')}\n\n'
            'Add each to storageSurfaces with a verdict and a reason, or to '
            'nonStorageConstants with why it is not a key. This is the gate '
            'Feature #853 asked for: a new global key cannot land unnoticed.',
      );
    });

    test('nothing declared has vanished from the source', () {
      // The other direction: a surface removed from the code but left in the
      // inventory is a lie in the opposite direction. pending_messages will
      // trip this the moment Epic B deletes it, which is intended.
      final found = _scanLibForCandidateKeys().keys.toSet();
      final stale = declaredKeys.difference(found).toList()..sort();

      expect(
        stale,
        isEmpty,
        reason:
            'declared but not found in lib/:\n${stale.join('\n')}\n\n'
            'If the surface was deleted, remove its row. If it was renamed, '
            'update it.',
      );
    });
  });

  group('the gate can fail', () {
    // A check nobody has watched fail is not evidence. These run the scan
    // logic over synthetic source instead of lib/, so the failure is provable
    // without breaking the real tree.

    test('an undeclared snake_case key is caught', () {
      final found = _extractCandidateKeys(
        "class Foo { static const String _k = 'a_brand_new_global_key'; }",
        'synthetic.dart',
      );

      expect(found.keys, contains('a_brand_new_global_key'));
      expect(
        declaredKeys.contains('a_brand_new_global_key') ||
            nonStorageConstants.containsKey('a_brand_new_global_key'),
        isFalse,
        reason: 'so the real test would fail on it, which is the point',
      );
    });

    test('a declared key is not flagged', () {
      final found = _extractCandidateKeys(
        "const String _p = 'channel_messages_';",
        'synthetic.dart',
      );

      expect(found.keys, contains('channel_messages_'));
      expect(declaredKeys, contains('channel_messages_'));
    });

    test('a non-key shape is ignored rather than demanding a verdict', () {
      final found = _extractCandidateKeys(
        "const String a = 'assets/radio_presets/';\n"
            "const String b = 'com.meshcore.open';\n"
            "const String c = 'linux connect stage failure';",
        'synthetic.dart',
      );

      expect(
        found,
        isEmpty,
        reason:
            'paths, package ids and prose must not demand a verdict, or '
            'the check gets worked around',
      );
    });
  });
}

/// `const String <name> = '<lower_snake_case>'`, the shape every storage key in
/// this repo is declared with.
///
/// Leading underscores are allowed in the VALUE because internal markers use
/// them (`__msgrows_migrated`). The first run of this test declared that key
/// and then reported it missing, because the pattern required a letter first.
final RegExp _candidate = RegExp(
  r"const\s+String\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*'(_{0,2}[a-z][a-z0-9_]*)'",
);

Map<String, String> _extractCandidateKeys(String source, String path) {
  final out = <String, String>{};
  for (final m in _candidate.allMatches(source)) {
    out[m.group(1)!] = path;
  }
  return out;
}

/// Candidate key -> the file it was found in.
Map<String, String> _scanLibForCandidateKeys() {
  final lib = Directory('lib');
  expect(
    lib.existsSync(),
    isTrue,
    reason: 'this test must run from the package root so lib/ is visible',
  );

  final out = <String, String>{};
  for (final f in lib.listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    if (f.path.endsWith('.g.dart')) continue; // generated, not authored
    out.addAll(_extractCandidateKeys(f.readAsStringSync(), f.path));
  }
  return out;
}
