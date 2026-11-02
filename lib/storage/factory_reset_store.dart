import 'dart:convert';

import 'prefs_manager.dart';

/// A factory reset that was sent and not yet proven (#1054).
///
/// The firmware disables the link before it formats, so the client never
/// hears whether the wipe worked. The proof is the next connect to the same
/// device: a new identity means it worked. Until then this record keeps the
/// old radio's data alive, so a reset that failed cannot cost the user their
/// history.
class PendingFactoryReset {
  const PendingFactoryReset({
    required this.deviceId,
    required this.radioPrefix,
    required this.deleteAppData,
  });

  /// The transport identity the reset went to: BLE remote id, USB port key or
  /// TCP endpoint. A connect to anything else says nothing about this reset.
  final String deviceId;

  /// First 10 hex of the radio's key before the reset.
  final String radioPrefix;

  /// The user's choice in the confirm dialog.
  final bool deleteAppData;

  Map<String, dynamic> toJson() => {
    'device_id': deviceId,
    'radio_prefix': radioPrefix,
    'delete_app_data': deleteAppData,
  };

  static PendingFactoryReset? fromJson(Map<String, dynamic> json) {
    final deviceId = json['device_id'];
    final radioPrefix = json['radio_prefix'];
    final deleteAppData = json['delete_app_data'];
    if (deviceId is! String ||
        radioPrefix is! String ||
        deleteAppData is! bool) {
      return null;
    }
    return PendingFactoryReset(
      deviceId: deviceId,
      radioPrefix: radioPrefix,
      deleteAppData: deleteAppData,
    );
  }
}

enum FactoryResetOutcome {
  /// New identity, and the user asked for the app data to go.
  wipeAppData,

  /// New identity, and the user asked to keep the app data.
  keepAppData,

  /// Same identity: the radio was not wiped. Nothing is deleted.
  notReset,
}

/// What connecting to [deviceId] as [radioPrefix] says about [pending].
///
/// Null when it is a different device, so the record stays and nothing is
/// decided on the strength of some other radio.
FactoryResetOutcome? resolveFactoryReset(
  PendingFactoryReset pending, {
  required String deviceId,
  required String radioPrefix,
}) {
  if (deviceId != pending.deviceId) return null;
  if (radioPrefix == pending.radioPrefix) return FactoryResetOutcome.notReset;
  return pending.deleteAppData
      ? FactoryResetOutcome.wipeAppData
      : FactoryResetOutcome.keepAppData;
}

/// Survives an app restart between the reset and the reconnect, so closing
/// the app in between does not quietly skip the delete the user asked for.
class FactoryResetStore {
  static const String _key = 'factory_reset_pending';

  PendingFactoryReset? load() {
    final raw = PrefsManager.instance.getString(_key);
    if (raw == null) return null;
    try {
      return PendingFactoryReset.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save(PendingFactoryReset pending) =>
      PrefsManager.instance.setString(_key, jsonEncode(pending.toJson()));

  Future<void> clear() => PrefsManager.instance.remove(_key);
}
