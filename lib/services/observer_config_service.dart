// Drives the Offband config command end-to-end: builds frames via
// [ObserverConfigClient], sends them over the active transport, awaits and
// parses the response, and holds the parsed [ObserverConfig].
//
// Device NVS is the source of truth — this service caches the last read but
// never persists locally. The firmware protocol has no request id, so
// responses are correlated by ORDER: keep ONE request in flight at a time
// (the settings UI sends staged changes sequentially, awaiting each).

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connector/meshcore_connector.dart';
import '../connector/observer_config_client.dart';
import '../models/observer_config.dart';
import 'file_log_service.dart';

class ObserverConfigService extends ChangeNotifier {
  ObserverConfigService(this._connector);

  final MeshCoreConnector _connector;

  /// Per-request timeout. The device replies within a few frames; a miss means
  /// an unsupported node or a dropped frame.
  Duration timeout = const Duration(seconds: 6);

  /// After a broker enable/disable SET, wait this long before the verify re-read
  /// so a device that applies the change asynchronously has settled (#89).
  static const Duration applySettleDelay = Duration(milliseconds: 600);

  ObserverConfig? _config;
  ObserverConfig? get config => _config;

  /// True after a refresh failed to complete — the UI shows stale data warning
  /// rather than silently presenting an out-of-date snapshot.
  bool _stale = false;
  bool get stale => _stale;

  /// Last error surfaced (SAFELANE §6 — every failure is visible). The UI shows
  /// it; cleared on the next success.
  String? _lastError;
  String? get lastError => _lastError;

  /// True when the broker-pool dump failed but the flat settings read OK — the
  /// UI shows the broker section as unavailable instead of blanking the pane.
  bool _brokersUnavailable = false;
  bool get brokersUnavailable => _brokersUnavailable;

  /// Whether the connected device supports the config command — the version
  /// gate AND the capability bit, read live from the connector's device-info
  /// parse. The settings UI watches the connector, so the Observer category
  /// appears/hides as this flips on connect/disconnect.
  bool get supported => ObserverConfigClient.supportsConfig(
    firmwareVerCode: _connector.firmwareVerCode ?? 0,
    offbandCaps: _connector.offbandCaps ?? 0,
  );

  void _setError(String? e) {
    _lastError = e;
    notifyListeners();
  }

  // --- Single-flight serialization (Gemini BLOCKER #1) ----------------------
  // No firmware request id -> responses correlate by ORDER, so exactly one
  // transport round-trip may be in flight at a time. This chain-lock serializes
  // every send/await so overlapping refresh()/setFlat() cannot cross responses.
  Future<void> _lock = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() op) {
    final release = Completer<void>();
    final prev = _lock;
    _lock = release.future;
    return prev.then((_) => op()).whenComplete(() => release.complete());
  }

  /// Secret keys whose name must never appear in a surfaced error (Gemini #6).
  static bool _isSecretKey(String key) =>
      key == 'wifi.pwd' || key.endsWith('.password') || key.endsWith('.pwd');
  static String _safeKey(String key) => _isSecretKey(key) ? '<secret>' : key;

  // --- Round-trips ----------------------------------------------------------

  /// Send [frame] and await the first config response (scalar SET/GET).
  Future<ConfigResponse> _roundTrip(Uint8List frame) {
    return _serialized(() async {
      final completer = Completer<ConfigResponse>();
      final sub = _connector.receivedFrames.listen((f) {
        if (f.isNotEmpty &&
            f[0] == ObserverConfigClient.respConfig &&
            !completer.isCompleted) {
          completer.complete(ObserverConfigClient.parse(f));
        }
      });
      try {
        await _connector.sendFrame(frame);
        return await completer.future.timeout(timeout);
      } finally {
        await sub.cancel();
      }
    });
  }

  /// SET a flat key (or `mqtt.broker.<N>.<field>`). Returns true on ACK; on ERR
  /// or timeout records [lastError] and returns false.
  Future<bool> setFlat(String key, String value) async {
    try {
      final r = await _roundTrip(ObserverConfigClient.buildSet(key, value));
      if (r is ConfigAck) {
        _setError(null);
        return true;
      }
      _setError(
        r is ConfigErr ? r.text : 'SET ${_safeKey(key)}: unexpected response',
      );
      return false;
    } catch (e) {
      _setError('SET ${_safeKey(key)} failed: $e');
      return false;
    }
  }

  /// GET a flat key. Returns the value text, or null on ERR/timeout.
  Future<String?> getFlat(String key) async {
    try {
      final r = await _roundTrip(ObserverConfigClient.buildGet(key));
      if (r is ConfigValue) return r.value;
      if (r is ConfigErr) _setError(r.text);
      return null;
    } catch (e) {
      _setError('GET ${_safeKey(key)} failed: $e');
      return null;
    }
  }

  /// SET one broker field (`mqtt.broker.<slot>.<field>`).
  Future<bool> setBrokerField(int slot, String field, String value) =>
      setFlat('mqtt.broker.$slot.$field', value);

  /// Save a broker [slot] field-at-a-time per the firmware contract: a live slot
  /// is disabled first, each changed [fields] entry is written, then `enabled`
  /// is written LAST (when [enable]). Stops at the first ERR/timeout and reports
  /// the failed field — a partial save therefore leaves the slot disabled, never
  /// live-corrupt (#80). The caller re-GETs the slot to show true state + offer
  /// retry/clear.
  Future<BrokerSaveResult> saveBroker(
    int slot, {
    required Map<String, String> fields,
    required bool enable,
    required bool wasLive,
  }) async {
    if (wasLive) {
      if (!await setBrokerField(slot, 'enabled', '0')) {
        return const BrokerSaveResult.failed('enabled');
      }
    }
    for (final e in fields.entries) {
      if (!await setBrokerField(slot, e.key, e.value)) {
        return BrokerSaveResult.failed(e.key);
      }
    }
    if (enable) {
      if (!await setBrokerField(slot, 'enabled', '1')) {
        return const BrokerSaveResult.failed('enabled');
      }
    }
    return const BrokerSaveResult.ok();
  }

  /// Definitively wipe a broker slot — `mqtt.broker.<slot>.clear` (#80).
  Future<bool> clearBroker(int slot) => setBrokerField(slot, 'clear', '1');

  /// Re-read a single broker [slot] field-by-field — the post-save / recovery
  /// re-GET. Cheaper than the whole pool: 14 scalar GETs for one slot, not the
  /// 84-frame OCFG_BROKERS dump (#80). Returns null if any field GET fails.
  Future<BrokerConfig?> getBroker(int slot) async {
    const fields = [
      'enabled',
      'url',
      'port',
      'transport',
      'auth_type',
      'username',
      'password',
      'topic_prefix',
      'iata_override',
      'jwt_audience',
      'jwt_refresh',
      'jwt_owner',
      'jwt_email',
      'ca_cert',
    ];
    final kv = <String, String>{};
    for (final f in fields) {
      final v = await getFlat('mqtt.broker.$slot.$f');
      if (v == null) {
        // password is write-only — a missing read is its presence, not a slot
        // failure; any other missing field means the re-GET is incomplete.
        if (f == 'password') continue;
        return null;
      }
      kv[f] = v;
    }
    return BrokerConfig.fromWireFields(slot, kv);
  }

  void _logBroker(String msg) => FileLogService.instance.write(
    '${DateTime.now().toIso8601String()} [INFO/Broker] $msg',
  );

  /// Read the broker pool (paginated START → KV → END). Null on a stall or
  /// error. The completion deadline is an INACTIVITY watchdog re-armed on every
  /// frame — a large pool streams field-by-field and outlasts any single fixed
  /// deadline, so only a genuine stall (no frame for [timeout]) fails (#103).
  /// The fetch lifecycle is logged to the shared file log (#108) so a tester's
  /// Share-logs capture shows in plain text where a pool load succeeds or fails.
  Future<List<BrokerConfig>?> getBrokers() {
    return _serialized(() async {
      final started = DateTime.now();
      final decoder = BrokerListDecoder();
      final completer = Completer<List<BrokerConfig>>();
      var frames = 0;
      int? expected;
      Timer? idle;
      void armIdle() {
        idle?.cancel();
        idle = Timer(timeout, () {
          if (!completer.isCompleted) {
            completer.completeError(
              TimeoutException('broker pool stalled', timeout),
            );
          }
        });
      }

      final sub = _connector.receivedFrames.listen((f) {
        if (f.isEmpty || f[0] != ObserverConfigClient.respConfig) return;
        armIdle(); // re-arm: a steadily-streaming dump must never time out.
        final r = ObserverConfigClient.parse(f);
        if (r is ConfigBrokersStart) {
          expected = r.count;
          _logBroker('pool GET: header — ${r.count} brokers');
        }
        frames++;
        final list = decoder.add(r);
        if (list != null && !completer.isCompleted) completer.complete(list);
      });
      try {
        await _connector.sendFrame(ObserverConfigClient.buildBrokers());
        _logBroker('pool GET: request sent');
        armIdle(); // initial deadline: if the device never replies at all.
        final list = await completer.future;
        _logBroker(
          'pool GET: COMPLETED ${list.length} brokers '
          '(header said ${expected ?? "?"}) in '
          '${DateTime.now().difference(started).inMilliseconds}ms, $frames frames',
        );
        return list;
      } catch (e) {
        _logBroker(
          'pool GET: FAILED after '
          '${DateTime.now().difference(started).inMilliseconds}ms '
          '($frames frames, header said ${expected ?? "?"}) — $e',
        );
        _setError('broker list failed: $e');
        return null;
      } finally {
        idle?.cancel();
        await sub.cancel();
      }
    });
  }

  // --- Full snapshot --------------------------------------------------------

  /// Read the whole observer config from the device into [config]. On any
  /// failure sets [stale] so the UI never presents a half-read snapshot as live.
  Future<void> refresh({bool includeBrokers = true}) async {
    try {
      final ssid = await getFlat('wifi.ssid');
      final wifiEnabled = await getFlat('wifi.enabled');
      final wifiStatus = await getFlat('wifi.status');
      final iata = await getFlat('mqtt.iata');
      final statusInterval = await getFlat('mqtt.status_interval');
      final alwaysOn = await getFlat('display.always_on');
      final rotation = await getFlat('display.rotation');
      // Skip the heavy broker dump (84 frames) when only flat settings changed
      // (e.g. after a flat Save) — it must not re-flood BLE for a toggle (#81).
      final brokers = includeBrokers ? await getBrokers() : null;
      final keptBrokers = _config?.brokers ?? const <BrokerConfig>[];

      // The broker pool loads independently of the flat settings: a broker-dump
      // failure (e.g. the firmware never sends BROKERS_END) must NOT blank
      // settings that read cleanly. Surface it as broker-only "unavailable".
      _config = ObserverConfig(
        wifi: _parseWifi(ssid, wifiEnabled, wifiStatus),
        mqtt: MqttGlobalConfig(
          iata: iata ?? '',
          statusInterval: int.tryParse(statusInterval ?? '') ?? 60,
        ),
        brokers: includeBrokers ? (brokers ?? const []) : keptBrokers,
        display: DisplayConfig(
          alwaysOn: alwaysOn == '1',
          rotation: int.tryParse(rotation ?? '') ?? 0,
        ),
      );
      if (includeBrokers) _brokersUnavailable = brokers == null;

      // A null from any flat getFlat is a failed read (GET returns the value,
      // null on ERR/timeout). Stale reflects the FLAT read only; a broker miss
      // is shown in its own section, not as a stale snapshot (SAFELANE §6).
      final allFlatRead =
          ssid != null &&
          wifiEnabled != null &&
          wifiStatus != null &&
          iata != null &&
          statusInterval != null &&
          alwaysOn != null &&
          rotation != null;
      _stale = !allFlatRead;
      if (allFlatRead) _lastError = null;
      notifyListeners();
    } catch (e) {
      _stale = true;
      _setError('refresh failed: $e');
    }
  }

  WifiConfig _parseWifi(String? ssid, String? enabled, String? statusRaw) {
    var status = WifiStatus.unknown;
    String? ip;
    if (statusRaw != null && statusRaw.isNotEmpty) {
      final parts = statusRaw.split(' ip=');
      status = WifiStatus.fromWire(parts.first.trim());
      if (parts.length > 1) ip = parts[1].trim();
    }
    return WifiConfig(
      ssid: (ssid == null || ssid == '(unset)') ? '' : ssid,
      enabled: enabled != '0',
      status: status,
      ip: ip,
    );
  }
}

/// Outcome of [ObserverConfigService.saveBroker]. On failure [failedField] names
/// the field whose SET failed (or `enabled`); the slot is left disabled, safe.
class BrokerSaveResult {
  const BrokerSaveResult.ok() : ok = true, failedField = null;
  const BrokerSaveResult.failed(this.failedField) : ok = false;
  final bool ok;
  final String? failedField;
}
