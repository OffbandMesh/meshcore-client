import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../connector/caplog_reassembler.dart';
import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../utils/log_export.dart';

/// Serial-capture diagnostics screen (#430).
///
/// Controls the connected radio's serial-capture buffer over the 0xC4 companion
/// command (enable / disable / erase / status) and downloads it as a shareable
/// file. Support is gated on the device-info **capability bit** (`0x20` +
/// `FIRMWARE_VER_CODE >= 17`), which is static and refreshes on reconnect, so
/// the feature never latches "unsupported" after a reboot. Capture state is
/// derived from the device STATUS, so an auto-resumed capture (post-reboot)
/// shows STOP, not START.
///
/// Strings are English-only for now; localization is a follow-up (#427).
class SerialCaptureScreen extends StatefulWidget {
  const SerialCaptureScreen({super.key});

  @override
  State<SerialCaptureScreen> createState() => _SerialCaptureScreenState();
}

class _SerialCaptureScreenState extends State<SerialCaptureScreen> {
  /// Capture-window options in minutes for the timed flow; 0 = until stopped.
  static const List<int> _durations = [1, 5, 15, 30, 0];

  MeshCoreConnector? _connector;
  CaplogDeviceStatus? _status;
  int _durationMinutes = 5;
  bool _busy = false;
  String? _error;
  bool _wasConnected = false;

  DateTime? _startedAt;
  int? _timedWindowMinutes; // set while a timed capture is running (for the UI)
  Timer? _tick;
  Timer? _autoStop;
  Timer? _statusPoll;

  @override
  void initState() {
    super.initState();
    final c = context.read<MeshCoreConnector>();
    _connector = c;
    c.addListener(_onConnectorChanged);
    _wasConnected = c.isConnected;
    if (c.isConnected && c.supportsOffbandCaplog) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refreshStatus());
    }
  }

  @override
  void dispose() {
    _connector?.removeListener(_onConnectorChanged);
    _stopTimers();
    super.dispose();
  }

  /// React to connection transitions: on reconnect re-derive device state (no
  /// latch); on disconnect stop polling a dead link.
  void _onConnectorChanged() {
    final c = _connector;
    if (c == null || !mounted) return;
    final connected = c.isConnected;
    if (connected && !_wasConnected) {
      _wasConnected = true;
      if (c.supportsOffbandCaplog) _refreshStatus();
    } else if (!connected && _wasConnected) {
      _wasConnected = false;
      _stopTimers();
      setState(() {});
    }
  }

  Future<void> _refreshStatus() async {
    final c = _connector;
    if (c == null || !c.isConnected) return;
    try {
      final status = await c.getDeviceCaplogStatus();
      if (!mounted) return;
      setState(() => _status = status);
      // Keep local timers/elapsed in sync with the device's actual state, so an
      // auto-resumed capture after a reboot is reflected as running.
      if (status.enabled) {
        _startedAt ??= DateTime.now();
        _startTickers();
      } else {
        _startedAt = null;
        _timedWindowMinutes = null;
        _stopTimers();
      }
    } catch (_) {
      // Transient (e.g. mid-reconnect); keep last-known state and retry on the
      // next poll / reconnect rather than latching.
    }
  }

  void _startTickers() {
    _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _statusPoll ??= Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refreshStatus(),
    );
  }

  void _stopTimers() {
    _tick?.cancel();
    _autoStop?.cancel();
    _statusPoll?.cancel();
    _tick = _autoStop = _statusPoll = null;
  }

  Future<bool> _setEnabled(bool enabled) async {
    final c = _connector;
    if (c == null) return false;
    final ok = await c.setDeviceCaplogEnabled(enabled);
    if (!ok) {
      throw Exception('device rejected ${enabled ? 'enable' : 'disable'}');
    }
    return ok;
  }

  Future<void> _startTimed() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _setEnabled(true);
      if (!mounted) return;
      _startedAt = DateTime.now();
      _timedWindowMinutes = _durationMinutes > 0 ? _durationMinutes : null;
      _startTickers();
      if (_durationMinutes > 0) {
        _autoStop?.cancel();
        _autoStop = Timer(Duration(minutes: _durationMinutes), _stop);
      }
      await _refreshStatus();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start capture: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await _setEnabled(false);
      if (mounted) {
        _startedAt = null;
        _timedWindowMinutes = null;
      }
      _stopTimers();
      await _refreshStatus();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not stop capture: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Boot-log flow (#428): enable capture with no timer, then reboot so the
  /// radio records the boot sequence from power-on. The connection drops during
  /// reboot; on reconnect `_onConnectorChanged` re-derives STATUS and (once
  /// firmware #428 persists the flag) the capture shows as running → Stop here.
  Future<void> _startAndReboot() async {
    final c = _connector;
    if (c == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start capture & reboot?'),
        content: const Text(
          'Enables serial capture, then reboots the radio so the boot log is '
          'captured from power-on. There is no timer — capture runs until you '
          'Stop it. The connection drops during the reboot; when it reconnects, '
          'capture is still running and you can Stop and download here.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red[700]),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Start & Reboot'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _setEnabled(true); // no timer: runs until Stop
      _startedAt = DateTime.now();
      _timedWindowMinutes = null;
      await c.rebootDevice();
      // Connection drops now; reconnect handling re-derives STATUS.
    } catch (e) {
      if (mounted) setState(() => _error = 'Start & reboot failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download() async {
    final c = _connector;
    if (c == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await c.downloadCaplog();
      final dir = await getTemporaryDirectory();
      final ts = DateTime.now();
      final name =
          'serial-capture-'
          '${ts.year}${_pad2(ts.month)}${_pad2(ts.day)}-'
          '${_pad2(ts.hour)}${_pad2(ts.minute)}${_pad2(ts.second)}.txt';
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      await LogExport.shareFile(
        context,
        file,
        subject: 'Offband serial capture',
      );
    } on CaplogBusyException {
      if (mounted) {
        setState(
          () => _error = 'Device busy (another transfer in progress). Retry.',
        );
      }
    } on CaplogTruncatedException catch (e) {
      if (mounted) setState(() => _error = 'Capture truncated: $e');
    } on TimeoutException {
      if (mounted) setState(() => _error = 'No response from device.');
    } catch (e) {
      if (mounted) setState(() => _error = 'Download failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _erase() async {
    final c = _connector;
    if (c == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await c.eraseDeviceCaplog();
      await _refreshStatus();
    } catch (e) {
      if (mounted) setState(() => _error = 'Erase failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _pad2(int n) => n.toString().padLeft(2, '0');

  String _elapsed() {
    final s = _startedAt == null
        ? 0
        : DateTime.now().difference(_startedAt!).inSeconds;
    return '${_pad2(s ~/ 60)}:${_pad2(s % 60)}';
  }

  String _remaining() {
    final window = _timedWindowMinutes;
    if (_startedAt == null || window == null) return '';
    final total = window * 60;
    final left = (total - DateTime.now().difference(_startedAt!).inSeconds)
        .clamp(0, total);
    return '${_pad2(left ~/ 60)}:${_pad2(left % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    return Scaffold(
      appBar: AppBar(title: const Text('Serial capture'), centerTitle: true),
      body: _body(connector),
    );
  }

  Widget _body(MeshCoreConnector connector) {
    if (!connector.isConnected) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: Text(
            'Connect to a device to use serial capture.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (!connector.supportsOffbandCaplog) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: Text(
            "This device's firmware doesn't support serial capture.",
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final capturing = _status?.enabled ?? (_startedAt != null);
    final timed = _timedWindowMinutes != null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_error != null)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.error_outline),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_error!)),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _error = null),
                  ),
                ],
              ),
            ),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  capturing ? 'Capturing…' : 'Idle',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (capturing)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Elapsed ${_elapsed()}'
                      '${timed ? '  ·  auto-stops in ${_remaining()}' : ''}',
                    ),
                  ),
                if (_status != null) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: _status!.capacityBytes > 0
                        ? (_status!.usedBytes / _status!.capacityBytes).clamp(
                            0.0,
                            1.0,
                          )
                        : null,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Buffer ${_status!.usedBytes} / ${_status!.capacityBytes} bytes',
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Text('Capture duration'),
            const Spacer(),
            DropdownButton<int>(
              value: _durationMinutes,
              onChanged: capturing
                  ? null
                  : (v) {
                      if (v != null) setState(() => _durationMinutes = v);
                    },
              items: _durations
                  .map(
                    (m) => DropdownMenuItem(
                      value: m,
                      child: Text(m == 0 ? 'Until I stop' : '$m min'),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : (capturing ? _stop : _startTimed),
          icon: Icon(capturing ? Icons.stop : Icons.fiber_manual_record),
          label: Text(capturing ? 'Stop capture' : 'Start capture'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _busy || capturing ? null : _download,
          icon: Icon(LogExport.icon),
          label: const Text('Download & share'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _busy || capturing ? null : _erase,
          icon: const Icon(Icons.delete_outline),
          label: const Text('Erase buffer'),
        ),
        const Divider(height: 24),
        // Boot-log flow (#428): enable capture (no timer) + reboot, styled as a
        // dangerous action (it reboots the radio and drops the connection).
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.red[700],
            foregroundColor: Colors.white,
          ),
          onPressed: _busy || capturing ? null : _startAndReboot,
          icon: const Icon(Icons.restart_alt),
          label: const Text('Start & Reboot (capture boot log)'),
        ),
      ],
    );
  }
}
