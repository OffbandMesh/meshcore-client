import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../connector/meshcore_connector.dart';
import '../../connector/offband_device_ui.dart';
import '../../connector/offband_screen_settings.dart';
import '../../models/badge_time_zones.dart';
import '../../widgets/device_ui_error_banner.dart';

/// The badge's own screen settings (#987): its Nav text, Message text, Screen
/// off and Time zone rows, with the same choices and no others. Gated on caps
/// byte 2 `0x40`; the Node Settings row that leads here is gated the same way.
///
/// Every control draws from the radio's re-read reply, never from the tap.
/// English-only, matching [DeviceUiView].
class BadgeScreenView extends StatefulWidget {
  const BadgeScreenView({super.key});

  @override
  State<BadgeScreenView> createState() => _BadgeScreenViewState();
}

class _BadgeScreenViewState extends State<BadgeScreenView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<MeshCoreConnector>().requestScreenSettings();
    });
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    final s = connector.screenSettings;
    final error = connector.deviceUiError;
    return ListView(
      children: [
        if (error != null &&
            connector.deviceUiErrorSurface == DeviceUiSurface.screenSettings)
          DeviceUiErrorBanner(
            message: error,
            onDismiss: connector.clearDeviceUiError,
          ),
        if (s == null)
          const ListTile(
            leading: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            title: Text('Reading screen settings from the radio'),
          )
        else ...[
          const _Header('Text size'),
          // The badge's Nav text and Message text, named for what they govern
          // (owner decision 2026-10-25).
          _TextSizeRow(
            label: 'Menus and lists',
            value: s.navText,
            onChanged: (v) =>
                connector.setTextSize(BadgeTextTarget.navigation, v),
          ),
          _TextSizeRow(
            label: 'Messages',
            value: s.messageText,
            onChanged: (v) =>
                connector.setTextSize(BadgeTextTarget.messages, v),
          ),
          const _Header('Screen off'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'How long the screen stays on after the last key press.',
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<int>(
              segments: [
                for (final secs in screenOffSteps)
                  ButtonSegment(value: secs, label: Text(screenOffLabel(secs))),
              ],
              selected: {
                if (screenOffSteps.contains(s.screenOffStored))
                  s.screenOffStored,
              },
              emptySelectionAllowed: true,
              onSelectionChanged: (v) {
                if (v.isNotEmpty) connector.setScreenOff(v.first);
              },
            ),
          ),
          if (!screenOffSteps.contains(s.screenOffStored))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                s.screenOffIsDefault
                    ? 'Board default: ${screenOffLabel(s.screenOffSeconds)}'
                    : 'Set to ${screenOffLabel(s.screenOffStored)} elsewhere',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const _Header('Time zone'),
          ListTile(
            leading: const Icon(Icons.public),
            title: Text(timeZoneName(s.timeZone)),
            subtitle: Text(_zoneSubtitle(s.timeZone)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TimeZonePickerScreen(current: s.timeZone),
              ),
            ),
          ),
        ],
      ],
    );
  }

  String _zoneSubtitle(int index) {
    final offset = timeZoneOffsetMinutes(index, DateTime.now().toUtc());
    if (offset == null) {
      return index == timeZoneNotSet
          ? 'Messages show their age'
          : 'A zone this app does not know';
    }
    return '${formatUtcOffset(offset)} now. Message times show as clock times.';
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _TextSizeRow extends StatelessWidget {
  const _TextSizeRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final BadgeTextSize? value;
  final ValueChanged<BadgeTextSize> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<BadgeTextSize>(
              segments: [
                for (final size in BadgeTextSize.values)
                  ButtonSegment(value: size, label: Text(size.label)),
              ],
              selected: {?value},
              emptySelectionAllowed: true,
              onSelectionChanged: (v) {
                if (v.isNotEmpty) onChanged(v.first);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The badge's zone list, with "not set" and a suggestion from the phone's
/// own zone, as the badge suggests one from GPS.
class TimeZonePickerScreen extends StatefulWidget {
  const TimeZonePickerScreen({super.key, required this.current});

  final int current;

  @override
  State<TimeZonePickerScreen> createState() => _TimeZonePickerScreenState();
}

class _TimeZonePickerScreenState extends State<TimeZonePickerScreen> {
  String _query = '';

  void _choose(int index) {
    context.read<MeshCoreConnector>().setTimeZone(index);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final suggested = suggestTimeZone(
      now: now,
      offsetAt: (local) => local.timeZoneOffset,
    );
    final q = _query.trim().toLowerCase();
    bool shown(int i) => q.isEmpty || timeZoneName(i).toLowerCase().contains(q);
    final scheme = Theme.of(context).colorScheme;

    Widget zoneTile(int i, {bool suggestion = false}) {
      final offset = timeZoneOffsetMinutes(i, now.toUtc());
      final selected = !suggestion && i == widget.current;
      return ListTile(
        leading: suggestion
            ? const Icon(Icons.smartphone)
            : Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: selected ? scheme.primary : null,
              ),
        title: Text(timeZoneName(i)),
        subtitle: suggestion
            ? const Text('Matches this phone')
            : selected
            ? const Text('Current')
            : i == timeZoneNotSet
            ? const Text('Messages show their age')
            : null,
        trailing: offset == null ? null : Text(formatUtcOffset(offset)),
        selected: selected,
        onTap: () => _choose(i),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Time zone'), centerTitle: true),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SearchBar(
              hintText: 'Search zones',
              leading: const Icon(Icons.search),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          if (suggested != null && shown(suggested)) ...[
            zoneTile(suggested, suggestion: true),
            const Divider(height: 1),
          ],
          for (var i = 0; i < badgeTimeZones.length; i++)
            if (shown(i)) zoneTile(i),
        ],
      ),
    );
  }
}
