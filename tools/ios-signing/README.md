# iOS signing: the owner's steps

For Feature #200 (Apple App Store). These are the only steps that need the Account Holder in person. Everything runs on Windows; no Mac is involved. Each round is done once.

**Before you start any round:** PowerShell 7 (`pwsh`), Git for Windows, and the GitHub CLI signed in. The script lives in this repository; run it from the repository folder.

**What never happens:** no password, key or certificate is printed, typed or pasted into chat. The script keeps every secret file in `<your user folder>\.offband-ios`, outside the repository. To keep them with your other keys instead, add `-WorkDir "<that folder>"` to every script command below and use that folder wherever this page says `.offband-ios`.

---

## Round 2: after Apple confirms your membership

All on the web, signed in as the Account Holder. About 20 minutes.

1. **Sign the agreement.** App Store Connect, **Business**: sign the latest agreement. Apple will not let you create an app until you do.
2. **Ask for API access.** App Store Connect, **Users and Access**, **Integrations**, **Request Access**, tick the box, **Submit**. Apple reviews this case by case, so it is done first and waited on.
3. **Register the app's identifier.** developer.apple.com, **Certificates, Identifiers & Profiles**, **Identifiers**, the **+** button, **App IDs**, **Continue**, type **App**, **Continue**.
   - Description: `Offband Meshcore`
   - **Explicit**, Bundle ID: `app.offband.meshcore.ios`
   - Leave the capabilities as they are. **Continue**, **Register**.
4. **Create the app record.** App Store Connect, **Apps**, **+**, **New App**.
   - Platform: **iOS** only
   - Name: `Offband Meshcore`
   - Primary language: English (U.S.)
   - Bundle ID: pick `app.offband.meshcore.ios` from the list
   - SKU: `offband-meshcore-ios`
   - User Access: **Full Access**, then **Create**.
5. **Set availability without France.** In the new app, **Pricing and Availability**, **App Availability**, **Set Up Availability**, **Specific Countries or Regions**. Select all, then **untick France**. Also tick the box at the bottom for future countries, **Next**, **Confirm**.
6. **Declare non-trader.** App Store Connect, **Business**, **Agreements**, the **Compliance** section, next to **Digital Services Act** click **Complete Compliance Requirements**, choose **This is not a trader account**, **Done**.

Tell the session "round 2 done". Nothing to paste back.

---

## Round 3: after Apple approves API access

About 20 minutes. Commands are PowerShell; paste each line as written.

**1. Make the signing request.**

```powershell
pwsh .\tools\ios-signing\ios-signing.ps1 new-csr
```

You will see `Done. Upload this file to Apple ...` and a path ending in `dist.certSigningRequest`.

**2. Create the Distribution certificate.** developer.apple.com, **Certificates**, **+**, **Apple Distribution**, **Continue**, choose the `dist.certSigningRequest` file from step 1, **Continue**, **Download**. It saves a `.cer` file, usually `distribution.cer` in Downloads.

**3. Turn it into the signing bundle.**

```powershell
pwsh .\tools\ios-signing\ios-signing.ps1 make-p12 -Cer "$HOME\Downloads\distribution.cer"
```

You will see `Done. Signing bundle made and checked`. If you see `STOPPED: This certificate was not issued for the private key`, the `.cer` is from a different request; use the one made from step 1.

**4. Create the provisioning profile.** developer.apple.com, **Profiles**, **+**, under Distribution **App Store Connect**, **Continue**, App ID `app.offband.meshcore.ios`, **Continue**, select the certificate from step 2, **Continue**, name `Offband App Store`, **Generate**, **Download**.

**5. Create the upload key.** App Store Connect, **Users and Access**, **Integrations**, **Team Keys**, **Generate API Key**, name `offband-ci-upload`, access **Developer**, **Generate**. Then **Download** the key. **Apple lets you download it only once.** It is a file named `AuthKey_` followed by letters and numbers, ending `.p8`. On the same page, copy the **Issuer ID** shown above the key list.

**6. Store everything as GitHub secrets.** Replace the two file names with yours, and paste the Issuer ID between the quotes:

```powershell
pwsh .\tools\ios-signing\ios-signing.ps1 set-secrets -ProvisioningProfile "$HOME\Downloads\Offband_App_Store.mobileprovision" -ApiKey "$HOME\Downloads\AuthKey_XXXXXXXXXX.p8" -IssuerId "paste-issuer-id-here"
```

You will see six lines starting `set`, then `Done. All six secrets are set.` Only the secret names are shown, never their values.

**7. Move the two downloads out of Downloads.** Put `AuthKey_...p8` and the `.mobileprovision` file into `<your user folder>\.offband-ios` alongside the rest. Keep that folder backed up the same way you back up the Android keystore, because the private key in it cannot be downloaded again.

Tell the session "round 3 done".

---

## Rotation

| Secret | When it changes |
|---|---|
| `APPLE_DIST_P12_BASE64`, `APPLE_DIST_P12_PASSWORD` | When the Distribution certificate expires or is revoked: repeat round 3 steps 1 to 4 and 6 with `-WorkDir` set to a new, empty folder, and keep the old folder until the new certificate has signed a build |
| `APPLE_PROFILE_BASE64` | Whenever the certificate changes, or the profile expires |
| `ASC_API_KEY_P8_BASE64`, `ASC_API_KEY_ID` | Only if the key is lost or exposed: revoke it in App Store Connect and repeat step 5 and 6 |
| `ASC_API_ISSUER_ID` | Fixed for the account |

The values exist only in GitHub's `apple-signing` Environment and in your `.offband-ios` folder. Nowhere else.
