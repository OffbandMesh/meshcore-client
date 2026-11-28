# Store disclosures for Send to Offband

Task #1220 (Epic F, Feature #1190). What Offband declares in Play Console and App Store Connect for Send to Offband. These are Offband's answers read against each store's definitions, not legal advice.

**Entered 2026-11-27** by the owner, for the 1.8.1 cut (#1239), as recorded below. Play: submitted for review (Data safety is the only change in that submission). App Store: live the same day.

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
| The user's optional name or screen name, and email | So Offband can follow up with them (owner decision 2026-11-27). Sealed inside the encrypted package, never on the report |

Passwords and PINs are removed before anything is written to the log. The package is encrypted on the device to Offband's key and sent over HTTPS. Sending is the user's choice each time, unless they turn on automatic sending, which is off by default. Deleted 30 days after review, or sooner on request by reference code.

## Google Play: Data safety

**Data collection and security**

| Question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | Yes |
| Is all of the user data collected by your app encrypted in transit? | Yes |
| Do you provide a way for users to request that their data is deleted? | Yes. Delete data URL: `https://offband.org/privacy/`, whose Data deletion section says to email support@offband.org with the reference code |

**Data types: collected, not shared.** Cloudflare stores the encrypted file as Offband's service provider, which Google does not count as sharing.

| Data type | Collected | Shared | Processed ephemerally | Required or optional | Purpose |
|---|---|---|---|---|---|
| Messages: Other in-app messages | Yes | No | No | Optional | App functionality |
| Location: Precise location | Yes | No | No | Optional | App functionality |
| App info and performance: Crash logs | Yes | No | No | Optional | App functionality |
| App info and performance: Diagnostics | Yes | No | No | Optional | App functionality |
| Personal info: Name | Yes | No | No | Optional | App functionality, Developer communications |
| Personal info: Email address | Yes | No | No | Optional | App functionality, Developer communications |

"App functionality" is used because the data is used only to find and fix problems the user reports, not to measure how the app is used. Name and email also carry **Developer communications** (owner decision 2026-11-27): a reply such as "fixed in the next version" is a notification about the app, which is how Play defines that purpose, and declaring more is the safe side with Play. Every other data type is not collected.

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
| Contact Info | Name |
| Contact Info | Email Address |

Apple's App Functionality purpose includes customer support and minimizing app crashes, which is what the name, the email and the logs are for. Apple has no purpose like Play's "Developer communications"; a reply about a report is customer support.

**Why these aren't left off under Apple's "optional disclosure" rule.** Apple lets an app leave a type off only when it meets all four of its criteria. The last one requires the user to provide the data in the app's interface, with their name shown in the form, and to choose each time to send it. The Send logs screen meets that: the crash prompt's Send opens it, it says what is included, name and email are optional fields that start empty each time, and nothing goes until the user taps Send. **Send crash logs automatically** does not: once the user turns it on, the next launch after a crash sends the package with no screen and no tap. So the four log types (messages, location, crash data, other diagnostic data) must be disclosed while automatic sending exists. Name and email are never in an automatic package, so they were optional to disclose; they are disclosed anyway so the label matches Play and the privacy policy (owner decision 2026-11-27). If automatic sending is ever removed, the whole label could be revisited.

**Linked to the user: Yes** for all six types. Name and email identify the user directly. The other four are linked by owner decision (2026-11-26, option B): there is no account, but the log contains the user's own node name and its public key, and a node name is often a call sign. Apple counts data as linked when it is tied to the user's identity "via their account, device, or other details", so "linked" is the reading that can't be called wrong later.

## Notes from entering them

- **App Store Connect publishes each data type as it is saved.** There was no separate Publish step: the label went live on the 1.8.0 listing while 1.8.1 was still in testing, so for a short time it declares more than the live version sends. That is the safe direction.
- **Play holds the change for review** under Publishing overview, and with managed publishing off it goes live when approved. It must be approved before a build that sends logs reaches any track, since Play checks every track's builds against it.
- If the package ever gains a data type, this page and both labels change first.
