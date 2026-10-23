import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../services/stale_history_sweep.dart';
import '../storage/drift/blob_store.dart';
import '../utils/app_logger.dart';

/// "Clear Stale History Now": the manual trigger for the #962 sweep.
///
/// A migrated message key keeps a frozen copy of its history, which the sweep
/// reclaims 30 days later on its own. This is for not waiting.
///
/// Its own widget rather than another card inside `app_settings_view.dart`,
/// which is already past a thousand lines, and so that B2's tests can drive it
/// without standing up the whole settings screen.
///
/// Stateful, against the repo's usual StatelessWidget-plus-Consumer habit,
/// because the running flag and the last result are local to this card and
/// belong to no service.
class StorageReclaimCard extends StatefulWidget {
  const StorageReclaimCard({
    super.key,
    BlobStore? blobs,
    Future<StaleHistoryOutcome> Function()? runSweep,
    Future<int> Function()? readSize,
  }) : _blobs = blobs,
       _runSweep = runSweep,
       _readSize = readSize;

  /// Injectable for tests; production reads the singleton.
  final BlobStore? _blobs;

  /// The sweep, injectable.
  ///
  /// Not only for convenience: the real sweep uses `compute`, and an isolate
  /// deadlocks `pumpAndSettle` inside `flutter_test`'s fake-async zone. The
  /// sweep's own behaviour is covered by Epic A's unit tests, which run under
  /// plain `test()` where isolates work. What is left to prove here is that
  /// this card reports each outcome correctly, and that is testable without
  /// re-running the engine.
  final Future<StaleHistoryOutcome> Function()? _runSweep;

  /// The size read, injectable for the same reason.
  final Future<int> Function()? _readSize;

  @override
  State<StorageReclaimCard> createState() => _StorageReclaimCardState();
}

class _StorageReclaimCardState extends State<StorageReclaimCard> {
  BlobStore get _blobs => widget._blobs ?? BlobStore.instance;

  bool _running = false;
  int? _sizeBytes;
  StaleHistoryOutcome? _result;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _refreshSize();
  }

  Future<void> _refreshSize() async {
    try {
      final size = await (widget._readSize ?? _blobs.databaseSizeBytes)();
      if (mounted) setState(() => _sizeBytes = size);
    } catch (e) {
      // A size we cannot read is not worth an error state: the action below
      // still works, and the row simply shows nothing.
      appLogger.warn('Could not read the database size: $e', tag: 'Storage');
    }
  }

  Future<void> _clear() async {
    // The disabled button is not enough on its own. `setState` only schedules
    // a rebuild, so two taps inside one frame both see an `onPressed` that is
    // still non-null and both reach here, which would run two sweeps and two
    // VACUUMs concurrently (Gemini review).
    if (_running) return;
    setState(() {
      _running = true;
      _result = null;
      _error = null;
    });
    try {
      // `olderThan: Duration.zero` is the whole point of the button: every
      // migrated key is eligible immediately. The per-key verification is
      // unchanged, so this skips the wait and not the safety.
      final outcome =
          await (widget._runSweep ??
              () => StaleHistorySweep(_blobs).run(olderThan: Duration.zero))();
      if (!mounted) return;
      setState(() {
        _result = outcome;
        _sizeBytes = outcome.bytesAfter;
      });
    } catch (e, s) {
      appLogger.error('Clear stale history failed: $e\n$s', tag: 'Storage');
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.storage_title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (_sizeBytes != null)
              Text(l10n.storage_databaseSize(_mb(_sizeBytes!))),
            const SizedBox(height: 8),
            Text(
              l10n.storage_staleHint,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: _running ? null : _clear,
                child: Text(
                  _running ? l10n.storage_working : l10n.storage_clearStaleNow,
                ),
              ),
            ),
            ?_resultLine(l10n),
          ],
        ),
      ),
    );
  }

  Widget? _resultLine(AppLocalizations l10n) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          l10n.storage_resultFailed,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
    }
    final r = _result;
    if (r == null) return null;

    final lines = <String>[
      if (r.cleared.isEmpty)
        l10n.storage_resultNothing
      else
        l10n.storage_resultCleared(
          r.cleared.length,
          _mb(r.bytesReclaimed < 0 ? 0 : r.bytesReclaimed),
        ),
      // Owner decision 2026-10-22: the button reports what it refused, it does
      // not just log it. A key kept back because its rows could not be
      // verified is the single most useful thing this action can tell you, and
      // staying quiet about it is how #952 went unnoticed for days.
      if (r.refused.isNotEmpty) l10n.storage_resultRefused(r.refused.length),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final line in lines) Text(line)],
      ),
    );
  }
}
