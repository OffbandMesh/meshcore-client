import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../connector/meshcore_connector.dart';
import '../l10n/l10n.dart';
import '../models/channel.dart';
import '../models/community.dart';
import '../storage/community_store.dart';
import '../widgets/adaptive_app_bar_title.dart';
import '../widgets/qr_scanner_widget.dart';
import '../helpers/channel_slot_ui.dart';
import '../helpers/snack_bar_builder.dart';

/// Screen for scanning community QR codes to join communities.
///
/// After successful scan, the user can:
/// 1. Join the community (saves to local storage)
/// 2. Optionally add the Community Public Channel to the device
class CommunityQrScannerScreen extends StatefulWidget {
  const CommunityQrScannerScreen({super.key});

  @override
  State<CommunityQrScannerScreen> createState() =>
      _CommunityQrScannerScreenState();
}

class _CommunityQrScannerScreenState extends State<CommunityQrScannerScreen> {
  final CommunityStore _communityStore = CommunityStore();
  bool _isProcessing = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: AdaptiveAppBarTitle(context.l10n.channels_scanQr),
        centerTitle: true,
      ),
      body: _isProcessing
          ? const Center(child: CircularProgressIndicator())
          : QrScannerWidget(
              onScanned: (data) => _handleScannedData(context, data),
              validator: (data) =>
                  Community.isValidQrData(data) ||
                  Channel.isValidShareUri(data),
              onValidationFailed: (_) => _showInvalidQrError(context),
              instructions: context.l10n.channels_scanQrInstructions,
            ),
    );
  }

  Future<void> _handleScannedData(BuildContext context, String data) async {
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
    });

    final connector = context.read<MeshCoreConnector>();
    _communityStore.setPublicKeyHex = connector.selfPublicKeyHex;

    try {
      // A channel share URI (meshcore://channel/add) is handled separately
      // from community QR JSON. (#161)
      if (Channel.isValidShareUri(data)) {
        await _handleChannelUri(context, data);
        return;
      }
      // Parse the community data
      final community = Community.fromQrData(const Uuid().v4(), data);

      // Check if this community already exists
      final existing = await _communityStore.findByCommunityId(
        community.communityId,
      );

      if (existing != null) {
        if (context.mounted) {
          _showAlreadyMemberDialog(context, existing);
        }
        return;
      }

      // Show confirmation dialog
      if (context.mounted) {
        await _showJoinConfirmationDialog(context, community);
      }
    } catch (e) {
      if (context.mounted) {
        showDismissibleSnackBar(
          context,
          content: Text(context.l10n.community_invalidQrCode),
          backgroundColor: Colors.red,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  void _showInvalidQrError(BuildContext context) {
    showDismissibleSnackBar(
      context,
      content: Text(context.l10n.community_invalidQrCode),
      backgroundColor: Colors.orange,
      duration: const Duration(seconds: 2),
    );
  }

  void _showAlreadyMemberDialog(BuildContext context, Community community) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.community_alreadyMember),
        content: Text(
          context.l10n.community_alreadyMemberMessage(community.name),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              Navigator.pop(context);
            },
            child: Text(context.l10n.common_ok),
          ),
        ],
      ),
    );
  }

  Future<void> _showJoinConfirmationDialog(
    BuildContext context,
    Community community,
  ) async {
    bool addPublicChannel = true;

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(context.l10n.community_joinTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.community_joinConfirmation(community.name)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(
                    Icons.groups,
                    color: Theme.of(dialogContext).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          community.name,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'ID: ${community.shortCommunityId}...',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: addPublicChannel,
                onChanged: (value) {
                  setDialogState(() {
                    addPublicChannel = value ?? true;
                  });
                },
                title: Text(context.l10n.community_addPublicChannel),
                subtitle: Text(context.l10n.community_addPublicChannelHint),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(context.l10n.common_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(context.l10n.community_join),
            ),
          ],
        ),
      ),
    );

    if (result == true && context.mounted) {
      await _joinCommunity(context, community, addPublicChannel);
    } else if (context.mounted) {
      // User cancelled - go back
      Navigator.pop(context);
    }
  }

  Future<void> _joinCommunity(
    BuildContext context,
    Community community,
    bool addPublicChannel,
  ) async {
    // Save community to local storage
    final connector = context.read<MeshCoreConnector>();
    _communityStore.setPublicKeyHex = connector.selfPublicKeyHex;
    await _communityStore.addCommunity(community);

    // Optionally add the community public channel to the device. The
    // community is already saved above, so a refused slot only skips the
    // channel; it never loses the community.
    //
    // This used to skip the channel silently when the radio was full and then
    // show a green "joined" toast, which told the user everything had worked
    // when the channel had not been added (#1021). A refusal, or a write the
    // radio did not confirm (#1026), now explains itself, and only a confirmed
    // write shows the green confirmation.
    var channelRefused = false;
    if (addPublicChannel && context.mounted) {
      final connector = context.read<MeshCoreConnector>();
      final psk = community.deriveCommunityPublicPsk();
      final slot = allocateChannelSlotOrExplain(context, connector, psk: psk);
      if (slot == null) {
        channelRefused = true;
      } else {
        final channelName = '${community.name} Public';
        final result = await connector.setChannel(slot, channelName, psk);
        if (context.mounted) {
          channelRefused = explainUnconfirmedChannelWrite(context, result);
        }
      }
    }

    if (context.mounted) {
      // The refusal message is already showing and persists; a green toast
      // on top of it would contradict it.
      if (!channelRefused) {
        showDismissibleSnackBar(
          context,
          content: Text(context.l10n.community_joined(community.name)),
          backgroundColor: Colors.green,
        );
      }

      // Return to previous screen
      Navigator.pop(context, community);
    }
  }

  Future<void> _handleChannelUri(BuildContext context, String data) async {
    final channel = Channel.fromShareUri(data);
    if (channel == null) {
      if (context.mounted) {
        showDismissibleSnackBar(
          context,
          content: Text(context.l10n.channels_invalidQr),
          backgroundColor: Colors.red,
        );
      }
      return;
    }
    final connector = context.read<MeshCoreConnector>();
    if (connector.channels.any((c) => c.pskHex == channel.pskHex)) {
      if (context.mounted) {
        showDismissibleSnackBar(
          context,
          content: Text(context.l10n.channels_qrExists(channel.name)),
        );
        Navigator.pop(context);
      }
      return;
    }
    // No slot is chosen here. It used to be, and that is the same bug the
    // channels screen had: the index was picked before the confirmation
    // dialog below and written after it, so a channel sync during the
    // confirmation (a channel write starts one) could leave it pointing at
    // an occupied slot. The slot is now chosen after the user confirms.
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.channels_scanQr),
        content: Text(context.l10n.channels_qrAddConfirm(channel.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.common_add),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      final slot = allocateChannelSlotOrExplain(
        context,
        connector,
        psk: channel.psk,
      );
      // Refused: the persistent message explains why. Stay on this screen so
      // the user can retry, rather than popping away from the explanation.
      if (slot == null) return;
      final result = await connector.setChannel(
        slot,
        channel.name,
        channel.psk,
      );
      if (!context.mounted) return;
      // Not confirmed: stay on this screen with the explanation showing.
      if (explainUnconfirmedChannelWrite(context, result)) return;
      showDismissibleSnackBar(
        context,
        content: Text(context.l10n.channels_qrAdded(channel.name)),
        backgroundColor: Colors.green,
      );
      Navigator.pop(context);
    } else if (context.mounted) {
      Navigator.pop(context);
    }
  }
}
