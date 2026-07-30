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
  });
}
