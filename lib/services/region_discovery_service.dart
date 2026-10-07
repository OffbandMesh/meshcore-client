import 'package:flutter/foundation.dart';

import '../connector/meshcore_protocol.dart';
import '../models/region.dart';

/// Where a discovery run can land. Each non-success state is distinct so the UI
/// can render it as itself (an empty reply is not success; a timeout is not an
/// error). (#814)
enum RegionDiscoveryStatus { idle, loading, success, empty, timeout, error }

/// Sends one regions-discovery request to a repeater and returns the reply, or
/// null on timeout. In production this is [MeshCoreConnector.discoverRegions];
/// tests inject a fake so the lifecycle can be exercised without a radio.
typedef RegionsDiscoverer =
    Future<RegionsReply?> Function(Uint8List repeaterPubKey, Duration timeout);

/// Drives Discover Regions: ask a chosen repeater which flood regions it
/// advertises, dedupe them, and expose a single discovery state for the UI.
class RegionDiscoveryService extends ChangeNotifier {
  RegionDiscoveryService(this._discover);

  final RegionsDiscoverer _discover;

  RegionDiscoveryStatus _status = RegionDiscoveryStatus.idle;
  List<Region> _regions = const [];
  int? _clock;
  String? _errorMessage;
  bool _disposed = false;

  RegionDiscoveryStatus get status => _status;
  List<Region> get regions => _regions;

  /// The repeater's clock from the last successful reply (for clock display).
  int? get clock => _clock;

  /// A human-readable reason when [status] is [RegionDiscoveryStatus.error].
  String? get errorMessage => _errorMessage;

  bool get isLoading => _status == RegionDiscoveryStatus.loading;

  /// Discover regions from [repeaterPubKey] (a 32-byte node key). Concurrent
  /// starts are ignored while one is in flight.
  Future<void> discover(
    Uint8List repeaterPubKey, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_status == RegionDiscoveryStatus.loading) return;
    _status = RegionDiscoveryStatus.loading;
    _regions = const [];
    _errorMessage = null;
    _safeNotify();

    try {
      final reply = await _discover(repeaterPubKey, timeout);
      if (reply == null) {
        _status = RegionDiscoveryStatus.timeout;
      } else {
        _clock = reply.clock;
        final regions = _dedupe(reply.regionNames);
        if (regions.isEmpty) {
          _status = RegionDiscoveryStatus.empty;
        } else {
          _regions = regions;
          _status = RegionDiscoveryStatus.success;
        }
      }
    } catch (e) {
      _status = RegionDiscoveryStatus.error;
      _errorMessage = e.toString();
    }
    // The screen may have been popped (and this service disposed) while the
    // discovery future was in flight; notifying a disposed ChangeNotifier
    // throws, so guard it.
    _safeNotify();
  }

  /// Return to the idle state, clearing any prior result.
  void reset() {
    _status = RegionDiscoveryStatus.idle;
    _regions = const [];
    _clock = null;
    _errorMessage = null;
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  /// Dedupe by [Region] value-equality, preserving first-seen order.
  List<Region> _dedupe(List<String> names) {
    final seen = <Region>{};
    final out = <Region>[];
    for (final name in names) {
      final region = Region(name);
      if (seen.add(region)) out.add(region);
    }
    return out;
  }
}
