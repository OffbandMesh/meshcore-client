# App Store listing

For the version page and **App Information** in App Store Connect (Feature #200, task C4). Limits are from Apple's [platform version](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information) and [app information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information) pages, read 2026-10-31.

Copy rules: no promotional terms, no ALL-CAPS beyond the brand, no em-dash, and no other platform or marketplace named (guideline 2.3.10).

| Field | Limit | Value |
|---|---|---|
| Name | 30 characters | `Offband MeshCore` |
| Subtitle | 30 characters | `LoRa mesh messaging by radio` |
| Primary category | | Utilities |
| Secondary category | | Social Networking |
| Keywords | 100 bytes | `lora,mesh,radio,off-grid,messenger,chat,repeater,node,bluetooth,companion,channel,map` |
| Support URL | | `https://offband.org/support` |
| Marketing URL | optional | `https://offband.org/app` |
| Privacy Policy URL | | `https://offband.org/privacy` |
| Copyright | | `2026 Offband` |
| Version | | the build's version, from `pubspec.yaml` |
| Price | | Free |

The app's name is already searchable, so `meshcore` and `offband` are left out of the keywords, as Apple advises.

## Promotional text

170 characters. Optional, and can change without a new version.

```text
Message over MeshCore LoRa radios, with no cell service and no account. Connect your radio over Bluetooth for channels, direct messages and a map of your mesh.
```

## Description

4,000 characters, plain text.

```text
Offband MeshCore is a client for MeshCore LoRa mesh radios. Pair a MeshCore radio over Bluetooth and use your iPhone to send messages across the mesh, with no cell service, no internet connection and no account.

You need a MeshCore-compatible radio to send and receive messages. The app does not include one.

CHAT
Direct messages and named group channels. See whether a message was delivered and the route it took across the mesh.

CONTACTS AND CHANNELS
Keep your contacts in groups and mark favorites. Share contacts and join communities with QR codes. Block a contact to stop their direct messages.

MAP
See nodes that report a position, and trace the path a message traveled. Download map areas ahead of time, and check line of sight between two points.

REPEATER ADMINISTRATION
View a repeater's status, change its settings, or use its command line.

OFFLINE TRANSLATION
Translate incoming messages on your device, without sending them anywhere. The language model is an optional download.

PRIVATE BY DESIGN
Messages travel from radio to radio. There is no Offband account and no Offband server holding your conversations, and the app includes no analytics or advertising.

OPEN SOURCE
Offband MeshCore is open source under the MIT License, built on MeshCore Open by zjs81. Source code: https://github.com/OffbandMesh/meshcore-client
```

## Screenshots

From Apple's [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications), read 2026-10-31:

- **Required:** at least one for iPhone with Dynamic Island (medium display), and up to 10.
- **Size, portrait:** 1179 x 2556 or 1206 x 2622 pixels.
- **Format:** PNG or JPEG, with no transparency.

A screenshot taken on a Dynamic Island iPhone of that size comes out right as it is. Take them from the TestFlight build, using test names and no real location.

| # | Screen | Shows |
|---|---|---|
| 1 | A channel conversation | Chat, the app's main use |
| 2 | Connecting to a radio | That it needs a radio |
| 3 | A direct message with delivery state | Direct chat |
| 4 | The map with nodes | Map |
| 5 | Contacts | Contacts and groups |
| 6 | A message's route | Path detail |

## Age rating

Apple's questionnaire appears in App Store Connect, and I have not seen its current wording. Facts to answer from: users exchange messages they write themselves, GIF search is limited to Giphy's G rating, there is no web browser inside the app, and links open in the system browser.
