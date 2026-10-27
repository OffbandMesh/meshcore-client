import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../connector/meshcore_connector.dart';
import '../../connector/offband_device_ui.dart';
import '../../connector/offband_tones.dart';
import '../../widgets/device_ui_error_banner.dart';
import '../../widgets/radio_tone.dart';
import 'tune_slot_editor_screen.dart';

/// Settings for a headless device's physical UI: the button-action matrix
/// (#474) and the device notification scope (#475).
///
/// The whole pane is capability-gated. A radio that does not advertise the bit
/// gets no screen and never sees the command, so stock and older firmware
/// degrade silently with nothing shown and no error.
///
/// English-only for now, matching the serial-capture pane (#430); localization
/// is a follow-up rather than a blocker on shipping the capability.
///
/// Shows one [part] at a time (#978): button actions open from Node Settings,
/// the buzzer from Message Settings. They are separate features with separate
/// bits, and boards with a buzzer and no button exist.
class DeviceUiView extends StatefulWidget {
  const DeviceUiView({super.key, required this.part});

  final DeviceUiPart part;

  @override
  State<DeviceUiView> createState() => _DeviceUiViewState();
}

/// Which half of the device UI a [DeviceUiView] shows.
enum DeviceUiPart { buttons, buzzer }

class _DeviceUiViewState extends State<DeviceUiView> {
  @override
  void initState() {
    super.initState();
    // Re-read on open as well as on device-info: the user may have changed the
    // scope by triple-pressing the device since the last refresh.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = context.read<MeshCoreConnector>();
      switch (widget.part) {
        case DeviceUiPart.buttons:
          c.requestButtonMatrix();
        case DeviceUiPart.buzzer:
          c.requestNotifyScope();
          if (c.supportsTunes) {
            c.requestEventTones();
            c.requestTuneSlots();
          }
      }
    });
  }

  /// An error is shown on the screen it belongs to. One that could not be
  /// attributed to a write is shown on both halves rather than hidden.
  bool _ownsError(DeviceUiSurface? surface) => switch (surface) {
    null => true,
    DeviceUiSurface.buttonMatrix => widget.part == DeviceUiPart.buttons,
    DeviceUiSurface.notifyScope ||
    DeviceUiSurface.channelTune ||
    DeviceUiSurface.eventTone ||
    DeviceUiSurface.tunePlay ||
    DeviceUiSurface.tuneSlot => widget.part == DeviceUiPart.buzzer,
    DeviceUiSurface.gpsMode || DeviceUiSurface.screenSettings => false,
  };

  @override
  Widget build(BuildContext context) {
    return Consumer<MeshCoreConnector>(
      builder: (context, connector, _) {
        final showButtons =
            widget.part == DeviceUiPart.buttons &&
            connector.supportsButtonMatrix;
        final showScope =
            widget.part == DeviceUiPart.buzzer && connector.supportsNotifyScope;
        // A radio advertising neither bit has no button and no buzzer to
        // configure, so it gets nothing. The tile that leads here is gated the
        // same way, so this is a belt-and-braces guard rather than a path a
        // user can reach. (#474 negative test)
        if (!showButtons && !showScope) {
          return const SizedBox.shrink();
        }
        // The radio advertises the capability but shipped firmware has no
        // get/set command yet, so it can be detected and not queried. Say that
        // plainly instead of spinning forever on a read that never returns.
        if (!connector.supportsDeviceUiCommand) {
          return ListView(
            children: [
              const _SectionHeader('Supported by this radio'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  'This radio reports that it supports '
                  '${showScope && showButtons
                      ? 'notification scope and button actions'
                      : showScope
                      ? 'the notification scope'
                      : 'button actions'}.\n\n'
                  'Reading and changing it from the app needs a firmware '
                  'update that is still in progress, so there is nothing to '
                  'set here yet.',
                ),
              ),
              if (showScope)
                const ListTile(
                  leading: Icon(Icons.touch_app_outlined),
                  title: Text('Change it on the device'),
                  subtitle: Text(
                    'Triple-press the button to cycle All, Self, then None. '
                    'The default is All.',
                  ),
                ),
            ],
          );
        }
        return ListView(
          children: [
            if (connector.deviceUiError != null &&
                _ownsError(connector.deviceUiErrorSurface))
              DeviceUiErrorBanner(
                message: connector.deviceUiError!,
                onDismiss: connector.clearDeviceUiError,
              ),
            if (showScope) ...[
              const _SectionHeader('Device notification scope'),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Controls whether this radio\'s buzzer sounds. This is '
                  'separate from per-channel notifications, which control '
                  'whether this app notifies you.',
                ),
              ),
              ..._scopeTiles(connector),
              // The badge's Tones screen, in its order: the scope gates every
              // tone below it (#986, #970). Needs the tune engine, 0x10.
              if (connector.supportsTunes) ...[
                const _SectionHeader('Tones'),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text('What this radio plays for each event.'),
                ),
                ..._eventToneTiles(connector),
                const _SectionHeader('Custom tunes'),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Eight tunes stored on this radio, in RTTTL. A saved tune '
                    'can be picked for any event or channel.',
                  ),
                ),
                ..._slotTiles(connector),
              ],
            ],
            if (showButtons) ...[
              const _SectionHeader('Button actions'),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Assign what each button press does. Long press is reserved '
                  'by the firmware for CLI rescue and power off, so it cannot '
                  'be reassigned.',
                ),
              ),
              ..._buttonTiles(connector),
            ],
          ],
        );
      },
    );
  }

  List<Widget> _scopeTiles(MeshCoreConnector connector) {
    final current = connector.deviceNotifyScope;
    if (current == null) {
      return [
        const ListTile(
          leading: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text('Reading scope from the radio'),
        ),
      ];
    }
    // Plain ListTiles rather than RadioListTile: the Radio group API is
    // deprecated in this Flutter version and the replacement needs a
    // RadioGroup ancestor, which buys nothing for three mutually exclusive
    // rows.
    return DeviceNotifyScope.values
        .map(
          (scope) => ListTile(
            leading: Icon(
              scope == current
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: scope == current
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            title: Text(scope.label),
            subtitle: Text(scope.description),
            selected: scope == current,
            onTap: () => connector.setNotifyScope(scope),
          ),
        )
        .toList();
  }

  /// The six events, each naming the tune that plays. "(radio default)" marks
  /// one nobody has chosen, so a choice and a default never look alike.
  List<Widget> _eventToneTiles(MeshCoreConnector connector) {
    return ToneEvent.values.map((event) {
      final state = connector.eventTone(event);
      if (state == null) {
        return ListTile(
          leading: const Icon(Icons.music_note_outlined),
          title: Text(event.label),
          subtitle: const Text('Reading from the radio'),
        );
      }
      final name =
          tuneLabel(state.effective, connector.tuneSlots) ??
          'Tune ${state.effective}';
      return ListTile(
        leading: Icon(tuneIcon(state.effective)),
        title: Text(event.label),
        subtitle: Text(state.isRadioDefault ? '$name (radio default)' : name),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _pickEventTone(connector, event, state),
      );
    }).toList();
  }

  Future<void> _pickEventTone(
    MeshCoreConnector connector,
    ToneEvent event,
    EventToneState state,
  ) async {
    // No Default row: firmware refuses 0xFF on an event, as the badge's own
    // picker offers none (owner decision 2026-10-25).
    final choice = await showTunePickerDialog(
      context,
      title: '${event.label} tone',
      description: event == ToneEvent.dm
          ? 'Plays for every direct message.'
          : null,
      current: state.effective,
    );
    if (choice is TuneIdChoice) await connector.setEventTone(event, choice.id);
  }

  /// All eight slots, as the badge lists them: an empty slot is where you go
  /// to fill one, so it is a row too.
  List<Widget> _slotTiles(MeshCoreConnector connector) {
    return [
      for (var slot = 0; slot < tuneSlotCount; slot++)
        _slotTile(connector, slot, connector.tuneSlots[slot]),
    ];
  }

  Widget _slotTile(MeshCoreConnector connector, int slot, TuneSlotInfo? info) {
    final number = slot + 1;
    if (info == null) {
      return ListTile(
        leading: const Icon(Icons.music_note_outlined),
        title: Text('$number'),
        subtitle: const Text('Reading from the radio'),
      );
    }
    void open() => Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TuneSlotEditorScreen(slot: slot, info: info),
      ),
    );
    if (info.isEmpty) {
      return ListTile(
        leading: const Icon(Icons.add_circle_outline),
        title: Text('$number (empty)'),
        subtitle: const Text('Tap to add a tune'),
        onTap: open,
      );
    }
    final name = info.name.isEmpty ? 'Slot $number' : info.name;
    return ListTile(
      leading: const Icon(Icons.music_note_outlined),
      title: Text('$number $name'),
      subtitle: Text('${info.length} characters'),
      trailing: IconButton(
        icon: const Icon(Icons.play_circle_outline),
        color: Theme.of(context).colorScheme.primary,
        tooltip: 'Play on the radio',
        onPressed: () => _play(connector, slotTuneId(slot)),
      ),
      onTap: open,
    );
  }

  Future<void> _play(MeshCoreConnector connector, int id) async {
    final messenger = ScaffoldMessenger.of(context);
    final note = describeTunePlay(await connector.playTune(id));
    if (note == null) return;
    // Stays until OK: an explanation the user cannot finish reading is not
    // one.
    messenger.showSnackBar(
      SnackBar(
        content: Text(note),
        duration: const Duration(days: 1),
        action: SnackBarAction(label: 'OK', onPressed: () {}),
      ),
    );
  }

  List<Widget> _buttonTiles(MeshCoreConnector connector) {
    final matrix = connector.buttonMatrix;
    if (matrix == null) {
      return [
        const ListTile(
          leading: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text('Reading button configuration from the radio'),
        ),
      ];
    }
    // Only actions the radio said it can perform are offered, so a board with
    // no buzzer or no GPS never shows a choice it would reject. (#474)
    final actions = matrix.availableActions;
    return ButtonSequence.values.map((seq) {
      final assigned = matrix.assignments[seq] ?? ButtonAction.none;
      return ListTile(
        title: Text(seq.label),
        subtitle: Text(assigned.label),
        trailing: DropdownButton<ButtonAction>(
          value: actions.contains(assigned) ? assigned : ButtonAction.none,
          onChanged: (value) {
            if (value != null) connector.setButtonAction(seq, value);
          },
          items: actions
              .map(
                (a) => DropdownMenuItem<ButtonAction>(
                  value: a,
                  child: Text(a.label),
                ),
              )
              .toList(),
        ),
      );
    }).toList();
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}
