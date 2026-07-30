import '../models/config_profile.dart';
import 'config_profile_writes.dart';

/// Builds the human-facing diff for a profile apply (#406): current → new, per
/// field, categorized so the preview can render its two-tier confirm.
///
/// Pure, the screen fetches current device values and passes them in, so this
/// is unit-testable without a device.

enum DiffKind {
  /// Device has no value; the profile sets one.
  add,

  /// Device has a value; the profile sets a different one.
  change,
}

class DiffRow {
  const DiffRow({
    required this.label,
    required this.oldValue,
    required this.newValue,
    required this.kind,
    required this.danger,
    required this.secret,
  });

  /// Firmware key (flat) or `broker N.<field>`, never a value, safe to show.
  final String label;

  /// Current on-device value, or null if unknown/unreadable (e.g. write-only
  /// `wifi.pwd`) or absent.
  final String? oldValue;
  final String newValue;
  final DiffKind kind;

  /// In the credential/identity danger set, routed to the red gate.
  final bool danger;

  /// A true secret (password / wifi.pwd), the UI must mask both values.
  final bool secret;
}

class ProfileDiff {
  const ProfileDiff(this.rows);
  final List<DiffRow> rows;

  bool get isEmpty => rows.isEmpty;
  List<DiffRow> get dangerRows => rows.where((r) => r.danger).toList();
  List<DiffRow> get safeRows => rows.where((r) => !r.danger).toList();
  bool get hasDanger => rows.any((r) => r.danger);
}

/// Broker sub-keys + flat keys that hold true secrets (mask both values).
const Set<String> _secretBrokerFields = {ConfigKeys.brokerPassword};
const Set<String> _secretFlatKeys = {ConfigKeys.wifiPassword};

/// Build the diff. [currentFlat] maps a flat key → current value (null =
/// unknown/absent). [currentBroker] maps slot → (subkey → current value).
/// Rows where the new value equals the current value are dropped (no-op).
ProfileDiff buildProfileDiff(
  ProfileWrites writes, {
  required Map<String, String?> currentFlat,
  required Map<int, Map<String, String?>> currentBroker,
}) {
  final rows = <DiffRow>[];

  for (final f in writes.flats) {
    final current = currentFlat[f.key];
    if (current == f.value) continue; // unchanged
    rows.add(
      DiffRow(
        label: f.key,
        oldValue: current,
        newValue: f.value,
        kind: (current == null || current.isEmpty)
            ? DiffKind.add
            : DiffKind.change,
        danger: f.danger,
        secret: _secretFlatKeys.contains(f.key),
      ),
    );
  }

  for (final b in writes.brokers) {
    final cur = currentBroker[b.slot] ?? const {};
    for (final entry in b.fields.entries) {
      final current = cur[entry.key];
      if (current == entry.value) continue; // unchanged
      rows.add(
        DiffRow(
          label: 'broker ${b.slot}.${entry.key}',
          oldValue: current,
          newValue: entry.value,
          kind: (current == null || current.isEmpty)
              ? DiffKind.add
              : DiffKind.change,
          danger: b.dangerFields.contains(entry.key),
          secret: _secretBrokerFields.contains(entry.key),
        ),
      );
    }
    // Broker enabled is not a profile field (#456), never diffed/applied.
  }

  return ProfileDiff(rows);
}
