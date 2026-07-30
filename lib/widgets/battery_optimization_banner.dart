import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../l10n/l10n.dart';
import '../utils/platform_info.dart';

/// Warns the user when the app is NOT exempt from Android battery optimization
/// and guides them to the settings to fix it (#443).
///
/// On aggressive OEMs (e.g. Samsung One UI) a backgrounded app that is not
/// exempt gets put to sleep on screen-off, dropping the radio connection. The
/// app can't force the exemption without the Play-restricted
/// `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission, so it only reads its own
/// status and deep-links to the settings screen — no restricted permission,
/// no Play-policy impact.
///
/// Mirrors [StorageUnavailableBanner]'s wrap-child shape: when there is nothing
/// to warn about (non-Android, already exempt, or dismissed) this is a
/// transparent pass-through and adds no layout.
class BatteryOptimizationBanner extends StatefulWidget {
  final Widget child;

  const BatteryOptimizationBanner({super.key, required this.child});

  @override
  State<BatteryOptimizationBanner> createState() =>
      _BatteryOptimizationBannerState();
}

class _BatteryOptimizationBannerState extends State<BatteryOptimizationBanner>
    with WidgetsBindingObserver {
  // Assume exempt until the async check says otherwise, so the banner never
  // flashes on first frame.
  bool _ignoring = true;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check on resume so the banner clears once the user sets the app to
    // Unrestricted in settings.
    if (state == AppLifecycleState.resumed) {
      _check();
    }
  }

  Future<void> _check() async {
    if (!PlatformInfo.isAndroid) return;
    final ignoring = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!mounted) return;
    setState(() => _ignoring = ignoring);
  }

  Future<void> _openSettings() async {
    await FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
    // The user returns via resume, which triggers _check() and clears the
    // banner if they applied the change.
  }

  @override
  Widget build(BuildContext context) {
    final show = PlatformInfo.isAndroid && !_ignoring && !_dismissed;
    if (!show) return widget.child;

    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Material(
          color: scheme.secondaryContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.battery_alert_outlined,
                    color: scheme.onSecondaryContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.l10n.batteryOptimizationTitle,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: scheme.onSecondaryContainer,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          context.l10n.batteryOptimizationBody,
                          style: TextStyle(color: scheme.onSecondaryContainer),
                        ),
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: _openSettings,
                            child: Text(
                              context.l10n.batteryOptimizationOpenSettings,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    color: scheme.onSecondaryContainer,
                    tooltip: context.l10n.batteryOptimizationDismiss,
                    onPressed: () => setState(() => _dismissed = true),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}
