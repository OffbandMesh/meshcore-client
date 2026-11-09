import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../storage/prefs_manager.dart';
import '../utils/app_logger.dart';
import '../utils/platform_info.dart';

enum _Choice { never, later, sponsor }

/// The sponsor window (#1129). App-wide, never per radio. Owner's rules,
/// 2026-11-09:
/// - first shown once the app has been launched [minLaunches] times and at
///   least [firstWait] has passed since its first launch;
/// - after Not now (or closing it), not again for [notNowWait];
/// - after Sponsor, not again for [afterSponsorWait];
/// - Never Show Again ends it on this install.
/// Test builds (built with `--dart-define=GIT_SHA=<sha>`) show it once per
/// commit and skip every wait, so each test build can be checked.
class SponsorPrompt {
  static const String firstLaunchKey = 'sponsor_prompt_first_launch_ms';
  static const String launchesKey = 'sponsor_prompt_launches';
  static const String nextKey = 'sponsor_prompt_next_ms';
  static const String offKey = 'sponsor_prompt_off';
  static const String shownForKey = 'sponsor_prompt_shown_for';

  static const int minLaunches = 3;
  static const Duration firstWait = Duration(days: 7);
  static const Duration notNowWait = Duration(days: 30);
  static const Duration afterSponsorWait = Duration(days: 90);

  static final Uri sponsorUri = Uri.parse('https://offband.org/donate');

  /// The commit a test build was made from. Empty in release builds.
  static const String buildSha = String.fromEnvironment('GIT_SHA');

  /// What one installed build is known by: `1.8.0+69`, or `1.8.0+69@<sha>`.
  static String buildId(String version, {String sha = buildSha}) =>
      sha.isEmpty ? version : '$version@$sha';

  /// Called once per app launch. Counts the launch, then shows the window if
  /// the rules above say it's due. The next due time is saved before the
  /// window opens, so a crash can't make it show again straight away.
  static Future<void> onLaunch(
    BuildContext context, {
    String sha = buildSha,
    bool? isIOS,
    SharedPreferences? prefs,
    DateTime Function()? clock,
    Future<String?> Function()? installedVersion,
    Future<bool> Function(Uri)? open,
  }) async {
    if (isIOS ?? PlatformInfo.isIOS) return;
    final store = prefs ?? PrefsManager.instance;
    final now = (clock ?? DateTime.now)();
    final launches = (store.getInt(launchesKey) ?? 0) + 1;
    await store.setInt(launchesKey, launches);
    final first = store.getInt(firstLaunchKey);
    if (first == null) {
      await store.setInt(firstLaunchKey, now.millisecondsSinceEpoch);
    }

    if (sha.isNotEmpty) {
      final version = await (installedVersion ?? _installedVersion)();
      if (version == null) return;
      final id = buildId(version, sha: sha);
      if (store.getString(shownForKey) == id) return;
      await store.setString(shownForKey, id);
    } else {
      if (store.getBool(offKey) ?? false) return;
      if (launches < minLaunches || first == null) return;
      if (now.difference(_at(first)) < firstWait) return;
      final next = store.getInt(nextKey);
      if (next != null && now.isBefore(_at(next))) return;
    }

    await _setNext(store, now, notNowWait);
    if (!context.mounted) return;
    final choice = await showDialog<_Choice>(
      context: context,
      builder: (_) => const _SponsorDialog(),
    );
    if (choice == _Choice.never) {
      await store.setBool(offKey, true);
    } else if (choice == _Choice.sponsor) {
      await _setNext(store, now, afterSponsorWait);
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

  static DateTime _at(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

  static Future<void> _setNext(
    SharedPreferences store,
    DateTime now,
    Duration wait,
  ) => store.setInt(nextKey, now.add(wait).millisecondsSinceEpoch);

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

/// Wraps the app's first screen. Each app launch builds it once, so it counts
/// the launch and offers the window after the screen has drawn.
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
      if (mounted) SponsorPrompt.onLaunch(context);
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
      content: Text(
        '${l10n.sponsorPrompt_body}\n\n${l10n.sponsorPrompt_anytime}',
      ),
      actions: [
        TextButton(
          onPressed: () => choose(_Choice.never),
          child: Text(l10n.sponsorPrompt_never),
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
