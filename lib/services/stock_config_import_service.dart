/// Applies a stock-compatible config file to the connected device (#575,
/// epic #568).
///
/// Merge semantics deliberately match the stock app, which states them on its
/// own Import Config screen:
///
/// * **Contacts**: "New contacts will be added. Existing contacts will be
///   updated." An upsert keyed on public key. Nothing is ever deleted.
/// * **Channels**: "New channels will be added. Existing channels will not
///   change." Purely additive, so a rotated PSK for a channel the user already
///   has does not apply.
/// * **Identity**: "Importing this private key will overwrite your current
///   identity." Destructive, and the caller must have confirmed with the user.
///
/// We match that behavior but not stock's silence about it: anything skipped
/// comes back in [StockConfigImportResult] so the UI can name it. A channel
/// that quietly failed to import is exactly the kind of silent no-op SAFELANE
/// section 6 forbids.
library;

import 'dart:typed_data';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../models/channel.dart';
import '../models/stock_config.dart';
import 'stock_config_export_service.dart' show StockConfigSection;

/// Why a section or a single channel was not applied.
enum StockConfigImportIssue {
  /// The file did not contain this section.
  absentFromFile,

  /// The device is not connected, or did not answer.
  noReply,

  /// The radio's firmware was built without the feature.
  unsupported,

  /// The device refused the request.
  rejected,

  /// The device already has this channel, and stock's rule is that existing
  /// channels are never overwritten.
  alreadyPresent,

  /// Every channel slot on the device is occupied.
  noFreeSlot,

  /// We have no supported way to write this value to the device.
  notWritable,
}

/// A channel present in the file that did not land on the device.
class SkippedChannel {
  const SkippedChannel(this.name, this.reason);

  final String name;
  final StockConfigImportIssue reason;
}

class StockConfigImportResult {
  const StockConfigImportResult({
    required this.applied,
    required this.failed,
    required this.skippedChannels,
    required this.contactsWritten,
    required this.channelsAdded,
  });

  final Set<StockConfigSection> applied;
  final Map<StockConfigSection, StockConfigImportIssue> failed;

  /// Channels in the file that were not written, each with a reason. Shown to
  /// the user; never discarded.
  final List<SkippedChannel> skippedChannels;

  final int contactsWritten;
  final int channelsAdded;

  bool get isComplete => failed.isEmpty && skippedChannels.isEmpty;
}

class StockConfigImportService {
  StockConfigImportService(this._connector);

  final MeshCoreConnector _connector;

  /// Applies the selected [sections] of [config] to the device.
  ///
  /// [StockConfigSection.identity] is destructive and is only applied when the
  /// caller includes it; confirming that with the user is the UI's job.
  Future<StockConfigImportResult> apply({
    required StockConfig config,
    required Set<StockConfigSection> sections,
  }) async {
    final applied = <StockConfigSection>{};
    final failed = <StockConfigSection, StockConfigImportIssue>{};
    final skippedChannels = <SkippedChannel>[];
    var contactsWritten = 0;
    var channelsAdded = 0;

    if (!_connector.isConnected) {
      return StockConfigImportResult(
        applied: const {},
        failed: {for (final s in sections) s: StockConfigImportIssue.noReply},
        skippedChannels: const [],
        contactsWritten: 0,
        channelsAdded: 0,
      );
    }

    if (sections.contains(StockConfigSection.name)) {
      final name = config.name;
      if (name == null) {
        failed[StockConfigSection.name] = StockConfigImportIssue.absentFromFile;
      } else {
        await _connector.setNodeName(name);
        applied.add(StockConfigSection.name);
      }
    }

    if (sections.contains(StockConfigSection.identity)) {
      final identity = config.privateKey;
      if (identity == null) {
        failed[StockConfigSection.identity] =
            StockConfigImportIssue.absentFromFile;
      } else {
        // Destructive: replaces the node's identity outright.
        switch (await _connector.importPrivateKey(identity)) {
          case IdentityTransfer.ok:
            applied.add(StockConfigSection.identity);
          case IdentityTransfer.unsupported:
            failed[StockConfigSection.identity] =
                StockConfigImportIssue.unsupported;
          case IdentityTransfer.rejected:
            failed[StockConfigSection.identity] =
                StockConfigImportIssue.rejected;
          case IdentityTransfer.noReply:
            failed[StockConfigSection.identity] =
                StockConfigImportIssue.noReply;
        }
      }
    }

    if (sections.contains(StockConfigSection.radioSettings)) {
      final radio = config.radioSettings;
      if (radio == null) {
        failed[StockConfigSection.radioSettings] =
            StockConfigImportIssue.absentFromFile;
      } else {
        // The device takes frequency in the same kHz unit the file uses, so
        // this is a straight pass-through. See the note in the export service.
        await _connector.sendFrame(
          buildSetRadioParamsFrame(
            radio.frequencyKhz,
            radio.bandwidthHz,
            radio.spreadingFactor,
            radio.codingRate,
          ),
        );
        applied.add(StockConfigSection.radioSettings);
      }
    }

    if (sections.contains(StockConfigSection.positionSettings)) {
      final position = config.positionSettings;
      if (position == null) {
        failed[StockConfigSection.positionSettings] =
            StockConfigImportIssue.absentFromFile;
      } else {
        await _connector.setNodeLocation(
          lat: position.latitude,
          lon: position.longitude,
        );
        applied.add(StockConfigSection.positionSettings);
      }
    }

    if (sections.contains(StockConfigSection.otherSettings)) {
      final other = config.otherSettings;
      if (other == null) {
        failed[StockConfigSection.otherSettings] =
            StockConfigImportIssue.absentFromFile;
      } else {
        // buildSetOtherParamsFrame deliberately pins the auto-add-contacts
        // byte to disabled, so `manual_add_contacts` from the file cannot be
        // written without changing app-wide behavior. Only the advert location
        // policy is applied, and the section is reported as partially written
        // rather than claimed as done.
        await _connector.sendFrame(
          buildSetOtherParamsFrame(
            (_connector.telemetryModeEnv << 4) |
                (_connector.telemetryModeLoc << 2) |
                _connector.telemetryModeBase,
            other.advertLocationPolicy,
            _connector.multiAcks,
          ),
        );
        failed[StockConfigSection.otherSettings] =
            StockConfigImportIssue.notWritable;
      }
    }

    if (sections.contains(StockConfigSection.autoAddSettings)) {
      final autoAdd = config.autoAddSettings;
      if (autoAdd == null) {
        failed[StockConfigSection.autoAddSettings] =
            StockConfigImportIssue.absentFromFile;
      } else {
        await _connector.sendFrame(
          buildSetAutoAddConfigFrame(
            autoAddChat: autoAdd.autoAddChat,
            autoAddRepeater: autoAdd.autoAddRepeater,
            autoAddRoomServer: autoAdd.autoAddRoomServer,
            autoAddSensor: autoAdd.autoAddSensor,
            overwriteOldest: autoAdd.overwriteOldest,
            maxHops: autoAdd.autoAddMaxHops,
          ),
        );
        applied.add(StockConfigSection.autoAddSettings);
      }
    }

    if (sections.contains(StockConfigSection.channels)) {
      final channels = config.channels;
      if (channels == null) {
        failed[StockConfigSection.channels] =
            StockConfigImportIssue.absentFromFile;
      } else {
        channelsAdded = await _applyChannels(channels, skippedChannels);
        applied.add(StockConfigSection.channels);
      }
    }

    if (sections.contains(StockConfigSection.contacts)) {
      final contacts = config.contacts;
      if (contacts == null) {
        failed[StockConfigSection.contacts] =
            StockConfigImportIssue.absentFromFile;
      } else {
        contactsWritten = await _applyContacts(contacts);
        applied.add(StockConfigSection.contacts);
      }
    }

    return StockConfigImportResult(
      applied: applied,
      failed: failed,
      skippedChannels: skippedChannels,
      contactsWritten: contactsWritten,
      channelsAdded: channelsAdded,
    );
  }

  Future<int> _applyChannels(
    List<StockChannel> incoming,
    List<SkippedChannel> skipped,
  ) async {
    final plan = planChannelImport(
      existing: _connector.channels,
      incoming: incoming,
      maxChannels: _connector.maxChannels,
    );
    for (final assignment in plan.assignments) {
      await _connector.setChannel(
        assignment.slot,
        assignment.channel.name,
        assignment.channel.secret,
      );
    }
    skipped.addAll(plan.skipped);
    return plan.assignments.length;
  }

  /// Upserts every contact. The firmware's add-or-update command keys on the
  /// public key, so an existing contact is updated in place and a new one is
  /// created. Nothing is removed, in either direction.
  Future<int> _applyContacts(List<StockContact> contacts) async {
    var written = 0;
    for (final contact in contacts) {
      final path = contact.outPath;
      final hasPosition = contact.latitude != 0 || contact.longitude != 0;
      await _connector.sendFrame(
        buildUpdateContactPathFrame(
          contact.publicKey,
          path?.bytes ?? _emptyPath,
          // No path in the file means flood, which the frame encodes as -1.
          path == null || path.hopCount == 0 ? -1 : path.hopCount,
          hashWidth: path == null || path.hashWidth == 0 ? 1 : path.hashWidth,
          type: contact.type,
          flags: contact.flags,
          name: contact.name,
          lat: hasPosition ? contact.latitude : null,
          lon: hasPosition ? contact.longitude : null,
          lastModified: DateTime.fromMillisecondsSinceEpoch(
            contact.lastModified * 1000,
          ),
        ),
      );
      written++;
    }
    return written;
  }
}

/// A zero-length path, which the frame builder pads out to the fixed-size
/// path field.
final Uint8List _emptyPath = Uint8List(0);

/// One incoming channel and the device slot it will occupy.
class ChannelAssignment {
  const ChannelAssignment(this.slot, this.channel);

  final int slot;
  final StockChannel channel;
}

/// The decision of which incoming channels get written, and where.
class ChannelImportPlan {
  const ChannelImportPlan(this.assignments, this.skipped);

  final List<ChannelAssignment> assignments;
  final List<SkippedChannel> skipped;
}

/// Decides which of [incoming] to write, honoring stock's additive rule.
///
/// A channel counts as already present when either its PSK or its name matches
/// one already on the device. Stock says only that existing channels do not
/// change, without defining what makes a channel "existing"; matching on both
/// is the non-destructive reading, and pinning down what stock actually does is
/// one of the T1 gate's questions.
///
/// New channels go into the lowest free slot. Stock's file has no index field,
/// so incoming order is the only ordering information there is, and slots
/// already occupied are left alone.
ChannelImportPlan planChannelImport({
  required List<Channel> existing,
  required List<StockChannel> incoming,
  required int maxChannels,
}) {
  final live = existing.where((c) => !c.isEmpty).toList();
  final takenSlots = live.map((c) => c.index).toSet();
  final psks = live.map((c) => c.pskHex).toSet();
  final names = live.map((c) => c.name).toSet();

  final assignments = <ChannelAssignment>[];
  final skipped = <SkippedChannel>[];

  for (final channel in incoming) {
    final pskHex = pubKeyToHex(channel.secret);
    if (psks.contains(pskHex) || names.contains(channel.name)) {
      skipped.add(
        SkippedChannel(channel.name, StockConfigImportIssue.alreadyPresent),
      );
      continue;
    }
    int? slot;
    for (var i = 0; i < maxChannels; i++) {
      if (!takenSlots.contains(i)) {
        slot = i;
        break;
      }
    }
    if (slot == null) {
      skipped.add(
        SkippedChannel(channel.name, StockConfigImportIssue.noFreeSlot),
      );
      continue;
    }
    assignments.add(ChannelAssignment(slot, channel));
    takenSlots.add(slot);
    psks.add(pskHex);
    names.add(channel.name);
  }
  return ChannelImportPlan(assignments, skipped);
}
