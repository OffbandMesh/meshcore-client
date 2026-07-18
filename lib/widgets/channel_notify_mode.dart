import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/app_settings.dart';
import '../models/channel.dart';
import '../services/app_settings_service.dart';

/// Shared per-channel notify-mode affordance (#262), reachable both from the
/// Channels list and from inside a channel's chat (#275). Single implementation
/// so the two entry points cannot drift.

/// Notify-mode storage key for [channel]: its PSK identity, so the setting
/// survives a rename and does not follow a reused slot (#259).
String channelNotifyKeyFor(Channel channel) => AppSettings.channelNotifyKey(
  channelIndex: channel.index,
  pskHex: channel.pskHex,
);

IconData channelNotifyModeIcon(ChannelNotifyMode mode) {
  switch (mode) {
    case ChannelNotifyMode.all:
      return Icons.notifications_outlined;
    case ChannelNotifyMode.mentionsOnly:
      return Icons.alternate_email;
    case ChannelNotifyMode.off:
      return Icons.notifications_off_outlined;
  }
}

String channelNotifyModeLabel(BuildContext context, ChannelNotifyMode mode) {
  switch (mode) {
    case ChannelNotifyMode.all:
      return context.l10n.channels_notifyAll;
    case ChannelNotifyMode.mentionsOnly:
      return context.l10n.channels_notifyMentionsOnly;
    case ChannelNotifyMode.off:
      return context.l10n.channels_notifyOff;
  }
}

void showChannelNotifyModeDialog(BuildContext context, Channel channel) {
  final settingsService = context.read<AppSettingsService>();
  final identityKey = channelNotifyKeyFor(channel);
  final current = settingsService.channelNotifyMode(
    identityKey: identityKey,
    channelName: channel.name,
  );

  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(dialogContext.l10n.channels_notifications),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final mode in ChannelNotifyMode.values)
            ListTile(
              leading: Icon(channelNotifyModeIcon(mode)),
              title: Text(channelNotifyModeLabel(dialogContext, mode)),
              trailing: mode == current ? const Icon(Icons.check) : null,
              onTap: () async {
                Navigator.pop(dialogContext);
                await settingsService.setChannelNotifyMode(
                  identityKey: identityKey,
                  channelName: channel.name,
                  mode: mode,
                );
              },
            ),
        ],
      ),
    ),
  );
}
