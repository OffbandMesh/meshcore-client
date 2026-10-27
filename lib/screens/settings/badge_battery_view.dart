import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../connector/meshcore_connector.dart';
import '../../connector/offband_device_ui.dart';
import '../../connector/offband_screen_settings.dart';
import '../../widgets/device_ui_error_banner.dart';

/// Where the badge's battery bar puts 100%, and how it got there (#987):
/// the badge's own Battery screen, with its two actions. Gated on caps byte 2
/// `0x40`. English-only, matching [DeviceUiView].
class BadgeBatteryView extends StatefulWidget {
  const BadgeBatteryView({super.key});

  @override
  State<BadgeBatteryView> createState() => _BadgeBatteryViewState();
}

/// Where the full point came from, in the badge's terms (default, learned,
/// set). Shared with the Node Settings row.
String batteryFullSource(ScreenSettingsState s) => s.batteryFullStored == 0
    ? 'Default for this board'
    : s.batteryPinned
    ? 'Set by hand'
    : 'Learned after a full charge';

class _BadgeBatteryViewState extends State<BadgeBatteryView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<MeshCoreConnector>().requestScreenSettings();
    });
  }

  Future<void> _pin(MeshCoreConnector connector) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Set 100% here?'),
        content: const Text(
          'Only do this with the radio fully charged. The radio uses its '
          'current reading as full, and stops learning it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Set 100% here'),
          ),
        ],
      ),
    );
    if (confirmed == true) await connector.setBatteryFull(pin: true);
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    final s = connector.screenSettings;
    final error = connector.deviceUiError;
    final textTheme = Theme.of(context).textTheme;
    final mv = connector.batteryMillivolts;
    final pct = connector.batteryPercent;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (error != null &&
            connector.deviceUiErrorSurface == DeviceUiSurface.screenSettings)
          DeviceUiErrorBanner(
            message: error,
            onDismiss: connector.clearDeviceUiError,
            margin: const EdgeInsets.only(bottom: 12),
          ),
        if (pct != null) Text('$pct%', style: textTheme.headlineMedium),
        if (mv != null) Text('Reading $mv mV'),
        const SizedBox(height: 12),
        if (s == null)
          const ListTile(
            leading: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            title: Text('Reading battery settings from the radio'),
          )
        else ...[
          Card(
            child: ListTile(
              leading: const Icon(Icons.battery_std),
              title: Text('100% at ${s.batteryFullMv} mV'),
              subtitle: Text(batteryFullSource(s)),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'The radio learns where full is after a complete charge. Set it by '
            'hand only if the bar never reaches 100% when charged.',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => _pin(connector),
                icon: const Icon(Icons.bolt),
                label: const Text('Set 100% here'),
              ),
              // Only when there is something to hand back, as on the badge.
              if (s.batteryFullStored != 0)
                TextButton(
                  onPressed: () => connector.setBatteryFull(pin: false),
                  child: const Text('Back to auto'),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
