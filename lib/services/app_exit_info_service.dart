import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../storage/prefs_manager.dart';
import 'file_log_service.dart';

/// One `ApplicationExitInfo` record, as the platform channel delivers it.
class ExitRecord {
  const ExitRecord({
    required this.reason,
    required this.reasonName,
    required this.timestampMs,
    required this.pid,
    this.description,
    this.processName,
    this.importance = 0,
    this.pssKb = 0,
    this.rssKb = 0,
    this.status = 0,
    this.traceBytes,
    this.traceUnavailable,
    this.traceTruncated = false,
  });

  factory ExitRecord.fromMap(Map<Object?, Object?> map) {
    int asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);
    return ExitRecord(
      reason: asInt(map['reason']),
      reasonName: map['reasonName'] as String? ?? 'UNKNOWN',
      timestampMs: asInt(map['timestampMs']),
      pid: asInt(map['pid']),
      description: map['description'] as String?,
      processName: map['processName'] as String?,
      importance: asInt(map['importance']),
      pssKb: asInt(map['pssKb']),
      rssKb: asInt(map['rssKb']),
      status: asInt(map['status']),
      traceBytes: map['traceBytes'] as Uint8List?,
      traceUnavailable: map['traceUnavailable'] as String?,
      traceTruncated: map['traceTruncated'] as bool? ?? false,
    );
  }

  final int reason;
  final String reasonName;
  final int timestampMs;
  final int pid;
  final String? description;
  final String? processName;
  final int importance;
  final int pssKb;
  final int rssKb;
  final int status;
  final Uint8List? traceBytes;
  final String? traceUnavailable;
  final bool traceTruncated;

  /// Reasons that mean the app was killed or broke, as opposed to a routine
  /// stop. Drives the log level so an ANR does not read like a normal exit.
  bool get isNoteworthy => const {
    'ANR',
    'CRASH',
    'CRASH_NATIVE',
    'LOW_MEMORY',
    'EXCESSIVE_RESOURCE_USAGE',
    'FREEZER',
    'INITIALIZATION_FAILURE',
  }.contains(reasonName);
}

/// Every message this service can surface, in one place.
///
/// They live here rather than inline so the tests can assert each one is
/// produced by its own failure and absent on the happy path, which is the
/// standing requirement for anything handed over for testing. The alternative
/// would be faking `path_provider` to read the log file back, and there is no
/// precedent for that in this test suite.
abstract final class ExitInfoMessages {
  static const String notAndroid =
      'exit-info capture is Android only, skipping';

  static const String nullResult =
      'getExitRecords returned null, nothing logged';

  static String unsupported(Object? reason, Object? sdkInt) =>
      'exit-info capture unavailable: ${reason ?? 'unknown'} (sdkInt=$sdkInt); '
      'devices below API 30 keep no exit records';

  static String queryFailed(String code, String? message) =>
      'exit-info query failed: $code ${message ?? ''}'.trimRight();

  static String captureFailed(Object error) =>
      'exit-info capture failed: $error';

  static String traceDirMissing(int pid) =>
      'no logs directory, trace for pid $pid not written';

  static String traceWriteFailed(String name, Object error) =>
      'could not write trace $name: $error';

  static String pruneFailed(Object error) => 'trace pruning failed: $error';

  static String listFailed(Object error) => 'could not list trace dir: $error';

  static String watermarkReadFailed(Object error) =>
      'could not read exit watermark, treating as first run: $error';

  static String watermarkWriteFailed(Object error) =>
      'could not persist exit watermark, may re-log: $error';

  static String forceBlockFailed(Object error) =>
      'forceMainThreadBlock failed: $error';

  /// Fragments that must never appear in a line produced on the happy path.
  static const List<String> failureMarkers = [
    'unavailable:',
    'failed',
    'could not',
    'no logs directory',
  ];
}

/// What [selectExitRecords] decided to do with a batch of records.
class ExitSelection {
  const ExitSelection({
    required this.records,
    required this.backfill,
    required this.traceBudget,
    required this.newWatermarkMs,
  });

  /// Only the records newer than the watermark, newest first.
  final List<ExitRecord> records;

  /// True on the first run, when there is no watermark yet and the system's
  /// buffer may hold months of history.
  final bool backfill;

  /// How many of [records] may have their trace written out.
  final int traceBudget;

  /// Where the watermark moves to, or null when nothing was new.
  final int? newWatermarkMs;
}

/// Pick the records that have not been logged yet.
///
/// [all] arrives newest first, as `getHistoricalProcessExitReasons` returns it.
/// Records with a timestamp equal to the watermark were already logged, so the
/// comparison is strictly greater. Two records sharing a millisecond are both
/// greater than the watermark in the same pass, so both are kept and neither is
/// lost when the watermark then advances past them.
ExitSelection selectExitRecords(
  List<ExitRecord> all,
  int? watermarkMs, {
  int backfillTraceCap = 3,
}) {
  final backfill = watermarkMs == null;
  final fresh = backfill
      ? List<ExitRecord>.of(all)
      : all.where((r) => r.timestampMs > watermarkMs).toList();

  if (fresh.isEmpty) {
    return const ExitSelection(
      records: [],
      backfill: false,
      traceBudget: 0,
      newWatermarkMs: null,
    );
  }

  var highest = fresh.first.timestampMs;
  for (final r in fresh) {
    if (r.timestampMs > highest) highest = r.timestampMs;
  }

  return ExitSelection(
    records: fresh,
    backfill: backfill,
    traceBudget: backfill
        ? (fresh.length < backfillTraceCap ? fresh.length : backfillTraceCap)
        : fresh.length,
    newWatermarkMs: highest,
  );
}

/// Human-readable form of the `RunningAppProcessInfo` importance value. Whether
/// the process was in the foreground is the first thing you want to know about
/// an ANR, since a cached-process hang is not user-visible.
String importanceName(int importance) {
  switch (importance) {
    case 100:
      return 'FOREGROUND';
    case 125:
      return 'FOREGROUND_SERVICE';
    case 200:
      return 'VISIBLE';
    case 230:
      return 'PERCEPTIBLE';
    case 300:
      return 'SERVICE';
    case 350:
      return 'CANT_SAVE_STATE';
    case 400:
      return 'CACHED';
    case 1000:
      return 'GONE';
    default:
      return importance == 0 ? 'unknown' : 'IMPORTANCE_$importance';
  }
}

/// Memory figures are documented in kB and are 0 when the system never sampled
/// the process, so 0 is rendered as unknown rather than as a real measurement.
String _memory(int kb) => kb <= 0 ? 'unknown' : '${kb}kB';

String _traceField(ExitRecord record, String? writtenFileName) {
  if (writtenFileName != null) {
    return record.traceTruncated
        ? 'trace=$writtenFileName(truncated)'
        : 'trace=$writtenFileName';
  }
  final why = record.traceUnavailable;
  return 'trace=none${why == null ? '' : '($why)'}';
}

/// The log line for one exit record, in the same shape the app log already
/// uses: `<iso8601> [LEVEL/Tag] message`.
String formatExitLine(
  ExitRecord record, {
  required bool backfill,
  String? writtenFileName,
  DateTime? now,
}) {
  final stamp = (now ?? DateTime.now()).toIso8601String();
  final level = record.isNoteworthy ? 'WARN' : 'INFO';
  final at = DateTime.fromMillisecondsSinceEpoch(
    record.timestampMs,
    isUtc: true,
  ).toIso8601String();
  final desc = record.description;

  final parts = <String>[
    'reason=${record.reasonName}(${record.reason})',
    if (desc != null && desc.isNotEmpty) 'desc="$desc"',
    'at=$at',
    'pid=${record.pid}',
    if (record.processName != null) 'proc=${record.processName}',
    'importance=${importanceName(record.importance)}',
    'pss=${_memory(record.pssKb)}',
    'rss=${_memory(record.rssKb)}',
    'status=${record.status}',
    _traceField(record, writtenFileName),
    if (backfill) 'backfill=true',
  ];

  return '$stamp [$level/ExitInfo] ${parts.join(' ')}';
}

/// `anr-<utc>-<pid>.txt`. The UTC stamp sorts lexicographically, which is what
/// lets the pruner treat a plain name sort as chronological.
String traceFileName(int timestampMs, int pid) {
  final t = DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true);
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp =
      '${t.year}${two(t.month)}${two(t.day)}T'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
  return 'anr-$stamp-$pid.txt';
}

/// Which trace files to delete, given every file's name and size.
///
/// Keeps at most [keep] of the newest and holds the total at or under
/// [ceilingBytes], dropping oldest first. Names sort chronologically, so the
/// caller does not need file timestamps. The newest file is never deleted, even
/// when it alone exceeds the ceiling: a trace too big to keep is still the one
/// piece of evidence worth having.
List<String> traceFilesToPrune(
  Map<String, int> sizesByName, {
  int keep = 5,
  int ceilingBytes = 1024 * 1024,
}) {
  final names = sizesByName.keys.toList()..sort();
  final doomed = <String>[];

  final surviving = names.toList();
  while (surviving.length > keep) {
    doomed.add(surviving.removeAt(0));
  }

  var total = surviving.fold<int>(0, (sum, n) => sum + (sizesByName[n] ?? 0));
  while (total > ceilingBytes && surviving.length > 1) {
    final oldest = surviving.removeAt(0);
    total -= sizesByName[oldest] ?? 0;
    doomed.add(oldest);
  }

  return doomed;
}

/// Reports why the app's previous processes died, by reading the system's own
/// exit records on the next launch and writing them into the debug log (#906).
///
/// Android only, API 30 and up. Everywhere else this is a no-op that says so
/// once. ANR traces go to a file beside `offband.log` with a pointer line in the
/// log itself, because the log export only ever ships the active log file, and a
/// trace written inline would both evict surrounding context and later rotate
/// away.
class AppExitInfoService {
  AppExitInfoService._();
  static final AppExitInfoService instance = AppExitInfoService._();

  static const MethodChannel _channel = MethodChannel(
    'meshcore_open/app_exit_info',
  );

  /// SharedPreferences key holding the highest exit timestamp already logged.
  static const String watermarkKey = 'anr_last_exit_ts_ms';

  static const String traceDirName = 'anr';
  static const int keepTraceFiles = 5;
  static const int traceDirCeilingBytes = 1024 * 1024;
  static const int backfillTraceCap = 3;

  bool _ran = false;

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// The directory ANR traces are written to, or null when file logging is
  /// unavailable. Used by the log export so the traces ship with the log.
  static Directory? get traceDir {
    final logs = FileLogService.instance.logDir;
    if (logs == null) return null;
    return Directory('${logs.path}${Platform.pathSeparator}$traceDirName');
  }

  /// Any ANR trace files currently on disk, oldest first. Empty when there are
  /// none, when the directory does not exist, or when it cannot be listed.
  static Future<List<File>> traceFiles() async {
    final dir = traceDir;
    if (dir == null) return const [];
    try {
      if (!await dir.exists()) return const [];
      return (await dir.list().toList()).whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    } catch (error) {
      instance._log('WARN', ExitInfoMessages.listFailed(error));
      return const [];
    }
  }

  /// Read the system's exit records and log anything not logged before.
  ///
  /// Safe to call once per launch; a second call is a no-op. Never throws: a
  /// diagnostic must not be able to break startup. Every failure path writes a
  /// line, so nothing here is silent.
  Future<void> collect() async {
    if (_ran) return;
    _ran = true;

    if (!_isAndroid) {
      _log('INFO', ExitInfoMessages.notAndroid);
      return;
    }

    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'getExitRecords',
      );
      if (raw == null) {
        _log('WARN', ExitInfoMessages.nullResult);
        return;
      }

      if (raw['supported'] != true) {
        _log(
          'INFO',
          ExitInfoMessages.unsupported(raw['unsupportedReason'], raw['sdkInt']),
        );
        return;
      }

      final records = (raw['records'] as List?)
          ?.whereType<Map<Object?, Object?>>()
          .map(ExitRecord.fromMap)
          .toList();
      if (records == null || records.isEmpty) return;

      await _report(records);
    } on PlatformException catch (error) {
      // The query failed. Leave the watermark alone so the next launch retries.
      _log('WARN', ExitInfoMessages.queryFailed(error.code, error.message));
    } catch (error) {
      _log('WARN', ExitInfoMessages.captureFailed(error));
    }
  }

  Future<void> _report(List<ExitRecord> records) async {
    final selection = selectExitRecords(
      records,
      _readWatermark(),
      backfillTraceCap: backfillTraceCap,
    );
    if (selection.records.isEmpty) return;

    var tracesWritten = 0;
    for (final record in selection.records) {
      String? writtenName;
      final bytes = record.traceBytes;
      if (bytes != null &&
          bytes.isNotEmpty &&
          tracesWritten < selection.traceBudget) {
        writtenName = await _writeTrace(record, bytes);
        if (writtenName != null) tracesWritten++;
      }
      FileLogService.instance.write(
        formatExitLine(
          record,
          backfill: selection.backfill,
          writtenFileName: writtenName,
        ),
      );
    }

    await _prune();
    await _writeWatermark(selection.newWatermarkMs);

    // FileLogService batches on a 2 second timer, so without this the lines
    // above can be lost if the process dies again before the next flush,
    // leaving a trace file on disk with nothing pointing at it.
    await FileLogService.instance.flushAndGetActiveFile();
  }

  Future<String?> _writeTrace(ExitRecord record, Uint8List bytes) async {
    final dir = traceDir;
    if (dir == null) {
      _log('WARN', ExitInfoMessages.traceDirMissing(record.pid));
      return null;
    }
    final name = traceFileName(record.timestampMs, record.pid);
    try {
      await dir.create(recursive: true);
      await File(
        '${dir.path}${Platform.pathSeparator}$name',
      ).writeAsBytes(bytes, flush: true);
      return name;
    } catch (error) {
      // Reported into the main log, which is a different file and so is likely
      // still writable even when this one is not.
      _log('WARN', ExitInfoMessages.traceWriteFailed(name, error));
      return null;
    }
  }

  Future<void> _prune() async {
    final files = await traceFiles();
    if (files.isEmpty) return;
    try {
      final sizes = <String, int>{};
      for (final f in files) {
        sizes[f.uri.pathSegments.last] = await f.length();
      }
      final doomed = traceFilesToPrune(
        sizes,
        keep: keepTraceFiles,
        ceilingBytes: traceDirCeilingBytes,
      );
      for (final name in doomed) {
        for (final f in files) {
          if (f.uri.pathSegments.last == name) {
            await f.delete();
            break;
          }
        }
      }
    } catch (error) {
      _log('WARN', ExitInfoMessages.pruneFailed(error));
    }
  }

  int? _readWatermark() {
    try {
      return PrefsManager.instance.getInt(watermarkKey);
    } catch (error) {
      // Treated as a first run, which backfills under a cap and says so.
      _log('WARN', ExitInfoMessages.watermarkReadFailed(error));
      return null;
    }
  }

  Future<void> _writeWatermark(int? value) async {
    if (value == null) return;
    try {
      await PrefsManager.instance.setInt(watermarkKey, value);
    } catch (error) {
      // Worth surfacing: the same records will be logged again next launch.
      _log('WARN', ExitInfoMessages.watermarkWriteFailed(error));
    }
  }

  /// Test-only hook, called from the owner-only Experimental section in builds
  /// compiled with `OFFBAND_ANR_TEST`. Hangs the Android main thread so the
  /// system raises a real ANR, which is the only way to produce a record to
  /// read back (#911).
  Future<void> forceMainThreadBlock({int millis = 20000}) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<int>('forceMainThreadBlock', {
        'millis': millis,
      });
    } catch (error) {
      _log('WARN', ExitInfoMessages.forceBlockFailed(error));
    }
  }

  /// Visible for tests so a second `collect()` can be exercised.
  @visibleForTesting
  void resetForTest() => _ran = false;

  void _log(String level, String message) {
    FileLogService.instance.write(
      '${DateTime.now().toIso8601String()} [$level/ExitInfo] $message',
    );
  }
}
