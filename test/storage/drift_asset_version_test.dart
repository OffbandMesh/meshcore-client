import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the one way the web build can break silently (#335).
///
/// drift on the web needs two binaries shipped in `web/`, and they must match
/// the resolved `drift` package. If someone bumps drift without re-downloading
/// them, nothing fails at build time: the app compiles, deploys, and then
/// fails in the browser. SAFELANE 6 says that must not be silent, so this
/// turns it into a red test with instructions.
///
/// Update `web/drift_assets.version` whenever the assets are re-downloaded.
void main() {
  test('shipped drift web assets match the pinned drift version', () {
    final root = Directory.current.path;

    final lock = File('$root/pubspec.lock');
    expect(
      lock.existsSync(),
      isTrue,
      reason:
          'pubspec.lock must be committed so dependency resolution is '
          'reproducible; the drift web assets are matched against it.',
    );

    final resolved = RegExp(
      r'^  drift:\n(?:.*\n)*?    version: "([^"]+)"',
      multiLine: true,
    ).firstMatch(lock.readAsStringSync())?.group(1);
    expect(resolved, isNotNull, reason: 'drift not found in pubspec.lock');

    final stamp = File('$root/web/drift_assets.version');
    expect(
      stamp.existsSync(),
      isTrue,
      reason:
          'web/drift_assets.version is missing. It records which drift release '
          'web/sqlite3.wasm and web/drift_worker.js came from.',
    );

    expect(
      stamp.readAsStringSync().trim(),
      resolved,
      reason:
          '\nDrift web assets are STALE.\n'
          'pubspec.lock resolves drift $resolved, but the shipped assets are '
          'from ${stamp.readAsStringSync().trim()}.\n'
          'The web build would compile and then fail in the browser.\n\n'
          'Fix:\n'
          '  gh release download drift-$resolved --repo simolus3/drift \\\n'
          '    --pattern drift_worker.js --pattern sqlite3.wasm --clobber\n'
          '  (run inside web/, then write $resolved into web/drift_assets.version)\n',
    );

    for (final name in ['sqlite3.wasm', 'drift_worker.js']) {
      expect(
        File('$root/web/$name').existsSync(),
        isTrue,
        reason: 'web/$name is missing; the web build would fail at runtime.',
      );
    }

    // Cheap integrity check: the wasm must actually be WebAssembly.
    final magic = File('$root/web/sqlite3.wasm').openSync().readSync(4);
    expect(
      magic,
      orderedEquals([0x00, 0x61, 0x73, 0x6d]),
      reason:
          'web/sqlite3.wasm does not start with the WebAssembly magic '
          'bytes (\\0asm) — the download is corrupt or is not a wasm file.',
    );
  });
}
