import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/offband_channel_notify.dart';
import '../connector/offband_device_ui.dart';
import '../l10n/l10n.dart';
import '../models/channel.dart';

/// The RADIO's per-channel sound setting (#544).
///
/// Deliberately a separate control from the app's per-channel notification
/// setting in `channel_notify_mode.dart`: that one decides whether the PHONE
/// notifies, this one decides whether the RADIO beeps, and neither reads the
/// other (owner, 2026-11-03). Do not merge them, and do not resolve one from
/// the other.

IconData radioChannelNotifyIcon(RadioChannelNotify mode) {
  switch (mode) {
    case RadioChannelNotify.all:
      return Icons.volume_up_outlined;
    case RadioChannelNotify.mentions:
      return Icons.alternate_email;
    case RadioChannelNotify.off:
      return Icons.volume_off_outlined;
    case RadioChannelNotify.unset:
      return Icons.settings_backup_restore;
  }
}

String radioChannelNotifyLabel(BuildContext context, RadioChannelNotify mode) {
  switch (mode) {
    case RadioChannelNotify.all:
      return context.l10n.channels_notifyAll;
    case RadioChannelNotify.mentions:
      return context.l10n.channels_notifyMentionsOnly;
    case RadioChannelNotify.off:
      return context.l10n.channels_notifyOff;
    case RadioChannelNotify.unset:
      return context.l10n.channels_radioSoundUnset;
  }
}

/// What this channel will ACTUALLY do on the radio, which is not always the
/// stored byte (#544 C3, owner's call 2026-11-03).
///
/// The radio's rules, per firmware: a channel with a mode set decides for
/// itself; a channel with no mode falls back to the device-wide scope; and a
/// device scope of None overrides even a channel that is set. Showing the raw
/// mode would tell a user with the radio muted that a channel is on "All
/// messages" while it sits silent.
///
/// Null when the composition cannot be known: the mode has not been read, or
/// it is unset and the device scope has not been read either. A caller must
/// show "reading", never a guess.
String? radioChannelNotifyEffective(
  BuildContext context,
  RadioChannelNotify? mode,
  DeviceNotifyScope? scope,
) {
  if (mode == null) return null;
  if (scope == DeviceNotifyScope.none) {
    return context.l10n.channels_radioSoundMutedByRadio;
  }
  if (mode != RadioChannelNotify.unset) {
    return radioChannelNotifyLabel(context, mode);
  }
  if (scope == null) return null;
  return context.l10n.channels_radioSoundFollows(scope.label);
}

/// Whether this radio can be offered the control at all. The app's own
/// per-channel setting is never gated on this.
bool radioChannelNotifySupported(MeshCoreConnector connector) =>
    connector.supportsChannelNotify;

void showRadioChannelNotifyDialog(BuildContext context, Channel channel) {
  final connector = context.read<MeshCoreConnector>();

  showDialog<void>(
    context: context,
    builder: (dialogContext) => Consumer<MeshCoreConnector>(
      builder: (consumerContext, live, _) {
        // State follows the radio's reply, never the tap: until the radio has
        // answered for this slot there is no current value to tick, and a
        // write that it refuses never appears as saved.
        final current = live.channelNotifyFor(channel);
        final error = live.deviceUiErrorSurface == DeviceUiSurface.channelNotify
            ? live.deviceUiError
            : null;

        return AlertDialog(
          title: Text(consumerContext.l10n.channels_radioSound),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(consumerContext).colorScheme.error,
                    ),
                  ),
                ),
              if (current == null)
                ListTile(
                  leading: const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  title: Text(consumerContext.l10n.channels_radioSoundReading),
                ),
              for (final mode in RadioChannelNotify.values)
                ListTile(
                  leading: Icon(radioChannelNotifyIcon(mode)),
                  title: Text(radioChannelNotifyLabel(consumerContext, mode)),
                  subtitle: mode == RadioChannelNotify.unset
                      ? Text(
                          radioChannelNotifyEffective(
                                consumerContext,
                                RadioChannelNotify.unset,
                                live.deviceNotifyScope,
                              ) ??
                              consumerContext.l10n.channels_radioSoundReading,
                        )
                      : null,
                  trailing: mode == current ? const Icon(Icons.check) : null,
                  onTap: () async {
                    Navigator.pop(dialogContext);
                    await connector.setChannelNotify(channel, mode);
                  },
                ),
            ],
          ),
        );
      },
    ),
  );
}
