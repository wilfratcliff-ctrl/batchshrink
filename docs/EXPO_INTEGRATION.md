# Expo development application

The repository now contains an Expo SDK 57 application with a local iOS module that hosts the existing SwiftUI prototype. The native Photos/HEVC implementation remains in `VideoShrink/`. TypeScript, bundling and module discovery can be checked on Windows. The Swift module has been compiled and signed by EAS through build 10, but the media pipeline still needs physical-device testing.

The Expo entry point renders `VideoShrinkNative`, a native view backed by a child `UIHostingController`. All existing Photos selection, states, measurements, preview, verification and save controls remain in SwiftUI for this proof. Expo Go displays a clear unsupported-build message; it does not simulate compression. See [Expo custom native code](https://docs.expo.dev/workflow/customizing/) and [Modules setup](https://docs.expo.dev/modules/get-started/).

## Current build arrangement

- `package.json` and `package-lock.json`: npm dependencies based on Expo's official blank TypeScript template. `expo-dev-client` supplies the development launcher. EAS CLI is installed globally, outside app dependencies.
- `app.json`: iOS-only app, Photos permission strings, native deployment target of iOS 18, icon and EAS project link. `com.wilfr.videoshrink` is the bundle identifier; Apple signing and device registration are configured, and EAS has signed builds for it through build 10.
- `eas.json`: `development` produces a physical-iPhone internal/ad hoc build; `development-simulator` is a separate simulator-only profile. Neither profile submits to TestFlight.
- `modules/videoshrink-native`: Apple-only module scaffolded with `create-expo-module`, then adapted to host the existing interface. A process-wide model prevents React remounts from starting competing cleanup operations. App backgrounding and module teardown explicitly reach the native cancellation policy.
- `scripts/sync-native-sources.mjs`: copies the 36 shared Swift files and the privacy manifest into the module's ignored generated directory. It excludes the standalone `@main` app and standalone Info.plist. `postinstall` recreates these copies on EAS; the EAS post-install hook checks their hashes. Edit the original files, then run `npm run sync:native`.
- A privacy resource bundle accompanies the pod. CocoaPods installation and Xcode compilation have happened in the EAS builds through build 10. Runtime view containment, sheet presentation and lifecycle forwarding still need device tests.

The Expo development client uses the local network to connect to Metro and includes development tooling. This is separate from the native media pipeline: no video bytes cross into JavaScript or an app upload endpoint. Review release-build privacy separately when replacing this development setup with a commercial build.

Follow [EAS_DEVELOPMENT_BUILD.md](EAS_DEVELOPMENT_BUILD.md). EAS has produced builds for this app; build 10 is the production submission recorded in [RELEASE_10.md](RELEASE_10.md). The round 1 reliability work is not in any build.

## Reuse boundary

- Keep `Models` and `Services` as native code. Keep video bytes, AVAssets, decoding, cancellation, verification and Photos transactions on the native side.
- For a future React Native product interface, replace the embedded SwiftUI form with a deliberate native method/event boundary. Do not assume a JavaScript picker URI grants PhotoKit access or represents the original iCloud resource.
- Extract orchestration from the current main-actor `CompressionViewModel` into a UI-independent native coordinator when bridging. The existing service protocols remain test seams.
- Expose job identifiers, readable states, measured metadata, progress events, cancel/discard and explicit save commands. Pass metadata and managed handles across the bridge, never a complete video as base64 or a large JS array.
- Keep the native service as the authority for “verified,” “smaller” and “save permitted.” A JavaScript state reset or navigation event must not bypass verification or create duplicate saves.
- Translate native structured errors into stable bridge codes. Reconcile late events by operation identifier and define cancellation on screen unmount, reload and app background transitions.

## Migration acceptance

First run the native pipeline inside the Expo development build and complete the device matrix. The later move to React Native controls must repeat those tests across the new method/event bridge. Native code changes require rebuilding the native app. Configure Photos privacy strings, the privacy manifest, deployment target and signing through the Expo project's supported configuration rather than relying on manual edits that regeneration may replace.

EAS is now the selected cloud build route from Windows. A rented Mac remains useful for Xcode diagnostics and running the standalone XCTest suite, but is not required to request an EAS build. Expo does not change iOS background scheduling limits or the need for physical iCloud/HEVC tests. No signing credentials are stored in this repository.

The Codex Expo plugin is a development assistant integration, distinct from the Expo runtime now included in this project. Neither makes custom Swift code runnable in Expo Go.
