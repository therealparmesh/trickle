# Release Process

## Publisher prerequisites

1. The Apple Developer bundle identifier `com.parmscript.trickle` is registered, and App Store Connect record `6792352845` exists. Create the initial Google Play app record before uploading there; public store APIs manage existing apps but do not create initial records. If the identifier must change, update it before the first release in `android/app/build.gradle.kts`, the iOS Runner target, `lib/services/background_refresh_service.dart`, `ios/Runner/AppDelegate.swift`, and `ios/Runner/Info.plist`.
2. Use `trickle: podcasts & RSS` for the unique App Store listing name and lowercase `trickle` for the on-device product name. Store consoles are authoritative for name and identifier availability.
3. Complete Apple Developer and Google Play enrollment, agreements, identity verification, and any required tax or banking setup.
4. Publish the public repository's `main/docs` directory through GitHub Pages. Verify the support and privacy targets in `store/metadata.md` without an authenticated session before adding them to either store record.
5. Create the store records from `store/metadata.md`. Add the publisher's legal name, copyright, pricing, countries, content-rating answers, screenshots, review contact, and review notes.

## Versioning

The version in `pubspec.yaml` uses `major.minor.patch+build` format. Increment the build number for every upload. Increment the public version when the user-visible release version changes.

Release from a clean `main`, commit each version/build change as `chore: prepare <version> build <build>`, and push it before uploading. The committed version and build provide the release history; tags are optional.

## Preflight checks

From the repository root:

```sh
flutter pub get
oxfmt --check README.md 'docs/**/*.md' 'store/**/*.md'
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build appbundle --release
flutter build ios --release --no-codesign
```

The final two commands prove both release targets compile without requiring publisher credentials. They do not produce store-uploadable signed artifacts.

Flutter 3.44.4 reports forward-compatibility warnings because `disk_space_plus` and `workmanager_android` still apply the legacy Kotlin Gradle plugin, and part of the iOS plugin set still requires CocoaPods. The current compatible dependency versions build successfully. Recheck those upstream migrations before upgrading Flutter; CocoaPods is intentionally enabled until every required iOS plugin supports Swift Package Manager.

## Android signing and upload

Create an upload key once and keep it outside the repository:

```sh
keytool -genkeypair -v -keystore "$HOME/trickle-upload-keystore.jks" \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
cp android/key.properties.example android/key.properties
```

Edit `android/key.properties`, then build:

```sh
flutter pub get
flutter test
flutter build appbundle --release
```

Upload `build/app/outputs/bundle/release/app-release.aab`. Enable Play App Signing and retain the upload key securely. After the one-time app record, declarations, and service-account access are configured in Play Console, automate bundle, listing, and track updates through the Google Play Publishing API. The project has a minimum API of 24 and targets API 36, including Google's [API 36 requirement beginning August 31, 2026](https://developer.android.com/google/play/requirements/target-sdk).

If `android/key.properties` is absent, release bundles are deliberately unsigned. This allows local and CI compilation checks without ever using the public Android debug key for a release artifact.

Current Android release status: the application identifier and API levels are ready, but no upload keystore, `android/key.properties`, Play app record, or Publishing API service account has been created. Do not upload the existing unsigned bundle.

Complete Play Console Data safety from `store/metadata.md`, declare no ads, select News & Magazines, provide the hosted privacy URL, complete content rating, and test the exact signed bundle in internal testing before production.

If the publisher is using a personal Play developer account created after November 13, 2023, Google requires a closed test with at least 12 opted-in testers continuously for 14 days before production access can be requested. Organization accounts and older personal accounts follow the eligibility shown by Play Console.

## iOS signing and upload

The Xcode project uses automatic development signing with team `7654L3CX5L`. App Store export uses the explicit `trickle App Store` profile and Apple Distribution certificate so builds are reproducible without an Xcode UI account. Xcode 26 or later is required on the release Mac.

```sh
tool/release_ios.sh build
```

This runs formatting, analysis, and tests before producing `build/ios/ipa/trickle.ipa`. To rebuild, validate, and upload directly to App Store Connect without Xcode Organizer or Transporter UI:

```sh
tool/release_ios.sh upload
```

The upload uses App Store Connect key `DC6F5JMNM3` and issuer `19bebb70-4123-40d3-9379-1476fcc51b60` by default, with the private key kept outside the repository at `~/.appstoreconnect/private_keys/AuthKey_DC6F5JMNM3.p8`. Set `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, or `API_PRIVATE_KEYS_DIR` to override them.

Apple has required [Xcode 26 or later with the iOS 26 SDK or later since April 28, 2026](https://developer.apple.com/news/upcoming-requirements/?id=02032026a). The verified local release environment uses Xcode 26.6 and the iOS 26.5 SDK.

The application includes its privacy manifest, background-audio configuration, background-refresh identifier, encryption declaration, and 1024-pixel icon. A final build phase removes the downloader SDK's generic Photo Library declaration because trickle stores audio only in app-private storage and does not use that optional SDK feature.

The iOS target is iPhone-only. Five prepared 1320×2868 iPhone 17 Pro Max PNG screenshots are in `store/apple/screenshots/`. The capture flow does not seed content: prepare a simulator with the podcast and feed data asserted by `tool/maestro/capture_store_screenshots.yaml`, then regenerate the images from the repository root with `maestro test tool/maestro/capture_store_screenshots.yaml`.

In App Store Connect, use `store/metadata.md` and `store/app_review_notes.md`, answer App Privacy as no data collected by the developer, and publish that response before submitting a version. Provide the verified hosted privacy and support URLs, complete age-rating and content-rights answers, attach the prepared screenshots, provide review contact details, and test the uploaded build using `store/testflight_notes.md`.

## Acceptance checklist

- Installation: fresh install, upgrade, relaunch, offline launch, low storage, and database migration
- Playback: stream, seek, pause, resume, previous/next, interruptions, unplugged headphones, lock screen, background audio, and every global speed
- Downloads: Wi-Fi/mobile policy, automatic/manual download, pause, retry, completion, keep, removal, and every cleanup policy
- Queue and extras: reorder, remove, persistence, sleep timers, intro/outro skip, repeat-one, chapters, transcripts, and bookmarks
- Subscriptions: concurrent row-level catalog subscriptions, public/private direct URLs, query/path credentials, website discovery, malformed feeds, redirects, UTF-8/UTF-16 OPML import, podcast/reading/combined OPML exports, backup/restore, and unsubscribe cleanup
- Reader: RSS, Atom, JSON Feed, YouTube channel and playlist discovery, unread/read/saved state, reader extraction, preview images, local search, remote-image toggle, sharing, and external links
- Video: in-app playback, minimize/expand/close/reopen, iOS WebKit system presentation, Android 8+ activity Picture in Picture, background behavior allowed by the active player and device settings, no duplicate in-app player during Picture in Picture, playback restoration after Picture in Picture closes, yout-ube-first loading, official YouTube fallback only after failure, unmodified official-player ads, network loss, and no reload while navigating
- Loading and failures: initial, inline, row-level, and pull-to-refresh progress; repeated-tap prevention; coalesced duplicate refreshes; stale-response rejection; 10-second video-source attempts; 15-second background work; 30-second document and per-feed deadlines; partial refresh results; actionable retry controls; safe malformed-file messages; and replacement rather than stacking of transient messages
- System behavior: notification denied/granted, per-feed notifications, background refresh, airplane mode, DNS failure, and server errors
- Accessibility and layout: VoiceOver, TalkBack, dynamic text, small/large phones, portrait/landscape, contrast, and smooth long-list scrolling
- Packaging: signed store artifact, privacy report, no cleartext traffic, no committed secret material, and production signing
