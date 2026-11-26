# Store disclosures for Send to Offband

Task #1220 (Epic F, Feature #1190). What to enter in Play Console and App Store Connect once Send to Offband ships. These are Offband's answers read against each store's definitions, not legal advice. Enter them in the same release that ships the feature, not before.

Neither store can be set from here. Play has a Data Safety API, but the publishing service account has only the two release permissions. App Store Connect has no API for privacy labels. Both are pasted by the owner.

## What leaves the device, and only when the user sends it

| Data | Why it is in the package |
|---|---|
| Messages (direct and channel text) | The app log records them; most bugs are about messages |
| Radio traffic between the app and the radio | Needed to diagnose the radio side |
| Positions the radio received (other nodes, and the user's own radio if it reports one) | Present in radio traffic |
| App version, platform, OS version, radio model and firmware | Manifest, to match the build |
| Android crash and freeze reports | The crash being reported |
| The user's optional note | Shown on the report |

Passwords and PINs are removed before anything is written to the log. The package is encrypted on the device to Offband's key and sent over HTTPS. Sending is the user's choice each time, unless they turn on automatic sending, which is off by default. Deleted 30 days after review, or sooner on request by reference code.

## Google Play: Data safety

**Data collection and security**

| Question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | Yes |
| Is all of the user data collected by your app encrypted in transit? | Yes |
| Do you provide a way for users to request that their data is deleted? | Yes (email support@offband.org with the reference code) |

**Data types: collected, not shared.** Cloudflare stores the encrypted file as Offband's service provider, which Google does not count as sharing.

| Data type | Collected | Shared | Processed ephemerally | Required or optional | Purpose |
|---|---|---|---|---|---|
| Messages: Other in-app messages | Yes | No | No | Optional | App functionality |
| Location: Precise location | Yes | No | No | Optional | App functionality |
| App info and performance: Crash logs | Yes | No | No | Optional | App functionality |
| App info and performance: Diagnostics | Yes | No | No | Optional | App functionality |

"App functionality" is used because the data is used only to find and fix problems the user reports, not to measure how the app is used. Leave every other data type as not collected.

## App Store: App Privacy

This replaces "Data Not Collected" in `../200-ios-app-store/APP-PRIVACY.md`.

| Question | Answer |
|---|---|
| Do you or your third-party partners collect data from this app? | **Yes** |

Data types to select, each with **Purpose: App Functionality** and **Used for tracking: No**:

| Category | Type |
|---|---|
| User Content | Emails or Text Messages |
| Location | Precise Location |
| Diagnostics | Crash Data |
| Diagnostics | Other Diagnostic Data |

**Linked to the user: one call for the owner.** There is no account and no device identifier in the package. The log does contain the user's own node name and its public key, and a node name is often a call sign. Apple counts data as linked when it is tied to the user's identity "via their account, device, or other details".

- **A: Not linked.** There's no account, and Offband never ties a log to a person. This is a shorter label, but it rests on reading "other details" narrowly.
- **B: Linked** ⭐ (recommended). The node name and key can name the user, so this is the reading that can't be called wrong later. It costs a longer label.

## Before entering

- Enter both in the release that ships Send to Offband. Before that, the current answers are still true.
- If the package ever gains a data type, this page and both labels change first.
