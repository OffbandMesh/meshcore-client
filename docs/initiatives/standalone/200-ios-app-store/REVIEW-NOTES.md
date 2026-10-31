# App Review notes and demo video

For **App Review Information** in App Store Connect and for the beta review (Feature #200, task C3). Paste the block under "Notes" as written, after replacing the video link. Apple's limit is 4,000 bytes.

## Notes

```text
Offband MeshCore is a client for MeshCore LoRa mesh radios. It needs a MeshCore radio, paired over Bluetooth, to send or receive messages. It sends no messages over the internet and has no account or sign-in.

DEMO VIDEO
A recording of the app running on an iPhone with a real radio, from launch through sending and receiving: <VIDEO LINK>

WITHOUT A RADIO
The app opens to the Bluetooth connection screen and will scan, but chat, contacts and the map's live data need a connected radio. MeshCore radios are third-party hardware, so the video shows these features. We can supply a radio on request.

WHAT IT DOES
Direct messages and group channels over the mesh, contacts, a map of nodes that report a position, delivery and route information, and administration of MeshCore repeaters.

WHAT YOU MAY NOTICE
- Bluetooth permission: used only to talk to the radio. It stays connected in the background (bluetooth-central) so messages arrive with the screen off.
- Camera permission: used only to scan QR codes for contacts and communities.
- Offline translation: optional. A language model is downloaded from Hugging Face only if the user turns translation on, and it runs on the device. This is why the app contains an on-device inference library.
- Map tiles come from OpenStreetMap. Line-of-sight checks send the path's coordinates to Open-Meteo for elevation data.
- The app does not read the phone's GPS. Positions on the map come from radios.

USER-GENERATED CONTENT
Messages are sent radio to radio. There is no Offband server holding them, so we cannot see, filter or remove them. Users can block a contact from the Contacts screen or a sender from a channel. That drops the contact's direct messages and hides the sender's channel messages. There is no in-app report button, because no one operates a service to receive or act on a report; users can write to support@offband.org. GIF search is limited to Giphy's G rating.

ENCRYPTION
The app uses standard AES, SHA-256 and HMAC from open-source libraries. Export compliance was answered in App Store Connect. The source code is public: https://github.com/OffbandMesh/meshcore-client
```

## Demo video

Record on a family iPhone from the TestFlight build, with a second radio or phone in frame to show messages arriving. Use the screen recorder for the app, and film the hardware if you can. No narration needed. Keep it near 2 minutes.

Before recording, make sure nothing private is visible: use a test channel, a test contact name, and no real location on the map.

| # | Show | Why Apple needs it |
|---|---|---|
| 1 | The radio, powered on, beside the iPhone | Proves the hardware is real |
| 2 | Launching the app and allowing the Bluetooth prompt | The permission and its reason |
| 3 | Picking the radio from the scan list and connecting | The core function |
| 4 | Opening a channel and sending a message | Sending |
| 5 | The message arriving on the second device, then a reply arriving on the iPhone | Receiving, end to end |
| 6 | A direct message to a contact, with its delivery state | Direct chat |
| 7 | Contacts, then blocking a test contact | The block control guideline 1.2 asks for |
| 8 | The map, with a node showing | Map |
| 9 | Scanning a QR code | The camera permission's reason |
| 10 | Turning on translation and translating a message, if the model is already downloaded | The on-device model |
Upload it unlisted, somewhere that needs no sign-in to watch, and put that link in the notes.

## The beta review

Apple reviews the first build sent to an external TestFlight group. Those notes go in **TestFlight > Test Information**, under Beta App Review Information, and the same text works.
