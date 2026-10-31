# App Store privacy answers

What to enter under **App Privacy** in App Store Connect (Feature #200, task C2). These are Offband's answers read against Apple's definitions, not legal advice. Apple's published label is the developer's own statement, so if the app's network use changes, this page and the label change with it.

## Apple's definitions

From [App privacy details on the App Store](https://developer.apple.com/app-store/app-privacy-details/), read 2026-10-31:

> "Collect" refers to transmitting data off the device in a way that allows you and/or your third-party partners to access it for a period longer than what is necessary to service the transmitted request in real time.

> "Third-party partners" refers to analytics tools, advertising networks, third-party SDKs, or other external vendors whose code you've added to your app.

## What to enter

| Screen | Answer |
|---|---|
| Do you or your third-party partners collect data from this app? | **Yes, we collect data from this app** |
| Data types | **Other Data Types** only |
| Other Data: how is it used? | **App Functionality** only |
| Other Data: linked to the user's identity? | **No** |
| Other Data: used to track the user? | **No** |
| Privacy Policy URL | `https://offband.org/privacy` |

Then **Publish**. The listing will show "Data Not Linked to You: Other Data". It will not read "Data Not Collected", because CoreScope is declared.

## Why, host by host

Read from `lib/`, 2026-10-31. The app includes no analytics, advertising or crash-reporting SDK.

| Host | What the app sends | When | Vendor code in the app? | Answer |
|---|---|---|---|---|
| `map.okimesh.org` (CoreScope) | The hash of a packet already broadcast on the public mesh | Only if the Experimental section is unlocked and this feature is turned on; off by default | No | **Declared.** The server keeps what it hears, and the developer helps run it, so this is the one host that can meet "collect". A hash of a public packet with no account or name attached is declared as not linked. |
| `api.open-meteo.com` | Coordinates of the path being checked | Line-of-sight check, on request | No | Not collected: a third party serves the request, and no vendor code or developer access is involved |
| `api.giphy.com` | GIF search text | GIF picker, on request | No, plain HTTP | Not collected, same reason |
| `media.giphy.com` | A request for the chosen GIF | Viewing a GIF | No | Not collected, same reason |
| `tile.openstreetmap.org` | Requests for map tiles | Map, tile download | No | Not collected, same reason |
| `huggingface.co` | A model download request | Translation model download, opt-in | No | Not collected, no user data |
| `raw.githubusercontent.com` | Requests for public radio presets | Loading presets | No | Not collected, no user data |

Messages travel over the owner's radio and the mesh, not through any Offband server. Contacts, messages and settings stay on the device.

## Before this is final

- The privacy policy has to name CoreScope and GitHub raw, and give iOS deletion and permission text, before C5. That work is in `OffbandMesh/offband-site`.
- If the app ever adds a host or vendor SDK, this table is out of date and the label may be wrong.
