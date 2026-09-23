# First cloud-Mac session

## Requirements

Rent a Mac running a macOS version compatible with your chosen stable **Xcode 26 or later**, with the iOS SDK and an iPhone simulator runtime installed. Xcode 26 requires macOS Sequoia 15.6 or later; newer Xcode releases may require newer macOS. Confirm the host supports the selected release using [Apple’s Xcode support table](https://developer.apple.com/support/xcode/). Prefer Apple silicon for practical encoding/simulator performance.

As checked on 2026-09-17, Apple requires Xcode 26+ with the iOS 26 SDK or later for App Store Connect uploads. The app’s deployment target remains iOS 18; the build SDK and minimum supported phone OS are different settings. Recheck [Apple’s upload requirements](https://developer.apple.com/news/upcoming-requirements/) before distributing. A phone on a newer OS may require a newer Xcode.

No paid project-generation tool is needed. XcodeGen is free, used only to generate the project from `project.yml`. There are no third-party runtime dependencies. Node is optional on the Mac; the icon is already committed-ready and does not need regeneration.

## Transfer, generate and build

The Windows workspace now has two local commits (`10ab65f` baseline, `559f693` round 1) but no configured remote and nothing pushed. Before cloning, you must explicitly arrange a push to **your private repository**, or securely copy the source tree to the Mac. There is no repository URL to assume.

Use your own Mac user account on the rented host. Authenticate to private GitHub through its credential manager or a short-lived SSH key; never put a token into the clone URL.

```bash
# Replace OWNER/PRIVATE_REPO after you have uploaded the source yourself.
git clone git@github.com:OWNER/PRIVATE_REPO.git VideoShrink
cd VideoShrink
uname -s
xcode-select -p
xcodebuild -version
```

If the host only selects Command Line Tools, ask its administrator or select the actual Xcode installation (adjust path to the installed application):

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
```

Open Xcode once to accept any license and install the iOS platform/runtime in Xcode Settings → Components/Platforms. Install [Homebrew](https://brew.sh/) only if the host has not supplied it, following the official installation directions, then:

```bash
brew install xcodegen
xcodegen --version
xcodegen generate
open VideoShrink.xcodeproj
bash scripts/validate-mac.sh
```

The last command regenerates the project and runs plist validation plus an unsigned simulator build. It intentionally does not claim to run tests without a selected simulator. An unsigned simulator build does not require an Apple account, Developer Program membership or physical iPhone.

List installed simulators, choose an available **iPhone** UUID, then execute tests:

```bash
xcrun simctl list devices available
SIMULATOR_UDID="REPLACE_WITH_IPHONE_SIMULATOR_UUID" bash scripts/validate-mac.sh
```

Equivalent explicit build/test commands:

```bash
xcodebuild -project VideoShrink.xcodeproj -scheme VideoShrink \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

xcodebuild -project VideoShrink.xcodeproj -scheme VideoShrink \
  -destination 'platform=iOS Simulator,id=REPLACE_WITH_IPHONE_SIMULATOR_UUID' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test
```

Run all `VideoShrinkTests` before distribution. Fix compiler errors and warnings that expose real isolation/API problems, update the source/specification, regenerate and rerun. No previous successful compile is available as a baseline. The tests exercise mocks and pure rules; simulator success does not prove iCloud or hardware HEVC behavior.

## Identity and signing

1. In `project.yml`, replace `com.example.VideoShrink` and the tests identifier with your unique reverse-domain identifiers, e.g. `com.YOURNAME.VideoShrink` and `com.YOURNAME.VideoShrink.Tests`. Use an identifier you control and can register. These values are not secrets.
2. Run `xcodegen generate` again, then reopen the project. Select the **VideoShrink** target → Signing & Capabilities → Automatically manage signing. Select your Apple development team. Configure the test target too if running tests on a device.
3. Add your Apple account through Xcode Settings → Accounts. Use the provider’s private user/keychain, with 2FA. Do not paste account passwords into terminals, chat, project files or Git.
4. No iCloud entitlement is needed to request Photos assets. No Background Modes capability should be added for Phase 0. Photos privacy strings and a disk-space privacy manifest are already supplied.
5. UI team changes live in the ignored generated project and can be lost on regeneration. Either select the team again afterward or supply `DEVELOPMENT_TEAM` on the archive command as below. Team IDs are not passwords. Keep any local export/signing configuration in ignored files.

A free Personal Team can be useful for local, physically connected device development subject to Apple’s restrictions. It does **not** provide TestFlight distribution. A remotely rented Mac normally cannot directly attach to your Windows-connected iPhone; do not assume USB forwarding or remote wireless pairing will work. TestFlight is the straightforward delivery route here.

## Archive and upload

For TestFlight you need active **Apple Developer Program membership**, an App Store Connect app record with the matching bundle ID, and the appropriate account role/agreements. You do not need membership merely to write source, generate the project or build/test the simulator.

After tests pass, select “Any iOS Device (arm64)” or the generic iOS destination and choose Product → Archive. Alternatively, after updating the bundle identifier in the spec:

```bash
xcodebuild -project VideoShrink.xcodeproj -scheme VideoShrink \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/VideoShrink.xcarchive \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates archive
open build/VideoShrink.xcarchive
```

`-allowProvisioningUpdates` permits Xcode to contact Apple to manage signing after you authenticate. It is not an upload command. Do not use `CODE_SIGNING_ALLOWED=NO` for a distributable archive.

In Xcode Organizer:

1. Select the archive and validate it. Inspect signing, bundled privacy manifest and app icon. Resolve validation errors; do not skip them.
2. Choose **Distribute App → App Store Connect → Upload**, or **TestFlight Internal Only** for a deliberately internal build. Apple’s wording can vary with Xcode. Internal-only builds cannot later be assigned to external testers.
3. Select the correct team/app and upload after reviewing the summary. Complete any App Store Connect export-compliance questions accurately. The prototype adds no custom cryptography; do not infer an answer to legal compliance questions solely from this guide.
4. Wait for build processing. In App Store Connect → app → TestFlight, add the build to an internal testing group and add yourself as an eligible internal tester. External distribution may require Beta App Review and additional information.
5. On the iPhone, install Apple’s **TestFlight** app, accept the invitation using the invited Apple account, then install VideoShrink. The phone needs a compatible iOS version and network connectivity; it does not need to be attached to the Mac.

For subsequent uploads, increase `CURRENT_PROJECT_VERSION` in `project.yml`, regenerate, test and archive again. Record Xcode/XcodeGen/OS versions and keep the `.xcresult` locally with test evidence. Avoid checking private screenshots, videos or diagnostic paths into Git.

See [Apple distribution guidance](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases), [TestFlight overview](https://developer.apple.com/testflight/) and [internal tester setup](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers).

## Credentials on a rented host

Use a private host account, lock the remote session and review the provider’s security/retention policy. Keep certificates, `.p12`, `.p8`, provisioning profiles, keychains, tokens and passwords outside the repository. The ignore rules help but are not secret detection. Inspect `git status` and staged changes before any future commit. At rental end, remove your account/keychain and repo credentials according to the provider’s supported procedure; revoke temporary access tokens/SSH keys if applicable. Do not upload real personal test videos to the cloud Mac: the important tests run on your phone.
