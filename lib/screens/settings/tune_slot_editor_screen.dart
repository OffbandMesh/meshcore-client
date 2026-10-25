import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../connector/meshcore_connector.dart';
import '../../connector/offband_device_ui.dart';
import '../../connector/offband_tones.dart';
import '../../widgets/device_ui_error_banner.dart';
import '../../widgets/radio_tone.dart';

/// Edit one custom tune slot on the radio (#970).
///
/// Opens with the stored tune read back (`SLOT_READ`), so a filled slot can be
/// changed rather than only replaced. Typing is checked with firmware's own
/// validator and words before anything is sent, since the radio can only
/// answer "malformed". Saving is the chunked `SLOT_SET`; the radio replaces
/// the slot only on the final chunk, so a failed save changes nothing.
///
/// English-only, matching [DeviceUiView].
class TuneSlotEditorScreen extends StatefulWidget {
  const TuneSlotEditorScreen({
    super.key,
    required this.slot,
    required this.info,
  });

  final int slot;
  final TuneSlotInfo info;

  @override
  State<TuneSlotEditorScreen> createState() => _TuneSlotEditorScreenState();
}

class _TuneSlotEditorScreenState extends State<TuneSlotEditorScreen> {
  final _controller = TextEditingController();

  /// What the radio holds, once read. Null while reading, or if the read
  /// failed: then the slot's content is unknown and Play saved is off.
  String? _saved;
  bool _reading = false;
  int _readBytes = 0;
  bool _saving = false;
  int _sentBytes = 0;
  int _sendTotal = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
    if (widget.info.isEmpty) {
      _saved = '';
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _read());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    final connector = context.read<MeshCoreConnector>();
    setState(() => _reading = true);
    final text = await connector.readTuneSlot(
      widget.slot,
      onProgress: (n) {
        if (mounted) setState(() => _readBytes = n);
      },
    );
    if (!mounted) return;
    setState(() {
      _reading = false;
      _saved = text;
      if (text != null) _controller.text = text;
    });
  }

  bool get _busy => _reading || _saving;
  String get _text => _controller.text;
  bool get _dirty => _text != (_saved ?? '');

  Future<void> _save() async {
    final connector = context.read<MeshCoreConnector>();
    final navigator = Navigator.of(context);
    final text = _text;
    setState(() {
      _saving = true;
      _sentBytes = 0;
      _sendTotal = text.length;
    });
    final ok = await connector.saveTuneSlot(
      widget.slot,
      text,
      onProgress: (sent, total) {
        if (mounted) setState(() => _sentBytes = sent);
      },
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _saved = text;
    });
    if (!ok) return;
    // Pop after the rebuild, so PopScope sees the saved state and does not
    // ask to discard a tune that was just saved.
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) navigator.pop();
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Clear slot ${widget.slot + 1}?'),
        content: const Text(
          'The tune is removed from the radio. Events and channels using it '
          'stop playing it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _controller.text = '';
    await _save();
  }

  Future<void> _playSaved() async {
    final connector = context.read<MeshCoreConnector>();
    final messenger = ScaffoldMessenger.of(context);
    final note = describeTunePlay(
      await connector.playTune(slotTuneId(widget.slot)),
    );
    if (note == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(note),
        duration: const Duration(days: 1),
        action: SnackBarAction(label: 'OK', onPressed: () {}),
      ),
    );
  }

  Future<bool> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('This tune has not been saved to the radio.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard == true;
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    final scheme = Theme.of(context).colorScheme;
    final problem = rtttlProblem(_text);
    final emptyText = _text.isEmpty;
    // Firmware's own words fit 21 badge columns and do not say that order is
    // the problem, which it usually is for RTTTL from elsewhere. When the
    // header is the only fault, say so and offer the fix.
    final orderFix = emptyText ? null : fixRtttlDefaultsOrder(_text);
    final helper = emptyText
        ? (_saved == null ? '' : 'Type or paste an RTTTL tune')
        : problem == RtttlProblem.ok
        ? 'Plays as "${deriveSlotName(_text)}"'
        : orderFix != null
        ? 'The badge reads d=, o=, b= in that order, each once'
        : problem.text;
    final helperIsProblem = !emptyText && problem != RtttlProblem.ok;
    final savedHasTune = _saved != null && _saved!.isNotEmpty;
    final error = connector.deviceUiError;
    final showError =
        error != null &&
        (connector.deviceUiErrorSurface == DeviceUiSurface.tuneSlot ||
            connector.deviceUiErrorSurface == DeviceUiSurface.tunePlay);

    return PopScope(
      // Held while a read or save is in flight: leaving would abandon it
      // halfway, and the radio would keep the old tune.
      canPop: !_dirty && !_busy,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _busy) return;
        final navigator = Navigator.of(context);
        if (await _confirmDiscard()) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('Slot ${widget.slot + 1}'),
          centerTitle: true,
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (showError)
              DeviceUiErrorBanner(
                message: error,
                onDismiss: connector.clearDeviceUiError,
                margin: const EdgeInsets.only(bottom: 12),
              ),
            TextField(
              controller: _controller,
              readOnly: _busy,
              minLines: 4,
              maxLines: 8,
              maxLength: maxSlotRtttl,
              keyboardType: TextInputType.visiblePassword,
              autocorrect: false,
              enableSuggestions: false,
              // RTTTL is plain ASCII on one line; the radio stores bytes.
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[\x20-\x7E]')),
              ],
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: InputDecoration(
                labelText: 'RTTTL',
                border: const OutlineInputBorder(),
                helperText: helperIsProblem ? null : helper,
                errorText: helperIsProblem ? helper : null,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (orderFix != null)
                  TextButton(
                    onPressed: _busy ? null : () => _controller.text = orderFix,
                    child: const Text('Fix order'),
                  ),
                TextButton(
                  onPressed: _busy || !savedHasTune ? null : _clear,
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                  child: const Text('Clear slot'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy || !savedHasTune || _dirty
                      ? null
                      : _playSaved,
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Play saved'),
                ),
                FilledButton(
                  onPressed:
                      _busy ||
                          !_dirty ||
                          emptyText ||
                          problem != RtttlProblem.ok
                      ? null
                      : _save,
                  child: const Text('Save'),
                ),
              ],
            ),
            if (_reading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: widget.info.length == 0
                    ? null
                    : _readBytes / widget.info.length,
              ),
              const SizedBox(height: 6),
              Text(
                'Reading from the radio: $_readBytes of '
                '${widget.info.length} characters',
              ),
            ],
            if (_saving) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: _sendTotal == 0 ? null : _sentBytes / _sendTotal,
              ),
              const SizedBox(height: 6),
              Text(
                _sendTotal == 0
                    ? 'Clearing the slot'
                    : 'Sending to the radio: $_sentBytes of $_sendTotal '
                          'characters',
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'Play saved plays what is on the radio, so it is off while there '
              'are unsaved changes.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
