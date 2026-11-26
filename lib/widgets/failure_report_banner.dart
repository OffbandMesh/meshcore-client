import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../screens/send_logs_screen.dart';
import '../services/app_settings_service.dart';
import '../services/failure_monitor.dart';
import '../services/log_package.dart';
import '../services/log_upload_service.dart';
import '../utils/app_logger.dart';

/// After a run that ended badly, offers to send the logs: Send, Not now,
/// Don't ask again (#1214). With "Send crash logs automatically" on, it sends
/// them without asking and only asks if that send fails.
class FailureReportBanner extends StatefulWidget {
  const FailureReportBanner({
    super.key,
    required this.monitor,
    required this.navigatorKey,
    required this.messengerKey,
    required this.child,
    this.uploader,
    this.zipPackage,
  });

  final FailureMonitor monitor;
  final GlobalKey<NavigatorState> navigatorKey;
  final GlobalKey<ScaffoldMessengerState> messengerKey;
  final Widget child;
  final LogUploader? uploader;
  final LogPackageZipper? zipPackage;

  @override
  State<FailureReportBanner> createState() => _FailureReportBannerState();
}

class _FailureReportBannerState extends State<FailureReportBanner> {
  bool _autoTried = false;
  bool _autoSending = false;
  late final AppSettingsService _settings = context.read<AppSettingsService>();

  @override
  void initState() {
    super.initState();
    widget.monitor.addListener(_onChange);
    _settings.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onChange());
  }

  @override
  void dispose() {
    widget.monitor.removeListener(_onChange);
    _settings.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    // A run whose on-screen state is unknown is a can't-tell case: it is
    // offered, never sent without asking (PLAN.md section 6).
    final pending = widget.monitor.pending;
    if (pending != null &&
        pending != FailureKind.unknownExit &&
        _settings.settings.crashLogsAutoSend &&
        !_autoTried) {
      _autoTried = true;
      _autoSend();
      return;
    }
    setState(() {});
  }

  Future<void> _autoSend() async {
    setState(() => _autoSending = true);
    final radio = context.read<MeshCoreConnector>();
    LogUploadResult result;
    try {
      final zip = await (widget.zipPackage ?? _zip)(radio);
      result = zip == null
          ? const LogUploadFailed(LogUploadFailure.refused, 'no logs')
          : await (widget.uploader ?? LogUploader()).send(
              zip,
              platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
              appVersion: appLogger.appVersion,
              note: 'Sent automatically after: ${widget.monitor.pending?.name}',
            );
    } catch (e) {
      result = LogUploadFailed(LogUploadFailure.refused, '$e');
    }
    if (!mounted) return;
    setState(() => _autoSending = false);
    if (result is LogUploadSent) {
      widget.monitor.resolve();
      widget.messengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(context.l10n.failureOffer_autoSent(result.code)),
        ),
      );
    }
  }

  static Future<Uint8List?> _zip(MeshCoreConnector radio) async {
    final package = await LogPackage.build(radio: radio);
    return package.files.length > 1 ? package.zip() : null;
  }

  String _title(BuildContext context, FailureKind kind) => switch (kind) {
    FailureKind.anr => context.l10n.failureOffer_anr,
    FailureKind.crash ||
    FailureKind.dartError => context.l10n.failureOffer_crashed,
    FailureKind.foregroundExit ||
    FailureKind.unknownExit => context.l10n.failureOffer_exited,
  };

  @override
  Widget build(BuildContext context) {
    final kind = widget.monitor.pending;
    final settings = context.watch<AppSettingsService>().settings;
    if (kind == null || !settings.crashLogsAsk || _autoSending) {
      return widget.child;
    }
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Material(
          color: scheme.secondaryContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _title(context, kind),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n.failureOffer_body,
                    style: TextStyle(color: scheme.onSecondaryContainer),
                  ),
                  Wrap(
                    alignment: WrapAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () {
                          context.read<AppSettingsService>().setCrashLogsAsk(
                            false,
                          );
                          widget.monitor.resolve();
                        },
                        child: Text(l10n.failureOffer_dontAsk),
                      ),
                      TextButton(
                        onPressed: widget.monitor.resolve,
                        child: Text(l10n.failureOffer_notNow),
                      ),
                      FilledButton(
                        onPressed: () {
                          widget.monitor.resolve();
                          widget.navigatorKey.currentState?.push(
                            MaterialPageRoute<void>(
                              builder: (_) => const SendLogsScreen(),
                            ),
                          );
                        },
                        child: Text(l10n.sendLogs_send),
                      ),
                    ],
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
