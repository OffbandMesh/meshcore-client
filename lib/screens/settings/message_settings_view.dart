import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/app_settings_service.dart';
import '../../services/notification_service.dart';
import '../../helpers/snack_bar_builder.dart';

/// Embeddable view (no Scaffold) for the Message Settings shell pane.
///
/// Renders notification toggles and message-handling settings. Both cards read
/// and write only [AppSettingsService].
class MessageSettingsView extends StatelessWidget {
  const MessageSettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppSettingsService>(
      builder: (context, settingsService, child) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildNotificationsCard(context, settingsService),
            const SizedBox(height: 16),
            _buildMessagingCard(context, settingsService),
          ],
        );
      },
    );
  }

  Widget _buildNotificationsCard(
    BuildContext context,
    AppSettingsService settingsService,
  ) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              context.l10n.appSettings_notifications,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_outlined),
            title: Text(context.l10n.appSettings_enableNotifications),
            subtitle: Text(
              context.l10n.appSettings_enableNotificationsSubtitle,
            ),
            value: settingsService.settings.notificationsEnabled,
            onChanged: (value) async {
              if (value) {
                // Request permission when enabling
                final granted = await NotificationService()
                    .requestPermissions();
                if (!granted) {
                  if (context.mounted) {
                    showDismissibleSnackBar(
                      context,
                      content: Text(
                        context.l10n.appSettings_notificationPermissionDenied,
                      ),
                      duration: const Duration(seconds: 2),
                    );
                  }
                  return;
                }
              }

              await settingsService.setNotificationsEnabled(value);
              if (context.mounted) {
                showDismissibleSnackBar(
                  context,
                  content: Text(
                    value
                        ? context.l10n.appSettings_notificationsEnabled
                        : context.l10n.appSettings_notificationsDisabled,
                  ),
                  duration: const Duration(seconds: 2),
                );
              }
            },
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: Icon(
              Icons.message_outlined,
              color: settingsService.settings.notificationsEnabled
                  ? null
                  : Colors.grey,
            ),
            title: Text(
              context.l10n.appSettings_messageNotifications,
              style: TextStyle(
                color: settingsService.settings.notificationsEnabled
                    ? null
                    : Colors.grey,
              ),
            ),
            subtitle: Text(
              context.l10n.appSettings_messageNotificationsSubtitle,
              style: TextStyle(
                color: settingsService.settings.notificationsEnabled
                    ? null
                    : Colors.grey,
              ),
            ),
            value: settingsService.settings.notifyOnNewMessage,
            onChanged: settingsService.settings.notificationsEnabled
                ? (value) {
                    settingsService.setNotifyOnNewMessage(value);
                  }
                : null,
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: Icon(
              Icons.forum_outlined,
              color: settingsService.settings.notificationsEnabled
                  ? null
                  : Colors.grey,
            ),
            title: Text(
              context.l10n.appSettings_channelMessageNotifications,
              style: TextStyle(
                color: settingsService.settings.notificationsEnabled
                    ? null
                    : Colors.grey,
              ),
            ),
            subtitle: Text(
              context.l10n.appSettings_channelMessageNotificationsSubtitle,
              style: TextStyle(
                color: settingsService.settings.notificationsEnabled
                    ? null
                    : Colors.grey,
              ),
            ),
            value: settingsService.settings.notifyOnNewChannelMessage,
            onChanged: settingsService.settings.notificationsEnabled
                ? (value) {
                    settingsService.setNotifyOnNewChannelMessage(value);
                  }
                : null,
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: Icon(
              Icons.cell_tower,
              color: settingsService.settings.notificationsEnabled
                  ? null
                  : Colors.grey,
            ),
            title: Text(
              context.l10n.appSettings_advertisementNotifications,
              style: TextStyle(
                color: settingsService.settings.notificationsEnabled
                    ? null
                    : Colors.grey,
              ),
            ),
            subtitle: Text(
              context.l10n.appSettings_advertisementNotificationsSubtitle,
              style: TextStyle(
                color: settingsService.settings.notificationsEnabled
                    ? null
                    : Colors.grey,
              ),
            ),
            value: settingsService.settings.notifyOnNewAdvert,
            onChanged: settingsService.settings.notificationsEnabled
                ? (value) {
                    settingsService.setNotifyOnNewAdvert(value);
                  }
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildMessagingCard(
    BuildContext context,
    AppSettingsService settingsService,
  ) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              context.l10n.appSettings_messaging,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.refresh_outlined),
            title: Text(context.l10n.appSettings_clearPathOnMaxRetry),
            subtitle: Text(
              context.l10n.appSettings_clearPathOnMaxRetrySubtitle,
            ),
            value: settingsService.settings.clearPathOnMaxRetry,
            onChanged: (value) {
              settingsService.setClearPathOnMaxRetry(value);
              showDismissibleSnackBar(
                context,
                content: Text(
                  value
                      ? context.l10n.appSettings_pathsWillBeCleared
                      : context.l10n.appSettings_pathsWillNotBeCleared,
                ),
                duration: const Duration(seconds: 2),
              );
            },
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.vertical_align_top),
            title: Text(context.l10n.appSettings_jumpToOldestUnread),
            subtitle: Text(context.l10n.appSettings_jumpToOldestUnreadSubtitle),
            value: settingsService.settings.jumpToOldestUnread,
            onChanged: settingsService.setJumpToOldestUnread,
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.alt_route),
            title: Text(context.l10n.appSettings_autoRouteRotation),
            subtitle: Text(context.l10n.appSettings_autoRouteRotationSubtitle),
            value: settingsService.settings.autoRouteRotationEnabled,
            onChanged: (value) {
              settingsService.setAutoRouteRotationEnabled(value);
              showDismissibleSnackBar(
                context,
                content: Text(
                  value
                      ? context.l10n.appSettings_autoRouteRotationEnabled
                      : context.l10n.appSettings_autoRouteRotationDisabled,
                ),
                duration: const Duration(seconds: 2),
              );
            },
          ),
          if (settingsService.settings.autoRouteRotationEnabled) ...[
            const Divider(height: 1),
            ListTile(
              title: Text(context.l10n.appSettings_maxRouteWeight),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.l10n.appSettings_maxRouteWeightSubtitle),
                  Slider(
                    value: settingsService.settings.maxRouteWeight,
                    min: 1,
                    max: 10,
                    divisions: 9,
                    label: settingsService.settings.maxRouteWeight
                        .round()
                        .toString(),
                    onChanged: (value) =>
                        settingsService.setMaxRouteWeight(value),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              title: Text(context.l10n.appSettings_initialRouteWeight),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.l10n.appSettings_initialRouteWeightSubtitle),
                  Slider(
                    value: settingsService.settings.initialRouteWeight,
                    min: 0.5,
                    max: 5.0,
                    divisions: 9,
                    label: settingsService.settings.initialRouteWeight
                        .toStringAsFixed(1),
                    onChanged: (value) =>
                        settingsService.setInitialRouteWeight(value),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              title: Text(context.l10n.appSettings_routeWeightSuccessIncrement),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context
                        .l10n
                        .appSettings_routeWeightSuccessIncrementSubtitle,
                  ),
                  Slider(
                    value: settingsService.settings.routeWeightSuccessIncrement,
                    min: 0.1,
                    max: 2.0,
                    divisions: 19,
                    label: settingsService.settings.routeWeightSuccessIncrement
                        .toStringAsFixed(1),
                    onChanged: (value) =>
                        settingsService.setRouteWeightSuccessIncrement(value),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              title: Text(context.l10n.appSettings_routeWeightFailureDecrement),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context
                        .l10n
                        .appSettings_routeWeightFailureDecrementSubtitle,
                  ),
                  Slider(
                    value: settingsService.settings.routeWeightFailureDecrement,
                    min: 0.1,
                    max: 2.0,
                    divisions: 19,
                    label: settingsService.settings.routeWeightFailureDecrement
                        .toStringAsFixed(1),
                    onChanged: (value) =>
                        settingsService.setRouteWeightFailureDecrement(value),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              title: Text(context.l10n.appSettings_maxMessageRetries),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.l10n.appSettings_maxMessageRetriesSubtitle),
                  Slider(
                    value: settingsService.settings.maxMessageRetries
                        .toDouble(),
                    min: 2,
                    max: 10,
                    divisions: 8,
                    label: settingsService.settings.maxMessageRetries
                        .toString(),
                    onChanged: (value) =>
                        settingsService.setMaxMessageRetries(value.toInt()),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
