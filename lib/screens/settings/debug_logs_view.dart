import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../helpers/snack_bar_builder.dart';
import '../../l10n/l10n.dart';
import '../../services/app_debug_log_service.dart';
import '../../services/app_settings_service.dart';
import '../../utils/log_export.dart';
import '../app_debug_log_screen.dart';
import '../ble_debug_log_screen.dart';

/// The radio-independent rows of the Debug pane: share the log, the app debug
/// logging switch, and the two log viewers.
///
/// Split out of the device Settings Debug pane (#693) so the scanner's
/// app-only settings can offer them with no radio connected. The radio rows
/// (Device CLI, serial capture, mesh topology) stay in device Settings.
class DebugLogTiles extends StatelessWidget {
  const DebugLogTiles({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settingsService = context.watch<AppSettingsService>();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: Icon(LogExport.icon),
          title: Text(LogExport.tooltip(context)),
          onTap: () => LogExport.shareLogs(
            context,
            webContent: () => LogExport.appLogText(
              context.read<AppDebugLogService>().entries.reversed,
            ),
          ),
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
                  persist: true,
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
      ],
    );
  }
}

/// The Debug pane of the app-only settings: the log rows in their own card.
class DebugLogsView extends StatelessWidget {
  const DebugLogsView({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  context.l10n.settings_debug,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const DebugLogTiles(),
            ],
          ),
        ),
      ],
    );
  }
}
