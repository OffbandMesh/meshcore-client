import '../storage/channel_message_store.dart';
import '../storage/drift/blob_store.dart';
import '../storage/message_store.dart';
import '../utils/app_logger.dart';

/// How long a migrated key keeps its stale blob before the sweep reclaims it.
///
/// Owner decision, 2026-10-22: 30 days. One full month of real use, matching
/// the monthly granularity of the Play install and crash reports he reads, so
/// a migration problem has a reporting cycle to surface in before the snapshot
/// goes. A named constant so changing it is one edit and tests can pass their
/// own window instead of manipulating clocks.
const Duration staleHistoryWindow = Duration(days: 30);

/// What a sweep did. Byte counts come from SQLite, not from adding up blob
/// lengths, so they are what actually changed rather than what should have.
class StaleHistoryOutcome {
  const StaleHistoryOutcome({
    required this.cleared,
    required this.refused,
    required this.bytesBefore,
    required this.bytesAfter,
  });

  /// Keys whose stale blob was verified redundant and deleted.
  final List<String> cleared;

  /// Keys that were eligible by age but **kept**, because the blob could not
  /// be verified against the rows. Surfaced to the user by the manual action
  /// (#966); the automatic sweep logs them.
  final List<String> refused;

  final int bytesBefore;
  final int bytesAfter;

  int get bytesReclaimed => bytesBefore - bytesAfter;

  bool get didAnything => cleared.isNotEmpty;
}

/// What a sweep WOULD do, for the confirmation dialog (#962).
class StaleHistoryPreview {
  const StaleHistoryPreview({
    required this.eligible,
    required this.refused,
    required this.approximateBytes,
    required this.messagesKept,
  });

  /// Keys whose stale copy is verified redundant and would be deleted.
  final List<String> eligible;

  /// Keys already known to be unverifiable, so they would be kept. Saying so
  /// before the press beats reporting it afterwards.
  final List<String> refused;

  /// Blob bytes that would go.
  ///
  /// **Approximate on purpose.** It is the sum of the blob lengths, which is
  /// not the same as what `VACUUM` returns to the filesystem: page rounding
  /// and existing free pages both move the real figure. The dialog says
  /// "about", and the result afterwards reports what actually changed.
  final int approximateBytes;

  /// Total stored messages, so the dialog can say what is NOT affected. The
  /// reassurance is the point: this action deletes, and the user needs to know
  /// their history is not what is being deleted.
  final int messagesKept;

  bool get hasWork => eligible.isNotEmpty;
}

/// Deletes the frozen pre-migration blob of a key that has been on rows long
/// enough, and returns the space to the filesystem (#962).
///
/// The blob a migrated key leaves behind is a snapshot taken at the migration
/// moment, not a mirror: nothing writes it afterwards. So it protects the
/// pre-migration history against a migration or read-path bug found later, and
/// protects nothing that arrived since, which is single-copy from the instant
/// it lands either way. After [staleHistoryWindow] that protection has had its
/// chance and the duplicate is just cost.
///
/// Every delete is gated on asking the rows again, immediately, rather than
/// trusting the marker. A key that cannot be verified keeps its blob and says
/// so, and is never retried in a loop: a refusal that silently repeats forever
/// is what made #952 invisible for days.
class StaleHistorySweep {
  StaleHistorySweep(this._blobs);

  final BlobStore _blobs;

  /// Only these two key shapes have a row equivalent. `contacts`,
  /// `discovered_contacts` and `path_history_` live in blobs as their ONLY
  /// storage, so they are never candidates, and this is asserted by name in
  /// the tests rather than left to the marker to get right.
  static const List<String> _historyPrefixes = [
    'channel_messages_',
    'messages_',
  ];

  static bool isHistoryKey(String key) => _historyPrefixes.any(key.startsWith);

  /// The converter for a key, chosen by its shape. Channel and direct
  /// histories encode differently, and using the wrong one would make every
  /// record look missing, which refuses rather than deletes.
  static BlobToRowsCallback converterFor(String key) =>
      key.startsWith('channel_messages_')
      ? channelHistoryToRows
      : dmHistoryToRows;

  /// Whether a key is old enough to reclaim. The ONE age rule, shared by
  /// [preview] and [run], so the dialog cannot promise what the sweep will not
  /// do.
  ///
  /// A key with no timestamp, or one stamped during this pass, has no age to
  /// judge. For the automatic sweep that means **not eligible**: the stamp
  /// exists so installing an update never deletes a blob on sight. For an
  /// explicit press it means **eligible**, because a user asking to clear now
  /// is not an app update. Treating the two the same made the button report
  /// "nothing to clear" on any install that migrated before #962, which is
  /// every real install, since none of their keys carry a stamp yet.
  static bool eligibleByAge({
    required DateTime? migratedAt,
    required bool freshlyStamped,
    required Duration window,
    required DateTime at,
    required bool includeNewlyStamped,
  }) {
    if (freshlyStamped || migratedAt == null) return includeNewlyStamped;
    return at.difference(migratedAt) >= window;
  }

  /// What a sweep would do, without doing any of it (#962).
  ///
  /// The confirmation dialog states real numbers rather than an estimate, so
  /// the verification has to run before the delete rather than as part of it.
  /// The cost is that it happens twice for a confirmed clear: once here, once
  /// under the key lock in [run]. That is the price of saying what will go
  /// before it goes.
  ///
  /// Writes nothing. In particular it does not stamp, so calling it never
  /// changes what a later [run] does.
  Future<StaleHistoryPreview> preview({
    Duration? olderThan,
    DateTime? now,
    bool includeNewlyStamped = false,
  }) async {
    final window = olderThan ?? staleHistoryWindow;
    final at = now ?? DateTime.now();

    final eligible = <String>[];
    final refused = <String>[];
    var bytes = 0;

    for (final key in (await _blobs.messageStoreKeys()).toList()..sort()) {
      if (!isHistoryKey(key)) continue;
      if (!await _blobs.isOnMessageRows(key)) continue;
      if (!eligibleByAge(
        migratedAt: await _blobs.messageRowsMigratedAt(key),
        freshlyStamped: false,
        window: window,
        at: at,
        includeNewlyStamped: includeNewlyStamped,
      )) {
        continue;
      }

      final blob = await _blobs.read(key);
      if (blob == null) continue; // already reclaimed

      final missing = await _blobs.missingFromRows(key, converterFor(key));
      if (missing == null || missing.isNotEmpty) {
        refused.add(key);
        continue;
      }
      eligible.add(key);
      bytes += blob.length;
    }

    return StaleHistoryPreview(
      eligible: eligible,
      refused: refused,
      approximateBytes: bytes,
      messagesKept: await _blobs.totalMessageRows(),
    );
  }

  /// Runs one sweep.
  ///
  /// [olderThan] defaults to [staleHistoryWindow]; [now] exists so tests can
  /// choose a moment rather than wait. Backfills a timestamp onto any
  /// already-migrated key that has none. [includeNewlyStamped] decides whether
  /// such a key can be cleared on the same pass: false for the automatic
  /// sweep, true for an explicit press. See [eligibleByAge].
  Future<StaleHistoryOutcome> run({
    Duration? olderThan,
    DateTime? now,
    bool includeNewlyStamped = false,
  }) async {
    final window = olderThan ?? staleHistoryWindow;
    final at = now ?? DateTime.now();
    final bytesBefore = await _blobs.databaseSizeBytes();

    // Stamp first. A key seen for the first time gets the full window from
    // now, so updating the app never deletes a blob on the spot.
    final stamped = await _blobs.backfillMigratedAt(now: at);

    final cleared = <String>[];
    final refused = <String>[];

    for (final key in (await _blobs.messageStoreKeys()).toList()..sort()) {
      if (!isHistoryKey(key)) continue;
      if (!await _blobs.isOnMessageRows(key)) continue;
      if (!eligibleByAge(
        migratedAt: await _blobs.messageRowsMigratedAt(key),
        freshlyStamped: stamped.contains(key),
        window: window,
        at: at,
        includeNewlyStamped: includeNewlyStamped,
      )) {
        continue;
      }

      // Verify and delete under the key's own lock, as one step. Deciding on
      // one call and deleting on another leaves a window, and a delete made on
      // a stale answer cannot be taken back.
      final result = await _blobs.reclaimVerifiedHistoryBlob(
        key,
        converterFor(key),
      );

      if (result.deleted) {
        cleared.add(key);
        continue;
      }
      final missing = result.missing;
      if (missing == null) {
        // Unverifiable, NOT verified-empty. Keep it.
        refused.add(key);
        continue;
      }
      if (missing.isNotEmpty) {
        appLogger.error(
          'Keeping the stale blob for $key: ${missing.length} of its records '
          'have no row (e.g. ${missing.take(3).join(', ')}). The blob stays '
          'the only copy of those and is not deleted.',
          tag: 'Storage',
        );
        refused.add(key);
      }
      // Otherwise there was no blob left to reclaim: not cleared, not refused.
    }

    if (cleared.isNotEmpty) {
      // VACUUM takes an exclusive lock and rebuilds the file, so database
      // access queues behind it. It does NOT block the UI thread: drift_flutter
      // runs SQLite in a spawned isolate (`_isolateEntrypoint` ->
      // `DriftIsolate.inCurrent`), so this is a stall on history-backed reads
      // rather than an ANR, which is the distinction that matters for an app
      // whose storage work started as an ANR investigation.
      //
      // It is also close to once per install: a key is cleared once and then
      // has no blob to consider, so later launches delete nothing and never
      // reach here. Measured at 0.6 s on the owner's 70.9 MiB database. The
      // duration is logged because that is a number worth watching in the
      // field rather than assuming.
      final sw = Stopwatch()..start();
      try {
        await _blobs.vacuum();
        appLogger.info(
          'VACUUM took ${sw.elapsedMilliseconds} ms after clearing '
          '${cleared.length} stale blob(s).',
          tag: 'Storage',
        );
      } catch (e) {
        // The deletes already happened and were each verified; VACUUM only
        // affects file size, so a failure here costs space and not data. The
        // next sweep retries it.
        appLogger.warn(
          'Deleted ${cleared.length} stale blob(s) but VACUUM failed, so the '
          'space is free for reuse and not yet returned to the filesystem: '
          '$e',
          tag: 'Storage',
        );
      }
    }

    // A sweep that deleted blobs correctly must not be reported as a failure
    // because the closing size read threw. The deletes are the work; the byte
    // count is reporting. Falling back to `bytesBefore` makes the reclaimed
    // figure read as 0, which understates rather than invents, and keeps the
    // manual action from telling the user nothing happened when something did
    // (Gemini review).
    int bytesAfter;
    try {
      bytesAfter = await _blobs.databaseSizeBytes();
    } catch (e) {
      appLogger.warn(
        'Cleared ${cleared.length} stale blob(s) but could not read the '
        'database size afterwards, so the reclaimed figure reads as 0: $e',
        tag: 'Storage',
      );
      bytesAfter = bytesBefore;
    }

    if (cleared.isNotEmpty || refused.isNotEmpty) {
      // Names the keys, not just a count. "Cleared 40" is not an audit trail
      // for a delete that cannot be undone.
      appLogger.info(
        'Stale history sweep: cleared ${cleared.length}, kept '
        '${refused.length} that could not be verified, '
        '${bytesBefore - bytesAfter} bytes returned.\n'
        'cleared: ${cleared.join(', ')}'
        '${refused.isEmpty ? '' : '\nkept: ${refused.join(', ')}'}',
        tag: 'Storage',
      );

      // And durably, because the log above is gated on the app-debug-logging
      // setting, which is off by default. Without this an irreversible delete
      // would leave no trail at all on a normal install.
      try {
        await _blobs.appendReclaimAudit(
          at: at,
          cleared: cleared,
          refused: refused,
          bytesBefore: bytesBefore,
          bytesAfter: bytesAfter,
        );
      } catch (e) {
        appLogger.warn(
          'Could not write the reclaim audit entry: $e',
          tag: 'Storage',
        );
      }
    }

    return StaleHistoryOutcome(
      cleared: cleared,
      refused: refused,
      bytesBefore: bytesBefore,
      bytesAfter: bytesAfter,
    );
  }
}
