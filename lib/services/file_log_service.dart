import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/file_log_writer.dart';

/// Always-on, app-wide file logging (#97). Mirrors the in-memory app + BLE logs
/// to a rotating file under `getApplicationSupportDirectory()/logs` so users
/// (and support) can retrieve a log without enabling anything. No-op on web
/// (no filesystem). A singleton initialised in `main()`; the two log services
/// call [write] on every entry, and a periodic flush batches them to disk so
/// the hot logging path never touches the disk directly.
class FileLogService {
  FileLogService._();
  static final FileLogService instance = FileLogService._();

  FileLogWriter? _writer;
  Directory? _dir;
  final List<String> _queue = [];
  Timer? _flushTimer;
  bool _initStarted = false;

  /// The logs directory once resolved (null on web / before init / on failure).
  Directory? get logDir => _dir;

  /// Resolve the platform logs dir and start the periodic flush. Safe to call
  /// once; a no-op on web. Lines written before this completes are queued.
  Future<void> init() async {
    if (_initStarted || kIsWeb) return;
    _initStarted = true;
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}${Platform.pathSeparator}logs');
      await dir.create(recursive: true);
      _dir = dir;
      _writer = FileLogWriter(dir: dir);
      _flushTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_flush()),
      );
    } catch (_) {
      // Logging must never crash the app. If the dir can't be resolved we stay
      // a no-op; the in-memory logs still work.
    }
  }

  /// Queue one already-formatted line for the next flush. No-op on web. Bounded
  /// so a stalled flush can't grow memory without limit.
  void write(String line) {
    if (kIsWeb) return;
    _queue.add(line);
    if (_queue.length > 5000) _queue.removeRange(0, _queue.length - 5000);
  }

  Future<void> _flush() async {
    final w = _writer;
    if (w == null || _queue.isEmpty) return;
    final batch = List<String>.of(_queue);
    _queue.clear();
    try {
      await w.writeLines(batch);
    } catch (_) {
      // Drop on IO error; never crash the app over a log write.
    }
  }

  /// Flush pending lines and return the active log file (for share/export).
  /// Null when file logging is unavailable (web / not initialised).
  Future<File?> flushAndGetActiveFile() async {
    await _flush();
    return _writer?.activeFile;
  }

  /// Cancel the periodic flush and flush once more. The singleton normally lives
  /// for the app's lifetime; this is for a clean shutdown / tests.
  Future<void> dispose() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _flush();
  }
}
