import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

// Always-on file sink for queue-sync diagnostics, independent of the in-app App
// Debug Log toggle (off by default, and its in-memory buffer is lost when the
// app is closed during a drain). Lands at
// <app documents>/offband-queuesync.log. See #51.
//
// The IOSink is intentionally held open for the app's lifetime (append-only,
// low-frequency) rather than open/close per line; the OS closes the handle on
// process exit. `_sinkFuture ??= _openSink()` assigns synchronously before the
// await, so concurrent callers share one sink — no double-open on the event
// loop.

Future<IOSink>? _sinkFuture;

Future<IOSink> _openSink() async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/offband-queuesync.log');
  debugPrint('[QueueSync] file sink: ${file.path}');
  final sink = file.openWrite(mode: FileMode.append);
  sink.writeln(
    '\n===== offband queue-sync session '
    '${DateTime.now().toIso8601String()} =====',
  );
  return sink;
}

Future<void> appendQueueSyncLine(String msg) async {
  try {
    final sink = await (_sinkFuture ??= _openSink());
    sink.writeln('${DateTime.now().toIso8601String()}  $msg');
    await sink.flush();
  } catch (e) {
    _sinkFuture = null; // allow re-init on the next event
    debugPrint('[QueueSync] file sink error: $e');
  }
}
