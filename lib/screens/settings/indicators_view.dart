import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../connector/meshcore_connector.dart';
import '../../connector/offband_device_ui.dart';
import '../../connector/offband_indicators.dart';
import '../../widgets/device_ui_error_banner.dart';

/// The radio's display and LED (#523, #944): display mode, rotation and the
/// status LED. Each block shows only when the radio has that control
/// ([MeshCoreConnector.supportsDisplayControl],
/// [MeshCoreConnector.supportsLedControl], #1132); the Node Settings row that
/// leads here shows when it has either.
///
/// Every control draws from what the radio reported, never from the tap.
/// English-only, matching [DeviceUiView].
class IndicatorsView extends StatelessWidget {
  const IndicatorsView({super.key});

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    final error = connector.deviceUiError;
    final errorSurface = connector.deviceUiErrorSurface;
    final mode = connector.displayMode;
    final led = connector.ledEnabled;
    return ListView(
      children: [
        if (error != null &&
            (errorSurface == DeviceUiSurface.display ||
                errorSurface == DeviceUiSurface.led ||
                errorSurface == DeviceUiSurface.rotation))
          DeviceUiErrorBanner(
            message: error,
            onDismiss: connector.clearDeviceUiError,
          ),
        if (connector.supportsDisplayControl) ...[
          const _Header('Display'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<DisplayMode>(
              segments: [
                for (final m in DisplayMode.values)
                  ButtonSegment(value: m, label: Text(m.label)),
              ],
              selected: {?mode},
              emptySelectionAllowed: true,
              onSelectionChanged: (v) {
                if (v.isNotEmpty) connector.setDisplayMode(v.first);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              mode?.description ??
                  'The radio has not reported its display mode',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
        if (connector.supportsDisplayRotation) ...[
          const _Header('Rotation'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Normal')),
                ButtonSegment(value: 180, label: Text('Flipped')),
              ],
              // Null until the radio answers the rotation GET, and the
              // capability tag arrives BEFORE that reply, so on any slow link
              // this builds with no value at all. Empty selection, never a
              // force unwrap, matching the display-mode control above.
              selected: {?connector.displayRotation},
              emptySelectionAllowed: true,
              onSelectionChanged: (v) {
                if (v.isNotEmpty) connector.setDisplayRotation(v.first);
              },
            ),
          ),
        ],
        if (connector.supportsLedControl) ...[
          const _Header('LED'),
          SwitchListTile(
            title: const Text('Status LED'),
            subtitle: Text(
              led == null
                  ? 'The radio has not reported its LED'
                  : 'Turn off to save battery or to stay unseen',
            ),
            value: led ?? false,
            onChanged: connector.setLedEnabled,
          ),
        ],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}
