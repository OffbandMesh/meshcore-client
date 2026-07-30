import 'package:flutter/material.dart';

import '../../helpers/config_profile_diff.dart';
import '../../helpers/config_profile_writes.dart';
import '../../models/config_profile.dart';
import '../../services/observer_apply_service.dart';
import '../../services/observer_config_service.dart';

/// Full sub-screen preview of a config-profile apply (#406): shows the current
/// -> new diff, then a two-tier confirm, a normal Apply for plain config, and a
/// separate red gate for credential/identity changes.
class ConfigProfilePreviewScreen extends StatefulWidget {
  const ConfigProfilePreviewScreen({
    super.key,
    required this.profile,
    required this.service,
  });

  final ConfigProfile profile;
  final ObserverConfigService service;

  @override
  State<ConfigProfilePreviewScreen> createState() =>
      _ConfigProfilePreviewScreenState();
}

class _ConfigProfilePreviewScreenState
    extends State<ConfigProfilePreviewScreen> {
  late ProfileWrites _writes;
  ProfileDiff? _diff;
  String? _error;
  bool _loading = true;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _writes = enumerateProfileWrites(widget.profile);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final currentFlat = <String, String?>{};
      for (final f in _writes.flats) {
        currentFlat[f.key] = await widget.service.getFlat(f.key);
      }
      final currentBroker = <int, Map<String, String?>>{};
      for (final b in _writes.brokers) {
        final m = <String, String?>{};
        for (final key in [...b.fields.keys, ConfigKeys.brokerEnabled]) {
          m[key] = await widget.service.getFlat(ConfigKeys.broker(b.slot, key));
        }
        currentBroker[b.slot] = m;
      }
      final diff = buildProfileDiff(
        _writes,
        currentFlat: currentFlat,
        currentBroker: currentBroker,
      );
      if (mounted) setState(() => _diff = diff);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not read current config: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _apply(ProfileWrites writes, String what) async {
    setState(() => _applying = true);
    try {
      final result = await ObserverApplyService(widget.service).apply(writes);
      if (!mounted) return;
      final msg = result.allOk
          ? '$what applied.'
          : '$what: ${result.failures.length} of ${result.items.length} failed '
                '(${result.failures.first.error ?? 'error'}).';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: result.allOk
              ? null
              : Theme.of(context).colorScheme.error,
        ),
      );
      await _load(); // re-diff against true state (partial-save recovery)
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final diff = _diff;
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('Review config profile'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _ErrorView(message: _error!, onRetry: _load)
          : diff == null
          ? const SizedBox.shrink()
          : _buildBody(context, diff),
    );
  }

  Widget _buildBody(BuildContext context, ProfileDiff diff) {
    if (diff.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No changes: the device already matches this profile.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final split = splitProfileWrites(_writes);

    return Column(
      children: [
        if (widget.profile.name != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.profile.name!,
                style: theme.textTheme.titleMedium,
              ),
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final r in diff.safeRows) _DiffTile(row: r),
              if (diff.hasDanger) ...[
                const SizedBox(height: 16),
                _DangerHeader(count: diff.dangerRows.length),
                for (final r in diff.dangerRows)
                  _DiffTile(row: r, danger: true),
              ],
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                FilledButton(
                  onPressed: _applying || diff.safeRows.isEmpty
                      ? null
                      : () => _apply(split.safe, 'Config changes'),
                  child: Text(
                    diff.safeRows.isEmpty
                        ? 'No plain-config changes'
                        : 'Apply ${diff.safeRows.length} config change'
                              '${diff.safeRows.length == 1 ? '' : 's'}',
                  ),
                ),
                if (diff.hasDanger) ...[
                  const SizedBox(height: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.error,
                      foregroundColor: theme.colorScheme.onError,
                    ),
                    onPressed: _applying
                        ? null
                        : () => _confirmDanger(context, split.danger, diff),
                    child: Text(
                      'Danger: change ${diff.dangerRows.length} '
                      'credential/identity value'
                      '${diff.dangerRows.length == 1 ? '' : 's'}',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmDanger(
    BuildContext context,
    ProfileWrites dangerWrites,
    ProfileDiff diff,
  ) async {
    final theme = Theme.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change credential / identity values?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'These bind this device to an identity or credentials. Only proceed '
              'if you trust this profile:',
            ),
            const SizedBox(height: 12),
            for (final r in diff.dangerRows)
              Text('• ${r.label}', style: theme.textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Change them'),
          ),
        ],
      ),
    );
    // Guard the async gap: the screen may have been disposed while the dialog
    // was open; _apply's setState would then throw (Gemini review).
    if (ok == true && mounted) await _apply(dangerWrites, 'Credential changes');
  }
}

class _DiffTile extends StatelessWidget {
  const _DiffTile({required this.row, this.danger = false});
  final DiffRow row;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isChange = row.kind == DiffKind.change;
    final newText = row.secret ? '••••••' : row.newValue;
    final oldText = row.secret
        ? '—'
        : (row.oldValue == null || row.oldValue!.isEmpty ? '—' : row.oldValue!);
    final accent = danger
        ? theme.colorScheme.error
        : isChange
        ? Colors.amber.shade800
        : theme.colorScheme.primary;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          isChange ? Icons.edit_outlined : Icons.add_circle_outline,
          color: accent,
        ),
        title: Text(row.label, style: theme.textTheme.bodyMedium),
        subtitle: Text(
          isChange ? '$oldText  →  $newText' : 'set to $newText',
          style: theme.textTheme.bodySmall,
        ),
      ),
    );
  }
}

class _DangerHeader extends StatelessWidget {
  const _DangerHeader({required this.count});
  final int count;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Credential / identity changes ($count), require the red button',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
