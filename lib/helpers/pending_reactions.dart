import '../utils/app_logger.dart';
import 'reaction_helper.dart';

class _Pending {
  final String scopeKey;
  final ReactionInfo info;
  final String reactingSender;
  final DateTime queuedAt;

  const _Pending(this.scopeKey, this.info, this.reactingSender, this.queuedAt);
}

/// Reactions that arrived before the message they point at.
///
/// Out-of-order delivery is normal on a mesh, so a reaction with no local
/// target is not junk, it is early. Before this existed the connector consumed
/// such a reaction and dropped it with no badge, no message and no log, which
/// is indistinguishable from nobody having reacted (GH #382).
///
/// Entries are bounded and expire. A drop is logged at warn so it surfaces in
/// the in-app log and the file log rather than vanishing (SAFELANE 6). Whether
/// dropping is the right end state is still open; the ratio of late matches to
/// expiries in the log is the evidence for revisiting it.
class PendingReactions {
  static const int maxEntries = 50;
  static const Duration ttl = Duration(minutes: 15);

  final List<_Pending> _entries = [];

  int get length => _entries.length;

  void add(
    String scopeKey,
    ReactionInfo info,
    String reactingSender,
    DateTime now,
  ) {
    expire(now);
    _entries.add(_Pending(scopeKey, info, reactingSender, now));
    if (_entries.length > maxEntries) {
      _drop(_entries.removeAt(0), now, 'queue full');
    }
    appLogger.info(
      'Queued reaction ${info.emoji} from $reactingSender for unseen target '
      '${info.targetHash} in $scopeKey (${_entries.length}/$maxEntries pending)',
      tag: 'Reactions',
    );
  }

  /// Re-attempt every live entry for [scopeKey]. [apply] receives the queued
  /// reaction and the name of whoever sent it, and reports whether it found its
  /// target; matched entries are removed, the rest stay.
  void retry(
    String scopeKey,
    bool Function(ReactionInfo info, String reactingSender) apply,
    DateTime now,
  ) {
    expire(now);
    _entries.removeWhere((entry) {
      if (entry.scopeKey != scopeKey) return false;
      if (!apply(entry.info, entry.reactingSender)) return false;
      appLogger.info(
        'Late-matched reaction ${entry.info.emoji} from ${entry.reactingSender} '
        'to ${entry.info.targetHash} in $scopeKey after '
        '${now.difference(entry.queuedAt).inSeconds}s',
        tag: 'Reactions',
      );
      return true;
    });
  }

  void expire(DateTime now) {
    _entries.removeWhere((entry) {
      if (now.difference(entry.queuedAt) < ttl) return false;
      _drop(entry, now, 'expired after ${ttl.inMinutes}m');
      return true;
    });
  }

  void _drop(_Pending entry, DateTime now, String why) {
    appLogger.warn(
      'Dropping unmatched reaction ${entry.info.emoji} from '
      '${entry.reactingSender} for target ${entry.info.targetHash} in '
      '${entry.scopeKey} ($why, age ${now.difference(entry.queuedAt).inSeconds}s). '
      'The message it points at was never seen locally.',
      tag: 'Reactions',
    );
  }
}
