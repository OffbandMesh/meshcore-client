import 'package:flutter/foundation.dart';

/// Tracks which region-scoped channels have had their banner dismissed, for the
/// current app session only. Keyed by channel PSK hex, held in memory, so a
/// dismissal lasts until the app is closed and the banner returns on a fresh
/// open (#1258). Not persisted.
class RegionScopeBannerService extends ChangeNotifier {
  final Set<String> _dismissed = {};

  bool isDismissed(String channelPskHex) => _dismissed.contains(channelPskHex);

  void dismiss(String channelPskHex) {
    if (_dismissed.add(channelPskHex)) notifyListeners();
  }
}
