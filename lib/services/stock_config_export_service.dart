/// Builds a stock-compatible config export from the connected device (#573,
/// epic #568).
///
/// The wire format lives in `models/stock_config.dart`; this service is only
/// concerned with reading live state and mapping it across. Section selection
/// mirrors stock's Export Config screen, where every section is individually
/// checkable and the file simply omits what was not selected.
library;

import 'dart:typed_data';

import '../connector/meshcore_connector.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../models/stock_config.dart';

/// One checkbox on the export screen. [identity] covers the public and private
/// key together, matching stock's single "Private Identity Key" control.
enum StockConfigSection {
  name,
  identity,
  radioSettings,
  positionSettings,
  otherSettings,
  autoAddSettings,
  channels,
  contacts,
}

/// Why a requested section did not make it into the file.
enum StockConfigOmission {
  /// The device is not connected, or did not answer in time.
  noReply,

  /// The radio's firmware was built without the feature. Retrying is pointless.
  unsupported,

  /// The device refused the request.
  rejected,

  /// The device has not reported this value, so there is nothing to write.
  unavailable,
}

/// The outcome of an export attempt.
///
/// [omitted] is the important half: a section the user ticked that could not be
/// gathered must be reported, never dropped quietly. The export screen shows
/// these before writing the file.
class StockConfigExportResult {
  const StockConfigExportResult({
    required this.config,
    required this.included,
    required this.omitted,
  });

  final StockConfig config;
  final Set<StockConfigSection> included;
  final Map<StockConfigSection, StockConfigOmission> omitted;

  bool get isComplete => omitted.isEmpty;
}

class StockConfigExportService {
  StockConfigExportService(this._connector);

  final MeshCoreConnector _connector;

  /// Gathers [sections] from the connected device.
  ///
  /// Reading the identity is the only step that talks to the radio; everything
  /// else is already in connector state from the SELF_INFO handshake and the
  /// contact and channel syncs.
  Future<StockConfigExportResult> build({
    required Set<StockConfigSection> sections,
  }) async {
    final included = <StockConfigSection>{};
    final omitted = <StockConfigSection, StockConfigOmission>{};

    void include(StockConfigSection section) => included.add(section);
    void omit(StockConfigSection section, StockConfigOmission why) =>
        omitted[section] = why;

    String? name;
    if (sections.contains(StockConfigSection.name)) {
      name = _connector.selfName;
      if (name == null) {
        omit(StockConfigSection.name, StockConfigOmission.unavailable);
      } else {
        include(StockConfigSection.name);
      }
    }

    Uint8List? publicKey;
    Uint8List? privateKey;
    if (sections.contains(StockConfigSection.identity)) {
      final result = await _connector.exportPrivateKey();
      switch (result.outcome) {
        case IdentityTransfer.ok:
          // The keys travel as a pair, so a missing public key means we write
          // neither rather than half an identity.
          final self = _connector.selfPublicKey;
          if (self == null) {
            omit(StockConfigSection.identity, StockConfigOmission.unavailable);
          } else {
            publicKey = self;
            privateKey = result.identity;
            include(StockConfigSection.identity);
          }
        case IdentityTransfer.unsupported:
          omit(StockConfigSection.identity, StockConfigOmission.unsupported);
        case IdentityTransfer.rejected:
          omit(StockConfigSection.identity, StockConfigOmission.rejected);
        case IdentityTransfer.noReply:
          omit(StockConfigSection.identity, StockConfigOmission.noReply);
      }
    }

    StockRadioSettings? radio;
    if (sections.contains(StockConfigSection.radioSettings)) {
      radio = _buildRadioSettings();
      if (radio == null) {
        omit(StockConfigSection.radioSettings, StockConfigOmission.unavailable);
      } else {
        include(StockConfigSection.radioSettings);
      }
    }

    StockPositionSettings? position;
    if (sections.contains(StockConfigSection.positionSettings)) {
      position = StockPositionSettings(
        latitude: _connector.selfLatitude ?? 0,
        longitude: _connector.selfLongitude ?? 0,
      );
      include(StockConfigSection.positionSettings);
    }

    StockOtherSettings? other;
    if (sections.contains(StockConfigSection.otherSettings)) {
      other = StockOtherSettings(
        // The raw device byte, not the connector's inverted convenience flag.
        manualAddContacts: _connector.manualAddContactsRaw,
        advertLocationPolicy: _connector.advertLocationPolicy,
      );
      include(StockConfigSection.otherSettings);
    }

    StockAutoAddSettings? autoAdd;
    if (sections.contains(StockConfigSection.autoAddSettings)) {
      autoAdd = StockAutoAddSettings(
        autoAddChat: _connector.autoAddUsers ?? false,
        autoAddRepeater: _connector.autoAddRepeaters ?? false,
        autoAddRoomServer: _connector.autoAddRoomServers ?? false,
        autoAddSensor: _connector.autoAddSensors ?? false,
        overwriteOldest: _connector.autoAddOverwriteOldest ?? false,
        autoAddMaxHops: _connector.autoAddMaxHops,
      );
      include(StockConfigSection.autoAddSettings);
    }

    List<StockChannel>? channels;
    if (sections.contains(StockConfigSection.channels)) {
      channels = [
        for (final channel in _connector.channels)
          if (!channel.isEmpty) toStockChannel(channel),
      ];
      include(StockConfigSection.channels);
    }

    List<StockContact>? contacts;
    if (sections.contains(StockConfigSection.contacts)) {
      contacts = [
        for (final contact in _connector.contacts) toStockContact(contact),
      ];
      include(StockConfigSection.contacts);
    }

    return StockConfigExportResult(
      config: StockConfig(
        name: name,
        publicKey: publicKey,
        privateKey: privateKey,
        radioSettings: radio,
        positionSettings: position,
        otherSettings: other,
        autoAddSettings: autoAdd,
        channels: channels,
        contacts: contacts,
      ),
      included: included,
      omitted: omitted,
    );
  }

  /// Null until the device has reported its radio parameters. Partial radio
  /// state is never written: stock's reader takes the five values together.
  StockRadioSettings? _buildRadioSettings() {
    // `currentFreqHz` is misnamed: the value is kHz, which is what stock's
    // `frequency` field also carries, so it passes through unconverted.
    // `currentBwHz` really is Hz, matching stock's `bandwidth`. The units
    // differ between the two fields in both our state and the file.
    final frequencyKhz = _connector.currentFreqHz;
    final bandwidthHz = _connector.currentBwHz;
    final sf = _connector.currentSf;
    final cr = _connector.currentCr;
    final txPower = _connector.currentTxPower;
    if (frequencyKhz == null ||
        bandwidthHz == null ||
        sf == null ||
        cr == null ||
        txPower == null) {
      return null;
    }
    return StockRadioSettings(
      frequencyKhz: frequencyKhz,
      bandwidthHz: bandwidthHz,
      spreadingFactor: sf,
      codingRate: cr,
      txPower: txPower,
    );
  }
}

/// Maps one of our channels onto the stock record. The channel's index is not
/// written: stock derives it from array position.
StockChannel toStockChannel(Channel channel) =>
    StockChannel(name: channel.name, secret: channel.psk);

/// Maps one of our contacts onto the stock record.
StockContact toStockContact(Contact contact) {
  return StockContact(
    type: contact.type,
    name: contact.name,
    publicKey: contact.publicKey,
    flags: contact.flags,
    latitude: contact.latitude ?? 0,
    longitude: contact.longitude ?? 0,
    lastAdvert: _epochSeconds(contact.lastSeen),
    lastModified: _epochSeconds(contact.lastModified ?? contact.lastSeen),
    outPath: _toStockOutPath(contact),
  );
}

/// Our path is a hash count plus a per-hop width (#309); stock writes one
/// comma-separated hash per hop, so the width survives as each element's
/// length. A flood route (`pathLength` of -1) and an empty path both mean
/// "no route", which stock spells as a null field.
StockOutPath? _toStockOutPath(Contact contact) {
  if (contact.pathLength <= 0 || contact.path.isEmpty) return null;
  final width = contact.pathHashWidth;
  if (!kStockPathHashWidths.contains(width)) return null;
  final usable = contact.pathLength * width;
  if (usable > contact.path.length) return null;
  return StockOutPath(
    hashWidth: width,
    bytes: Uint8List.sublistView(contact.path, 0, usable),
  );
}

int _epochSeconds(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;
