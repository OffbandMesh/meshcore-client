import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// #781 (C4 of #755): the fake radio is test code. Nothing the app ships
// (everything under lib/) may import it, or anything from test/ or tool/.

final _import = RegExp(
  r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

/// Imports in [source] that reach test-only code.
List<String> forbiddenImports(String source) => [
  for (final m in _import.allMatches(source))
    if (_forbidden(m.group(1)!)) m.group(1)!,
];

bool _forbidden(String uri) =>
    uri.contains('fake_radio') ||
    uri.contains('/test/') ||
    uri.startsWith('test/') ||
    uri.contains('../test') ||
    uri.contains('/tool/') ||
    uri.startsWith('tool/') ||
    uri.contains('../tool');

void main() {
  test('nothing under lib/ imports the fake radio, test/ or tool/', () {
    final offenders = <String>[];
    final dartFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final file in dartFiles) {
      for (final uri in forbiddenImports(file.readAsStringSync())) {
        offenders.add('${file.path}: $uri');
      }
    }
    expect(offenders, isEmpty);
    expect(dartFiles, isNotEmpty); // guard against scanning nothing
  });

  test('the scan catches each way test code could be pulled in', () {
    expect(
      forbiddenImports('''
import 'package:flutter/material.dart';
import '../../test/support/fake_radio/fake_radio.dart';
import 'package:meshcore_open/x/fake_radio_runner.dart';
export '../tool/fake_radio.dart';
part 'test/thing.dart';
import "../services/storage_service.dart";
'''),
      hasLength(4),
    );
  });
}
