import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/offband_device_ui.dart';
import '../connector/offband_tones.dart';
import '../models/channel.dart';

/// The radio's tune picker (#971, #986), shared by the six event tones and a
/// channel's own tone, so every entry point offers the same list the badge's
/// picker does. A channel's "Radio tone" row lives here too, reachable from
/// the Channels sheet and the channel chat menu, so the two cannot drift.
///
/// English-only, matching [DeviceUiView] which hosts the event rows.

IconData tuneIcon(int? id) => id == null
    ? Icons.sync
    : id == tuneSilent
    ? Icons.volume_off_outlined
    : Icons.music_note_outlined;

/// The radio's reason a preview made no sound, or null when it played.
String? describeTunePlay(TunePlayResult? result) => switch (result) {
  TunePlayResult.played => null,
  TunePlayResult.busy =>
    'The radio is playing a notification. Try again in a moment.',
  TunePlayResult.soundOff =>
    'Sound is off on this radio. Set the scope to All or Self to hear it.',
  null => 'The radio did not play that tune.',
};

/// A tune choice from [showTunePickerDialog].
sealed class TuneChoice {
  const TuneChoice();
}

/// "Default": no choice, follow the radio's tone. Offered only to a channel.
class DefaultTuneChoice extends TuneChoice {
  const DefaultTuneChoice();
}

class TuneIdChoice extends TuneChoice {
  const TuneIdChoice(this.id);
  final int id;
}

/// Show the picker. [current] is the row to mark; null marks Default. Returns
/// the choice, or null when the user cancels.
///
/// The play button auditions on the radio and never chooses; tapping a name
/// chooses (owner decision 2026-10-25). Only what firmware accepts is listed:
/// named built-ins and filled slots.
Future<TuneChoice?> showTunePickerDialog(
  BuildContext context, {
  required String title,
  String? description,
  required int? current,
  String? defaultSubtitle,
  bool withDefault = false,
}) {
  return showDialog<TuneChoice>(
    context: context,
    builder: (dialogContext) => _TunePickerDialog(
      title: title,
      description: description,
      current: current,
      defaultSubtitle: defaultSubtitle,
      withDefault: withDefault,
    ),
  );
}

class _TunePickerDialog extends StatefulWidget {
  const _TunePickerDialog({
    required this.title,
    required this.description,
    required this.current,
    required this.defaultSubtitle,
    required this.withDefault,
  });

  final String title;
  final String? description;
  final int? current;
  final String? defaultSubtitle;
  final bool withDefault;

  @override
  State<_TunePickerDialog> createState() => _TunePickerDialogState();
}

class _TunePickerDialogState extends State<_TunePickerDialog> {
  /// A preview's refusal, shown inside the dialog: a snackbar would sit
  /// behind the dialog's scrim.
  String? _playNote;

  Future<void> _play(MeshCoreConnector connector, int id) async {
    setState(() => _playNote = null);
    final result = await connector.playTune(id);
    if (!mounted) return;
    setState(() => _playNote = describeTunePlay(result));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Consumer<MeshCoreConnector>(
      builder: (context, connector, _) {
        final slots = connector.tuneSlots;
        final ids = offeredTuneIds(slots);
        final builtins = ids.where((id) => !isSlotTuneId(id)).toList();
        final custom = ids.where(isSlotTuneId).toList();

        Widget row(int id) {
          final selected = id == widget.current;
          return ListTile(
            leading: Icon(tuneIcon(id)),
            title: Text(tuneLabel(id, slots) ?? 'Tune $id'),
            subtitle: selected ? const Text('Current') : null,
            selected: selected,
            trailing: id == tuneSilent
                ? null
                : IconButton(
                    icon: const Icon(Icons.play_circle_outline),
                    color: scheme.primary,
                    tooltip: 'Play on the radio',
                    onPressed: () => _play(connector, id),
                  ),
            onTap: () => Navigator.pop(context, TuneIdChoice(id)),
          );
        }

        return AlertDialog(
          title: Text(widget.title),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                if (widget.description != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: Text(widget.description!),
                  ),
                if (_playNote != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: Text(
                      _playNote!,
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                if (widget.withDefault) ...[
                  ListTile(
                    leading: Icon(tuneIcon(null)),
                    title: const Text('Default'),
                    subtitle: widget.defaultSubtitle == null
                        ? null
                        : Text(widget.defaultSubtitle!),
                    selected: widget.current == null,
                    trailing: widget.current == null
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () =>
                        Navigator.pop(context, const DefaultTuneChoice()),
                  ),
                  const Divider(height: 1),
                ],
                for (final id in builtins) row(id),
                if (custom.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
                    child: Text(
                      'Your tunes',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                  for (final id in custom) row(id),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }
}

/// What a channel's Default plays: the Channel event's effective tune, when
/// the radio has reported it.
String _defaultSubtitle(MeshCoreConnector connector) {
  final effective = connector.eventTone(ToneEvent.channel)?.effective;
  final name = effective == null
      ? null
      : tuneLabel(effective, connector.tuneSlots);
  return name == null
      ? 'The radio\'s channel tone'
      : '$name, the radio\'s channel tone';
}

/// The subtitle for a channel's Radio tone row.
String channelRadioToneLabel(MeshCoreConnector connector, int channel) {
  final tune = connector.channelTuneFor(channel);
  if (tune == null) return 'Reading from the radio';
  if (tune.inherits) return 'Default';
  return tuneLabel(tune.tuneId!, connector.tuneSlots) ?? 'Tune ${tune.tuneId}';
}

/// Read what the Radio tone row and its picker need.
void requestChannelRadioTone(MeshCoreConnector connector, int channel) {
  connector.requestChannelTune(channel);
  connector.requestEventTones();
  connector.requestTuneSlots();
}

/// Show the radio's refusal of a write to [surface] as a snackbar that stays
/// until dismissed, for screens with no banner of their own. Watches for a few
/// seconds after the write; a confirmed write shows nothing.
void showRefusalWhenItArrives(
  BuildContext context,
  MeshCoreConnector connector,
  DeviceUiSurface surface,
) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  late final VoidCallback listener;
  listener = () {
    final error = connector.deviceUiError;
    if (connector.deviceUiErrorSurface != surface || error == null) return;
    connector.removeListener(listener);
    messenger.showSnackBar(
      SnackBar(
        content: Text(error),
        duration: const Duration(days: 1),
        action: SnackBarAction(
          label: 'OK',
          onPressed: connector.clearDeviceUiError,
        ),
      ),
    );
  };
  connector.addListener(listener);
  Future.delayed(
    const Duration(seconds: 5),
    () => connector.removeListener(listener),
  );
}

Future<void> showChannelRadioToneDialog(
  BuildContext context,
  Channel channel,
) async {
  final connector = context.read<MeshCoreConnector>();
  final tune = connector.channelTuneFor(channel.index);
  final choice = await showTunePickerDialog(
    context,
    title: 'Radio tone',
    description: channel.name,
    current: tune?.tuneId,
    defaultSubtitle: _defaultSubtitle(connector),
    withDefault: true,
  );
  if (choice != null && context.mounted) {
    showRefusalWhenItArrives(context, connector, DeviceUiSurface.channelTune);
  }
  switch (choice) {
    case DefaultTuneChoice():
      await connector.setChannelTune(
        channel.index,
        const ChannelTune.inherit(),
      );
    case TuneIdChoice(:final id):
      await connector.setChannelTune(channel.index, ChannelTune.tune(id));
    case null:
      break;
  }
}

/// The channel sheet's Radio tone row. Reads the channel's tune when shown, so
/// its subtitle is the radio's answer. Shown only with caps byte 2 `0x10`.
class ChannelRadioToneTile extends StatefulWidget {
  const ChannelRadioToneTile({
    super.key,
    required this.channel,
    required this.onTap,
  });

  final Channel channel;
  final VoidCallback onTap;

  @override
  State<ChannelRadioToneTile> createState() => _ChannelRadioToneTileState();
}

class _ChannelRadioToneTileState extends State<ChannelRadioToneTile> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = context.read<MeshCoreConnector>();
      if (c.supportsTunes) requestChannelRadioTone(c, widget.channel.index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    if (!connector.supportsTunes) return const SizedBox.shrink();
    final tune = connector.channelTuneFor(widget.channel.index);
    return ListTile(
      leading: Icon(tune == null ? Icons.sync : tuneIcon(tune.tuneId)),
      title: const Text('Radio tone'),
      subtitle: Text(channelRadioToneLabel(connector, widget.channel.index)),
      onTap: widget.onTap,
    );
  }
}

/// Whether [surface]'s refusal belongs on a tone screen.
bool isToneSurface(DeviceUiSurface? surface) =>
    surface == DeviceUiSurface.channelTune ||
    surface == DeviceUiSurface.eventTone ||
    surface == DeviceUiSurface.tunePlay ||
    surface == DeviceUiSurface.tuneSlot;
