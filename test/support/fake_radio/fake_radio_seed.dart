import 'dart:typed_data';

import 'fake_radio_codes.dart';

/// A contact as the firmware stores it (`ContactInfo`), written back by
/// `writeContactRespFrame` (MyMesh.cpp:276).
class FakeContact {
  FakeContact({
    required this.publicKey,
    required this.name,
    this.type = fwAdvTypeChat,
    this.flags = 0,
    this.outPathLength = -1,
    Uint8List? outPath,
    this.lastAdvert = 1790000000,
    this.latE6 = 0,
    this.lonE6 = 0,
    this.lastmod = 1790000000,
  }) : outPath = outPath ?? Uint8List(0) {
    if (publicKey.length != fwPubKeySize) {
      throw ArgumentError('publicKey must be $fwPubKeySize bytes');
    }
  }

  /// A contact whose key is [keyByte] repeated, for readable seeds.
  factory FakeContact.keyed(
    int keyByte,
    String name, {
    int type = fwAdvTypeChat,
    int lastmod = 1790000000,
  }) => FakeContact(
    publicKey: Uint8List.fromList(List<int>.filled(fwPubKeySize, keyByte)),
    name: name,
    type: type,
    lastmod: lastmod,
  );

  final Uint8List publicKey;
  final String name;
  final int type;
  final int flags;

  /// -1 for flood (sent as 0xFF), otherwise the path length byte.
  final int outPathLength;
  final Uint8List outPath;
  final int lastAdvert;
  final int latE6;
  final int lonE6;
  final int lastmod;
}

/// A group channel slot (`ChannelDetails`), 128-bit secret only.
class FakeChannel {
  FakeChannel({required this.index, required this.name, Uint8List? secret})
    : secret = secret ?? Uint8List(16) {
    if (this.secret.length != 16) {
      throw ArgumentError('secret must be 16 bytes (128-bit)');
    }
  }

  final int index;
  final String name;
  final Uint8List secret;
}

/// Everything the fake radio starts from. Same seed, same replies.
class FakeRadioSeed {
  FakeRadioSeed({
    this.name = 'Fake Radio',
    Uint8List? publicKey,
    this.txPowerDbm = 20,
    this.maxTxPowerDbm = 22,
    this.latE6 = 0,
    this.lonE6 = 0,
    this.multiAcks = 0,
    this.advertLocPolicy = 0,
    this.telemetryModes = 0,
    this.manualAddContacts = 0,
    this.freqKhz = 910525,
    this.bwHz = 62500,
    this.sf = 7,
    this.cr = 5,
    this.maxContacts = 350,
    this.maxChannels = 8,
    this.blePin = 0,
    this.buildDate = '1 Oct 2026',
    this.manufacturer = 'Fake Radio Board',
    this.clientRepeat = false,
    this.pathHashMode = 0,
    this.batteryMillivolts = 4100,
    this.storageUsedKb = 12,
    this.storageTotalKb = 256,
    this.customVars = const {},
    this.autoAddConfig = 0,
    this.autoAddMaxHops = 0,
    this.deviceTime = 1790000000,
    List<FakeContact>? contacts,
    List<FakeChannel>? channels,
  }) : publicKey =
           publicKey ??
           Uint8List.fromList(
             List<int>.generate(fwPubKeySize, (i) => 0xA0 + i),
           ),
       contacts = contacts ?? const [],
       channels = channels ?? const [];

  final String name;
  final Uint8List publicKey;
  final int txPowerDbm;
  final int maxTxPowerDbm;
  final int latE6;
  final int lonE6;
  final int multiAcks;
  final int advertLocPolicy;
  final int telemetryModes;
  final int manualAddContacts;

  /// `_prefs.freq * 1000` as SELF_INFO reports it (MyMesh.cpp:2574).
  final int freqKhz;

  /// `_prefs.bw * 1000` as SELF_INFO reports it (MyMesh.cpp:2577).
  final int bwHz;
  final int sf;
  final int cr;
  final int maxContacts;
  final int maxChannels;
  final int blePin;
  final String buildDate;
  final String manufacturer;
  final bool clientRepeat;
  final int pathHashMode;
  final int batteryMillivolts;
  final int storageUsedKb;
  final int storageTotalKb;
  final Map<String, String> customVars;
  final int autoAddConfig;
  final int autoAddMaxHops;
  final int deviceTime;
  final List<FakeContact> contacts;
  final List<FakeChannel> channels;
}
