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
/// file. Support is probed on open (STATUS query); a device whose firmware
/// doesn't answer is shown as unsupported.
///
/// Strings are English-only for now; localization is a follow-up, mirroring the
/// LogExport helper (#427).
class SerialCaptureScreen extends StatefulWidget {
  const SerialCaptureScreen({super.key});

  @override
  State<SerialCaptureScreen> createState() => _SerialCaptureScreenState();
}

class _SerialCaptureScreenState extends State<SerialCaptureScreen> {
  /// Capture-window options in minutes; 0 means "until I stop".
  static const List<int> _durations = [1, 5, 15, 30, 0];

  bool? _supported; // null while probing
  CaplogDeviceStatus? _status;
  int _durationMinutes = 5;
  bool _busy = false;
  String? _error;

  DateTime? _startedAt;
  Timer? _tick; // 1s UI tick while capturing
  Timer? _autoStop; // fires at the chosen window
  Timer? _statusPoll; // refresh buffer usage while capturing

  MeshCoreConnector get _connector => context.read<MeshCoreConnector>();

  @override
  void initState() {
    super.initState();
    _probe();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _autoStop?.cancel();
    _statusPoll?.cancel();
    super.dispose();
  }

  Future<void> _probe() async {
    try {
      final status = await _connector.getDeviceCaplogStatus();
      if (!mounted) return;
      setState(() {
        _supported = true;
        _status = status;
        _startedAt = status.enabled ? DateTime.now() : null;
      });
      if (status.enabled) _startTimers();
    } catch (_) {
      if (mounted) setState(() => _supported = false);
    }
  }

  Future<void> _refreshStatus() async {
    try {
      final status = await _connector.getDeviceCaplogStatus();
      if (mounted) setState(() => _status = status);
    } catch (_) {
      // Transient during capture; ignore and let the next poll retry.
    }
  }

  void _startTimers() {
    _tick?.cancel();
    _autoStop?.cancel();
    _statusPoll?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _statusPoll = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refreshStatus(),
    );
    if (_durationMinutes > 0) {
      _autoStop = Timer(Duration(minutes: _durationMinutes), _stop);
    }
  }

  void _stopTimers() {
    _tick?.cancel();
    _autoStop?.cancel();
    _statusPoll?.cancel();
    _tick = _autoStop = _statusPoll = null;
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await _connector.setDeviceCaplogEnabled(true);
      if (!ok) throw Exception('device rejected enable');
      if (!mounted) return;
      setState(() => _startedAt = DateTime.now());
      _startTimers();
      await _refreshStatus();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start capture: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    if (!mounted) return;
    _stopTimers();
    setState(() => _busy = true);
    try {
      await _connector.setDeviceCaplogEnabled(false);
      if (mounted) setState(() => _startedAt = null);
      await _refreshStatus();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not stop capture: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await _connector.downloadCaplog();
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
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _connector.eraseDeviceCaplog();
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
    if (_startedAt == null || _durationMinutes == 0) return '';
    final total = _durationMinutes * 60;
    final left = (total - DateTime.now().difference(_startedAt!).inSeconds)
        .clamp(0, total);
    return '${_pad2(left ~/ 60)}:${_pad2(left % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Serial capture'), centerTitle: true),
      body: _body(),
    );
  }

  Widget _body() {
    if (_supported == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Checking device support…'),
          ],
        ),
      );
    }
    if (_supported == false) {
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

    final capturing = _startedAt != null;
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
                      '${_durationMinutes > 0 ? '  ·  auto-stops in ${_remaining()}' : ''}',
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
          onPressed: _busy ? null : (capturing ? _stop : _start),
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
      ],
    );
  }
}
