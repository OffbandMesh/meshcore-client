import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../helpers/snack_bar_builder.dart';
import '../../l10n/l10n.dart';
import '../../utils/platform_info.dart';

/// The About pane: app identity, version, outbound links and licenses.
///
/// Needs no radio, so both the device Settings screen and the app-only
/// settings reachable from the scanner show it (#693). Outbound links
/// (offband.org / Play / donate) added by #527.
class AboutView extends StatefulWidget {
  const AboutView({super.key});

  @override
  State<AboutView> createState() => _AboutViewState();
}

class _AboutViewState extends State<AboutView> {
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    _loadVersionInfo();
  }

  Future<void> _loadVersionInfo() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _appVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
    });
  }

  @override
  Widget build(BuildContext context) {
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
                    const SizedBox(height: 4),
                    Text(
                      l10n.settings_aboutPresetsAttribution,
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
              // App Store guideline 2.3.10 bars naming other marketplaces (#1048).
              if (!PlatformInfo.isIOS)
                ListTile(
                  leading: const Icon(Icons.shop_outlined),
                  title: Text(l10n.settings_aboutPlayStore),
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: () => _openExternalUrl(
                    'https://play.google.com/store/apps/details?id=app.offband.meshcore',
                  ),
                ),
              // Hidden on iOS for the first App Store submission (#1051).
              if (!PlatformInfo.isIOS)
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
      showDismissibleSnackBar(
        context,
        content: Text(context.l10n.settings_aboutLinkFailed),
        persist: true,
      );
    }
  }
}
