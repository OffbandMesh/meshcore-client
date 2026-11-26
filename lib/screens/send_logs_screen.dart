import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../services/log_package.dart';
import '../services/log_upload_service.dart';
import '../utils/app_logger.dart';

typedef LogPackageZipper = Future<Uint8List?> Function(MeshCoreConnector radio);

/// Send to Offband (#1210): say what is sent, take an optional note, seal and
/// upload the log package, and show the reference code. A failure stays on
/// screen with its reason and the package is kept for Retry.
class SendLogsScreen extends StatefulWidget {
  const SendLogsScreen({
    super.key,
    this.webContent,
    this.uploader,
    this.zipPackage,
  });

  /// On web there are no log files, so the caller hands over the log text.
  final String Function()? webContent;
  final LogUploader? uploader;

  /// Builds the zipped package, or null when there is nothing to send.
  /// Defaults to [LogPackage]; tests replace it.
  final LogPackageZipper? zipPackage;

  static Future<void> open(
    BuildContext context, {
    String Function()? webContent,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SendLogsScreen(webContent: webContent),
    ),
  );

  @override
  State<SendLogsScreen> createState() => _SendLogsScreenState();
}

enum _Phase { preparing, empty, prepareFailed, ready, sending, failed, sent }

class _SendLogsScreenState extends State<SendLogsScreen> {
  final _note = TextEditingController();
  late final LogUploader _uploader = widget.uploader ?? LogUploader();
  _Phase _phase = _Phase.preparing;
  Uint8List? _zip;
  LogPackage? _package;
  LogUploadFailure? _failure;
  String? _code;

  @override
  void initState() {
    super.initState();
    _prepare(context.read<MeshCoreConnector>());
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _prepare(MeshCoreConnector radio) async {
    Uint8List? zip;
    try {
      zip = await (widget.zipPackage ?? _defaultZip)(radio);
    } catch (e) {
      appLogger.error('Building the log package failed: $e', tag: 'LogUpload');
      if (mounted) setState(() => _phase = _Phase.prepareFailed);
      return;
    }
    if (!mounted) return;
    setState(() {
      _zip = zip;
      _phase = zip == null ? _Phase.empty : _Phase.ready;
    });
  }

  Future<Uint8List?> _defaultZip(MeshCoreConnector radio) async {
    if (kIsWeb) {
      final text = widget.webContent?.call() ?? '';
      return text.isEmpty
          ? null
          : LogPackage.textPackageZip(text, radio: radio);
    }
    final package = await LogPackage.build(radio: radio);
    _package = package;
    return package.files.length > 1 ? package.zip() : null;
  }

  Future<void> _send() async {
    final zip = _zip;
    if (zip == null) return;
    setState(() => _phase = _Phase.sending);
    final result = await _uploader.send(
      zip,
      platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
      appVersion: appLogger.appVersion,
      note: _note.text,
    );
    if (!mounted) return;
    switch (result) {
      case LogUploadSent(:final code):
        setState(() {
          _code = code;
          _phase = _Phase.sent;
        });
        _package?.delete();
      case LogUploadFailed(:final failure):
        setState(() {
          _failure = failure;
          _phase = _Phase.failed;
        });
    }
  }

  String _failureText(BuildContext context, LogUploadFailure failure) {
    final l10n = context.l10n;
    return switch (failure) {
      LogUploadFailure.network => l10n.sendLogs_failedNetwork,
      LogUploadFailure.tooLarge => l10n.sendLogs_failedTooLarge,
      LogUploadFailure.rateLimited => l10n.sendLogs_failedRateLimited,
      LogUploadFailure.refused => l10n.sendLogs_failedRefused,
      LogUploadFailure.server => l10n.sendLogs_failedServer,
    };
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final error = TextStyle(color: theme.colorScheme.error);
    final canSend = _phase == _Phase.ready || _phase == _Phase.failed;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.sendLogs_title), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l10n.sendLogs_consent),
          const SizedBox(height: 16),
          if (_phase == _Phase.preparing || _phase == _Phase.sending)
            Row(
              children: [
                const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Text(
                  _phase == _Phase.preparing
                      ? l10n.sendLogs_preparing
                      : l10n.sendLogs_sending,
                ),
              ],
            ),
          if (_phase == _Phase.empty) Text(l10n.sendLogs_noLogs),
          if (_phase == _Phase.prepareFailed)
            Text(l10n.sendLogs_failedPrepare, style: error),
          if (_zip != null && _phase != _Phase.sent) ...[
            Text(l10n.sendLogs_size(_size(_zip!.length))),
            const SizedBox(height: 8),
            TextField(
              controller: _note,
              enabled: canSend,
              maxLength: 500,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: l10n.sendLogs_noteLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: canSend ? _send : null,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: Text(
                _phase == _Phase.failed
                    ? l10n.sendLogs_retry
                    : l10n.sendLogs_send,
              ),
            ),
          ],
          if (_phase == _Phase.failed && _failure != null) ...[
            const SizedBox(height: 12),
            Text(_failureText(context, _failure!), style: error),
          ],
          if (_phase == _Phase.sent && _code != null) ...[
            Text(l10n.sendLogs_sentBody),
            const SizedBox(height: 12),
            Center(
              child: SelectableText(
                _code!,
                style: theme.textTheme.headlineMedium,
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _code!));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.sendLogs_codeCopied)),
                  );
                },
                icon: const Icon(Icons.copy),
                label: Text(l10n.sendLogs_copyCode),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
