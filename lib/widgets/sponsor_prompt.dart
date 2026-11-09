import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../storage/prefs_manager.dart';
import '../utils/app_logger.dart';
import '../utils/platform_info.dart';

enum _Choice { off, later, sponsor }

/// The sponsor window shown once on the first launch after an install or an
/// upgrade (#1129). App-wide, never per radio.
class SponsorPrompt {
  static const String shownForKey = 'sponsor_prompt_shown_for';
  static const String offKey = 'sponsor_prompt_off';
  static final Uri sponsorUri = Uri.parse('https://offband.org/donate');

  /// Shows the window unless it has already shown for [version], the user
  /// turned it off, or this is iOS (hidden there like About's Donate, #1051).
  /// The version is saved before the window opens, so a crash can't loop it.
  static Future<void> maybeShow(
    BuildContext context, {
    String? version,
    bool? isIOS,
    SharedPreferences? prefs,
    Future<bool> Function(Uri)? open,
  }) async {
    if (isIOS ?? PlatformInfo.isIOS) return;
    final store = prefs ?? PrefsManager.instance;
    if (store.getBool(offKey) ?? false) return;
    final current = version ?? await _installedVersion();
    if (current == null || store.getString(shownForKey) == current) return;
    await store.setString(shownForKey, current);
    if (!context.mounted) return;
    final choice = await showDialog<_Choice>(
      context: context,
      builder: (_) => const _SponsorDialog(),
    );
    if (choice == _Choice.off) {
      await store.setBool(offKey, true);
    } else if (choice == _Choice.sponsor) {
      if (await _open(open ?? _openExternally)) return;
      if (context.mounted) {
        showDismissibleSnackBar(
          context,
          content: Text(context.l10n.settings_aboutLinkFailed),
          persist: true,
        );
      }
    }
  }

  static Future<bool> _open(Future<bool> Function(Uri) open) async {
    try {
      return await open(sponsorUri);
    } catch (e) {
      appLogger.warn('Sponsor link did not open: $e', tag: 'Sponsor');
      return false;
    }
  }

  static Future<bool> _openExternally(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  static Future<String?> _installedVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (e) {
      appLogger.error('Sponsor prompt: no app version: $e', tag: 'Sponsor');
      return null;
    }
  }
}

/// Wraps the app's first screen and offers the sponsor window once it has
/// drawn.
class SponsorPromptGate extends StatefulWidget {
  const SponsorPromptGate({super.key, required this.child});

  final Widget child;

  @override
  State<SponsorPromptGate> createState() => _SponsorPromptGateState();
}

class _SponsorPromptGateState extends State<SponsorPromptGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) SponsorPrompt.maybeShow(context);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _SponsorDialog extends StatelessWidget {
  const _SponsorDialog();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    void choose(_Choice choice) => Navigator.of(context).pop(choice);
    return AlertDialog(
      title: Text(l10n.sponsorPrompt_title),
      content: Text(l10n.sponsorPrompt_body),
      actions: [
        TextButton(
          onPressed: () => choose(_Choice.off),
          child: Text(l10n.sponsorPrompt_dontShowAgain),
        ),
        TextButton(
          onPressed: () => choose(_Choice.later),
          child: Text(l10n.sponsorPrompt_notNow),
        ),
        FilledButton(
          onPressed: () => choose(_Choice.sponsor),
          child: Text(l10n.sponsorPrompt_sponsor),
        ),
      ],
    );
  }
}
