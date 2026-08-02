import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../connector/meshcore_connector.dart';
import '../../connector/offband_device_ui.dart';

/// Settings for a headless device's physical UI: the button-action matrix
/// (#474) and the device notification scope (#475).
///
/// The whole pane is capability-gated. A radio that does not advertise the bit
/// gets no screen and never sees the command, so stock and older firmware
/// degrade silently with nothing shown and no error.
///
/// English-only for now, matching the serial-capture pane (#430); localization
/// is a follow-up rather than a blocker on shipping the capability.
class DeviceUiView extends StatefulWidget {
  const DeviceUiView({super.key});

  @override
  State<DeviceUiView> createState() => _DeviceUiViewState();
}

class _DeviceUiViewState extends State<DeviceUiView> {
  @override
  void initState() {
    super.initState();
    // Re-read on open as well as on device-info: the user may have changed the
    // scope by triple-pressing the device since the last refresh.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = context.read<MeshCoreConnector>();
      c.requestButtonMatrix();
      c.requestNotifyScope();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MeshCoreConnector>(
      builder: (context, connector, _) {
        final showButtons = connector.supportsButtonMatrix;
        final showScope = connector.supportsNotifyScope;
        // A radio that advertises nothing gets a diagnosis, not a blank screen.
        // Silence used to be indistinguishable from a broken client, which is
        // exactly the failure this pane is meant to make visible.
        if (!showButtons && !showScope) {
          final caps2 = connector.offbandCaps2;
          return ListView(
            children: [
              const _SectionHeader('Not advertised by this radio'),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  caps2 == null
                      ? 'This radio sends no capability byte 2 at all, which '
                            'means its firmware predates the feature. Nothing '
                            'is wrong with the app; the radio needs newer '
                            'firmware.'
                      : 'This radio sends capability byte 2 as 0x'
                            '${caps2.toRadixString(16).padLeft(2, '0')}, with '
                            'neither the notification-scope bit (0x01) nor the '
                            'button-matrix bit (0x02) set. Its firmware knows '
                            'about byte 2 but does not claim these features, '
                            'for example a board with no buzzer.',
                ),
              ),
              ListTile(
                leading: const Icon(Icons.memory_outlined),
                title: const Text('Capability byte 2'),
                subtitle: Text(
                  caps2 == null
                      ? 'absent (frame shorter than 85 bytes)'
                      : '0x${caps2.toRadixString(16).padLeft(2, '0')}',
                ),
              ),
              const ListTile(
                leading: Icon(Icons.block_outlined),
                title: Text('No command will be sent'),
                subtitle: Text(
                  'The app never emits this command to a radio that has not '
                  'advertised support for it.',
                ),
              ),
            ],
          );
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
            if (connector.deviceUiError != null)
              _ErrorBanner(
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
              const Divider(height: 24),
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

/// Persistent error banner. Stays until dismissed rather than flashing, per the
/// error-visibility rule: an error the user cannot finish reading is not a
/// surfaced error.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, color: scheme.onErrorContainer),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
