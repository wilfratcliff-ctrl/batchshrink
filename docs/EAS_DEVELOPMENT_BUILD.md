# Expo development build from Windows

## Prepared state

The project uses npm, Expo SDK 57 and a local Swift native view. EAS CLI 24.7.0 is installed globally. Expo browser login succeeded and `eas whoami` identified the personal account **wilfrat1**. The EAS project is [@wilfrat1/videoshrink](https://expo.dev/accounts/wilfrat1/projects/videoshrink), ID `c6920080-775a-4e18-8067-f4995b9fd103`.

The `development` profile targets a **physical iPhone**, with `developmentClient: true`, `distribution: internal`, and `ios.simulator: false`. The alternative `development-simulator` profile sets `ios.simulator: true`; its artifact cannot be installed on a physical phone. Windows cannot run Apple's iOS Simulator.

The `preview` profile extends `production` but sets `distribution: internal`. It produces a standalone internal build with the JavaScript bundled: no development client and no Metro server, so it opens straight into the app. Expo shows the same install QR for it as for `development`, which makes it the quickest way to review native interface work on the registered iPhone. Every profile shares the bundle identifier `com.wilfr.videoshrink`, so installing an internal build replaces a TestFlight install and the other way round.

**Build 1 completed and the user confirmed the app runs on their iPhone on September 18.** Apple signing and device registration are configured. Build 1: `8441943f-fcb8-4584-ae19-cf691b7b7205`. The interface redesign also built successfully as build 2: `354ed8f9-5879-4001-9c82-6d7917fdf067`; install that build to see the new native screens. See `VALIDATION.md` for verification limits. The supported prototype platform is iOS. No Git commit or push has been made.

## Setup commands used

The repository originally had no Expo app or package manager. npm was selected, using compatible dependency versions from Expo's official blank TypeScript template. The module was scaffolded with Expo's generator rather than a handcrafted module structure.

```powershell
npm install
npx create-expo-module@57.0.1 --local --name VideoShrinkNative --description "VideoShrink Photos and HEVC prototype" --package expo.modules.videoshrink --platform apple --features View --package-manager npm
npx expo install expo-dev-client
npx expo install expo-build-properties
npm install --global eas-cli@24.7.0
eas login --browser
eas whoami
eas init --account wilfrat1 --non-interactive --no-icon
npm run sync:native
```

The generator's `modules/my-module` output was renamed to `modules/videoshrink-native`. EAS CLI was initially tried as a project development dependency; Expo Doctor recommends keeping it outside the project, so it was moved to a global installation. The application dependencies are recorded in `package-lock.json`. Future checkouts should use `npm ci`.

## Local validation

```powershell
npm run typecheck
npm run validate:native
node scripts/sync-native-sources.mjs --check
npx expo install --check
npx expo-modules-autolinking resolve --platform apple --json
npx expo config --type introspect --json
npx expo-doctor@latest
npx expo export --platform ios --output-dir build/expo-export
eas config --platform ios --profile development --non-interactive
```

Expo export checks the JavaScript bundle; it is not an iOS native build. Autolinking verifies module discovery; it does not compile Swift or run CocoaPods. The standalone project still contains 30 XCTest cases, which require Xcode to execute. Run the complete physical test plan after installation, including native sheet presentation, React reload during an operation, background cancellation and preservation of the original asset.

## After explicit build approval

The first build requires a paid Apple Developer membership, Apple signing setup and registration of the target iPhone. Expo account login does not verify that Apple membership. Complete sensitive account authentication in the CLI/browser yourself; never store credentials in source.

No commit or push is authorized. EAS can package the working directory without creating a Git commit:

```powershell
$env:EAS_NO_VCS = '1'
eas build --platform ios --profile development
```

The command uploads the app source/build configuration to Expo's builders. It does not upload the phone's Photos library. The generated native source copies are ignored in the upload, then recreated by `postinstall`; the post-install check fails if copies differ. The build uses Apple's toolchain on EAS, so native compiler errors remain possible.

Review the bundle identifier `com.wilfr.videoshrink` during signing. It has been configured locally, not registered with Apple during setup. The build command may prompt to create signing credentials and select/register your iPhone. Do not switch to a simulator merely to bypass signing if the intended destination is the phone.

When the build succeeds, open its installation link/QR on the registered iPhone and install the development build. Enable Developer Mode when iOS requires it. Then start Metro from this repository:

```powershell
npx expo start
```

Use the VideoShrink development client to open the Metro project, with the phone and PC on a reachable network. If iOS asks for local-network permission, it is for development-server access. The app's actual video work remains on-device. Do not claim installation succeeded until confirmed on the phone.

If the user instead explicitly requests an iOS Simulator, set `ios.simulator: true` on the requested `development` profile before the approved command, or agree to use the separate simulator profile. Installation requires a Mac with a compatible simulator runtime. This Windows session cannot perform that installation.

## Native changes and source ownership

Edit the original Swift code in `VideoShrink/`, then run `npm run sync:native`. Change Expo configuration in `app.json`, EAS profiles in `eas.json`, and wrapper code under `modules/videoshrink-native/ios`. Rebuild the development client after native changes; Metro refresh alone only updates JavaScript/TypeScript.

The standalone XcodeGen app remains available for isolated tests/debugging. The Expo app embeds its UI but does not automatically run the standalone XCTest target. Sources and behavior must pass real device validation before this is called a successful feasibility proof.
