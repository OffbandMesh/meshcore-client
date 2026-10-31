# App Store privacy answers

What to enter under **App Privacy** in App Store Connect (Feature #200, task C2). These are Offband's answers read against Apple's definitions, not legal advice. Apple's published label is the developer's own statement, so if the app's network use changes, this page and the label change with it.

## Apple's definitions

From [App privacy details on the App Store](https://developer.apple.com/app-store/app-privacy-details/), read 2026-10-31:

> "Collect" refers to transmitting data off the device in a way that allows you and/or your third-party partners to access it for a period longer than what is necessary to service the transmitted request in real time.

> "Third-party partners" refers to analytics tools, advertising networks, third-party SDKs, or other external vendors whose code you've added to your app.

## What to enter

| Screen | Answer |
|---|---|
| Do you or your third-party partners collect data from this app? | **No, we do not collect data from this app** |
| Privacy Policy URL | `https://offband.org/privacy` |

Then **Publish**. The listing will show "Data Not Collected".

## Why, host by host

Read from `lib/`, 2026-10-31. The app includes no analytics, advertising or crash-reporting SDK.

| Host | What the app sends | When | Vendor code in the app? | Answer |
|---|---|---|---|---|
| `api.open-meteo.com` | Coordinates of the path being checked | Line-of-sight check, on request | No | Not collected: a third party serves the request, and no vendor code or developer access is involved |
| `api.giphy.com` | GIF search text | GIF picker, on request | No, plain HTTP | Not collected, same reason |
| `media.giphy.com` | A request for the chosen GIF | Viewing a GIF | No | Not collected, same reason |
| `tile.openstreetmap.org` | Requests for map tiles | Map, tile download | No | Not collected, same reason |
| `huggingface.co` | A model download request | Translation model download, opt-in | No | Not collected, no user data |
| `raw.githubusercontent.com` | Requests for public radio presets | Loading presets | No | Not collected, no user data |

Messages travel over the owner's radio and the mesh, not through any Offband server. Contacts, messages and settings stay on the device.

**CoreScope is not on this list because iOS cannot reach it.** `map.okimesh.org` is the one host the developer helps run. Its only route is the Experimental section, which has no unlock on iOS (#1051), and its setting defaults to off. The plan's choice 2 declared it as Other Data; the owner's decision to hide that section on iOS replaces that answer.

**If the Experimental section ever returns on iOS,** this answer is wrong and must change first: declare Other Data, not linked to the user, App Functionality, not used for tracking.

## Before this is final

- The privacy policy has to name GitHub raw, and give iOS deletion and permission text, before C5. CoreScope stays in it for other platforms. That work is in OffbandMesh/offband-site#73.
- If the app ever adds a host or vendor SDK, this table is out of date and the label may be wrong.
