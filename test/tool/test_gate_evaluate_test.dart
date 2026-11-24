import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_gate.dart';

/// Builds runner output in the shape `flutter test --reporter json` emits,
/// as observed on Flutter 3.44: each file is a suite with a `loading <path>`
/// test (hidden when it compiles, a visible error when it does not), group
/// hooks appear as `(setUpAll)` / `(tearDownAll)`, then a final `done`.
class _Run {
  final _lines = <String>['Some non-JSON preamble the runner may print'];
  var _id = 0;

  void _emit(Map<String, Object?> event) => _lines.add(jsonEncode(event));

  int _start(int suite, String name) {
    final id = ++_id;
    _emit({
      'type': 'testStart',
      'test': {'id': id, 'name': name, 'suiteID': suite},
    });
    return id;
  }

  void _done(
    int id,
    String result, {
    bool hidden = false,
    bool skipped = false,
  }) => _emit({
    'type': 'testDone',
    'testID': id,
    'result': result,
    'hidden': hidden,
    'skipped': skipped,
  });

  int suite(String path, {bool compiles = true}) {
    final suite = ++_id;
    _emit({
      'type': 'suite',
      'suite': {'id': suite, 'path': path},
    });
    final loading = _start(suite, 'loading $path');
    if (compiles) {
      _done(loading, 'success', hidden: true);
    } else {
      _emit({'type': 'error', 'testID': loading, 'isFailure': false});
      _done(loading, 'error');
    }
    return suite;
  }

  void test(int suite, String name, String result, {bool skipped = false}) =>
      _done(_start(suite, name), result, skipped: skipped);

  void failedSetUpAll(int suite) => _done(_start(suite, '(setUpAll)'), 'error');

  String finish({bool done = true}) {
    if (done) _emit({'type': 'done', 'success': false});
    return _lines.join('\n');
  }
}

void main() {
  group('check 2 passes', () {
    test('when a real test fails an expectation on the base code', () {
      final run = _Run();
      final s = run.suite('/repo/test/a_test.dart');
      run.test(s, 'a refused add is not kept', 'failure');
      run.test(s, 'an accepted add is kept', 'success');
      final d = evaluateResults(run.finish());
      expect(d.passed, isTrue);
      expect(d.message, contains('a refused add is not kept'));
    });

    test('when a real test throws on the base code', () {
      final run = _Run();
      final s = run.suite('/repo/test/a_test.dart');
      run.test(s, 'throws on the old path', 'error');
      expect(evaluateResults(run.finish()).passed, isTrue);
    });

    test('when one file fails to compile but another fails for real', () {
      final run = _Run();
      run.suite('/repo/test/new_api_test.dart', compiles: false);
      final s = run.suite('/repo/test/behavior_test.dart');
      run.test(s, 'old behavior is wrong', 'failure');
      expect(evaluateResults(run.finish()).passed, isTrue);
    });
  });

  group('check 2 fails', () {
    test('when every changed test passes on the base code too', () {
      final run = _Run();
      final s = run.suite('/repo/test/a_test.dart');
      run.test(s, 'token test', 'success');
      run.test(s, 'another token test', 'success');
      final d = evaluateResults(run.finish());
      expect(d.passed, isFalse);
      expect(d.message, contains('pass on the base code too'));
    });

    test('when the only failures are compile failures', () {
      final run = _Run();
      run.suite('/repo/test/new_api_test.dart', compiles: false);
      final d = evaluateResults(run.finish());
      expect(d.passed, isFalse);
      expect(d.message, contains('no changed test ran'));
      expect(d.message, contains('/repo/test/new_api_test.dart'));
    });

    test('when compiled tests pass and the rest do not compile', () {
      final run = _Run();
      run.suite('/repo/test/new_api_test.dart', compiles: false);
      final s = run.suite('/repo/test/b_test.dart');
      run.test(s, 'passes anyway', 'success');
      final d = evaluateResults(run.finish());
      expect(d.passed, isFalse);
      expect(d.message, contains('/repo/test/new_api_test.dart'));
    });

    test('when only a setUpAll hook fails, since no real test ran', () {
      final run = _Run();
      final s = run.suite('/repo/test/a_test.dart');
      run.failedSetUpAll(s);
      final d = evaluateResults(run.finish());
      expect(d.passed, isFalse);
      expect(d.message, contains('no changed test ran'));
    });

    test('when the only non-passing test was skipped', () {
      final run = _Run();
      final s = run.suite('/repo/test/a_test.dart');
      run.test(s, 'skipped', 'success', skipped: true);
      expect(evaluateResults(run.finish()).passed, isFalse);
    });

    test('when the run never finished', () {
      final run = _Run();
      final s = run.suite('/repo/test/a_test.dart');
      run.test(s, 'would have failed', 'failure');
      final d = evaluateResults(run.finish(done: false));
      expect(d.passed, isFalse);
      expect(d.message, contains('did not finish'));
    });

    test('when the output is empty or not JSON', () {
      expect(evaluateResults('').passed, isFalse);
      expect(evaluateResults('Error: flutter crashed\n').passed, isFalse);
    });

    test('when events are malformed, without crashing', () {
      const lines = [
        '{"type":"testStart"}',
        '{"type":"testStart","test":null}',
        '{"type":"testStart","test":{"id":"7","name":5}}',
        '{"type":"testDone"}',
        '{"type":"testDone","testID":"7","result":"failure"}',
        '{"type":"testDone","testID":99,"result":"failure"}',
        '{"type":"suite","suite":[]}',
        '[1,2,3]',
        '{"type":"done","success":false}',
      ];
      final d = evaluateResults(lines.join('\n'));
      expect(d.passed, isFalse);
    });

    test('a failure for a test that never started is not counted', () {
      const lines = [
        '{"type":"testDone","testID":42,"result":"failure","hidden":false}',
        '{"type":"done","success":false}',
      ];
      expect(evaluateResults(lines.join('\n')).passed, isFalse);
    });
  });
}
