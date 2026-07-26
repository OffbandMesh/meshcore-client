import 'package:flutter/foundation.dart';

/// Tracks whether the app's storage layer (drift/SQLite) opened successfully at
/// startup (#385).
///
/// When the database can't open — e.g. the native `sqlite3` library fails to
/// load — every read and write silently fails and the app looks wiped. This
/// holds that state so the UI can show a loud, persistent warning instead of an
/// empty, normal-looking screen (SAFELANE §6: no silent failures).
class StorageHealthService extends ChangeNotifier {
  bool _available = true;
  String? _error;

  /// True until a startup probe proves storage cannot be read/written.
  bool get available => _available;

  /// The underlying error, for the log and diagnostics. Null when healthy.
  String? get error => _error;

  /// Marks storage as unavailable and records [error]. A one-way latch: once
  /// unavailable it stays that way for the session (recovery is a restart), so
  /// a later call is a no-op and does not re-notify.
  void markUnavailable(Object error) {
    if (!_available) return;
    _available = false;
    _error = error.toString();
    notifyListeners();
  }
}
