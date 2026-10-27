import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../connector/meshcore_connector.dart';
import '../../connector/offband_device_ui.dart';
import '../../helpers/snack_bar_builder.dart';
import '../../l10n/l10n.dart';
import '../../models/offband_gps_status.dart';
import '../../utils/app_logger.dart';

/// Embeddable view (no Scaffold) for the Location settings pane (#977).
///
/// The single home for GPS: the GPS control and its status, the node's
/// coordinates, and the position reporting interval. These used to sit in Node
/// Settings and a Location dialog, with the GPS toggle in both. The radio sees
/// the same writes as before: the same custom vars, the same validation, the
/// same error messages.
///
/// One deliberate difference: coordinates and the reporting interval now save
/// independently. In the old dialog an empty or invalid interval returned early
/// and silently skipped the coordinates as well.
///
/// On a radio that advertises caps byte 2 `0x20` (#969) the GPS card is one
/// Off / On / Power save control with one status row, per the approved mockups
/// in `docs/initiatives/standalone/975-settings-restructure/`. Everything shown
/// there is the device's reply, never the request. Other radios keep the plain
/// on/off toggle above, unchanged.
class LocationView extends StatefulWidget {
  const LocationView({super.key});

  @override
  State<LocationView> createState() => _LocationViewState();
}

class _LocationViewState extends State<LocationView> {
  OffbandGpsStatus? _gpsStatus;
  bool _queryingGps = false;
  bool _queriedOnce = false;

  /// Activity and the wait to the next attempt change on their own, so while
  /// this pane is open the GPS state is re-read on a slow cadence. One 2-byte
  /// request every 30 s, and only while visible.
  Timer? _gpsRefresh;
  static const _gpsRefreshEvery = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshGpsMode(context.read<MeshCoreConnector>());
    });
    _gpsRefresh = Timer.periodic(_gpsRefreshEvery, (_) {
      if (mounted) _refreshGpsMode(context.read<MeshCoreConnector>());
    });
  }

  @override
  void dispose() {
    _gpsRefresh?.cancel();
    super.dispose();
  }

  /// Re-read GPS mode, and the 0xC1 fix details that give the last-fix line.
  ///
  /// Unawaited on purpose (a timer and a button call it), so a send that fails
  /// because the link dropped mid-refresh is logged rather than escaping.
  void _refreshGpsMode(MeshCoreConnector connector) {
    if (!connector.supportsGpsMode) return;
    connector.requestGpsMode().catchError((Object e) {
      appLogger.warn('GPS mode refresh failed: $e', tag: 'Location');
    });
    if (connector.supportsOffbandGps) {
      connector
          .requestOffbandGps()
          .then((s) {
            if (mounted && s != null) setState(() => _gpsStatus = s);
          })
          .catchError((Object e) {
            appLogger.warn('GPS fix refresh failed: $e', tag: 'Location');
          });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connector = context.watch<MeshCoreConnector>();
    final customVars = connector.currentCustomVars ?? const <String, String>{};
    // A radio with no GPS hardware reports no `gps` custom var at all, which is
    // how the old screens decided to hide the GPS controls too.
    final hasGps = customVars.containsKey('gps');

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (connector.supportsGpsMode) ...[
          _gpsModeCard(connector),
          const SizedBox(height: 16),
        ] else if (hasGps) ...[
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.gps_fixed),
                  title: Text(l10n.settings_locationGPSEnable),
                  subtitle: Text(l10n.settings_locationGPSEnableSubtitle),
                  value: customVars['gps'] == '1',
                  onChanged: (value) => _setGpsEnabled(connector, value),
                ),
                if (connector.supportsOffbandGps)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: _buildGpsQuerySection(
                      context,
                      _gpsStatus ?? connector.offbandGpsStatus,
                      () => _queryGps(connector),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.location_on_outlined),
                title: Text(l10n.settings_locationCoordinates),
                subtitle: Text(_coordinatesText(connector)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _editCoordinates(connector),
              ),
              if (hasGps) ...[
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.schedule),
                  title: Text(l10n.settings_locationReportInterval),
                  subtitle: Text(_intervalText(customVars)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _editReportInterval(connector, customVars),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// #969: one control for whether AND how GPS runs, the way the badge's own
  /// screen writes it, then one status row, then the Power-save sleep.
  Widget _gpsModeCard(MeshCoreConnector connector) {
    final l10n = context.l10n;
    final state = connector.gpsModeState;
    final error = connector.deviceUiErrorSurface == DeviceUiSurface.gpsMode
        ? connector.deviceUiError
        : null;

    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Text(
          l10n.settings_gpsModeLabel,
          style: Theme.of(context).textTheme.labelLarge,
        ),
      ),
    ];

    if (state == null) {
      children.add(
        ListTile(
          leading: const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text(l10n.settings_gpsReading),
        ),
      );
    } else {
      children.addAll([
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<GpsMode>(
              segments: [
                ButtonSegment(
                  value: GpsMode.off,
                  label: Text(l10n.settings_gpsModeOff),
                ),
                ButtonSegment(
                  value: GpsMode.on,
                  label: Text(l10n.settings_gpsModeOn),
                ),
                // Offered only where this build can run it: a radio speaking
                // the GPS sub-codes without the duty cycle says so in ps_ok.
                if (state.powerSaveAvailable)
                  ButtonSegment(
                    value: GpsMode.powerSave,
                    label: Text(l10n.settings_gpsModePowerSave),
                  ),
              ],
              selected: {state.mode},
              onSelectionChanged: (picked) =>
                  connector.setGpsMode(picked.first),
            ),
          ),
        ),
        const Divider(height: 1),
        _gpsStatusTile(connector, state),
        if (state.mode == GpsMode.powerSave) ...[
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.hourglass_empty),
            title: Text(l10n.settings_gpsSleepTitle),
            subtitle: Text(
              state.intervalSeconds == 0
                  ? l10n.settings_gpsSleepDefault
                  : _durationText(state.intervalSeconds),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _editSleepInterval(connector, state),
          ),
        ],
      ]);
    }

    if (error != null) {
      // Held until dismissed: a refusal the user cannot finish reading is not
      // surfaced at all (SAFELANE §6).
      children.addAll([
        const Divider(height: 1),
        ListTile(
          leading: Icon(
            Icons.error_outline,
            color: Theme.of(context).colorScheme.error,
          ),
          title: Text(error),
          trailing: IconButton(
            icon: const Icon(Icons.close),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: connector.clearDeviceUiError,
          ),
        ),
      ]);
    }

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  /// One row for what GPS is doing: activity, next attempt, and last fix, so
  /// nothing on the card is said twice.
  Widget _gpsStatusTile(MeshCoreConnector connector, GpsModeState state) {
    final l10n = context.l10n;
    final activity = state.activity;

    final (IconData icon, Color color, String title) = switch (activity) {
      GpsActivity.off => (
        Icons.gps_off,
        Colors.grey,
        l10n.settings_gpsActivityOff,
      ),
      GpsActivity.on => (
        Icons.gps_fixed,
        Colors.green,
        l10n.settings_gpsActivityOn,
      ),
      GpsActivity.searching => (
        Icons.gps_not_fixed,
        Colors.orange,
        l10n.settings_gpsActivitySearching,
      ),
      GpsActivity.sleeping => (
        Icons.bedtime_outlined,
        Colors.blueGrey,
        l10n.settings_gpsActivitySleeping,
      ),
      GpsActivity.backedOff => (
        Icons.pause_circle_outline,
        Colors.orange,
        l10n.settings_gpsActivityBackedOff,
      ),
      // A state newer firmware knows and this client does not: say what the
      // mode is rather than guess at what it is doing.
      null => switch (state.mode) {
        GpsMode.off => (
          Icons.gps_off,
          Colors.grey,
          l10n.settings_gpsActivityOff,
        ),
        GpsMode.on => (
          Icons.gps_fixed,
          Colors.green,
          l10n.settings_gpsActivityOn,
        ),
        GpsMode.powerSave => (
          Icons.gps_not_fixed,
          Colors.orange,
          l10n.settings_gpsModePowerSave,
        ),
      },
    };

    final details = <String>[];
    if (state.mode == GpsMode.off) {
      details.add(l10n.settings_gpsOffDetail);
    } else {
      if (state.waitSeconds > 0) {
        details.add(
          state.waitSeconds >= 60
              ? l10n.settings_gpsNextTryMinutes(
                  (state.waitSeconds / 60).round(),
                )
              : l10n.settings_gpsNextTrySeconds(state.waitSeconds),
        );
      }
      final fix = _gpsStatus ?? connector.offbandGpsStatus;
      final at = fix?.timestampUtc;
      if (at != null) {
        final ago = DateTime.now().toUtc().difference(at.toUtc()).inMinutes;
        details.add(l10n.settings_gpsLastFixMinutes(ago < 0 ? 0 : ago));
      }
      final sats = fix?.satellites;
      if (sats != null && sats > 0 && state.waitSeconds == 0) {
        details.add(l10n.settings_gpsSatellites(sats));
      }
    }

    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title),
      subtitle: details.isEmpty ? null : Text(details.join(', ')),
      trailing: TextButton(
        onPressed: () => _refreshGpsMode(connector),
        child: Text(l10n.settings_gpsQuery),
      ),
    );
  }

  String _durationText(int seconds) {
    final l10n = context.l10n;
    if (seconds % 60 == 0) {
      return l10n.settings_locationEveryMinutes(seconds ~/ 60);
    }
    return l10n.settings_locationEverySeconds(seconds);
  }

  /// The sleep interval. 0 is a legal value meaning the firmware default, so
  /// the reporting interval's 60-second floor must not be copied here. The
  /// radio raises 1 to 299 to 300, and the row shows what it stored.
  void _editSleepInterval(MeshCoreConnector connector, GpsModeState state) {
    final l10n = context.l10n;
    final controller = TextEditingController(
      text: state.intervalSeconds.toString(),
    );
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.settings_gpsSleepTitle),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: l10n.settings_gpsSleepFieldLabel,
            helperText: l10n.settings_gpsSleepFieldHint,
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
          ),
          keyboardType: const TextInputType.numberWithOptions(
            decimal: false,
            signed: false,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            onPressed: () {
              final text = controller.text.trim();
              final seconds = text.isEmpty ? 0 : int.tryParse(text);
              Navigator.pop(dialogContext);
              if (seconds == null || seconds < 0 || seconds > 0xFFFFFFFF) {
                // Held until tapped away: an error that vanishes on a timer
                // before it is read is not surfaced (SAFELANE §6).
                showDismissibleSnackBar(
                  context,
                  content: Text(l10n.settings_gpsSleepInvalid),
                  persist: true,
                );
                return;
              }
              connector.setGpsMode(state.mode, intervalSeconds: seconds);
            },
            child: Text(l10n.common_save),
          ),
        ],
      ),
    );
  }

  String _coordinatesText(MeshCoreConnector connector) {
    final lat = connector.selfLatitude;
    final lon = connector.selfLongitude;
    if (lat == null || lon == null) return context.l10n.settings_locationNotSet;
    return '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}';
  }

  String _intervalText(Map<String, String> customVars) {
    final l10n = context.l10n;
    final seconds = int.tryParse(customVars['gps_interval'] ?? '');
    if (seconds == null || seconds <= 0) return l10n.settings_locationNotSet;
    if (seconds % 60 == 0) {
      return l10n.settings_locationEveryMinutes(seconds ~/ 60);
    }
    return l10n.settings_locationEverySeconds(seconds);
  }

  Future<void> _setGpsEnabled(MeshCoreConnector connector, bool value) async {
    try {
      await connector.setCustomVar(value ? 'gps:1' : 'gps:0');
    } catch (_) {
      if (mounted) {
        showDismissibleSnackBar(
          context,
          content: const Text(
            'Could not update GPS setting. Please try again.',
          ),
        );
      }
    }
  }

  Future<void> _queryGps(MeshCoreConnector connector) async {
    setState(() => _queryingGps = true);
    final s = await connector.requestOffbandGps();
    if (!mounted) return;
    setState(() {
      _queryingGps = false;
      _queriedOnce = true;
      _gpsStatus = s;
    });
  }

  Widget _buildGpsQuerySection(
    BuildContext context,
    OffbandGpsStatus? status,
    VoidCallback onRefresh,
  ) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );

    final children = <Widget>[
      const Divider(),
      Row(
        children: [
          Expanded(
            child: Text(
              l10n.settings_gpsStatusTitle,
              style: theme.textTheme.titleSmall,
            ),
          ),
          if (_queryingGps)
            const Padding(
              padding: EdgeInsets.all(8),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: l10n.settings_gpsStatusRefresh,
              onPressed: onRefresh,
            ),
        ],
      ),
    ];

    if (status != null) {
      final live = status.hasLiveFix;
      final color = live ? Colors.green : Colors.orange;
      children.add(
        Row(
          children: [
            Icon(
              live ? Icons.gps_fixed : Icons.gps_off,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                live
                    ? l10n.settings_gpsStatusLiveFix
                    : l10n.settings_gpsStatusNoFix,
                style: TextStyle(color: color, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
      children.add(const SizedBox(height: 8));
      final coords = (status.latitude != null && status.longitude != null)
          ? '${status.latitude!.toStringAsFixed(6)}, '
                '${status.longitude!.toStringAsFixed(6)}'
          : '—';
      children.add(row(l10n.settings_gpsStatusCoords, coords));
      children.add(
        row(l10n.settings_gpsStatusSats, status.satellites?.toString() ?? '—'),
      );
      children.add(
        row(
          l10n.settings_gpsStatusAltitude,
          status.altitudeCm != null
              ? '${(status.altitudeCm! / 100).toStringAsFixed(1)} m'
              : '—',
        ),
      );
      final t = status.timestampUtc?.toLocal();
      final ml = MaterialLocalizations.of(context);
      final timeStr = t == null
          ? '—'
          : '${ml.formatCompactDate(t)} '
                '${ml.formatTimeOfDay(TimeOfDay.fromDateTime(t))}';
      children.add(row(l10n.settings_gpsStatusTime, timeStr));
    } else {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            _queriedOnce
                ? l10n.settings_gpsStatusNoResponse
                : l10n.settings_gpsStatusTapRefresh,
            style: theme.textTheme.bodySmall,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  void _editCoordinates(MeshCoreConnector connector) {
    final l10n = context.l10n;
    final latController = TextEditingController(
      text: connector.selfLatitude?.toStringAsFixed(6) ?? '',
    );
    final lonController = TextEditingController(
      text: connector.selfLongitude?.toStringAsFixed(6) ?? '',
    );

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.settings_locationCoordinates),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: latController,
              decoration: InputDecoration(
                labelText: l10n.settings_latitude,
                border: const OutlineInputBorder(),
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: lonController,
              decoration: InputDecoration(
                labelText: l10n.settings_longitude,
                border: const OutlineInputBorder(),
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              Navigator.pop(dialogContext);

              final latText = latController.text.trim();
              final lonText = lonController.text.trim();
              if (latText.isEmpty && lonText.isEmpty) return;

              final lat = latText.isNotEmpty
                  ? double.tryParse(latText)
                  : connector.selfLatitude;
              final lon = lonText.isNotEmpty
                  ? double.tryParse(lonText)
                  : connector.selfLongitude;
              if (lat == null || lon == null) {
                if (!mounted) return;
                showDismissibleSnackBar(
                  context,
                  content: Text(l10n.settings_locationBothRequired),
                );
                return;
              }
              if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
                if (!mounted) return;
                showDismissibleSnackBar(
                  context,
                  content: Text(l10n.settings_locationInvalid),
                );
                return;
              }

              try {
                await connector.setNodeLocation(lat: lat, lon: lon);
                await connector.refreshDeviceInfo();
              } catch (_) {
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Could not update location. Please try again.',
                    ),
                  ),
                );
                return;
              }
              if (!mounted) return;
              showDismissibleSnackBar(
                context,
                content: Text(l10n.settings_locationUpdated),
              );
            },
            child: Text(l10n.common_save),
          ),
        ],
      ),
    );
  }

  void _editReportInterval(
    MeshCoreConnector connector,
    Map<String, String> customVars,
  ) {
    final l10n = context.l10n;
    // Same default the old dialog pre-filled: 900 seconds when the radio has
    // not reported an interval.
    final current = int.tryParse(customVars['gps_interval'] ?? '') ?? 900;
    final intervalController = TextEditingController(text: current.toString());

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.settings_locationReportInterval),
        content: TextField(
          controller: intervalController,
          decoration: InputDecoration(
            labelText: l10n.settings_locationIntervalSec,
            border: const OutlineInputBorder(),
          ),
          keyboardType: const TextInputType.numberWithOptions(
            decimal: false,
            signed: false,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              Navigator.pop(dialogContext);

              final intervalText = intervalController.text.trim();
              if (intervalText.isEmpty) return;

              final interval = int.tryParse(intervalText);
              if (interval == null || interval < 60 || interval >= 86400) {
                if (!mounted) return;
                showDismissibleSnackBar(
                  context,
                  content: Text(l10n.settings_locationIntervalInvalid),
                );
                return;
              }

              try {
                await connector.setCustomVar('gps_interval:$interval');
                await connector.refreshDeviceInfo();
              } catch (_) {
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Could not update location. Please try again.',
                    ),
                  ),
                );
                return;
              }
              if (!mounted) return;
              showDismissibleSnackBar(
                context,
                content: Text(l10n.settings_locationUpdated),
              );
            },
            child: Text(l10n.common_save),
          ),
        ],
      ),
    );
  }
}
