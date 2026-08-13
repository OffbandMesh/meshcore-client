import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:meshcore_open/utils/gpx_export.dart';
import 'package:meshcore_open/widgets/elements_ui.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../l10n/l10n.dart';
import '../models/offband_gps_status.dart';
import '../models/radio_settings.dart';
import '../services/app_debug_log_service.dart';
import '../services/app_settings_service.dart';
import '../connector/observer_config_client.dart';
import '../helpers/snack_bar_builder.dart';
import '../utils/build_info.dart';
import 'settings/settings_shell.dart';
import 'settings/app_settings_view.dart';
import 'settings/message_settings_view.dart';
import 'settings/observer_settings_view.dart';
import 'settings/blocked_view.dart';
import 'settings/device_ui_view.dart';
import 'app_debug_log_screen.dart';
import 'ble_debug_log_screen.dart';
import 'export_config_screen.dart';
import 'import_config_screen.dart';
import 'serial_capture_screen.dart';
import 'topology_debug_screen.dart';
import 'companion_radio_stats_screen.dart';
import '../widgets/sync_progress_overlay.dart';

/// Convert device coding-rate value (1-4 on some firmware, 5-8 on others)
/// to the UI enum range (always 5-8).
int _toUiCodingRate(int deviceCr) {
  return deviceCr <= 4 ? deviceCr + 4 : deviceCr;
}

/// Convert UI coding-rate value (5-8) back to firmware encoding.
/// Uses the current device CR to detect which encoding the firmware expects.
int _toDeviceCodingRate(int uiCr, int? deviceCr) {
  if (deviceCr != null && deviceCr <= 4) {
    return uiCr - 4;
  }
  return uiCr;
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _showBatteryVoltage = false;
  String _appVersion = '';

  // #509 hidden unlock: 7 taps on the version row within a rolling window
  // reveals the Experimental settings section.
  static const int _experimentalUnlockTaps = 7;
  static const Duration _experimentalTapWindow = Duration(seconds: 3);
  int _versionTapCount = 0;
  DateTime? _lastVersionTap;
  // Inline feedback shown in the version row itself (no snackbar: a bottom
  // snackbar overlaps the very row being tapped and blocks the next tap).
  String? _versionHint;
  Timer? _versionHintTimer;

  @override
  void initState() {
    super.initState();
    _loadVersionInfo();
  }

  @override
  void dispose() {
    _versionHintTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadVersionInfo() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _appVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
    });
  }

  void _handleUnlockTap() {
    final l10n = context.l10n;
    final settingsService = context.read<AppSettingsService>();

    if (settingsService.settings.experimentalUnlocked) {
      _versionTapCount = 0;
      _setVersionHint(l10n.settings_experimentalAlreadyUnlocked);
      return;
    }

    final now = DateTime.now();
    if (_lastVersionTap == null ||
        now.difference(_lastVersionTap!) > _experimentalTapWindow) {
      _versionTapCount = 0;
    }
    _lastVersionTap = now;
    _versionTapCount++;

    final remaining = _experimentalUnlockTaps - _versionTapCount;
    if (remaining <= 0) {
      _versionTapCount = 0;
      settingsService.setExperimentalUnlocked(true);
      _setVersionHint(l10n.settings_experimentalUnlocked);
    } else if (remaining <= 3) {
      _setVersionHint(l10n.settings_experimentalCountdown(remaining));
    }
  }

  void _setVersionHint(String hint) {
    _versionHintTimer?.cancel();
    setState(() => _versionHint = hint);
    _versionHintTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _versionHint = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsShell(
      title: l10n.settings_title,
      appBarBottom: const SyncProgressAppBarBottom(),
      categories: _categories(context),
    );
  }

  List<SettingsCategory> _categories(BuildContext context) {
    final l10n = context.l10n;
    // Rebuild ONLY when the observer gate flips, NOT on every connector update.
    // A blanket context.watch here rebuilt the whole settings screen on every
    // sync frame, thrashing the UI thread and slowing the channel sync (#81).
    final showObserver = context.select<MeshCoreConnector, bool>(
      (c) => ObserverConfigClient.supportsConfig(
        firmwareVerCode: c.firmwareVerCode ?? 0,
        offbandCaps: c.offbandCaps ?? 0,
      ),
    );
    // Owner-only Experimental section (#509), revealed by the 7-tap gesture on
    // the About version row. Selects narrowly so the category list only rebuilds
    // when the flag flips, not on every connector update (same reason as above).
    final experimentalUnlocked = context.select<AppSettingsService, bool>(
      (s) => s.settings.experimentalUnlocked,
    );
    return [
      SettingsCategory(
        icon: Icons.badge_outlined,
        title: l10n.settings_nodeSettings,
        builder: _identityPane,
      ),
      SettingsCategory(
        icon: Icons.settings_input_antenna,
        title: l10n.settings_radioSettings,
        subtitle: l10n.settings_radioSettingsSubtitle,
        builder: _radioRangePane,
      ),
      SettingsCategory(
        icon: Icons.sensors_outlined,
        title: l10n.radioStats_settingsTile,
        subtitle: l10n.radioStats_settingsSubtitle,
        builder: _radioStatsPane,
      ),
      SettingsCategory(
        icon: Icons.shield_outlined,
        title: l10n.settings_privacy,
        subtitle: l10n.settings_privacySubtitle,
        builder: _privacyPane,
      ),
      SettingsCategory(
        icon: Icons.contacts_outlined,
        title: l10n.contacts_title,
        subtitle: l10n.settings_contactSettingsSubtitle,
        builder: _contactsPane,
      ),
      SettingsCategory(
        icon: Icons.block,
        title: l10n.block_settingsTitle,
        subtitle: l10n.block_settingsSubtitle,
        builder: _blockedPane,
      ),
      SettingsCategory(
        icon: Icons.sms_outlined,
        title: l10n.settings_messageSettings,
        subtitle: l10n.settings_messageSettingsSubtitle,
        builder: _messageSettingsPane,
      ),
      if (showObserver)
        SettingsCategory(
          icon: Icons.cloud_outlined,
          title: 'Observer',
          subtitle: 'WiFi · MQTT brokers · display',
          builder: _observerPane,
        ),
      SettingsCategory(
        icon: Icons.tune,
        title: l10n.settings_appSettings,
        subtitle: l10n.settings_appSettingsSubtitle,
        builder: _appPane,
      ),
      SettingsCategory(
        icon: Icons.info_outline,
        title: l10n.settings_deviceInfo,
        builder: _devicePane,
      ),
      SettingsCategory(
        icon: Icons.bolt_outlined,
        title: l10n.settings_actions,
        builder: _actionsPane,
      ),
      if (experimentalUnlocked)
        SettingsCategory(
          icon: Icons.science_outlined,
          title: l10n.settings_experimental,
          subtitle: l10n.settings_experimentalSubtitle,
          builder: _experimentalPane,
        ),
      SettingsCategory(
        icon: Icons.build_outlined,
        title: l10n.settings_debug,
        builder: _diagnosticsPane,
      ),
      SettingsCategory(
        icon: Icons.info_outline,
        title: l10n.settings_about,
        builder: _aboutPane,
      ),
    ];
  }

  Widget _experimentalPane(BuildContext context) {
    final l10n = context.l10n;
    final settingsService = context.watch<AppSettingsService>();
    final supportsPktHash = context.select<MeshCoreConnector, bool>(
      (c) => c.supportsPktHash,
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(l10n.settings_experimentalDescription),
          ),
        ),
        const SizedBox(height: 16),
        // CoreScope observer counts (#524). Disabled until the connected radio
        // advertises the 0xC6 packet-hash capability.
        Card(
          child: SwitchListTile(
            secondary: const Icon(Icons.cloud_outlined),
            title: Text(l10n.settings_coreScopeObserverCount),
            subtitle: Text(
              supportsPktHash
                  ? l10n.settings_coreScopeObserverCountSubtitle
                  : l10n.settings_coreScopeObserverCountUnsupported,
            ),
            value: settingsService.settings.coreScopeObserverCountEnabled,
            onChanged: supportsPktHash
                ? (value) =>
                      settingsService.setCoreScopeObserverCountEnabled(value)
                : null,
          ),
        ),
        const SizedBox(height: 16),
        // Disable, not just hide: turns off every experimental toggle and
        // re-locks the section, so nothing keeps running invisibly (#553).
        Card(
          child: ListTile(
            leading: const Icon(Icons.block),
            title: Text(l10n.settings_experimentalDisable),
            subtitle: Text(l10n.settings_experimentalDisableSubtitle),
            onTap: () => settingsService.disableExperimental(),
          ),
        ),
      ],
    );
  }

  Widget _observerPane(BuildContext context) => const ObserverSettingsView();

  Widget _blockedPane(BuildContext context) => const BlockedView();

  Widget _radioRangePane(BuildContext context) {
    final l10n = context.l10n;
    final connector = context.watch<MeshCoreConnector>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.settings_radioSettings,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                _RadioSettingsForm(
                  key: ValueKey(
                    '${connector.currentFreqHz}-${connector.currentBwHz}-'
                    '${connector.currentSf}-${connector.currentCr}-'
                    '${connector.currentTxPower}-${connector.clientRepeat}',
                  ),
                  connector: connector,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(child: _PathHashSizeTile(connector: connector)),
      ],
    );
  }

  Widget _radioStatsPane(BuildContext context) =>
      const CompanionRadioStatsBody();

  Widget _identityPane(BuildContext context) {
    final l10n = context.l10n;
    final connector = context.watch<MeshCoreConnector>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(l10n.settings_nodeName),
                subtitle: Text(
                  connector.selfName ?? l10n.settings_nodeNameNotSet,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _editNodeName(context, connector),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.location_on_outlined),
                title: Text(l10n.settings_location),
                subtitle: Text(l10n.settings_locationSubtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _editLocation(context, connector),
              ),
              if (connector.currentCustomVars?.containsKey('gps') ?? false) ...[
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.gps_fixed),
                  title: Text(l10n.settings_locationGPSEnable),
                  subtitle: Text(l10n.settings_locationGPSEnableSubtitle),
                  value: connector.currentCustomVars?['gps'] == '1',
                  onChanged: (value) async {
                    try {
                      await connector.setCustomVar(value ? 'gps:1' : 'gps:0');
                    } catch (_) {
                      if (context.mounted) {
                        showDismissibleSnackBar(
                          context,
                          content: const Text(
                            'Could not update GPS setting. Please try again.',
                          ),
                        );
                      }
                    }
                  },
                ),
              ],
              // Button and buzzer: device UI config (#474/#475). Owner-placed
              // under Node Settings, directly above the public key.
              //
              // Gated STRICTLY on the capability bits. A radio without the
              // hardware has no button to configure, so it gets no tile, no
              // screen and no command. This is the negative test in #474:
              // "A device that does not advertise the bit shows no screen and
              // the client emits no command."
              if (connector.supportsButtonMatrix ||
                  connector.supportsNotifyScope) ...[
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.radio_button_checked_outlined),
                  title: const Text('Button and buzzer'),
                  subtitle: const Text(
                    'Assign button actions and set when this radio beeps',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => Scaffold(
                          appBar: AppBar(
                            title: const Text('Button and buzzer'),
                            centerTitle: true,
                          ),
                          body: const DeviceUiView(),
                        ),
                      ),
                    );
                  },
                ),
              ],
              if (connector.selfPublicKey != null) ...[
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: _buildInfoRow(
                    l10n.settings_infoPublicKey,
                    pubKeyToHex(connector.selfPublicKey!),
                    copyValue: pubKeyToHex(connector.selfPublicKey!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _privacyPane(BuildContext context) {
    final l10n = context.l10n;
    final connector = context.watch<MeshCoreConnector>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  l10n.settings_privacy,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              _PrivacySection(
                key: ValueKey(
                  '${connector.telemetryModeBase}-${connector.telemetryModeLoc}-'
                  '${connector.telemetryModeEnv}-${connector.advertLocationPolicy}-'
                  '${connector.multiAcks}',
                ),
                connector: connector,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _contactsPane(BuildContext context) {
    final l10n = context.l10n;
    final connector = context.watch<MeshCoreConnector>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  l10n.contactsSettings_autoAddTitle,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              _AutoAddSection(
                key: ValueKey(
                  '${connector.autoAddUsers}-${connector.autoAddRepeaters}-'
                  '${connector.autoAddRoomServers}-${connector.autoAddSensors}-'
                  '${connector.autoAddOverwriteOldest}',
                ),
                connector: connector,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _devicePane(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [_buildDeviceInfoCard(context, connector)],
    );
  }

  Widget _appPane(BuildContext context) => const AppSettingsView();

  Widget _messageSettingsPane(BuildContext context) =>
      const MessageSettingsView();

  Widget _actionsPane(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [_buildActionsCard(context, connector)],
    );
  }

  Widget _diagnosticsPane(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildDebugCard(context),
        const SizedBox(height: 16),
        _buildExportCard(connector),
      ],
    );
  }

  Widget _buildDeviceInfoCard(
    BuildContext context,
    MeshCoreConnector connector,
  ) {
    final l10n = context.l10n;
    final firmwareVersion = connector.firmwareVersion;
    final deviceModel = connector.deviceModel;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInfoRow(l10n.settings_infoName, connector.deviceDisplayName),
            _buildInfoRow(l10n.settings_infoId, connector.deviceIdLabel),
            _buildInfoRow(
              l10n.settings_infoStatus,
              connector.isConnected
                  ? l10n.common_connected
                  : l10n.common_disconnected,
            ),
            if (firmwareVersion != null)
              _buildInfoRow(l10n.settings_infoFirmware, firmwareVersion),
            if (deviceModel != null)
              _buildInfoRow(l10n.settings_infoModel, deviceModel),
            // Capability-gated controls vanish silently when a bit is clear,
            // which is indistinguishable from a bug. Surface the raw inputs so
            // "missing feature" can be diagnosed without enabling logging. (#304)
            // caps2 is shown as "absent" rather than omitted: on a radio running
            // byte-2 firmware the whole point is telling "the radio sent it" and
            // "the radio is too old to send it" apart at a glance, without
            // opening the debug log. All-bits-zero is a valid present value.
            // (#480)
            if (connector.offbandCaps != null)
              _buildInfoRow(
                l10n.settings_infoOffbandCaps,
                '0x${connector.offbandCaps!.toRadixString(16).padLeft(2, '0')}'
                ' (v${connector.firmwareVerCode ?? 0})'
                ' · caps2 '
                '${connector.offbandCaps2 == null ? 'absent' : '0x${connector.offbandCaps2!.toRadixString(16).padLeft(2, '0')}'}'
                '${connector.supportsOffbandFemLna ? ' · FEM LNA' : ''}'
                '${connector.supportsOffbandBlock ? ' · block' : ''}',
              ),
            _buildBatteryInfoRow(context, connector),
            if (connector.selfName != null)
              _buildInfoRow(l10n.settings_nodeName, connector.selfName!),
            if (connector.selfPublicKey != null) ...[
              _buildInfoRow(
                l10n.settings_infoPublicKey,
                pubKeyToHex(connector.selfPublicKey!),
                copyValue: pubKeyToHex(connector.selfPublicKey!),
              ),
              // #295: stores are keyed by the first 10 hex of the connected
              // radio's public key, so switching radios silently swaps which
              // history you are looking at. Surface the key that is in effect.
              ...() {
                final hex = pubKeyToHex(connector.selfPublicKey!);
                final scope = hex.length > 10 ? hex.substring(0, 10) : hex;
                if (scope.isEmpty) return <Widget>[];
                return <Widget>[
                  _buildInfoRow(
                    l10n.settings_infoDataScope,
                    scope,
                    copyValue: scope,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      l10n.settings_infoDataScopeSubtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ];
              }(),
            ],
            _buildInfoRow(
              l10n.settings_infoContactsCount,
              '${connector.contacts.length}',
            ),
            _buildInfoRow(
              l10n.settings_infoChannelCount,
              '${connector.channels.length}',
            ),
            // #397: identity of the running binary, injected at build time and
            // independent of the marketing version. Its own line so "which build
            // am I on" is answerable at a glance; copyable for bug reports.
            // Also the hidden 7-tap Experimental unlock anchor (#509/#553),
            // mirroring Android's Software-info build-number gesture.
            _buildInfoRow(
              l10n.settings_infoBuild,
              BuildInfo.stamp,
              copyValue: BuildInfo.stamp,
              onTap: _handleUnlockTap,
            ),
            if (_versionHint != null)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 6),
                child: Text(
                  _versionHint!,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBatteryInfoRow(
    BuildContext context,
    MeshCoreConnector connector,
  ) {
    final l10n = context.l10n;
    final percent = connector.batteryPercent;
    final millivolts = connector.batteryMillivolts;

    // figure out display value
    final String displayValue;
    if (millivolts == null) {
      displayValue = l10n.common_notAvailable;
    } else if (_showBatteryVoltage) {
      displayValue = l10n.common_voltageValue(
        (millivolts / 1000.0).toStringAsFixed(2),
      );
    } else {
      displayValue = percent != null
          ? l10n.common_percentValue(percent)
          : l10n.common_notAvailable;
    }

    final IconData icon;
    final Color? iconColor;
    final Color? valueColor;

    if (percent == null) {
      icon = Icons.battery_unknown;
      iconColor = Colors.grey;
      valueColor = null;
    } else if (percent <= 15) {
      icon = Icons.battery_alert;
      iconColor = Colors.orange;
      valueColor = Colors.orange;
    } else {
      icon = Icons.battery_full;
      iconColor = null;
      valueColor = null;
    }

    return _buildInfoRow(
      l10n.settings_infoBattery,
      displayValue,
      leading: Icon(icon, size: 18, color: iconColor),
      valueColor: valueColor,
      onTap: millivolts != null
          ? () {
              setState(() {
                _showBatteryVoltage = !_showBatteryVoltage;
              });
            }
          : null,
    );
  }

  Widget _buildActionsCard(BuildContext context, MeshCoreConnector connector) {
    final l10n = context.l10n;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              l10n.settings_actions,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: Text(l10n.settings_deleteAllPaths),
            subtitle: Text(
              l10n.settings_deleteAllPathsSubtitle,
              style: TextStyle(color: Colors.red[700]),
            ),
            onTap: () => connector.deleteAllPaths(),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.sync),
            title: Text(l10n.settings_syncTime),
            subtitle: Text(l10n.settings_syncTimeSubtitle),
            onTap: () => _syncTime(context, connector),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: Text(l10n.settings_refreshContacts),
            subtitle: Text(l10n.settings_refreshContactsSubtitle),
            onTap: () async {
              try {
                await connector.getContacts();
              } catch (_) {
                if (context.mounted) {
                  showDismissibleSnackBar(
                    context,
                    content: const Text(
                      'Could not refresh contacts. Please try again.',
                    ),
                  );
                }
              }
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.restart_alt, color: Colors.orange),
            title: Text(l10n.settings_rebootDevice),
            subtitle: Text(l10n.settings_rebootDeviceSubtitle),
            onTap: () => _confirmReboot(context, connector),
          ),
        ],
      ),
    );
  }

  // About is its own top-level Settings category (#525/#526), no longer a card
  // in the Debug pane. Outbound links (offband.org / Play / donate) added by
  // #527 between the info block and the licenses row.
  Widget _aboutPane(BuildContext context) {
    final l10n = context.l10n;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(l10n.appTitle),
                subtitle: Text(
                  l10n.settings_aboutVersion(
                    _appVersion.isEmpty ? l10n.common_loading : _appVersion,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.settings_aboutDescription),
                    const SizedBox(height: 12),
                    Text(
                      l10n.settings_aboutLegalese,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.language),
                title: Text(l10n.settings_aboutWebsite),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => _openExternalUrl('https://offband.org'),
              ),
              ListTile(
                leading: const Icon(Icons.shop_outlined),
                title: Text(l10n.settings_aboutPlayStore),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => _openExternalUrl(
                  'https://play.google.com/store/apps/details?id=app.offband.meshcore',
                ),
              ),
              ListTile(
                leading: const Icon(Icons.favorite_outline),
                title: Text(l10n.settings_aboutDonate),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => _openExternalUrl('https://offband.org/donate'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(l10n.settings_aboutLicenses),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: l10n.appTitle,
                  applicationVersion: _appVersion.isEmpty ? null : _appVersion,
                  applicationLegalese: l10n.settings_aboutLegalese,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openExternalUrl(String url) async {
    try {
      if (await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      // fall through to the failure message
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.settings_aboutLinkFailed)),
      );
    }
  }

  Widget _buildDebugCard(BuildContext context) {
    final l10n = context.l10n;
    final settingsService = context.watch<AppSettingsService>();
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              l10n.settings_debug,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.bluetooth_outlined),
            title: Text(l10n.settings_companionDebugLog),
            subtitle: Text(l10n.settings_companionDebugLogSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const BleDebugLogScreen(),
                ),
              );
            },
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.bug_report_outlined),
            title: Text(l10n.appSettings_appDebugLogging),
            subtitle: Text(l10n.appSettings_appDebugLoggingSubtitle),
            value: settingsService.settings.appDebugLogEnabled,
            onChanged: (value) async {
              try {
                await settingsService.setAppDebugLogEnabled(value);
              } catch (_) {
                if (context.mounted) {
                  showDismissibleSnackBar(
                    context,
                    content: const Text(
                      'Could not change debug logging. Please try again.',
                    ),
                  );
                }
                return;
              }
              if (!context.mounted) return;
              showDismissibleSnackBar(
                context,
                content: Text(
                  value
                      ? l10n.appSettings_appDebugLoggingEnabled
                      : l10n.appSettings_appDebugLoggingDisabled,
                ),
                duration: const Duration(seconds: 2),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.code_outlined),
            title: Text(l10n.settings_appDebugLog),
            subtitle: Text(l10n.settings_appDebugLogSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const AppDebugLogScreen(),
                ),
              );
            },
          ),
          const Divider(height: 1),
          // Serial capture (#430). English-only for now; localization follow-up.
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Serial capture'),
            subtitle: const Text(
              "Capture the radio's serial log and share it as a file",
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const SerialCaptureScreen(),
                ),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: const Text('Mesh topology'),
            subtitle: const Text(
              'Passively-learned node/edge graph (trace inference)',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const TopologyDebugScreen(),
                ),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.sync_problem_outlined),
            title: const Text('Sync queued messages now'),
            subtitle: const Text(
              'Force-pull messages the radio is holding, diagnostic for #51 '
              '(radio reports a count but the app shows none). Logs the flow '
              'for diagnostics.',
            ),
            trailing: const Icon(Icons.download),
            onTap: () {
              context.read<MeshCoreConnector>().syncQueuedMessages(force: true);
              showDismissibleSnackBar(
                context,
                content: const Text('Requested queued-message drain (force)'),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(
    String label,
    String value, {
    Widget? leading,
    Color? valueColor,
    VoidCallback? onTap,
    String? copyValue,
  }) {
    final theme = Theme.of(context);

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (leading != null) ...[leading, const SizedBox(width: 8)],
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (copyValue == null)
            Text(
              value,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: valueColor,
                fontWeight: FontWeight.w500,
              ),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  // When the row is tappable, use a plain Text so the value is
                  // part of the InkWell tap target (a SelectableText would eat
                  // the tap for selection). Copy is still available via the
                  // button. (#553)
                  child: onTap != null
                      ? Text(
                          value,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: valueColor,
                            fontWeight: FontWeight.w500,
                          ),
                        )
                      : SelectableText(
                          value,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: valueColor,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: context.l10n.common_copy,
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: copyValue));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(context.l10n.settings_publicKeyCopied),
                      ),
                    );
                  },
                ),
              ],
            ),
        ],
      ),
    );

    if (onTap != null) {
      return InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: row,
      );
    }

    return row;
  }

  void _editNodeName(BuildContext context, MeshCoreConnector connector) {
    final l10n = context.l10n;
    final controller = TextEditingController(text: connector.selfName ?? '');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settings_nodeName),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: l10n.settings_nodeNameHint,
            border: const OutlineInputBorder(),
          ),
          maxLength: 31,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await connector.setNodeName(controller.text);
              await connector.refreshDeviceInfo();
              if (!context.mounted) return;
              showDismissibleSnackBar(
                context,
                content: Text(l10n.settings_nodeNameUpdated),
              );
            },
            child: Text(l10n.common_save),
          ),
        ],
      ),
    );
  }

  Widget _buildGpsQuerySection(
    BuildContext context,
    OffbandGpsStatus? status,
    bool querying,
    bool queriedOnce,
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
      const SizedBox(height: 8),
      const Divider(),
      Row(
        children: [
          Expanded(
            child: Text(
              l10n.settings_gpsStatusTitle,
              style: theme.textTheme.titleSmall,
            ),
          ),
          if (querying)
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
            queriedOnce
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

  void _editLocation(BuildContext context, MeshCoreConnector connector) {
    final l10n = context.l10n;
    final latController = TextEditingController();
    final lonController = TextEditingController();
    final intervalController = TextEditingController();
    latController.text = connector.selfLatitude?.toStringAsFixed(6) ?? '';
    lonController.text = connector.selfLongitude?.toStringAsFixed(6) ?? '';

    // Safe access to custom vars - may be null before device responds
    final customVars = connector.currentCustomVars ?? {};
    final bool hasGPS = customVars.containsKey("gps");
    bool isGPSEnabled = customVars["gps"] == "1";

    // Read current interval or default to 900 (15 minutes)
    final currentInterval =
        int.tryParse(customVars["gps_interval"] ?? "") ?? 900;
    intervalController.text = currentInterval.toString();

    OffbandGpsStatus? gpsStatus = connector.offbandGpsStatus;
    bool queryingGps = false;
    bool queriedOnce = false;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(l10n.settings_location),
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
              if (hasGPS) ...[
                const SizedBox(height: 16),
                TextField(
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
                const SizedBox(height: 16),
                FeatureToggleRow(
                  title: l10n.settings_locationGPSEnable,
                  subtitle: l10n.settings_locationGPSEnableSubtitle,
                  value: isGPSEnabled,
                  onChanged: (value) async {
                    setDialogState(() => isGPSEnabled = value);
                    try {
                      await connector.setCustomVar(value ? "gps:1" : "gps:0");
                    } catch (_) {
                      if (context.mounted) {
                        showDismissibleSnackBar(
                          context,
                          content: const Text(
                            'Could not update GPS setting. Please try again.',
                          ),
                        );
                      }
                    }
                  },
                ),
                if (connector.supportsOffbandGps)
                  _buildGpsQuerySection(
                    context,
                    gpsStatus,
                    queryingGps,
                    queriedOnce,
                    () async {
                      setDialogState(() => queryingGps = true);
                      final s = await connector.requestOffbandGps();
                      if (!dialogContext.mounted) return;
                      setDialogState(() {
                        queryingGps = false;
                        queriedOnce = true;
                        gpsStatus = s;
                      });
                    },
                  ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.common_cancel),
            ),
            TextButton(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                Navigator.pop(context);

                if (hasGPS) {
                  final intervalText = intervalController.text.trim();
                  if (intervalText.isEmpty) {
                    return;
                  }

                  final interval = int.tryParse(intervalText);
                  if (interval == null || interval < 60 || interval >= 86400) {
                    if (!context.mounted) return;
                    showDismissibleSnackBar(
                      context,
                      content: Text(l10n.settings_locationIntervalInvalid),
                    );
                    return;
                  }

                  try {
                    await connector.setCustomVar("gps_interval:$interval");
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
                  if (!context.mounted) return;
                  showDismissibleSnackBar(
                    context,
                    content: Text(l10n.settings_locationUpdated),
                  );
                }

                final latText = latController.text.trim();
                final lonText = lonController.text.trim();
                if (latText.isEmpty && lonText.isEmpty) {
                  return;
                }

                final currentLat = connector.selfLatitude;
                final currentLon = connector.selfLongitude;
                final lat = latText.isNotEmpty
                    ? double.tryParse(latText)
                    : currentLat;
                final lon = lonText.isNotEmpty
                    ? double.tryParse(lonText)
                    : currentLon;
                if (lat == null || lon == null) {
                  if (!context.mounted) return;
                  showDismissibleSnackBar(
                    context,
                    content: Text(l10n.settings_locationBothRequired),
                  );
                  return;
                }
                if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
                  if (!context.mounted) return;
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
                if (!context.mounted) return;
                showDismissibleSnackBar(
                  context,
                  content: Text(l10n.settings_locationUpdated),
                );
              },
              child: Text(l10n.common_save),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _syncTime(
    BuildContext context,
    MeshCoreConnector connector,
  ) async {
    final l10n = context.l10n;
    try {
      await connector.syncTime();
    } catch (_) {
      if (context.mounted) {
        showDismissibleSnackBar(
          context,
          content: const Text('Could not sync time. Please try again.'),
        );
      }
      return;
    }
    if (!context.mounted) return;
    showDismissibleSnackBar(
      context,
      content: Text(l10n.settings_timeSynchronized),
    );
  }

  void _confirmReboot(BuildContext context, MeshCoreConnector connector) {
    final l10n = context.l10n;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settings_rebootDevice),
        content: Text(l10n.settings_rebootDeviceConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              connector.rebootDevice();
            },
            child: Text(
              l10n.common_reboot,
              style: const TextStyle(color: Colors.orange),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _gpxExport(
    GpxExport exporter,
    String name,
    String description,
    String filename,
    String shareText,
    String subject,
  ) async {
    final l10n = context.l10n;
    final result = await exporter.exportGPX(
      name,
      description,
      filename,
      shareText,
      subject,
    );
    if (!mounted) return;
    switch (result) {
      case gpxExportSuccess:
        showDismissibleSnackBar(
          context,
          content: Text(l10n.settings_gpxExportSuccess),
        );
      case gpxExportNoContacts:
        showDismissibleSnackBar(
          context,
          content: Text(l10n.settings_gpxExportNoContacts),
        );
        break;
      case gpxExportNotAvailable:
        showDismissibleSnackBar(
          context,
          content: Text(l10n.settings_gpxExportNotAvailable),
        );
        break;
      case gpxExportFailed:
        showDismissibleSnackBar(
          context,
          content: Text(l10n.settings_gpxExportError),
        );
        break;
    }
  }

  Widget _buildExportCard(MeshCoreConnector connector) {
    final l10n = context.l10n;
    return Card(
      child: Column(
        children: [
          // Stock-compatible whole-device backup and restore (#568), distinct
          // from the GPX exports below, which are map data only.
          ListTile(
            leading: const Icon(Icons.save_alt),
            title: Text(l10n.settings_exportConfig),
            subtitle: Text(l10n.settings_configBackupSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ExportConfigScreen(),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: Text(l10n.settings_importConfig),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ImportConfigScreen(),
              ),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: Text(l10n.settings_gpxExportRepeaters),
            subtitle: Text(l10n.settings_gpxExportRepeatersSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final exporter = GpxExport(connector);
              exporter.addRepeaters();
              _gpxExport(
                exporter,
                l10n.map_repeater,
                l10n.settings_gpxExportRepeatersRoom,
                "meshcore_repeaters_",
                l10n.settings_gpxExportShareText,
                l10n.settings_gpxExportShareSubject,
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: Text(l10n.settings_gpxExportContacts),
            subtitle: Text(l10n.settings_gpxExportContactsSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final exporter = GpxExport(connector);
              exporter.addContacts();
              _gpxExport(
                exporter,
                l10n.map_repeater,
                l10n.settings_gpxExportChat,
                "meshcore_contacts_",
                l10n.settings_gpxExportShareText,
                l10n.settings_gpxExportShareSubject,
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: Text(l10n.settings_gpxExportAll),
            subtitle: Text(l10n.settings_gpxExportAllSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final exporter = GpxExport(connector);
              exporter.addAll();
              _gpxExport(
                exporter,
                l10n.map_repeater,
                l10n.settings_gpxExportAllContacts,
                "meshcore_all_",
                l10n.settings_gpxExportShareText,
                l10n.settings_gpxExportShareSubject,
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Inline privacy controls for the Privacy pane.
///
/// Advert-location, multi-ACKs, and the three telemetry-access modes all commit
/// through a single [MeshCoreConnector.setTelemetryModeBase] call, so each
/// control sends the full current state on change (coalesced) and reverts to the
/// device's values on failure. The host re-keys this widget on the connector's
/// current values, so a device-reported change rebuilds it with fresh values.
class _PrivacySection extends StatefulWidget {
  final MeshCoreConnector connector;

  const _PrivacySection({super.key, required this.connector});

  @override
  State<_PrivacySection> createState() => _PrivacySectionState();
}

class _PrivacySectionState extends State<_PrivacySection> {
  late int _telemetryMode;
  late int _telemetryLocMode;
  late int _telemetryEnvMode;
  late bool _advertLocPolicy;
  late int _multiAcks;

  bool _applying = false;
  bool _applyAgain = false;

  @override
  void initState() {
    super.initState();
    _seedFromConnector();
  }

  void _seedFromConnector() {
    final c = widget.connector;
    _telemetryMode = c.telemetryModeBase;
    _telemetryLocMode = c.telemetryModeLoc;
    _telemetryEnvMode = c.telemetryModeEnv;
    _advertLocPolicy = c.advertLocationPolicy != 0;
    _multiAcks = c.multiAcks;
  }

  Future<void> _apply() async {
    if (_applying) {
      _applyAgain = true;
      return;
    }
    _applying = true;
    try {
      do {
        _applyAgain = false;
        await widget.connector.setTelemetryModeBase(
          _telemetryMode,
          _telemetryLocMode,
          _telemetryEnvMode,
          _advertLocPolicy ? 1 : 0,
          _multiAcks,
        );
      } while (_applyAgain);
    } catch (e) {
      if (!mounted) return;
      setState(_seedFromConnector);
      showDismissibleSnackBar(
        context,
        content: Text(context.l10n.settings_error(e.toString())),
      );
    } finally {
      _applying = false;
    }
  }

  Widget _telemetryDropdown({
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: DropdownButtonFormField<int>(
        key: ValueKey('$label-$value'),
        initialValue: value,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        items: [
          DropdownMenuItem(
            value: teleModeDeny,
            child: Text(l10n.settings_denyAll),
          ),
          DropdownMenuItem(
            value: teleModeAllowFlags,
            child: Text(l10n.settings_allowByContact),
          ),
          DropdownMenuItem(
            value: teleModeAllowAll,
            child: Text(l10n.settings_allowAll),
          ),
        ],
        onChanged: (v) {
          if (v == null) return;
          onChanged(v);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(l10n.settings_privacySettingsDescription),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.share_location_outlined),
          title: Text(l10n.settings_advertLocation),
          subtitle: Text(l10n.settings_advertLocationSubtitle),
          value: _advertLocPolicy,
          onChanged: (value) {
            setState(() => _advertLocPolicy = value);
            _apply();
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.done_all),
          title: Text(l10n.settings_multiAck),
          value: _multiAcks == 1,
          onChanged: (value) {
            setState(() => _multiAcks = value ? 1 : 0);
            _apply();
          },
        ),
        _telemetryDropdown(
          label: l10n.settings_telemetryBaseMode,
          value: _telemetryMode,
          onChanged: (v) {
            setState(() => _telemetryMode = v);
            _apply();
          },
        ),
        _telemetryDropdown(
          label: l10n.settings_telemetryLocationMode,
          value: _telemetryLocMode,
          onChanged: (v) {
            setState(() => _telemetryLocMode = v);
            _apply();
          },
        ),
        _telemetryDropdown(
          label: l10n.settings_telemetryEnvironmentMode,
          value: _telemetryEnvMode,
          onChanged: (v) {
            setState(() => _telemetryEnvMode = v);
            _apply();
          },
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// Inline path-hash size selector for the connected device.
///
/// 1/2/3-byte hop hashes trade repeater-ID space against the maximum hop
/// count. The width a region standardises on (commonly 2-byte) belongs here
/// in Radio & range, not buried under "experimental". Reads the current width
/// from device info and writes via [MeshCoreConnector.setPathHashMode].
class _PathHashSizeTile extends StatefulWidget {
  final MeshCoreConnector connector;

  const _PathHashSizeTile({required this.connector});

  @override
  State<_PathHashSizeTile> createState() => _PathHashSizeTileState();
}

class _PathHashSizeTileState extends State<_PathHashSizeTile> {
  // Hop ceilings per hash width (1/2/3 bytes), from the firmware path-hash spec.
  static const List<int> _maxHopsPerWidth = [64, 32, 21];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connector = widget.connector;
    final mode = (connector.pathHashByteWidth - 1).clamp(0, 2);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: DropdownButtonFormField<int>(
        key: ValueKey<int>(mode),
        initialValue: mode,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: l10n.repeater_pathHashMode,
          helperText: l10n.repeater_pathHashModeHelper,
          helperMaxLines: 5,
          prefixIcon: const Icon(Icons.alt_route),
          border: const OutlineInputBorder(),
        ),
        items: [
          for (var m = 0; m < 3; m++)
            DropdownMenuItem<int>(
              value: m,
              child: Text('${m + 1}-byte · max ${_maxHopsPerWidth[m]} hops'),
            ),
        ],
        onChanged: connector.isConnected
            ? (value) async {
                if (value == null) return;
                try {
                  await connector.setPathHashMode(value);
                  await connector.refreshDeviceInfo();
                  if (!context.mounted) return;
                  showDismissibleSnackBar(
                    context,
                    content: Text(
                      '${l10n.repeater_pathHashMode}: ${value + 1}-byte',
                    ),
                  );
                } catch (e) {
                  if (!context.mounted) return;
                  showDismissibleSnackBar(
                    context,
                    content: Text(l10n.settings_error(e.toString())),
                  );
                }
              }
            : null,
      ),
    );
  }
}

/// Inline auto-add controls for the Contacts pane.
///
/// Replaces the former modal dialog: toggles apply immediately (send + refetch
/// flags). The host re-keys this widget on the connector's current flags, so a
/// device-reported change rebuilds it with fresh values.
class _AutoAddSection extends StatefulWidget {
  final MeshCoreConnector connector;

  const _AutoAddSection({super.key, required this.connector});

  @override
  State<_AutoAddSection> createState() => _AutoAddSectionState();
}

class _AutoAddSectionState extends State<_AutoAddSection> {
  late bool _chat;
  late bool _repeater;
  late bool _roomServer;
  late bool _sensor;
  late bool _overwriteOldest;

  bool _applying = false;
  bool _applyAgain = false;

  @override
  void initState() {
    super.initState();
    final c = widget.connector;
    _chat = c.autoAddUsers ?? false;
    _repeater = c.autoAddRepeaters ?? false;
    _roomServer = c.autoAddRoomServers ?? false;
    _sensor = c.autoAddSensors ?? false;
    _overwriteOldest = c.autoAddOverwriteOldest ?? false;
  }

  Future<void> _apply() async {
    // Coalesce rapid toggles: if a send is already in flight, flag a re-apply
    // with the latest state for when it finishes instead of overlapping sends.
    if (_applying) {
      _applyAgain = true;
      return;
    }
    _applying = true;
    try {
      do {
        _applyAgain = false;
        await widget.connector.sendFrame(
          buildSetAutoAddConfigFrame(
            autoAddChat: _chat,
            autoAddRepeater: _repeater,
            autoAddRoomServer: _roomServer,
            autoAddSensor: _sensor,
            overwriteOldest: _overwriteOldest,
          ),
        );
        await widget.connector.sendFrame(buildGetAutoAddFlagsFrame());
      } while (_applyAgain);
    } catch (e) {
      if (!mounted) return;
      // Revert the optimistic toggles to the device's last-known flags.
      final c = widget.connector;
      setState(() {
        _chat = c.autoAddUsers ?? false;
        _repeater = c.autoAddRepeaters ?? false;
        _roomServer = c.autoAddRoomServers ?? false;
        _sensor = c.autoAddSensors ?? false;
        _overwriteOldest = c.autoAddOverwriteOldest ?? false;
      });
      showDismissibleSnackBar(
        context,
        content: Text(context.l10n.settings_error(e.toString())),
      );
    } finally {
      _applying = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.person_add_outlined),
          title: Text(l10n.contactsSettings_autoAddUsersTitle),
          subtitle: Text(l10n.contactsSettings_autoAddUsersSubtitle),
          value: _chat,
          onChanged: (value) {
            setState(() => _chat = value);
            _apply();
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.router_outlined),
          title: Text(l10n.contactsSettings_autoAddRepeatersTitle),
          subtitle: Text(l10n.contactsSettings_autoAddRepeatersSubtitle),
          value: _repeater,
          onChanged: (value) {
            setState(() => _repeater = value);
            _apply();
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.meeting_room_outlined),
          title: Text(l10n.contactsSettings_autoAddRoomServersTitle),
          subtitle: Text(l10n.contactsSettings_autoAddRoomServersSubtitle),
          value: _roomServer,
          onChanged: (value) {
            setState(() => _roomServer = value);
            _apply();
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.sensors_outlined),
          title: Text(l10n.contactsSettings_autoAddSensorsTitle),
          subtitle: Text(l10n.contactsSettings_autoAddSensorsSubtitle),
          value: _sensor,
          onChanged: (value) {
            setState(() => _sensor = value);
            _apply();
          },
        ),
        const Divider(height: 1),
        SwitchListTile(
          secondary: const Icon(Icons.autorenew),
          title: Text(l10n.contactsSettings_overwriteOldestTitle),
          subtitle: Text(l10n.contactsSettings_overwriteOldestSubtitle),
          value: _overwriteOldest,
          onChanged: (value) {
            setState(() => _overwriteOldest = value);
            _apply();
          },
        ),
      ],
    );
  }
}

class _RadioSettingsForm extends StatefulWidget {
  final MeshCoreConnector connector;

  const _RadioSettingsForm({super.key, required this.connector});

  @override
  State<_RadioSettingsForm> createState() => _RadioSettingsFormState();
}

class _RadioSettingsFormState extends State<_RadioSettingsForm> {
  final _frequencyController = TextEditingController();
  LoRaBandwidth _bandwidth = LoRaBandwidth.bw125;
  LoRaSpreadingFactor _spreadingFactor = LoRaSpreadingFactor.sf7;
  LoRaCodingRate _codingRate = LoRaCodingRate.cr4_5;
  final _txPowerController = TextEditingController(text: '20');
  bool _clientRepeat = false;
  int? _selectedPresetIndex;
  _RadioSettingsSnapshot? _lastNonRepeatSnapshot;

  AppDebugLogService get _appLog =>
      Provider.of<AppDebugLogService>(context, listen: false);

  @override
  void initState() {
    super.initState();

    // Populate with current settings if available
    if (widget.connector.currentFreqHz != null) {
      _frequencyController.text = (widget.connector.currentFreqHz! / 1000.0)
          .toStringAsFixed(3);
    } else {
      _frequencyController.text = '915.0';
    }

    if (widget.connector.currentBwHz != null) {
      // Find matching bandwidth enum
      final bwValue = widget.connector.currentBwHz!;
      for (var bw in LoRaBandwidth.values) {
        if (bw.hz == bwValue) {
          _bandwidth = bw;
          break;
        }
      }
    }

    if (widget.connector.currentSf != null) {
      // Find matching spreading factor enum
      final sfValue = widget.connector.currentSf!;
      for (var sf in LoRaSpreadingFactor.values) {
        if (sf.value == sfValue) {
          _spreadingFactor = sf;
          break;
        }
      }
    }

    if (widget.connector.currentCr != null) {
      // Find matching coding rate enum
      final crValue = _toUiCodingRate(widget.connector.currentCr!);
      for (var cr in LoRaCodingRate.values) {
        if (cr.value == crValue) {
          _codingRate = cr;
          break;
        }
      }
    }

    if (widget.connector.currentTxPower != null) {
      _txPowerController.text = widget.connector.currentTxPower.toString();
    }

    _clientRepeat = widget.connector.clientRepeat ?? false;
    _selectedPresetIndex = _findMatchingPresetIndex();
    if (_clientRepeat) {
      _lastNonRepeatSnapshot =
          _sessionRememberedNonRepeatSnapshot() ??
          _inferNonRepeatSnapshotForRepeatEnabled();
      _selectedPresetIndex = _findMatchingPresetIndexForSnapshot(
        _lastNonRepeatSnapshot!,
      );
    } else {
      _lastNonRepeatSnapshot = _nonRepeatSnapshotForCurrentSelection();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _logRadioSettingsState('Dialog initialized');
    });
  }

  @override
  void dispose() {
    _frequencyController.dispose();
    _txPowerController.dispose();
    super.dispose();
  }

  void _applyPreset(int index) {
    setState(() {
      _applyPresetState(index);
    });
    _logRadioSettingsState(
      'Applied preset ${RadioSettings.presets[index].$1} (#$index)',
    );
  }

  int? _findMatchingPresetIndex() {
    return _findMatchingPresetIndexForSnapshot(_currentSnapshot());
  }

  int? _findMatchingPresetIndexForSnapshot(_RadioSettingsSnapshot snapshot) {
    for (final i in _visiblePresetIndexes()) {
      final preset = RadioSettings.presets[i].$2;
      if (preset.frequencyHz == snapshot.frequencyHz &&
          preset.bandwidth == snapshot.bandwidth &&
          preset.spreadingFactor == snapshot.spreadingFactor &&
          preset.codingRate == snapshot.codingRate &&
          preset.txPowerDbm == snapshot.txPowerDbm) {
        return i;
      }
    }
    return null;
  }

  Iterable<int> _visiblePresetIndexes() sync* {
    for (var i = 0; i < RadioSettings.presets.length; i++) {
      if (_isOffGridPresetIndex(i)) {
        continue;
      }
      yield i;
    }
  }

  _RadioSettingsSnapshot _currentSnapshot() {
    final frequencyMHz = double.tryParse(_frequencyController.text) ?? 915.0;
    final txPowerDbm = int.tryParse(_txPowerController.text) ?? 20;
    return _RadioSettingsSnapshot(
      frequencyMHz: frequencyMHz,
      bandwidth: _bandwidth,
      spreadingFactor: _spreadingFactor,
      codingRate: _codingRate,
      txPowerDbm: txPowerDbm,
    );
  }

  bool _isOffGridPresetIndex(int? index) {
    if (index == null) return false;
    return RadioSettings.presets[index].$1.startsWith('Off-Grid ');
  }

  double _offGridFrequencyForBaseFrequency(double baseFrequencyMHz) {
    if (baseFrequencyMHz < 500) return 433.0;
    if (baseFrequencyMHz < 900) return 869.0;
    return 918.0;
  }

  double _normalFrequencyForBand(double frequencyMHz) {
    if (frequencyMHz < 500) return 433.650;
    if (frequencyMHz < 900) return 869.432;
    return 915.8;
  }

  _RadioSettingsSnapshot _fallbackNonRepeatSnapshot(
    double currentFrequencyMHz,
  ) {
    return _RadioSettingsSnapshot(
      frequencyMHz: _normalFrequencyForBand(currentFrequencyMHz),
      bandwidth: _bandwidth,
      spreadingFactor: _spreadingFactor,
      codingRate: _codingRate,
      txPowerDbm: int.tryParse(_txPowerController.text) ?? 20,
    );
  }

  _RadioSettingsSnapshot _nonRepeatSnapshotForCurrentSelection() {
    final current = _currentSnapshot();
    if (!_isOffGridPresetIndex(_selectedPresetIndex)) {
      return current;
    }
    return _fallbackNonRepeatSnapshot(current.frequencyMHz);
  }

  _RadioSettingsSnapshot? _sessionRememberedNonRepeatSnapshot() {
    final snapshot = widget.connector.rememberedNonRepeatRadioState;
    if (snapshot == null) return null;
    return _RadioSettingsSnapshot.fromMeshCoreSnapshot(snapshot);
  }

  _RadioSettingsSnapshot _inferNonRepeatSnapshotForRepeatEnabled() {
    final current = _currentSnapshot();
    for (final i in _visiblePresetIndexes()) {
      final preset = RadioSettings.presets[i].$2;
      final offGridFreqHz =
          (_offGridFrequencyForBaseFrequency(preset.frequencyMHz) * 1000)
              .round();
      if (offGridFreqHz == current.frequencyHz &&
          preset.bandwidth == current.bandwidth &&
          preset.spreadingFactor == current.spreadingFactor &&
          preset.codingRate == current.codingRate &&
          preset.txPowerDbm == current.txPowerDbm) {
        return _RadioSettingsSnapshot(
          frequencyMHz: preset.frequencyMHz,
          bandwidth: preset.bandwidth,
          spreadingFactor: preset.spreadingFactor,
          codingRate: preset.codingRate,
          txPowerDbm: preset.txPowerDbm,
        );
      }
    }
    return _fallbackNonRepeatSnapshot(current.frequencyMHz);
  }

  void _applySnapshot(_RadioSettingsSnapshot snapshot) {
    _frequencyController.text = snapshot.frequencyMHz.toStringAsFixed(3);
    _bandwidth = snapshot.bandwidth;
    _spreadingFactor = snapshot.spreadingFactor;
    _codingRate = snapshot.codingRate;
    _txPowerController.text = snapshot.txPowerDbm.toString();
  }

  void _applyPresetState(int index) {
    final preset = RadioSettings.presets[index].$2;
    final baseSnapshot = _RadioSettingsSnapshot(
      frequencyMHz: preset.frequencyMHz,
      bandwidth: preset.bandwidth,
      spreadingFactor: preset.spreadingFactor,
      codingRate: preset.codingRate,
      txPowerDbm: preset.txPowerDbm,
    );
    final frequencyMHz = _clientRepeat
        ? _offGridFrequencyForBaseFrequency(baseSnapshot.frequencyMHz)
        : baseSnapshot.frequencyMHz;
    _frequencyController.text = frequencyMHz.toString();
    _bandwidth = preset.bandwidth;
    _spreadingFactor = preset.spreadingFactor;
    _codingRate = preset.codingRate;
    _txPowerController.text = preset.txPowerDbm.toString();
    _selectedPresetIndex = index;
    _lastNonRepeatSnapshot = baseSnapshot;
  }

  void _syncPresetSelection() {
    final previousPresetIndex = _selectedPresetIndex;
    final previousLastNonRepeat = _lastNonRepeatSnapshot;
    if (_clientRepeat) {
      final baseSnapshot =
          previousLastNonRepeat ?? _inferNonRepeatSnapshotForRepeatEnabled();
      if (_bandwidth != baseSnapshot.bandwidth ||
          _spreadingFactor != baseSnapshot.spreadingFactor ||
          _codingRate != baseSnapshot.codingRate ||
          (int.tryParse(_txPowerController.text) ?? 20) !=
              baseSnapshot.txPowerDbm) {
        _lastNonRepeatSnapshot = _RadioSettingsSnapshot(
          frequencyMHz: baseSnapshot.frequencyMHz,
          bandwidth: _bandwidth,
          spreadingFactor: _spreadingFactor,
          codingRate: _codingRate,
          txPowerDbm: int.tryParse(_txPowerController.text) ?? 20,
        );
      }
      _selectedPresetIndex = _findMatchingPresetIndexForSnapshot(
        _lastNonRepeatSnapshot ?? baseSnapshot,
      );
      if (previousPresetIndex != _selectedPresetIndex ||
          previousLastNonRepeat != _lastNonRepeatSnapshot) {
        _logRadioSettingsState(
          'Preset match updated while repeat enabled: ${_presetLabel(previousPresetIndex)} -> ${_presetLabel(_selectedPresetIndex)}',
        );
      }
      return;
    }
    _lastNonRepeatSnapshot = _nonRepeatSnapshotForCurrentSelection();
    _selectedPresetIndex = _findMatchingPresetIndexForSnapshot(
      _lastNonRepeatSnapshot!,
    );
    if (previousPresetIndex != _selectedPresetIndex ||
        previousLastNonRepeat != _lastNonRepeatSnapshot) {
      _logRadioSettingsState(
        'Preset sync updated state from ${_presetLabel(previousPresetIndex)} to ${_presetLabel(_selectedPresetIndex)}',
      );
    }
  }

  void _handleManualSettingsChanged(String source) {
    _logRadioSettingsState('Manual settings edit: $source');
    setState(_syncPresetSelection);
  }

  void _handleClientRepeatChanged(bool enabled) {
    _logRadioSettingsState(
      'Off-grid repeat toggle requested: $_clientRepeat -> $enabled',
    );
    setState(() {
      final currentSnapshot = _currentSnapshot();
      if (enabled) {
        if (!_clientRepeat) {
          _syncPresetSelection();
        }
        final baseSnapshot = _lastNonRepeatSnapshot ?? currentSnapshot;
        _clientRepeat = true;
        _frequencyController.text = _offGridFrequencyForBaseFrequency(
          baseSnapshot.frequencyMHz,
        ).toStringAsFixed(3);
        return;
      }

      _clientRepeat = false;
      _applySnapshot(
        _lastNonRepeatSnapshot ??
            _fallbackNonRepeatSnapshot(currentSnapshot.frequencyMHz),
      );
      _syncPresetSelection();
    });
    _logRadioSettingsState('Off-grid repeat toggle applied');
  }

  Future<void> _saveSettings() async {
    final l10n = context.l10n;
    final freqMHz = double.tryParse(_frequencyController.text);
    final txPower = int.tryParse(_txPowerController.text);

    if (freqMHz == null || freqMHz < 300 || freqMHz > 2500) {
      showDismissibleSnackBar(
        context,
        content: Text(l10n.settings_frequencyInvalid),
      );
      return;
    }

    final maxTxPower = widget.connector.maxTxPower ?? 22;
    if (txPower == null || txPower < 0 || txPower > maxTxPower) {
      showDismissibleSnackBar(
        context,
        content: Text('${l10n.settings_txPowerInvalid} (0-$maxTxPower dBm)'),
      );
      return;
    }

    final freqHz = (freqMHz * 1000).round();
    final bwHz = _bandwidth.hz;
    final sf = _spreadingFactor.value;
    final cr = _toDeviceCodingRate(
      _codingRate.value,
      widget.connector.currentCr,
    );

    // if the client repeat isnt null then we know its supported
    //otherwise we leave it out of the frame to avoid accidentally enabling
    final knownRepeat = widget.connector.clientRepeat != null;

    if (knownRepeat) {
      const validRepeatFreqsKHz = {433000, 869000, 918000};
      if (_clientRepeat && !validRepeatFreqsKHz.contains(freqHz)) {
        showDismissibleSnackBar(
          context,
          content: Text(l10n.settings_clientRepeatFreqWarning),
        );
        return;
      }
    }

    try {
      _logRadioSettingsState('Saving radio settings');
      await widget.connector.sendFrame(
        buildSetRadioParamsFrame(
          freqHz,
          bwHz,
          sf,
          cr,
          clientRepeat: knownRepeat ? _clientRepeat : null,
        ),
      );
      await widget.connector.sendFrame(buildSetRadioTxPowerFrame(txPower));
      await widget.connector.refreshDeviceInfo();
      final rememberedSnapshot = _clientRepeat
          ? _lastNonRepeatSnapshot
          : _currentSnapshot();
      if (rememberedSnapshot != null) {
        widget.connector.rememberNonRepeatRadioState(
          rememberedSnapshot.toMeshCoreSnapshot(widget.connector.currentCr),
        );
      }

      if (!mounted) return;
      _logRadioSettingsState('Radio settings saved successfully');
      showDismissibleSnackBar(
        context,
        content: Text(l10n.settings_radioSettingsUpdated),
      );
    } catch (e) {
      _appLog.warn('Radio settings save failed: $e', tag: 'RadioSettings');
      if (!mounted) return;
      showDismissibleSnackBar(
        context,
        content: Text(l10n.settings_error(e.toString())),
      );
    }
  }

  String _presetLabel(int? index) {
    if (index == null) {
      return 'custom';
    }
    return '${RadioSettings.presets[index].$1} (#$index)';
  }

  String _formatSnapshot(_RadioSettingsSnapshot? snapshot) {
    if (snapshot == null) {
      return 'null';
    }
    return '${snapshot.frequencyMHz.toStringAsFixed(3)}MHz/'
        '${snapshot.bandwidth.label}/'
        '${snapshot.spreadingFactor.label}/'
        '${snapshot.codingRate.label}/'
        '${snapshot.txPowerDbm}dBm';
  }

  void _logRadioSettingsState(String message) {
    if (!kDebugMode) return;
    _appLog.info(
      '$message | '
      'freq=${_frequencyController.text}MHz '
      'bw=${_bandwidth.label} '
      'sf=${_spreadingFactor.label} '
      'cr=${_codingRate.label} '
      'tx=${_txPowerController.text}dBm '
      'repeat=$_clientRepeat '
      'preset=${_presetLabel(_selectedPresetIndex)} '
      'lastNonRepeat=${_formatSnapshot(_lastNonRepeatSnapshot)}',
      tag: 'RadioSettings',
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<int>(
          key: ValueKey<int?>(_selectedPresetIndex),
          initialValue: _selectedPresetIndex,
          decoration: InputDecoration(
            labelText: l10n.settings_presets,
            border: const OutlineInputBorder(),
          ),
          items: [
            for (final i in _visiblePresetIndexes())
              DropdownMenuItem(
                value: i,
                child: Text(RadioSettings.presets[i].$1),
              ),
          ],
          onChanged: (index) {
            if (index != null) {
              _applyPreset(index);
            }
          },
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _frequencyController,
          onChanged: (_) => _handleManualSettingsChanged('frequency'),
          decoration: InputDecoration(
            labelText: l10n.settings_frequency,
            border: const OutlineInputBorder(),
            helperText: l10n.settings_frequencyHelper,
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<LoRaBandwidth>(
          initialValue: _bandwidth,
          decoration: InputDecoration(
            labelText: l10n.settings_bandwidth,
            border: const OutlineInputBorder(),
          ),
          items: LoRaBandwidth.values
              .map((bw) => DropdownMenuItem(value: bw, child: Text(bw.label)))
              .toList(),
          onChanged: (value) {
            if (value != null) {
              setState(() {
                _bandwidth = value;
                _syncPresetSelection();
              });
              _logRadioSettingsState('Manual settings edit: bandwidth');
            }
          },
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<LoRaSpreadingFactor>(
          initialValue: _spreadingFactor,
          decoration: InputDecoration(
            labelText: l10n.settings_spreadingFactor,
            border: const OutlineInputBorder(),
          ),
          items: LoRaSpreadingFactor.values
              .map((sf) => DropdownMenuItem(value: sf, child: Text(sf.label)))
              .toList(),
          onChanged: (value) {
            if (value != null) {
              setState(() {
                _spreadingFactor = value;
                _syncPresetSelection();
              });
              _logRadioSettingsState('Manual settings edit: spreading factor');
            }
          },
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<LoRaCodingRate>(
          initialValue: _codingRate,
          decoration: InputDecoration(
            labelText: l10n.settings_codingRate,
            border: const OutlineInputBorder(),
          ),
          items: LoRaCodingRate.values
              .map((cr) => DropdownMenuItem(value: cr, child: Text(cr.label)))
              .toList(),
          onChanged: (value) {
            if (value != null) {
              setState(() {
                _codingRate = value;
                _syncPresetSelection();
              });
              _logRadioSettingsState('Manual settings edit: coding rate');
            }
          },
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _txPowerController,
          onChanged: (_) => _handleManualSettingsChanged('tx power'),
          decoration: InputDecoration(
            labelText: l10n.settings_txPower,
            border: const OutlineInputBorder(),
            helperText: widget.connector.maxTxPower != null
                ? '${l10n.settings_txPowerHelper} (max: ${widget.connector.maxTxPower} dBm)'
                : l10n.settings_txPowerHelper,
          ),
          keyboardType: TextInputType.number,
        ),
        if (widget.connector.clientRepeat != null) ...[
          const SizedBox(height: 16),
          SwitchListTile(
            title: Text(l10n.settings_clientRepeat),
            subtitle: Text(l10n.settings_clientRepeatSubtitle),
            value: _clientRepeat,
            onChanged: _handleClientRepeatChanged,
            contentPadding: EdgeInsets.zero,
          ),
        ],
        // Only this radio's own FEM probe decides whether this appears, never
        // model or version (#304). Deliberately not mirrored into local state:
        // firmware returns post-apply hardware truth, so the switch renders
        // what the radio reports rather than what we asked for.
        if (widget.connector.supportsOffbandFemLna) ...[
          const SizedBox(height: 16),
          ListenableBuilder(
            listenable: widget.connector,
            builder: (context, _) => SwitchListTile(
              title: Text(l10n.settings_femLna),
              subtitle: Text(l10n.settings_femLnaSubtitle),
              value: widget.connector.femLnaEnabled ?? true,
              onChanged: (value) => widget.connector.setFemLna(value),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _saveSettings,
            icon: const Icon(Icons.save_outlined),
            label: Text(l10n.common_save),
          ),
        ),
      ],
    );
  }
}

class _RadioSettingsSnapshot {
  final double frequencyMHz;
  final LoRaBandwidth bandwidth;
  final LoRaSpreadingFactor spreadingFactor;
  final LoRaCodingRate codingRate;
  final int txPowerDbm;

  const _RadioSettingsSnapshot({
    required this.frequencyMHz,
    required this.bandwidth,
    required this.spreadingFactor,
    required this.codingRate,
    required this.txPowerDbm,
  });

  /// Frequency in integer Hz, avoids floating-point comparison issues.
  int get frequencyHz => (frequencyMHz * 1000).round();

  /// Convert from the connector's raw-int snapshot to UI-enum snapshot.
  static _RadioSettingsSnapshot? fromMeshCoreSnapshot(
    MeshCoreRadioStateSnapshot snapshot,
  ) {
    final bw = LoRaBandwidth.values
        .where((b) => b.hz == snapshot.bwHz)
        .firstOrNull;
    final sf = LoRaSpreadingFactor.values
        .where((s) => s.value == snapshot.sf)
        .firstOrNull;
    final cr = LoRaCodingRate.values
        .where((c) => c.value == _toUiCodingRate(snapshot.cr))
        .firstOrNull;
    if (bw == null || sf == null || cr == null) return null;
    return _RadioSettingsSnapshot(
      frequencyMHz: snapshot.freqHz / 1000.0,
      bandwidth: bw,
      spreadingFactor: sf,
      codingRate: cr,
      txPowerDbm: snapshot.txPowerDbm,
    );
  }

  /// Convert back to the connector's raw-int snapshot.
  MeshCoreRadioStateSnapshot toMeshCoreSnapshot(int? deviceCr) {
    return MeshCoreRadioStateSnapshot(
      freqHz: frequencyHz,
      bwHz: bandwidth.hz,
      sf: spreadingFactor.value,
      cr: _toDeviceCodingRate(codingRate.value, deviceCr),
      txPowerDbm: txPowerDbm,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _RadioSettingsSnapshot &&
        frequencyHz == other.frequencyHz &&
        bandwidth == other.bandwidth &&
        spreadingFactor == other.spreadingFactor &&
        codingRate == other.codingRate &&
        txPowerDbm == other.txPowerDbm;
  }

  @override
  int get hashCode => Object.hash(
    frequencyHz,
    bandwidth,
    spreadingFactor,
    codingRate,
    txPowerDbm,
  );
}
