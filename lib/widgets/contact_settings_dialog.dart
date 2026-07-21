import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../models/contact.dart';
import '../services/app_settings_service.dart';

/// The per-contact settings dialog (Smaz/Cyr2Lat compression + telemetry
/// grants). Shared so it can be opened from the chat ellipsis AND the contacts
/// long-press menu without duplicating the body (#351).
void showContactSettingsDialog(BuildContext context, Contact contact) {
  final connector = Provider.of<MeshCoreConnector>(context, listen: false);
  final appSettingsService = Provider.of<AppSettingsService>(
    context,
    listen: false,
  );
  connector.ensureContactSmazSettingLoaded(contact.publicKeyHex);
  connector.ensureContactCyr2LatSettingLoaded(contact.publicKeyHex);
  bool smazEnabled = connector.isContactSmazEnabled(contact.publicKeyHex);
  bool cyr2latEnabled = connector.isContactCyr2LatEnabled(contact.publicKeyHex);
  String? selectedCyr2LatProfileId = connector.getContactCyr2LatProfileId(
    contact.publicKeyHex,
  );
  bool teleBaseEnabled = contact.teleBaseEnabled;
  bool teleLocEnabled = contact.teleLocEnabled;
  bool teleEnvEnabled = contact.teleEnvEnabled;
  showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(context.l10n.contact_settings),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (contact.hasLocation) ...[
                _infoRow(
                  context.l10n.chat_location,
                  '${contact.latitude?.toStringAsFixed(4)}, ${contact.longitude?.toStringAsFixed(4)}',
                ),
                const Divider(height: 8),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.channels_smazCompression),
                subtitle: Text(context.l10n.chat_compressOutgoingMessages),
                value: smazEnabled,
                onChanged: (value) {
                  connector.setContactSmazEnabled(contact.publicKeyHex, value);
                  connector.setContactCyr2LatEnabled(
                    contact.publicKeyHex,
                    false,
                  );
                  setDialogState(() {
                    smazEnabled = value;
                    if (smazEnabled) {
                      cyr2latEnabled = false;
                    }
                  });
                },
              ),
              const Divider(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.channels_cyr2latCompression),
                subtitle: Text(context.l10n.channels_cyr2latCompressionDscr),
                value: cyr2latEnabled,
                onChanged: (value) {
                  connector.setContactCyr2LatEnabled(
                    contact.publicKeyHex,
                    value,
                  );
                  connector.setContactSmazEnabled(contact.publicKeyHex, false);
                  setDialogState(() {
                    cyr2latEnabled = value;
                    if (cyr2latEnabled) {
                      smazEnabled = false;
                    }
                  });
                },
              ),
              if (cyr2latEnabled) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
                  child: DropdownButtonFormField<String>(
                    initialValue: selectedCyr2LatProfileId,
                    decoration: InputDecoration(
                      labelText:
                          context.l10n.channels_cyr2latSettingsSubheading,
                      border: const OutlineInputBorder(),
                    ),
                    items: appSettingsService.settings.cyr2latProfiles.map((
                      profile,
                    ) {
                      return DropdownMenuItem(
                        value: profile.id,
                        child: Text(profile.name),
                      );
                    }).toList(),
                    onChanged: (value) {
                      connector.setContactCyr2LatProfileId(
                        contact.publicKeyHex,
                        value,
                      );
                      setDialogState(() {
                        selectedCyr2LatProfileId = value;
                      });
                    },
                  ),
                ),
              ],
              const Divider(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.contact_teleBase),
                subtitle: Text(context.l10n.contact_teleBaseSubtitle),
                value: teleBaseEnabled,
                onChanged: (value) {
                  setDialogState(() => teleBaseEnabled = value);
                },
              ),
              const Divider(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.contact_teleLoc),
                subtitle: Text(context.l10n.contact_teleLocSubtitle),
                value: teleLocEnabled,
                onChanged: (value) {
                  setDialogState(() => teleLocEnabled = value);
                },
              ),
              const Divider(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(context.l10n.contact_teleEnv),
                subtitle: Text(context.l10n.contact_teleEnvSubtitle),
                value: teleEnvEnabled,
                onChanged: (value) {
                  setDialogState(() => teleEnvEnabled = value);
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              connector.setContactFlags(
                contact,
                teleBase: teleBaseEnabled,
                teleLoc: teleLocEnabled,
                teleEnv: teleEnvEnabled,
              );
              Navigator.pop(context);
            },
            child: Text(context.l10n.common_close),
          ),
        ],
      ),
    ),
  );
}

Widget _infoRow(String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(label, style: TextStyle(color: Colors.grey[600])),
        ),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}
