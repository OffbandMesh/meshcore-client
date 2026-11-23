import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../utils/app_logger.dart';
import 'drift/blob_store.dart';

/// One stored channel message, as the cleanup sees it.
typedef ScannedRow = ({String storeKey, String mergeKey, int? rxTime});

/// What [findCrossRadioCopies] decided.
class CopyDecision {
  const CopyDecision({required this.copies, required this.undecided});

  /// Rows to hold aside: each is a copy whose original is on another radio.
  final List<ScannedRow> copies;

  /// Copied messages left alone because no single radio can be shown to have
  /// received them.
  final int undecided;
}

const _channelPrefix = 'channel_messages_';

String _radioOf(String storeKey) =>
    storeKey.substring(_channelPrefix.length, _channelPrefix.length + 10);

/// Finds channel messages that one radio received and a radio switch then
/// wrote into another radio's history (#1163).
///
/// A copy keeps the original's receive time (`rxTime`) exactly. Two radios
/// that each heard a packet deliver it at different moments, so the same
/// message under two radios with the same receive time is one reception stored
/// twice.
///
/// The original is on the radio that was connected when the message arrived.
/// A radio's connected periods come from its own receptions: rows whose
/// receive time no other radio shares. Runs of them with no gap longer than
/// [gap] form a session, and a session covers [gap] either side. When exactly
/// one of the radios holding a copy covers the receive time, the others hold
/// copies. When none or several do, nothing is touched: the stored data cannot
/// say which is real.
///
/// Run on a copy of the owner's Windows store (2,893 copied messages): 2,864
/// rows held aside, 294 messages left alone. Every held row's original was
/// kept, and none of the 257 held agent alerts, whose channel is known from
/// their text, came from that channel.
CopyDecision findCrossRadioCopies(
  List<ScannedRow> rows, {
  Duration gap = const Duration(minutes: 60),
}) {
  final byMessage = <String, List<ScannedRow>>{};
  for (final r in rows) {
    if (r.rxTime == null || r.storeKey.length < _channelPrefix.length + 10) {
      continue;
    }
    byMessage.putIfAbsent(r.mergeKey, () => []).add(r);
  }

  final ownReceptions = <String, List<int>>{};
  final copyGroups = <List<ScannedRow>>[];
  for (final group in byMessage.values) {
    final byTime = <int, List<ScannedRow>>{};
    for (final r in group) {
      byTime.putIfAbsent(r.rxTime!, () => []).add(r);
    }
    for (final entry in byTime.entries) {
      final radios = {for (final r in entry.value) _radioOf(r.storeKey)};
      if (radios.length > 1) {
        copyGroups.add(entry.value);
      } else {
        ownReceptions.putIfAbsent(radios.single, () => []).add(entry.key);
      }
    }
  }

  final gapMs = gap.inMilliseconds;
  final sessions = <String, List<(int, int)>>{};
  ownReceptions.forEach((radio, times) {
    times.sort();
    final spans = <(int, int)>[];
    var start = times.first;
    var prev = times.first;
    for (final t in times.skip(1)) {
      if (t - prev > gapMs) {
        spans.add((start, prev));
        start = t;
      }
      prev = t;
    }
    spans.add((start, prev));
    sessions[radio] = spans;
  });

  bool connectedAt(String radio, int t) {
    final spans = sessions[radio];
    if (spans == null) return false;
    var lo = 0;
    var hi = spans.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final (s, e) = spans[mid];
      if (t < s - gapMs) {
        hi = mid - 1;
      } else if (t > e + gapMs) {
        lo = mid + 1;
      } else {
        return true;
      }
    }
    return false;
  }

  final copies = <ScannedRow>[];
  var undecided = 0;
  for (final group in copyGroups) {
    final t = group.first.rxTime!;
    final radios = {for (final r in group) _radioOf(r.storeKey)};
    final connected = radios.where((radio) => connectedAt(radio, t)).toList();
    if (connected.length != 1) {
      undecided++;
      continue;
    }
    copies.addAll(group.where((r) => _radioOf(r.storeKey) != connected.single));
  }
  return CopyDecision(copies: copies, undecided: undecided);
}

CopyDecision _decide(List<ScannedRow> rows) => findCrossRadioCopies(rows);

/// Runs [findCrossRadioCopies] once over the stored history and holds the
/// copies aside (#1163).
///
/// Held, not deleted: each copy moves to [heldPrefix] + its original key, a key
/// nothing reads, so a wrong call can be put back. A marker records the run so
/// it happens once; the counts go to the log either way.
class CrossRadioCopyCleanup {
  CrossRadioCopyCleanup._();

  static const doneMarkerKey = '__cleanup_1163_cross_radio_copies';
  static const heldPrefix = 'held_1163_copy|';

  static Future<void> run([BlobStore? store]) async {
    final blobs = store ?? BlobStore.instance;
    try {
      if (await blobs.read(doneMarkerKey) != null) return;
      final rows = await blobs.messageRowTimes(_channelPrefix);
      final decision = await compute(_decide, rows);

      final byKey = <String, List<String>>{};
      for (final r in decision.copies) {
        byKey.putIfAbsent(r.storeKey, () => []).add(r.mergeKey);
      }
      var blobsHeld = 0;
      for (final entry in byKey.entries) {
        await blobs.moveMessageRows(
          entry.key,
          '$heldPrefix${entry.key}',
          entry.value,
        );
        // A key left with no rows reads its frozen pre-#920 blob instead,
        // which would put the copies straight back on screen. Rows are a
        // superset of that blob (the #952 gate), so when every row was a copy
        // the blob holds only copies: it is held aside too (review of #1163).
        if (await blobs.messageRowCount(entry.key) == 0) {
          final blob = await blobs.read(entry.key);
          if (blob != null) {
            await blobs.write('$heldPrefix${entry.key}', blob);
            await blobs.deleteEverywhere(entry.key);
            blobsHeld++;
          }
        }
      }
      await blobs.write(
        doneMarkerKey,
        jsonEncode({
          'at': DateTime.now().toIso8601String(),
          'held': decision.copies.length,
          'undecided': decision.undecided,
          'blobsHeld': blobsHeld,
          'keys': {for (final e in byKey.entries) e.key: e.value.length},
        }),
      );
      appLogger.info(
        'Cross-radio copy cleanup: scanned ${rows.length} channel messages, '
        'held aside ${decision.copies.length} copies from ${byKey.length} '
        'channel histories, left ${decision.undecided} undecided (#1163)',
        tag: 'Storage',
      );
    } catch (e) {
      // No marker is written, so the next launch tries again; the history is
      // untouched by a failed move, which runs in one transaction per key.
      appLogger.error(
        'Cross-radio copy cleanup failed and will retry next launch: $e',
        tag: 'Storage',
      );
    }
  }
}
