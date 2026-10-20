// Rotating file-log writer (#97). Exercised against a real temp directory,
// dart:io File works in flutter_test on desktop, so the rotation behaviour is
// integration-tested, not mocked.

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/utils/file_log_writer.dart';

void main() {
  group('FileLogWriter', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('flog'));
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('appends lines to the active file', () async {
      final w = FileLogWriter(dir: dir, baseName: 't', maxBytes: 1 << 20);
      await w.writeLine('hello');
      await w.writeLine('world');
      expect(await w.activeFile.readAsString(), 'hello\nworld\n');
    });

    test('creates the directory if missing', () async {
      final sub = Directory('${dir.path}/nested/logs');
      final w = FileLogWriter(dir: sub, baseName: 't', maxBytes: 1 << 20);
      await w.writeLine('x');
      expect(sub.existsSync(), isTrue);
      expect(w.activeFile.existsSync(), isTrue);
    });

    test('rotates past maxBytes and caps at maxFiles total', () async {
      final w = FileLogWriter(
        dir: dir,
        baseName: 't',
        maxBytes: 100,
        maxFiles: 3,
      );
      for (var i = 0; i < 60; i++) {
        await w.writeLine('line $i ${'x' * 20}');
      }
      expect(File('${dir.path}/t.log').existsSync(), isTrue);
      expect(File('${dir.path}/t.1.log').existsSync(), isTrue);
      expect(File('${dir.path}/t.2.log').existsSync(), isTrue);
      // capped: active + .1 + .2 = 3 files, no .3
      expect(File('${dir.path}/t.3.log').existsSync(), isFalse);
    });

    test('maxFiles=1 keeps only the active file (restart on rotate)', () async {
      final w = FileLogWriter(
        dir: dir,
        baseName: 't',
        maxBytes: 50,
        maxFiles: 1,
      );
      for (var i = 0; i < 20; i++) {
        await w.writeLine('line $i padding padding');
      }
      expect(File('${dir.path}/t.log').existsSync(), isTrue);
      expect(File('${dir.path}/t.1.log').existsSync(), isFalse);
    });

    test('writeLines batches and still rotates', () async {
      final w = FileLogWriter(
        dir: dir,
        baseName: 't',
        maxBytes: 200,
        maxFiles: 3,
      );
      for (var b = 0; b < 10; b++) {
        await w.writeLines(
          List.generate(5, (i) => 'batch $b line $i ${'y' * 10}'),
        );
      }
      expect(File('${dir.path}/t.log').existsSync(), isTrue);
      expect(File('${dir.path}/t.1.log').existsSync(), isTrue);
    });

    // #906: the export used to ship only the active file, so a line written
    // once at startup was lost as soon as the log rotated. These pin the
    // accessor the export now relies on.
    group('existingFiles (#906)', () {
      test('is empty before anything is written', () async {
        final w = FileLogWriter(dir: dir, baseName: 't', maxBytes: 1 << 20);
        expect(await w.existingFiles(), isEmpty);
      });

      test('returns just the active file before any rotation', () async {
        final w = FileLogWriter(dir: dir, baseName: 't', maxBytes: 1 << 20);
        await w.writeLine('only');
        final files = await w.existingFiles();
        expect(files.map((f) => f.uri.pathSegments.last), ['t.log']);
      });

      test('returns the rotated files too, newest first', () async {
        final w = FileLogWriter(
          dir: dir,
          baseName: 't',
          maxBytes: 100,
          maxFiles: 3,
        );
        for (var i = 0; i < 60; i++) {
          await w.writeLine('line $i ${'x' * 20}');
        }
        final names = (await w.existingFiles())
            .map((f) => f.uri.pathSegments.last)
            .toList();
        expect(names, ['t.log', 't.1.log', 't.2.log']);
      });

      test('never reports more than maxFiles', () async {
        final w = FileLogWriter(
          dir: dir,
          baseName: 't',
          maxBytes: 60,
          maxFiles: 2,
        );
        for (var i = 0; i < 80; i++) {
          await w.writeLine('line $i ${'y' * 20}');
        }
        final files = await w.existingFiles();
        expect(files.length, lessThanOrEqualTo(2));
        expect(
          files.map((f) => f.uri.pathSegments.last),
          isNot(contains('t.2.log')),
        );
      });
    });

    // #906: exit-record capture puts a pointer line in offband.log and the
    // trace itself in a sibling file, partly because a trace is tens of KB.
    // These pin down what a large entry actually does to rotation, so the
    // Epic's "rotation still behaves with a large trace present" criterion is
    // measured rather than assumed.
    group('with an oversized entry present (#906)', () {
      test(
        'an entry larger than maxBytes rotates and is written whole',
        () async {
          final w = FileLogWriter(
            dir: dir,
            baseName: 't',
            maxBytes: 2048,
            maxFiles: 3,
          );
          await w.writeLine('small line to make the active file non-empty');
          final big = 'T' * 40000;
          await w.writeLine(big);

          // Rotation fired, and the oversized entry is intact rather than cut.
          expect(File('${dir.path}/t.1.log').existsSync(), isTrue);
          expect(await w.activeFile.readAsString(), '$big\n');
        },
      );

      test('a single entry over maxBytes leaves the active file above the cap, '
          'by design: it rotates once then appends regardless', () async {
        final w = FileLogWriter(
          dir: dir,
          baseName: 't',
          maxBytes: 2048,
          maxFiles: 3,
        );
        await w.writeLine('seed');
        await w.writeLine('T' * 40000);
        expect(
          await w.activeFile.length(),
          greaterThan(2048),
          reason: 'maxBytes gates when to rotate, it is not a hard truncation',
        );
      });

      test('normal rotation still works after an oversized entry', () async {
        final w = FileLogWriter(
          dir: dir,
          baseName: 't',
          maxBytes: 2048,
          maxFiles: 3,
        );
        await w.writeLine('T' * 40000);
        for (var i = 0; i < 40; i++) {
          await w.writeLine('line $i ${'z' * 100}');
        }
        expect(File('${dir.path}/t.log').existsSync(), isTrue);
        expect(File('${dir.path}/t.1.log').existsSync(), isTrue);
        expect(File('${dir.path}/t.2.log').existsSync(), isTrue);
        expect(
          File('${dir.path}/t.3.log').existsSync(),
          isFalse,
          reason: 'maxFiles still holds, so the log cannot grow without bound',
        );
      });

      test('an oversized batch rotates once and is not dropped', () async {
        final w = FileLogWriter(
          dir: dir,
          baseName: 't',
          maxBytes: 2048,
          maxFiles: 3,
        );
        await w.writeLine('seed');
        final lines = List.generate(500, (i) => 'trace frame $i ${'f' * 60}');
        await w.writeLines(lines);
        final active = await w.activeFile.readAsString();
        expect(active, contains('trace frame 0 '));
        expect(active, contains('trace frame 499 '));
      });
    });
  });
}
