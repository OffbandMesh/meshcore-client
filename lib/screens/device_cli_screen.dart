// Device CLI console (#883, interop plan F2/E2.1) - the local-device
// counterpart of RepeaterCliScreen, built to the owner-approved mockup on
// issue #883. Same console pattern, minus everything mesh-specific: no
// path/flood selection, no retries - one frame-66 send per command with a
// frame-level timeout surfaced as its own transcript row.
//
// Secrecy rule (W3/F4, applied here from day one): a reply to a command that
// names a secret (anything containing "pwd"/"password") renders masked and is
// only recoverable via long-press-to-copy; its cleartext never enters the
// widget tree as selectable text and is never logged by this screen.
//
// Population gating is NOT here: offering this screen only where the
// classifier allows frame 66 is #884 (entry point + gate). Until #884 lands,
// nothing navigates to this screen.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../connector/meshcore_connector.dart';
import '../helpers/device_name_validator.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../services/local_cli_service.dart';

enum _EntryKind { command, reply, timeout, sendFailed }

class _ConsoleEntry {
  _ConsoleEntry.command(this.text)
    : kind = _EntryKind.command,
      isError = false,
      secret = false,
      truncated = false,
      latencyMs = null;

  _ConsoleEntry.reply(
    this.text, {
    required this.latencyMs,
    required this.truncated,
    required this.secret,
    required this.isError,
  }) : kind = _EntryKind.reply;

  _ConsoleEntry.timeout(this.text)
    : kind = _EntryKind.timeout,
      isError = true,
      secret = false,
      truncated = false,
      latencyMs = null;

  _ConsoleEntry.sendFailed(this.text)
    : kind = _EntryKind.sendFailed,
      isError = true,
      secret = false,
      truncated = false,
      latencyMs = null;

  final _EntryKind kind;

  /// For a secret reply this still holds the cleartext (it is the long-press
  /// copy source) - rendering is what masks it, so nothing here may be handed
  /// to a logger or a selectable widget when [secret] is set.
  final String text;
  final bool isError;
  final bool secret;
  final bool truncated;
  final int? latencyMs;
}

class DeviceCliScreen extends StatefulWidget {
  const DeviceCliScreen({super.key, this.commandTimeout});

  /// Per-command reply window; null uses [LocalCliService.defaultTimeout].
  /// Tests shrink it so a timeout row renders without a 10 s pump.
  final Duration? commandTimeout;

  @override
  State<DeviceCliScreen> createState() => _DeviceCliScreenState();
}

class _DeviceCliScreenState extends State<DeviceCliScreen> {
  final TextEditingController _commandController = TextEditingController();
  final FocusNode _commandFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final List<_ConsoleEntry> _entries = [];
  int _historyIndex = -1;
  LocalCliService? _cliService;

  @override
  void initState() {
    super.initState();
    final connector = Provider.of<MeshCoreConnector>(context, listen: false);
    _cliService = LocalCliService(connector);
  }

  @override
  void dispose() {
    _cliService?.dispose();
    _commandController.dispose();
    _commandFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// The device-side handlers echo secrets in cleartext (stock `get wifi.pwd`
  /// reads back the stored password, INVESTIGATION.md section C) - the client
  /// is the only place masking can happen, so match generously.
  static bool isSecretCommand(String command) {
    final c = command.toLowerCase();
    return c.contains('pwd') || c.contains('password');
  }

  /// The wire has no error codes; stock firmware answers errors as plain
  /// "Unknown command" / "Error..." strings (INVESTIGATION.md section A1), so
  /// error styling is string-matched, exactly as the mockup states.
  static bool looksLikeErrorReply(String text) {
    final t = text.trimLeft();
    return t.startsWith('Unknown command') || t.startsWith('Error');
  }

  /// Extracts the name argument of a `set name <value>` command (any casing,
  /// any inner spacing), or null when the command is not one. #885 mirrors the
  /// device's own name-character rejection before the frame is sent.
  static String? setNameArg(String command) {
    final m = RegExp(
      r'^set\s+name\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(command.trim());
    return m?.group(1);
  }

  Future<void> _sendCommand() async {
    final command = _commandController.text.trim();
    if (command.isEmpty) return;
    final service = _cliService;
    if (service == null) return;

    // Mirror the firmware's `set name` character rejection locally: show the
    // typed command and a rejection row, and never send the frame (#885).
    final nameArg = setNameArg(command);
    if (nameArg != null) {
      final bad = forbiddenCharsIn(nameArg);
      if (bad.isNotEmpty) {
        setState(() {
          _entries.add(_ConsoleEntry.command(command));
          _entries.add(
            _ConsoleEntry.sendFailed(
              context.l10n.deviceCli_nameRejected(bad.join(' ')),
            ),
          );
        });
        _commandController.clear();
        _historyIndex = -1;
        _commandFocusNode.requestFocus();
        _scrollToBottom();
        return;
      }
    }

    final secret = isSecretCommand(command);
    setState(() {
      _entries.add(_ConsoleEntry.command(command));
    });
    _commandController.clear();
    _historyIndex = -1;
    _commandFocusNode.requestFocus();
    _scrollToBottom();

    final stopwatch = Stopwatch()..start();
    _ConsoleEntry entry;
    try {
      final reply = await service.run(command, timeout: widget.commandTimeout);
      stopwatch.stop();
      entry = _ConsoleEntry.reply(
        reply.text,
        latencyMs: stopwatch.elapsedMilliseconds,
        truncated: reply.atReplyBound,
        secret: secret,
        isError: looksLikeErrorReply(reply.text),
      );
    } on LocalCliTimeout catch (e) {
      if (!mounted) return;
      entry = _ConsoleEntry.timeout(
        context.l10n.deviceCli_noReply(command, e.secondsText),
      );
    } catch (e) {
      if (!mounted) return;
      entry = _ConsoleEntry.sendFailed(
        context.l10n.deviceCli_sendFailed(e.toString()),
      );
    }
    if (!mounted) return;
    setState(() {
      _entries.add(entry);
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _navigateHistory(bool up) {
    final commands = _entries
        .where((e) => e.kind == _EntryKind.command)
        .map((e) => e.text)
        .toList()
        .reversed
        .toList();
    if (commands.isEmpty) return;

    if (up) {
      if (_historyIndex < commands.length - 1) {
        _historyIndex++;
      }
    } else {
      if (_historyIndex > 0) {
        _historyIndex--;
      } else {
        _historyIndex = -1;
        _commandController.clear();
        return;
      }
    }

    if (_historyIndex >= 0 && _historyIndex < commands.length) {
      _commandController.text = commands[_historyIndex];
      _commandController.selection = TextSelection.fromPosition(
        TextPosition(offset: _commandController.text.length),
      );
    }
  }

  void _clearHistory() {
    setState(() {
      _entries.clear();
      _historyIndex = -1;
    });
  }

  void _copySecret(String cleartext) {
    Clipboard.setData(ClipboardData(text: cleartext));
    showDismissibleSnackBar(
      context,
      content: Text(context.l10n.deviceCli_secretCopied),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connector = context.watch<MeshCoreConnector>();
    final name = connector.selfName;
    final version = connector.firmwareVersion;
    final subtitle = [
      if (name != null && name.isNotEmpty) name,
      if (version != null && version.isNotEmpty) '($version)',
    ].join(' ');

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.deviceCli_title),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                ),
              ),
          ],
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: l10n.repeater_clearHistory,
            onPressed: _entries.isEmpty ? null : _clearHistory,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _entries.isEmpty ? _buildEmptyState() : _buildTranscript(),
          ),
          const Divider(height: 1),
          _buildCommandInput(),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final l10n = context.l10n;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.terminal, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            l10n.repeater_noCommandsSent,
            style: TextStyle(fontSize: 16, color: Colors.grey[600]),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.deviceCli_emptyHint,
            style: TextStyle(fontSize: 14, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }

  Widget _buildTranscript() {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: _entries.length,
      itemBuilder: (context, index) => _buildEntry(_entries[index]),
    );
  }

  Widget _buildEntry(_ConsoleEntry entry) {
    final scheme = Theme.of(context).colorScheme;
    final isCommand = entry.kind == _EntryKind.command;

    final badgeColor = entry.isError
        ? scheme.errorContainer
        : isCommand
        ? scheme.primaryContainer
        : scheme.secondaryContainer;
    final badgeIconColor = entry.isError
        ? scheme.onErrorContainer
        : isCommand
        ? scheme.onPrimaryContainer
        : scheme.onSecondaryContainer;
    final badgeIcon = switch (entry.kind) {
      _EntryKind.command => Icons.chevron_right,
      _EntryKind.reply when entry.isError => Icons.warning_amber,
      _EntryKind.reply => Icons.arrow_back,
      _EntryKind.timeout => Icons.timer_off_outlined,
      _EntryKind.sendFailed => Icons.warning_amber,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: badgeColor,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(badgeIcon, size: 16, color: badgeIconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                entry.secret ? _buildSecretText(entry) : _buildPlainText(entry),
                if (entry.truncated) _buildTruncationBadge(),
              ],
            ),
          ),
          if (entry.latencyMs != null) ...[
            const SizedBox(width: 8),
            Text(
              context.l10n.deviceCli_latencyMs(entry.latencyMs!),
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPlainText(_ConsoleEntry entry) {
    final scheme = Theme.of(context).colorScheme;
    final color = entry.isError
        ? scheme.error
        : entry.kind == _EntryKind.command
        ? scheme.primary
        : scheme.onSurface;
    return SelectableText(
      entry.text,
      style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: color),
    );
  }

  /// Masked rendering: fixed-width dots regardless of the secret's length
  /// (the dot count must not leak it), cleartext only via long-press copy.
  Widget _buildSecretText(_ConsoleEntry entry) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onLongPress: () => _copySecret(entry.text),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '●' * 8,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              context.l10n.deviceCli_secretLongPressToCopy,
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: scheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTruncationBadge() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.content_cut, size: 12, color: scheme.tertiary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              context.l10n.deviceCli_truncatedByDevice,
              style: TextStyle(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: scheme.tertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCommandInput() {
    final l10n = context.l10n;
    return Container(
      padding: const EdgeInsets.all(12),
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_upward, size: 20),
              tooltip: l10n.repeater_previousCommand,
              onPressed: () => _navigateHistory(true),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_downward, size: 20),
              tooltip: l10n.repeater_nextCommand,
              onPressed: () => _navigateHistory(false),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _commandController,
                focusNode: _commandFocusNode,
                decoration: InputDecoration(
                  hintText: l10n.deviceCli_commandHint,
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  prefixText: '> ',
                ),
                style: const TextStyle(fontFamily: 'monospace'),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendCommand(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              icon: const Icon(Icons.send),
              onPressed: _sendCommand,
            ),
          ],
        ),
      ),
    );
  }
}
