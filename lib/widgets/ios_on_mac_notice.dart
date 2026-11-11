import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../storage/prefs_manager.dart';
import '../utils/app_logger.dart';
import '../utils/platform_info.dart';

/// Tells a Mac user they are running the iPhone app (#1140). Shown once per
/// app version. No link to the macOS download, by the owner's decision.
class IosOnMacNotice {
  static const String shownForKey = 'ios_on_mac_notice_shown_for';
  static const MethodChannel _channel = MethodChannel('offband/platform');

  static Future<void> onLaunch(
    BuildContext context, {
    bool? isIOS,
    Future<bool> Function()? isOnMac,
    SharedPreferences? prefs,
    Future<String?> Function()? installedVersion,
  }) async {
    if (!(isIOS ?? PlatformInfo.isIOS)) return;
    if (!await (isOnMac ?? _isOnMac)()) return;
    final version = await (installedVersion ?? _installedVersion)();
    if (version == null) return;
    final store = prefs ?? PrefsManager.instance;
    if (store.getString(shownForKey) == version) return;
    await store.setString(shownForKey, version);
    if (!context.mounted) return;
    final l10n = context.l10n;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.iosOnMac_title),
        content: Text(l10n.iosOnMac_body),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.common_ok),
          ),
        ],
      ),
    );
  }

  static Future<bool> _isOnMac() async {
    try {
      return await _channel.invokeMethod<bool>('isiOSAppOnMac') ?? false;
    } catch (e) {
      appLogger.warn('iOS-on-Mac check failed: $e', tag: 'Platform');
      return false;
    }
  }

  static Future<String?> _installedVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (e) {
      appLogger.error('iOS-on-Mac notice: no app version: $e', tag: 'Platform');
      return null;
    }
  }
}

/// Wraps the app's first screen and offers the notice after it has drawn.
class IosOnMacNoticeGate extends StatefulWidget {
  const IosOnMacNoticeGate({super.key, required this.child});

  final Widget child;

  @override
  State<IosOnMacNoticeGate> createState() => _IosOnMacNoticeGateState();
}

class _IosOnMacNoticeGateState extends State<IosOnMacNoticeGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) IosOnMacNotice.onLaunch(context);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
