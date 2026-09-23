# Getting VideoShrink onto TestFlight

TestFlight needs a different kind of build from the one used for development. The development
build talks to Metro over the local network; a TestFlight build carries the JavaScript bundle
inside the app and runs on its own. That is what the `production` profile in `eas.json` is for.

**Status (historical):** the production build 10 submission recorded in
[RELEASE_10.md](RELEASE_10.md) has been uploaded. App Store Connect processing, internal and
external tester availability, and the beta review were not independently checked. This page is the
setup record; the steps below describe what was done, not a pending plan.

## What has to be true first

- **An app record in App Store Connect.** Done: the record exists with App Store Connect app ID
  `6813894354`, saved in `eas.json` under `submit.production.ios.ascAppId`. The bundle identifier
  `com.wilfr.videoshrink` is registered with the Apple team.
- **A distribution certificate and an App Store provisioning profile.** EAS manages these. If
  the stored Apple session has expired, `eas build` will ask you to sign in again.
- **Export compliance.** Already answered in `app.json` with
  `ITSAppUsesNonExemptEncryption: false`. The app has no networking of its own.
- **An icon.** A generated placeholder icon is in place, which is enough to ship a beta. Worth
  replacing before anyone outside the family sees it.

## The steps

1. **Create the app record.** App Store Connect > Apps > + > New App.
   - Platform: iOS
   - Name: `VideoShrink`
   - Primary language: English (U.K.)
   - Bundle ID: `com.wilfr.videoshrink`
   - SKU: anything unique to you, for example `videoshrink-1`
   - User access: full access

2. **Build for the store.** The first one has to be started in interactive mode, because an
   App Store provisioning profile does not exist yet and EAS has to sign in to Apple to create
   it. `--non-interactive` fails at this point with "Credentials are not set up", which is
   expected until that profile exists.

   ```powershell
   $env:EAS_NO_VCS='1'
   eas build --platform ios --profile production      # no --non-interactive the first time
   ```

   EAS will ask for the Apple ID, a password or app-specific password, and a two-factor code,
   then register the App Store provisioning profile against the distribution certificate that
   already exists. Every later production build can run non-interactively.

   The build number comes from `app.json` (`ios.buildNumber`), so bump it before every upload.
   EAS refuses a build number that has already been uploaded to App Store Connect.

3. **Upload it.** Either let EAS do it:

   ```powershell
   eas submit --platform ios --profile production
   ```

   or drag the `.ipa` into Apple's Transporter app. Non-interactive submits need the numeric
   App Store Connect app ID in `eas.json` under `submit.production.ios.ascAppId`, and either an
   App Store Connect API key or your Apple ID.

4. **Wait for processing.** App Store Connect takes a few minutes to process the upload, then the
   build appears under TestFlight. Export compliance is already answered, so it should go
   straight through.

5. **Add the testers.**
   - **Internal testers** (up to 100) must be users on the Apple team: App Store Connect > Users
     and Access, invite them, then add them under TestFlight > Internal Testing. They get the
     build as soon as it processes, with no review.
   - **External testers** only need an email address. Create a group under TestFlight > External
     Testing, add people, and submit the build for **Beta App Review**. That is the first build
     of each version only, and it is usually quick but is not instant.

   For family and friends who are not on the team, external testing is the normal route. There is
   also a public link option once a group exists.

6. **Fill in the beta information.** TestFlight asks for a beta app description, "What to test",
   and a feedback email. The "What to test" box is worth using honestly:

   > VideoShrink makes a smaller copy of a video and leaves the original alone by default.
   > Try the batch: scan the library, pick two or three short videos, and watch the count and
   > time estimate. Deleting originals is off unless you turn it on in Originals. Please tell me
   > if any copy looks wrong, sounds wrong, or if the estimate is badly off.

## Things Apple will ask about

- **App Privacy.** Nothing is collected: no analytics, no account, no network of the app's own.
  Photos access is the only sensitive capability, and the required-reason APIs are declared in
  the privacy manifest.
- **Age rating.** Answer the questionnaire honestly; a video utility is at the bottom of it.
- **Review notes.** Say that the app reads the user's photo library, that deleting is opt-in and
  off by default, and that deleted items go to Photos' Recently Deleted.

## Limits worth telling testers

- Builds expire after 90 days; a new build has to be uploaded to keep the beta alive.
- iOS 18 or later is required, because the export and async loading APIs the app uses start there.
- Videos kept only in iCloud have to download before they can be shrunk, so a batch needs
  connectivity and free space.
- Deleting an original frees space only once Photos clears it out of Recently Deleted, 30 days
  later.

## Before the real App Store submission, not this beta

- Replace the placeholder app icon with real artwork.
- Start a new TestFlight → App Store listing with its own review, screenshots and support URL.
- Consider dropping `expo-dev-client` from the dependencies so the shipped app carries no
  development launcher at all, and rebuild.
