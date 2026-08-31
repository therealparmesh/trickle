# Release Process

For the first Google Play and Zapstore launch, follow the staged [Android release plan](ANDROID_RELEASE.md) in addition to this shared checklist.

## Publisher prerequisites

1. The Apple Developer bundle identifier `com.parmscript.trickle` is registered, and App Store Connect record `6792352845` exists. Create the initial Google Play app record before uploading there; public store APIs manage existing apps but do not create initial records. If the identifier must change, update it before the first release in `android/app/build.gradle.kts`, the iOS Runner target, `lib/services/background_refresh_service.dart`, `ios/Runner/AppDelegate.swift`, and `ios/Runner/Info.plist`.
2. Use `trickle: podcasts & RSS` for the unique App Store listing name and lowercase `trickle` for the on-device product name. Store consoles are authoritative for name and identifier availability.
3. Complete Apple Developer and Google Play enrollment, agreements, identity verification, and any required tax or banking setup.
4. Publish the public repository's `main/docs` directory through GitHub Pages. Verify the support and privacy targets in `store/metadata.md` without an authenticated session before adding them to either store record.
5. Create the store records from `store/metadata.md`. Add the publisher's legal name, copyright, pricing, countries, content-rating answers, screenshots, review contact, and review notes.

## Versioning

The version in `pubspec.yaml` uses `major.minor.patch+build` format. Increment the build number for every upload. Increment the public version when the user-visible release version changes.

Release from a clean `main` and push the release commit before uploading. Use the repository's conventional commit style; a version-only change is `chore: prepare <version> build <build>`. The committed version and build provide the release history; tags are optional.

## Preflight checks

From the repository root:

```sh
flutter pub get
oxfmt --check README.md 'docs/**/*.md' 'store/**/*.md'
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build appbundle --release
(cd android && ./gradlew :app:lintRelease)
flutter build ios --release --no-codesign
```

The Android bundle and iOS build commands prove both release targets compile without requiring publisher credentials. They do not produce store-uploadable signed artifacts.

Use JDK 17 or 21 for Android builds and lint. JDK 26 is not supported by the current Android toolchain; GitHub Actions pins JDK 17, and local release verification uses JDK 21.

Flutter reports forward-compatibility warnings because `disk_space_plus` and `workmanager_android` still apply the legacy Kotlin Gradle plugin, and part of the iOS plugin set still requires CocoaPods. The current compatible dependency versions build successfully with Flutter 3.44.4 through 3.47.1. Recheck those upstream migrations before a later Flutter upgrade; CocoaPods remains enabled until every required iOS plugin supports Swift Package Manager.

## Android signing and upload

Use [ANDROID_RELEASE.md](ANDROID_RELEASE.md) for the Android signing identity and store rollout plan.

If signing properties are absent, release bundles are deliberately unsigned. This allows local and CI compilation checks without ever using the public Android debug key for a release artifact. Never upload an artifact produced by the unsigned verification command.

The `Android APK` workflow builds a universal APK with trickle's permanent app-signing key. A manual run stores the APK and its SHA-256 checksum as workflow artifacts. Publishing a GitHub Release runs the same build and attaches both files to that release. For a historical commit, run the workflow from `main`, set `source_ref` to the old commit or tag, and set `release_tag` to the existing release:

```sh
gh workflow run android-apk.yml \
  --ref main \
  -f source_ref=<commit-or-tag> \
  -f release_tag=<release-tag>
```

The repository secrets are `ANDROID_KEYSTORE_BASE64` and `ANDROID_KEYSTORE_PASSWORD`. The original keystore remains outside Git and must be retained for every direct APK and Zapstore update.

Current Android store status: the shared app-signing identity and signed GitHub APK workflow are ready, but Google Play and Zapstore still require their publisher setup. The project has a minimum API of 24 and targets API 36, including Google's [API 36 requirement beginning August 31, 2026](https://developer.android.com/google/play/requirements/target-sdk).

Complete Play Console Data safety from `store/metadata.md`, select News & Magazines, provide the hosted privacy URL, complete the required declarations and content rating, and test the exact signed bundle in internal testing before production.

If the publisher is using a personal Play developer account created after November 13, 2023, Google requires a closed test with at least 12 opted-in testers continuously for 14 days before production access can be requested. Organization accounts and older personal accounts follow the eligibility shown by Play Console.

## iOS signing and upload

The Xcode project uses automatic development signing with team `7654L3CX5L`. App Store export uses explicit profiles and an Apple Distribution certificate so builds are reproducible without an Xcode UI account. Xcode 26 or later is required on the release Mac.

The registered `com.parmscript.trickle.ShareExtension` target and App Group `group.com.parmscript.trickle` are attached to the main app and extension identifiers. App Store distribution uses the active profiles `trickle App Store` and `trickle Share Extension App Store`; recreate both after changing their capabilities or distribution certificate. The Xcode release configuration and `store/apple/AppStoreExportOptions.plist` pin the certificate and profiles so multiple active certificates cannot make signing nondeterministic. The build must fail rather than fall back to development signing when any required signing asset is missing.

```sh
tool/release_ios.sh build
```

This runs formatting, analysis, and tests before producing `build/ios/ipa/trickle.ipa`. To rebuild, validate, and upload directly to App Store Connect without Xcode Organizer or Transporter UI:

```sh
tool/release_ios.sh upload
```

The upload uses App Store Connect key `DC6F5JMNM3` and issuer `19bebb70-4123-40d3-9379-1476fcc51b60` by default, with the private key kept outside the repository at `~/.appstoreconnect/private_keys/AuthKey_DC6F5JMNM3.p8`. Set `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, or `API_PRIVATE_KEYS_DIR` to override them.

Apple has required [Xcode 26 or later with the iOS 26 SDK or later since April 28, 2026](https://developer.apple.com/news/upcoming-requirements/?id=02032026a). The verified local release environment uses Xcode 26.6 and the iOS 26.5 SDK.

The main app and share extension include privacy manifests. Their App Group `UserDefaults` access declares Apple reason `1C8F.1`; the shared text stays on-device. The application also includes background-audio configuration, its background-refresh identifier, the encryption declaration, and a 1024-pixel icon. A final build phase removes the downloader SDK's generic Photo Library declaration because trickle stores audio only in app-private storage and does not use that optional SDK feature.

The application targets iOS 17 or later, exceeding Apple's announced iOS 15 minimum for App Store Connect uploads and distribution submissions beginning in Spring 2027. Test fresh installs and upgrades on iOS 17 before every release.

The iOS target is iPhone-only. The five 1320×2868 images in `store/apple/screenshots/` were regenerated and visually verified against 1.2 on August 26, 2026. Their fictional podcast, feed, copy, and artwork are original project fixtures under `store/apple/fixtures/`; no third-party content appears. To replace the complete set after a visual change, build and launch trickle once on a booted iPhone Pro Max simulator with that resolution, then run:

```sh
tool/maestro/capture_store_screenshots.sh [simulator-udid]
```

The command seeds only the selected simulator's app data, fixes the capture environment, verifies every image is 1320×2868, and replaces all five checked-in files only after the Maestro flow passes. Fixture logic and artwork are not bundled into the released app.

In App Store Connect, use `store/metadata.md` and `store/app_review_notes.md`, answer App Privacy as no data collected by the developer, and publish that response before submitting a version. Provide the verified hosted privacy and support URLs, complete age-rating and content-rights answers, attach the current screenshots, provide review contact details, and test the uploaded build using `store/testflight_notes.md`.

## Acceptance checklist

- Installation: fresh install, upgrade, relaunch, offline launch, low storage, and database migration
- Playback: stream, seek, pause, resume, previous/next, interruptions, unplugged headphones, lock screen, background audio, one bounded recovery after an unexpected native stop, and every global speed
- Downloads: Wi-Fi/mobile policy, automatic/manual download, pause, retry, completion, keep, item and byte totals, played-only bulk removal, all-download removal, and every cleanup policy
- Queue and extras: reorder, remove, persistence, sleep timers, intro/outro skip, repeat-one, chapters, searchable timed and untimed transcripts, tap-to-seek, and bookmarks
- Subscriptions: complete catalog previews before subscription and after in-place unsubscribe, concurrent row-level catalog subscriptions, catalog recognition of public podcasts imported through OPML, capitalization-stable search, podcast-only direct URL validation, public/private direct URLs, query/path credentials, website discovery, system share-in with editable confirmation, Nostr `npub`/`nprofile`, malformed feeds, redirects, UTF-8/UTF-16 OPML import, reader-category OPML folder round-trips, one OPML scope chooser for podcasts, feeds, or all compatible subscriptions, versioned local backup/restore with duplicate-picker protection and actionable picker/read failures, and unsubscribe cleanup with retained saved or in-progress items
- Reader: RSS, Atom, JSON Feed, YouTube channel and playlist discovery, verified Nostr root posts without replies or reposts, relay timeouts, early closure, conflicting duplicate IDs, stale-response rejection, category assignment while subscribing and from source details, bulk category moves, confirmed category merges, category unread counts, category timelines and bulk-read actions, per-source search/filter/sort, persistent text size, offline saved article text, Markdown, content warnings, post attachments, native post audio, direct post video, unread/read/saved state, reader extraction, preview images, local search, remote-image toggle, sharing, and external links
- Video: initial-page loading, official-source fallback only after failure, minimize/expand without reload, a live minimized preview, a thumbnail-only in-app bar during user-started system Picture in Picture, foreground system-window dismissal and restoration to the same live minimized player, background system-window dismissal that fully closes the player, background audio only during Picture in Picture, foreground-only behavior otherwise, network loss, and close/reopen
- Loading and failures: initial, inline, row-level, and pull-to-refresh progress; repeated-tap prevention; coalesced duplicate refreshes; stale-response rejection; 10-second video-source attempts; 15-second background work; 30-second document and per-feed deadlines; partial refresh results; actionable retry controls; safe malformed-file messages; and replacement rather than stacking of transient messages
- System behavior: notification denied/granted, per-feed notifications, background refresh, airplane mode, DNS failure, and server errors
- Accessibility and layout: VoiceOver, TalkBack, dynamic text, small/large phones, portrait/landscape, contrast, and smooth long-list scrolling
- Packaging: signed main app and share extension, matching App Group entitlements and distribution profiles, privacy report, no cleartext traffic, no committed secret material, and production signing
