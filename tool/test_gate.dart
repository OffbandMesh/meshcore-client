// CI test gate (#1173). Two checks on a pull request:
//
//  1. scope:    a change to app code (lib/) must come with an added or
//               changed *_test.dart file.
//  2. evaluate: those test files, run against the base branch's lib/, must
//               include at least one real test that fails or throws. A test
//               file that only fails to compile against the base does not
//               count: it proves nothing about behavior.
//
// A PR whose title declares a type that claims no new or fixed behavior is
// exempt from both. Anything else, including no type at all, is enforced.
// There is no flag or label that skips the gate (#927).
//
// Usage (from .github/workflows/test_gate.yml):
//   dart run tool/test_gate.dart scope --changed changed.txt --entries entries.txt
//   dart run tool/test_gate.dart evaluate --results results.jsonl
// The PR title is read from the PR_TITLE environment variable, never from an
// argument the workflow interpolates into a shell line.

import 'dart:convert';
import 'dart:io';

const exemptTypes = {
  'refactor',
  'chore',
  'ci',
  'build',
  'docs',
  'style',
  'test',
};

/// The conventional-commit type of a PR title, lowercased, or null when the
/// title does not start with one (`type:`, `type(scope):`, `type!:`).
String? prType(String title) {
  final match = RegExp(r'^([A-Za-z]+)(\([^)]*\))?!?:').firstMatch(title.trim());
  return match?.group(1)!.toLowerCase();
}

/// A `feat` PR adds a capability the base does not have, so there may be no
/// old behavior for its tests to fail. Owner decision 2026-11-23: for a
/// feature, a test that cannot compile against the base counts in check 2.
/// Everything else, fixes above all, must fail on the base for real.
bool isNewCapability(String title) => prType(title) == 'feat';

/// App code the gate holds to the rule. Translations and their generated
/// Dart are mechanical and excluded.
bool isAppCode(String path) =>
    path.startsWith('lib/') && !path.startsWith('lib/l10n/');

bool isTestEntry(String path) =>
    path.startsWith('test/') && path.endsWith('_test.dart');

class ChangedFile {
  const ChangedFile(this.status, this.path);
  final String status;
  final String path;

  bool get removed => status.startsWith('D');
}

/// Parses `git diff --name-status -z` output: NUL-terminated fields, paths
/// never quoted. A rename or copy (status R or C) carries the old path and
/// then the new one; the new path is the one that exists in the PR.
List<ChangedFile> parseNameStatus(String text) {
  final fields = text.split('\x00');
  // Every field ends in NUL, so the split leaves one empty string after the
  // last one. It is not a field, and must not be read as a path.
  if (fields.isNotEmpty && fields.last.isEmpty) fields.removeLast();
  final files = <ChangedFile>[];
  var i = 0;
  while (i < fields.length) {
    final status = fields[i];
    if (status.isEmpty) {
      i++;
      continue;
    }
    final paths = status.startsWith('R') || status.startsWith('C') ? 2 : 1;
    if (i + paths >= fields.length) break;
    files.add(ChangedFile(status, fields[i + paths]));
    i += paths + 1;
  }
  return files;
}

/// The test files for check 2, NUL-terminated for `xargs -0`.
String encodeEntries(List<String> entries) =>
    entries.map((e) => '$e\x00').join();

class ScopeDecision {
  const ScopeDecision({
    required this.passed,
    required this.runEvaluate,
    required this.message,
    this.testEntries = const [],
  });

  final bool passed;
  final bool runEvaluate;
  final String message;
  final List<String> testEntries;
}

ScopeDecision decideScope({
  required String title,
  required List<ChangedFile> changed,
}) {
  final type = prType(title);
  if (type != null && exemptTypes.contains(type)) {
    return ScopeDecision(
      passed: true,
      runEvaluate: false,
      message:
          'EXEMPT: PR type "$type" claims no new or fixed behavior, so the '
          'test gate does not apply. A fix or a feature must not use this type.',
    );
  }
  final code = changed.where((f) => isAppCode(f.path)).toList();
  if (code.isEmpty) {
    return const ScopeDecision(
      passed: true,
      runEvaluate: false,
      message:
          'No app code (lib/) changed; nothing for the test gate to check.',
    );
  }
  final entries = changed
      .where((f) => !f.removed && isTestEntry(f.path))
      .map((f) => f.path)
      .toList();
  if (entries.isEmpty) {
    final list = code.map((f) => '  ${f.path}').join('\n');
    return ScopeDecision(
      passed: false,
      runEvaluate: false,
      message:
          'FAIL (check 1): app code changed but no *_test.dart file was added '
          'or changed. Every fix and every new capability ships with a test.\n'
          'Code changed:\n$list',
    );
  }
  return ScopeDecision(
    passed: true,
    runEvaluate: true,
    testEntries: entries,
    message:
        'Check 1 passed: ${entries.length} test file(s) changed alongside '
        '${code.length} code file(s). Check 2 runs them against the base code.',
  );
}

class EvaluateDecision {
  const EvaluateDecision(this.passed, this.message);
  final bool passed;
  final String message;
}

/// The runner reports a file's compile as a `loading <path>` test, and a
/// group hook as `(setUpAll)` / `(tearDownAll)`. None of them is a test of
/// behavior: a hook that throws stops the file's real tests from running.
bool _isPseudoTest(String name) =>
    name.startsWith('loading ') ||
    name == '(setUpAll)' ||
    name == '(tearDownAll)';

/// Reads `flutter test --reporter json` output from a run of the PR's test
/// files against the base branch's code.
EvaluateDecision evaluateResults(
  String jsonLines, {
  bool newCapability = false,
}) {
  final names = <int, String>{};
  final suitePaths = <int, String>{};
  final testSuite = <int, int>{};
  final failing = <String>[];
  final unloadable = <String>{};
  var realTestsRun = 0;
  var sawDone = false;

  // Every field is type-checked, and anything unexpected is skipped. A
  // skipped event can only lose proof, never invent it, so a format change
  // fails the gate closed (and the workflow's self-check names it).
  for (final line in const LineSplitter().convert(jsonLines)) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{')) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      continue;
    }
    if (decoded is! Map<String, dynamic>) continue;
    switch (decoded['type']) {
      case 'suite':
        final suite = decoded['suite'];
        if (suite is! Map<String, dynamic>) break;
        final id = suite['id'];
        final path = suite['path'];
        if (id is int && path is String) suitePaths[id] = path;
      case 'testStart':
        final test = decoded['test'];
        if (test is! Map<String, dynamic>) break;
        final id = test['id'];
        final name = test['name'];
        if (id is! int || name is! String) break;
        names[id] = name;
        final suiteId = test['suiteID'];
        if (suiteId is int) testSuite[id] = suiteId;
      case 'testDone':
        final id = decoded['testID'];
        if (id is! int) break;
        // A result for a test that never started proves nothing.
        final name = names[id];
        if (name == null) break;
        final result = decoded['result'];
        if (decoded['skipped'] == true) break;
        if (_isPseudoTest(name)) {
          if (name.startsWith('loading ') && result != 'success') {
            unloadable.add(suitePaths[testSuite[id]] ?? name);
          }
          break;
        }
        if (decoded['hidden'] == true) break;
        realTestsRun++;
        if (result == 'failure' || result == 'error') failing.add(name);
      case 'done':
        sawDone = true;
    }
  }

  if (!sawDone) {
    return const EvaluateDecision(
      false,
      'FAIL (check 2): the test run did not finish, so nothing was proven. '
      'See the step log for the runner output.',
    );
  }
  final unloadableList = unloadable.map((p) => '  $p').join('\n');
  if (failing.isNotEmpty) {
    final list = failing.map((n) => '  $n').join('\n');
    final alsoNotCompiled = unloadable.isEmpty
        ? ''
        : '\nThese files also do not compile against the base code:\n'
              '$unloadableList';
    return EvaluateDecision(
      true,
      'Check 2 passed: ${failing.length} test(s) fail on the base code, so '
      'they guard this change:\n$list$alsoNotCompiled',
    );
  }
  if (newCapability && unloadable.isNotEmpty) {
    return EvaluateDecision(
      true,
      'Check 2 passed for a new capability (feat): these test files need code '
      'the base does not have, so they cannot pass without this change:\n'
      '$unloadableList\n'
      'WARNING: this is the weaker rule for new capabilities. A fix must not '
      'be titled feat to use it: a fix needs a test that fails on the base '
      'code itself.',
    );
  }
  final notCompiled = unloadable.isEmpty
      ? ''
      : '\nThese files do not compile against the base code, which proves '
            'nothing about behavior:\n$unloadableList';
  if (realTestsRun == 0) {
    return EvaluateDecision(
      false,
      'FAIL (check 2): no changed test ran against the base code, so none of '
      'them shows the old behavior failing. Add at least one test that uses '
      'only code the base branch already has, and that fails there.'
      '$notCompiled',
    );
  }
  return EvaluateDecision(
    false,
    'FAIL (check 2): all $realTestsRun changed test(s) that ran pass on the '
    'base code too, so none of them guards this change. A regression test '
    'must fail without the fix.$notCompiled',
  );
}

void _appendTo(String? path, String text) {
  if (path == null || path.isEmpty) return;
  File(path).writeAsStringSync(text, mode: FileMode.append);
}

String _arg(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) {
    stderr.writeln('missing $name');
    exit(2);
  }
  return args[i + 1];
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: test_gate.dart scope|evaluate ...');
    exit(2);
  }
  final summary = Platform.environment['GITHUB_STEP_SUMMARY'];
  switch (args.first) {
    case 'scope':
      final decision = decideScope(
        title: Platform.environment['PR_TITLE'] ?? '',
        changed: parseNameStatus(
          File(_arg(args, '--changed')).readAsStringSync(),
        ),
      );
      File(
        _arg(args, '--entries'),
      ).writeAsStringSync(encodeEntries(decision.testEntries));
      _appendTo(
        Platform.environment['GITHUB_OUTPUT'],
        'evaluate=${decision.runEvaluate}\n',
      );
      _appendTo(summary, '### Test gate\n\n${decision.message}\n\n');
      stdout.writeln(decision.message);
      exit(decision.passed ? 0 : 1);
    case 'evaluate':
      final decision = evaluateResults(
        File(_arg(args, '--results')).readAsStringSync(),
        newCapability: isNewCapability(Platform.environment['PR_TITLE'] ?? ''),
      );
      _appendTo(summary, '${decision.message}\n');
      stdout.writeln(decision.message);
      exit(decision.passed ? 0 : 1);
    default:
      stderr.writeln('unknown command ${args.first}');
      exit(2);
  }
}
