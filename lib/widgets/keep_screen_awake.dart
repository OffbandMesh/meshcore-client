import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/app_settings_service.dart';

/// Holds a screen wakelock while [AppSettings.keepScreenAwake] is enabled and
/// the app is foregrounded (#269).
///
/// The lock is released when the setting is turned off, when the app leaves the
/// foreground, and on dispose — so normal display sleep resumes and the
/// background foreground-service behaviour is untouched.
class KeepScreenAwake extends StatefulWidget {
  const KeepScreenAwake({super.key, required this.child});

  final Widget child;

  @override
  State<KeepScreenAwake> createState() => _KeepScreenAwakeState();
}

class _KeepScreenAwakeState extends State<KeepScreenAwake>
    with WidgetsBindingObserver {
  AppSettingsService? _service;
  bool _foreground = true;
  bool _held = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final service = context.read<AppSettingsService>();
    if (!identical(service, _service)) {
      _service?.removeListener(_sync);
      _service = service..addListener(_sync);
    }
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  /// Drives the platform wakelock toward the desired state. Failures are
  /// logged and leave the tracked state released, never swallowed.
  Future<void> _sync() async {
    final want = (_service?.settings.keepScreenAwake ?? false) && _foreground;
    if (want == _held) return;
    try {
      await WakelockPlus.toggle(enable: want);
      _held = want;
    } catch (e) {
      _held = false;
      debugPrint('[KeepScreenAwake] failed to set wakelock to $want: $e');
    }
  }

  @override
  void dispose() {
    _service?.removeListener(_sync);
    WidgetsBinding.instance.removeObserver(this);
    if (_held) {
      WakelockPlus.disable().catchError(
        (Object e) =>
            debugPrint('[KeepScreenAwake] failed to release on dispose: $e'),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
