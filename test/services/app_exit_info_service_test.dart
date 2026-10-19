// Exit-record capture (#906). Covers the selection, formatting, naming and
// pruning logic as pure functions, plus the channel layer behind a mock handler
// so the dedup contract and the never-throw contract are both checked.
//
// NOT covered here, and it cannot be: that Android actually produces a
// REASON_ANR record with a readable trace. No adb command induces an ANR
// (`am crash` is a crash; `kill -3` dumps traces without a REASON_ANR death),
// so that needs a real main-thread block on an API 30+ device and a relaunch.
// That is #911 part B, and it is the only way to prove the mechanism.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/app_exit_info_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

ExitRecord _record({
  int reason = 6,
  String reasonName = 'ANR',
  required int timestampMs,
  int pid = 1234,
  String? description,
  String? processName = 'app.offband.meshcore',
  int importance = 100,
  int pssKb = 0,
  int rssKb = 0,
  int status = 0,
  Uint8List? traceBytes,
  String? traceUnavailable,
  bool traceTruncated = false,
}) => ExitRecord(
  reason: reason,
  reasonName: reasonName,
  timestampMs: timestampMs,
  pid: pid,
  description: description,
  processName: processName,
  importance: importance,
  pssKb: pssKb,
  rssKb: rssKb,
  status: status,
  traceBytes: traceBytes,
  traceUnavailable: traceUnavailable,
  traceTruncated: traceTruncated,
);

void main() {
  group('selectExitRecords', () {
    test('first run backfills everything and caps the trace budget', () {
      final all = [
        _record(timestampMs: 500),
        _record(timestampMs: 400),
        _record(timestampMs: 300),
        _record(timestampMs: 200),
        _record(timestampMs: 100),
      ];
      final s = selectExitRecords(all, null, backfillTraceCap: 3);
      expect(s.backfill, isTrue);
      expect(s.records.length, 5, reason: 'metadata for every record');
      expect(s.traceBudget, 3, reason: 'traces capped on a backfill');
      expect(s.newWatermarkMs, 500);
    });

    test('backfill budget never exceeds the number of records', () {
      final s = selectExitRecords(
        [_record(timestampMs: 10)],
        null,
        backfillTraceCap: 3,
      );
      expect(s.traceBudget, 1);
    });

    test('with a watermark, only strictly newer records are selected', () {
      final all = [
        _record(timestampMs: 300),
        _record(timestampMs: 200),
        _record(timestampMs: 100),
      ];
      final s = selectExitRecords(all, 200);
      expect(s.backfill, isFalse);
      expect(s.records.map((r) => r.timestampMs), [300]);
      expect(s.newWatermarkMs, 300);
      expect(s.traceBudget, 1, reason: 'no cap outside a backfill');
    });

    test('a record equal to the watermark is treated as already logged', () {
      final s = selectExitRecords([_record(timestampMs: 200)], 200);
      expect(s.records, isEmpty);
      expect(s.newWatermarkMs, isNull, reason: 'watermark must not move');
    });

    test('two records in the same millisecond are both kept', () {
      final all = [
        _record(timestampMs: 400, pid: 2),
        _record(timestampMs: 400, pid: 1),
        _record(timestampMs: 100, pid: 0),
      ];
      final s = selectExitRecords(all, 100);
      expect(s.records.map((r) => r.pid), [2, 1]);
      expect(
        s.newWatermarkMs,
        400,
        reason: 'both logged before the watermark advances past them',
      );
    });

    test('nothing new yields an empty, non-backfill selection', () {
      final s = selectExitRecords([_record(timestampMs: 50)], 999);
      expect(s.records, isEmpty);
      expect(s.backfill, isFalse);
      expect(s.traceBudget, 0);
      expect(s.newWatermarkMs, isNull);
    });

    test('watermark takes the highest timestamp, not the first', () {
      final all = [_record(timestampMs: 100), _record(timestampMs: 900)];
      expect(selectExitRecords(all, 50).newWatermarkMs, 900);
    });
  });

  group('formatExitLine', () {
    final at = DateTime.utc(2026, 10, 19, 7, 30).millisecondsSinceEpoch;
    final now = DateTime.utc(2026, 10, 19, 8);

    test('an ANR logs at WARN with reason, pid and the trace filename', () {
      final line = formatExitLine(
        _record(timestampMs: at, description: 'Input dispatching timed out'),
        backfill: false,
        writtenFileName: 'anr-20261019T073000Z-1234.txt',
        now: now,
      );
      expect(line, startsWith('2026-10-19T08:00:00.000Z [WARN/ExitInfo] '));
      expect(line, contains('reason=ANR(6)'));
      expect(line, contains('desc="Input dispatching timed out"'));
      expect(line, contains('pid=1234'));
      expect(line, contains('proc=app.offband.meshcore'));
      expect(line, contains('importance=FOREGROUND'));
      expect(line, contains('trace=anr-20261019T073000Z-1234.txt'));
      expect(line, isNot(contains('backfill=true')));
    });

    test('a routine exit logs at INFO, not WARN', () {
      final line = formatExitLine(
        _record(timestampMs: at, reason: 1, reasonName: 'EXIT_SELF'),
        backfill: false,
        now: now,
      );
      expect(line, contains('[INFO/ExitInfo]'));
      expect(line, contains('reason=EXIT_SELF(1)'));
    });

    test('a resource kill logs at WARN', () {
      for (final name in const [
        'LOW_MEMORY',
        'FREEZER',
        'EXCESSIVE_RESOURCE_USAGE',
        'CRASH',
        'CRASH_NATIVE',
      ]) {
        final line = formatExitLine(
          _record(timestampMs: at, reasonName: name),
          backfill: false,
          now: now,
        );
        expect(line, contains('[WARN/ExitInfo]'), reason: name);
      }
    });

    test('zero memory renders as unknown, never as a real measurement', () {
      final line = formatExitLine(
        _record(timestampMs: at, pssKb: 0, rssKb: 0),
        backfill: false,
        now: now,
      );
      expect(line, contains('pss=unknown'));
      expect(line, contains('rss=unknown'));
      expect(line, isNot(contains('0kB')));
    });

    test('real memory figures render in kB', () {
      final line = formatExitLine(
        _record(timestampMs: at, pssKb: 182340, rssKb: 241088),
        backfill: false,
        now: now,
      );
      expect(line, contains('pss=182340kB'));
      expect(line, contains('rss=241088kB'));
    });

    test('a null description is omitted rather than printed as null', () {
      final line = formatExitLine(
        _record(timestampMs: at),
        backfill: false,
        now: now,
      );
      expect(line, isNot(contains('desc=')));
      expect(line, isNot(contains('null')));
    });

    test('an absent trace records why, which is a normal outcome', () {
      final line = formatExitLine(
        _record(timestampMs: at, traceUnavailable: 'evicted_or_absent'),
        backfill: false,
        now: now,
      );
      expect(line, contains('trace=none(evicted_or_absent)'));
    });

    test('a truncated trace is marked as such', () {
      final line = formatExitLine(
        _record(timestampMs: at, traceTruncated: true),
        backfill: false,
        writtenFileName: 'anr-x.txt',
        now: now,
      );
      expect(line, contains('trace=anr-x.txt(truncated)'));
    });

    test('a backfilled record says so, so it is not read as fresh', () {
      final line = formatExitLine(
        _record(timestampMs: at),
        backfill: true,
        now: now,
      );
      expect(line, contains('backfill=true'));
    });

    test('an ideal line carries none of the failure markers', () {
      final line = formatExitLine(
        _record(
          timestampMs: at,
          pssKb: 1000,
          rssKb: 2000,
          description: 'Input dispatching timed out',
        ),
        backfill: false,
        writtenFileName: 'anr-ok.txt',
        now: now,
      );
      for (final marker in ExitInfoMessages.failureMarkers) {
        expect(line, isNot(contains(marker)), reason: marker);
      }
    });
  });

  group('importanceName', () {
    test('names the values that matter for reading an ANR', () {
      expect(importanceName(100), 'FOREGROUND');
      expect(importanceName(125), 'FOREGROUND_SERVICE');
      expect(importanceName(200), 'VISIBLE');
      expect(importanceName(230), 'PERCEPTIBLE');
      expect(importanceName(300), 'SERVICE');
      expect(importanceName(400), 'CACHED');
      expect(importanceName(1000), 'GONE');
    });

    test('zero is unknown, and an unmapped value keeps its number', () {
      expect(importanceName(0), 'unknown');
      expect(importanceName(275), 'IMPORTANCE_275');
    });
  });

  group('traceFileName', () {
    test('is UTC, zero-padded, and sorts chronologically by name', () {
      final a = traceFileName(
        DateTime.utc(2026, 9, 3, 4, 5, 6).millisecondsSinceEpoch,
        7,
      );
      final b = traceFileName(
        DateTime.utc(2026, 10, 19, 7, 30, 0).millisecondsSinceEpoch,
        1234,
      );
      expect(a, 'anr-20260903T040506Z-7.txt');
      expect(b, 'anr-20261019T073000Z-1234.txt');
      expect(a.compareTo(b), lessThan(0), reason: 'name order is time order');
    });
  });

  group('traceFilesToPrune', () {
    test('keeps nothing to do when under both limits', () {
      final doomed = traceFilesToPrune(
        {'anr-1.txt': 10, 'anr-2.txt': 10},
        keep: 5,
        ceilingBytes: 1000,
      );
      expect(doomed, isEmpty);
    });

    test('drops the oldest beyond the keep count', () {
      final doomed = traceFilesToPrune(
        {
          'anr-20260101T000000Z-1.txt': 10,
          'anr-20260102T000000Z-1.txt': 10,
          'anr-20260103T000000Z-1.txt': 10,
        },
        keep: 2,
        ceilingBytes: 1000,
      );
      expect(doomed, ['anr-20260101T000000Z-1.txt']);
    });

    test('drops oldest first until the byte ceiling is met', () {
      final doomed = traceFilesToPrune(
        {
          'anr-20260101T000000Z-1.txt': 600,
          'anr-20260102T000000Z-1.txt': 600,
          'anr-20260103T000000Z-1.txt': 600,
        },
        keep: 5,
        ceilingBytes: 1000,
      );
      expect(doomed, [
        'anr-20260101T000000Z-1.txt',
        'anr-20260102T000000Z-1.txt',
      ]);
    });

    test(
      'never deletes the newest file, even if it alone busts the ceiling',
      () {
        final doomed = traceFilesToPrune(
          {'anr-20260103T000000Z-1.txt': 5000},
          keep: 5,
          ceilingBytes: 1000,
        );
        expect(
          doomed,
          isEmpty,
          reason: 'a trace too big to keep is still the only evidence we have',
        );
      },
    );
  });

  group('ExitInfoMessages', () {
    test('each failure has a distinct, non-empty message', () {
      final messages = <String>[
        ExitInfoMessages.notAndroid,
        ExitInfoMessages.nullResult,
        ExitInfoMessages.unsupported('api_below_30', 29),
        ExitInfoMessages.queryFailed('exit_info_query_failed', 'boom'),
        ExitInfoMessages.captureFailed('boom'),
        ExitInfoMessages.traceDirMissing(42),
        ExitInfoMessages.traceWriteFailed('anr-x.txt', 'boom'),
        ExitInfoMessages.pruneFailed('boom'),
        ExitInfoMessages.listFailed('boom'),
        ExitInfoMessages.watermarkReadFailed('boom'),
        ExitInfoMessages.watermarkWriteFailed('boom'),
        ExitInfoMessages.forceBlockFailed('boom'),
      ];
      for (final m in messages) {
        expect(m, isNotEmpty);
      }
      expect(messages.toSet().length, messages.length, reason: 'all distinct');
    });

    test('the unsupported message names the API level and the reason', () {
      final m = ExitInfoMessages.unsupported('api_below_30', 29);
      expect(m, contains('api_below_30'));
      expect(m, contains('sdkInt=29'));
      expect(m, contains('API 30'));
    });

    test('a query failure names the code so it is traceable', () {
      expect(
        ExitInfoMessages.queryFailed('exit_info_query_failed', 'binder died'),
        contains('exit_info_query_failed'),
      );
    });

    test('every failure message trips at least one failure marker', () {
      final messages = <String>[
        ExitInfoMessages.unsupported('api_below_30', 29),
        ExitInfoMessages.queryFailed('c', 'm'),
        ExitInfoMessages.captureFailed('e'),
        ExitInfoMessages.traceDirMissing(1),
        ExitInfoMessages.traceWriteFailed('n', 'e'),
        ExitInfoMessages.pruneFailed('e'),
        ExitInfoMessages.listFailed('e'),
        ExitInfoMessages.watermarkReadFailed('e'),
        ExitInfoMessages.watermarkWriteFailed('e'),
        ExitInfoMessages.forceBlockFailed('e'),
      ];
      for (final m in messages) {
        expect(
          ExitInfoMessages.failureMarkers.any(m.contains),
          isTrue,
          reason: 'not detectable as a failure: $m',
        );
      }
    });
  });

  group('collect over the platform channel', () {
    const channel = MethodChannel('meshcore_open/app_exit_info');
    late List<MethodCall> calls;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      calls = [];
      SharedPreferences.setMockInitialValues({});
      PrefsManager.reset();
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      PrefsManager.reset();
    });

    void handle(Future<Object?>? Function(MethodCall) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
            calls.add(call);
            return handler(call);
          });
    }

    Map<String, Object?> reply(List<Map<String, Object?>> records) => {
      'supported': true,
      'sdkInt': 34,
      'records': records,
    };

    Map<String, Object?> rec(int ts, {int pid = 1}) => {
      'reason': 6,
      'reasonName': 'ANR',
      'timestampMs': ts,
      'pid': pid,
      'importance': 100,
      'pssKb': 0,
      'rssKb': 0,
      'status': 0,
      'traceUnavailable': 'evicted_or_absent',
    };

    test('advances the watermark so nothing is logged twice', () async {
      await PrefsManager.initialize();
      handle((_) async => reply([rec(5000), rec(4000)]));

      AppExitInfoService.instance.resetForTest();
      await AppExitInfoService.instance.collect();

      expect(
        PrefsManager.instance.getInt(AppExitInfoService.watermarkKey),
        5000,
      );

      // Second launch, same records: nothing new, watermark unchanged.
      AppExitInfoService.instance.resetForTest();
      await AppExitInfoService.instance.collect();
      expect(
        PrefsManager.instance.getInt(AppExitInfoService.watermarkKey),
        5000,
      );
    });

    test('a query failure leaves the watermark alone so it retries', () async {
      SharedPreferences.setMockInitialValues({
        AppExitInfoService.watermarkKey: 1234,
      });
      await PrefsManager.initialize();
      handle(
        (_) async => throw PlatformException(code: 'exit_info_query_failed'),
      );

      AppExitInfoService.instance.resetForTest();
      await AppExitInfoService.instance.collect();

      expect(
        PrefsManager.instance.getInt(AppExitInfoService.watermarkKey),
        1234,
        reason: 'an untouched watermark is what makes the next launch retry',
      );
    });

    test(
      'an unsupported platform reply does not throw or move anything',
      () async {
        await PrefsManager.initialize();
        handle(
          (_) async => {
            'supported': false,
            'unsupportedReason': 'api_below_30',
            'sdkInt': 29,
            'records': <Object?>[],
          },
        );

        AppExitInfoService.instance.resetForTest();
        await AppExitInfoService.instance.collect();

        expect(
          PrefsManager.instance.getInt(AppExitInfoService.watermarkKey),
          isNull,
        );
        expect(calls.single.method, 'getExitRecords');
      },
    );

    test('a null reply does not throw', () async {
      await PrefsManager.initialize();
      handle((_) async => null);
      AppExitInfoService.instance.resetForTest();
      await expectLater(AppExitInfoService.instance.collect(), completes);
    });

    test('collect runs once per launch', () async {
      await PrefsManager.initialize();
      handle((_) async => reply([rec(10)]));
      AppExitInfoService.instance.resetForTest();
      await AppExitInfoService.instance.collect();
      await AppExitInfoService.instance.collect();
      expect(calls.length, 1, reason: 'second call is a no-op');
    });

    test('off Android the channel is never touched', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await PrefsManager.initialize();
      handle((_) async => reply([rec(10)]));
      AppExitInfoService.instance.resetForTest();
      await AppExitInfoService.instance.collect();
      expect(calls, isEmpty);
    });
  });
}
