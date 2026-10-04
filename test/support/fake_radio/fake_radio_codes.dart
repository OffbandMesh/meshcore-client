// Companion protocol codes the fake radio speaks, copied from firmware
// (OffbandMesh/meshcore-firmware `examples/companion_radio/MyMesh.cpp`
// #defines, lines 47-209). Deliberately NOT imported from the client's
// `meshcore_protocol.dart`: the fake is an independent copy of the firmware,
// so a client constant that drifts from it shows up as a failing test.

const int fwCmdAppStart = 1;
const int fwCmdSendTxtMsg = 2;
const int fwCmdSendChannelTxtMsg = 3;
const int fwCmdGetContacts = 4;
const int fwCmdGetDeviceTime = 5;
const int fwCmdSetDeviceTime = 6;
const int fwCmdSendSelfAdvert = 7;
const int fwCmdSetAdvertName = 8;
const int fwCmdAddUpdateContact = 9;
const int fwCmdSyncNextMessage = 10;
const int fwCmdSetRadioParams = 11;
const int fwCmdSetRadioTxPower = 12;
const int fwCmdResetPath = 13;
const int fwCmdSetAdvertLatLon = 14;
const int fwCmdRemoveContact = 15;
const int fwCmdGetBattAndStorage = 20;
const int fwCmdDeviceQuery = 22;
const int fwCmdSendLogin = 26;
const int fwCmdGetChannel = 31;
const int fwCmdSetChannel = 32;
const int fwCmdSetOtherParams = 38;
const int fwCmdGetCustomVars = 40;
const int fwCmdSetCustomVar = 41;
const int fwCmdGetStats = 56;
const int fwCmdSetAutoAddConfig = 58;
const int fwCmdGetAutoAddConfig = 59;
const int fwCmdSetPathHashMode = 61;

const int fwRespOk = 0;
const int fwRespErr = 1;
const int fwRespContactsStart = 2;
const int fwRespContact = 3;
const int fwRespEndOfContacts = 4;
const int fwRespSelfInfo = 5;
const int fwRespSent = 6;
const int fwRespCurrTime = 9;
const int fwRespNoMoreMessages = 10;
const int fwRespBattAndStorage = 12;
const int fwRespDeviceInfo = 13;
const int fwRespChannelInfo = 18;
const int fwRespCustomVars = 21;
const int fwRespAutoAddConfig = 25;

const int fwErrUnsupportedCmd = 1;
const int fwErrNotFound = 2;
const int fwErrTableFull = 3;
const int fwErrBadState = 4;
const int fwErrIllegalArg = 6;

/// `ADV_TYPE_*` (src/helpers/AdvertDataHelpers.h).
const int fwAdvTypeChat = 1;
const int fwAdvTypeRepeater = 2;
const int fwAdvTypeRoom = 3;
const int fwAdvTypeSensor = 4;

/// `PUB_KEY_SIZE` and `MAX_PATH_SIZE` (src/MeshCore.h:8,22).
const int fwPubKeySize = 32;
const int fwMaxPathSize = 64;
