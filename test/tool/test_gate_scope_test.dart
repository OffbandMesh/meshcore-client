import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_gate.dart';

List<ChangedFile> _changed(Map<String, String> files) =>
    files.entries.map((e) => ChangedFile(e.value, e.key)).toList();

void main() {
  group('prType', () {
    test('reads the type with and without a scope', () {
      expect(prType('fix(#1028): wait for the radio'), 'fix');
      expect(prType('feat: a new thing'), 'feat');
      expect(prType('Refactor(#1): tidy'), 'refactor');
      expect(prType('feat!: breaking'), 'feat');
    });

    test('is null when the title has no conventional type', () {
      expect(prType('Wait for the radio before adding'), isNull);
      expect(prType('fix the add path'), isNull);
      expect(prType(''), isNull);
    });
  });

  group('parseNameStatus', () {
    // `git diff --name-status -z`: every field ends in NUL; a rename or copy
    // carries the old path, then the new one.
    test('keeps the new path of a rename and the status letter', () {
      final files = parseNameStatus(
        'M\x00lib/a.dart\x00R087\x00test/old_test.dart\x00test/new_test.dart\x00'
        'D\x00test/gone_test.dart\x00C100\x00lib/x.dart\x00lib/y.dart\x00',
      );
      expect(files.map((f) => f.path), [
        'lib/a.dart',
        'test/new_test.dart',
        'test/gone_test.dart',
        'lib/y.dart',
      ]);
      expect(files[2].removed, isTrue);
      expect(files.first.removed, isFalse);
    });

    test('takes a path with a space, tab or newline as it is, unquoted', () {
      final files = parseNameStatus(
        'M\x00lib/odd name.dart\x00A\x00test/tab\there_test.dart\x00'
        'M\x00lib/new\nline.dart\x00',
      );
      expect(files.map((f) => f.path), [
        'lib/odd name.dart',
        'test/tab\there_test.dart',
        'lib/new\nline.dart',
      ]);
    });

    test('a path git would quote still counts as app code', () {
      final d = decideScope(
        title: 'fix: x',
        changed: parseNameStatus('M\x00lib/odd "name".dart\x00'),
      );
      expect(d.passed, isFalse);
    });

    test('ignores a truncated trailing record', () {
      final files = parseNameStatus(
        'M\x00lib/a.dart\x00R100\x00lib/b.dart\x00',
      );
      expect(files.map((f) => f.path), ['lib/a.dart']);
    });
  });

  group('entries file', () {
    test('is NUL-separated so xargs -0 passes each path whole', () {
      expect(
        encodeEntries(['test/a b_test.dart', 'test/c_test.dart']),
        'test/a b_test.dart\x00test/c_test.dart\x00',
      );
      expect(encodeEntries([]), '');
    });
  });

  group('check 1: a code change needs a test change', () {
    test('code with no test change fails and names the code files', () {
      final d = decideScope(
        title: 'fix(#1): something',
        changed: _changed({'lib/connector/x.dart': 'M'}),
      );
      expect(d.passed, isFalse);
      expect(d.runEvaluate, isFalse);
      expect(d.message, contains('lib/connector/x.dart'));
    });

    test('a title with no type is enforced, not exempt', () {
      final d = decideScope(
        title: 'Make the add wait',
        changed: _changed({'lib/x.dart': 'M'}),
      );
      expect(d.passed, isFalse);
    });

    test('a deleted test does not count as a test change', () {
      final d = decideScope(
        title: 'fix: x',
        changed: _changed({'lib/x.dart': 'M', 'test/x_test.dart': 'D'}),
      );
      expect(d.passed, isFalse);
    });

    test('a changed helper that is not a *_test.dart does not count', () {
      final d = decideScope(
        title: 'fix: x',
        changed: _changed({'lib/x.dart': 'M', 'test/helpers/fake.dart': 'M'}),
      );
      expect(d.passed, isFalse);
    });

    test('code with a changed test passes and hands the tests to check 2', () {
      final d = decideScope(
        title: 'fix(#1): x',
        changed: _changed({
          'lib/x.dart': 'M',
          'test/x_test.dart': 'A',
          'test/y_test.dart': 'M',
          'test/z_test.dart': 'D',
        }),
      );
      expect(d.passed, isTrue);
      expect(d.runEvaluate, isTrue);
      expect(d.testEntries, ['test/x_test.dart', 'test/y_test.dart']);
    });

    test('translations alone are not app code', () {
      final d = decideScope(
        title: 'fix: wording',
        changed: _changed({
          'lib/l10n/app_en.arb': 'M',
          'lib/l10n/app_localizations_en.dart': 'M',
        }),
      );
      expect(d.passed, isTrue);
      expect(d.runEvaluate, isFalse);
    });

    test('no code change passes without running check 2', () {
      final d = decideScope(
        title: 'fix: docs and a tool',
        changed: _changed({'README.md': 'M', 'tool/x.dart': 'M'}),
      );
      expect(d.passed, isTrue);
      expect(d.runEvaluate, isFalse);
    });

    test('a test-only change passes without running check 2', () {
      final d = decideScope(
        title: 'test: cover the self-key path',
        changed: _changed({'test/x_test.dart': 'A'}),
      );
      expect(d.passed, isTrue);
      expect(d.runEvaluate, isFalse);
    });
  });

  group('isNewCapability', () {
    test('only a feat title is a new capability', () {
      expect(isNewCapability('feat(#1): x'), isTrue);
      expect(isNewCapability('Feat!: x'), isTrue);
      expect(isNewCapability('fix(#1): x'), isFalse);
      expect(isNewCapability('perf: x'), isFalse);
      expect(isNewCapability('a feat with no type'), isFalse);
      expect(isNewCapability(''), isFalse);
    });
  });

  group('exempt types', () {
    for (final type in exemptTypes) {
      test('$type is exempt and says so', () {
        final d = decideScope(
          title: '$type(#1): no behavior change',
          changed: _changed({'lib/x.dart': 'M'}),
        );
        expect(d.passed, isTrue);
        expect(d.runEvaluate, isFalse);
        expect(d.message, startsWith('EXEMPT'));
      });
    }

    test('fix and feat are enforced', () {
      for (final type in ['fix', 'feat', 'perf']) {
        final d = decideScope(
          title: '$type: x',
          changed: _changed({'lib/x.dart': 'M'}),
        );
        expect(d.passed, isFalse, reason: type);
      }
    });
  });
}
