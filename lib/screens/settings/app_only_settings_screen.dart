import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'about_view.dart';
import 'app_settings_view.dart';
import 'debug_logs_view.dart';
import 'settings_shell.dart';

/// The settings that need no radio, opened from the scanner (#693).
///
/// A user whose radio will not connect still has to be able to share the log,
/// so this offers only app-level categories. Everything that reads or writes
/// the radio stays in the device Settings screen, which is reachable only
/// while connected. Add a category here only if it works with no radio.
class AppOnlySettingsScreen extends StatelessWidget {
  const AppOnlySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SettingsShell(
      title: l10n.settings_title,
      categories: [
        SettingsCategory(
          icon: Icons.tune,
          title: l10n.settings_appSettings,
          subtitle: l10n.settings_appSettingsSubtitle,
          builder: (_) => const AppSettingsView(),
        ),
        SettingsCategory(
          icon: Icons.build_outlined,
          title: l10n.settings_debug,
          builder: (_) => const DebugLogsView(),
        ),
        SettingsCategory(
          icon: Icons.info_outline,
          title: l10n.settings_about,
          builder: (_) => const AboutView(),
        ),
      ],
    );
  }
}
