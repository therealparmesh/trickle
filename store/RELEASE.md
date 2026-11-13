# Release Process

For the first Google Play and Zapstore launch, follow the staged [Android release plan](ANDROID_RELEASE.md) in addition to this shared checklist.

## Publisher prerequisites

1. The Apple Developer bundle identifier `com.parmscript.trickle` is registered, and App Store Connect record `6792352845` exists. Create the initial Google Play app record before uploading there; public store APIs manage existing apps but do not create initial records. If the identifier must change, update it before the first release in `android/app/build.gradle.kts`, the iOS Runner target, `lib/services/background_refresh_service.dart`, `ios/Runner/AppDelegate.swift`, and `ios/Runner/Info.plist`.
2. Use `trickle: podcasts & RSS` for the unique App Store listing name and lowercase `trickle` for the on-device product name. Store consoles are authoritative for name and identifier availability.
3. Complete Apple Developer and Google Play enrollment, agreements, identity verification, and any required tax or banking setup.
4. Publish the public repository's `main/docs` directory through GitHub Pages. Verify the support and privacy targets in `store/metadata.md` without an authenticated session before adding them to either store record.
5. Create the store records from `store/metadata.md`. Add the publisher's legal name, copyright, pricing, countries, content-rating answers, screenshots, review contact, and review notes.

## Versioning

The version in `pubspec.yaml` uses `major.minor.patch+build` format. Increment the build number for every upload. Advance the public version in order for each new release. If replacing a candidate before it goes live on the App Store, keep the public version and increment only the build number.

Release from a clean `main` and push the release commit before uploading. Use the repository's conventional commit style and put the version bump in the release's fix or feature commit. If the changes are already committed, put the bump last as `chore: prepare <version> build <build>`. Tag the release commit for Android distribution.

Keep one GitHub release, one tag, and one active store build per public version. For a replacement, select the new App Store build and expire the superseded TestFlight build. Delete the superseded GitHub release and tag before publishing the replacement. Clean up only Android APK runs tied to the deleted release or tag; keep main-branch CI and Pages history.

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

Flutter reports forward-compatibility warnings because `disk_space_plus` and `workmanager_android` still apply the legacy Kotlin Gradle plugin, and part of the iOS plugin set still requires CocoaPods. The current compatible dependency versions build successfully with Flutter 3.44.4 through 3.47.9. Recheck those upstream migrations before a later Flutter upgrade; CocoaPods remains enabled until every required iOS plugin supports Swift Package Manager.

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

Apple has required [Xcode 26 or later with the iOS 26 SDK or later since April 28, 2026](https://developer.apple.com/news/upcoming-requirements/?id=02032026a). The local release environment uses Xcode 27.2 and the iOS 27.2 SDK.

The main app and share extension include privacy manifests. Their App Group `UserDefaults` access declares Apple reason `1C8F.1`; the shared text stays on-device. The application also includes background-audio configuration, its background-refresh identifier, the encryption declaration, and a 1024-pixel icon. A final build phase removes the downloader SDK's generic Photo Library declaration because trickle stores audio only in app-private storage and does not use that optional SDK feature.

The application targets iOS 17 or later, exceeding Apple's announced iOS 15 minimum for App Store Connect uploads and distribution submissions beginning in Spring 2027. Test fresh installs and upgrades on iOS 17 before every release.

The iOS target is iPhone-only. The five 1320×2868 images in `store/apple/screenshots/` show the fictional podcast and feed from `store/apple/fixtures/`; all copy and artwork are original. To replace the complete set after a visual change, build and launch trickle once on a booted iPhone Pro Max simulator with that resolution, then run:

```sh
tool/maestro/capture_store_screenshots.sh [simulator-udid]
```

The command seeds only the selected simulator's app data, fixes the capture environment, verifies every image is 1320×2868, and replaces all five checked-in files only after the Maestro flow passes. Fixture logic and artwork are not bundled into the released app.

In App Store Connect, use `store/metadata.md` and `store/app_review_notes.md`, answer App Privacy as no data collected by the developer, and publish that response before submitting a version. Provide the verified hosted privacy and support URLs, complete age-rating and content-rights answers, attach the current screenshots, provide review contact details, and test the uploaded build using `store/testflight_notes.md`.

## Acceptance checklist

- Installation: fresh install, upgrade, relaunch, offline launch, low storage, and database migration. Verify upgrades preserve saved items, enriched search text, and queued or staged episodes with downloads pending. Old article content must not be promoted into the new reader cache
- Playback: stream, seek, pause, resume, previous/next, resume the selected episode after opening a video during podcast loading, and seek after clearing Up next. Check system interruptions with and without permission to resume, explicit pause during an interruption, unplugged headphones, lock screen, background audio, one recovery attempt after an unexpected stop, and every global speed
- Android playback: lock the screen during a transient audio interruption and verify the same episode resumes when focus returns. With the screen off, let an episode finish and verify that the next queued episode starts. Verify that explicit pause, permanent focus loss, or 10 minutes without focus returning leave the episode paused and release the foreground service.
- Playback failures and handoff: Retry reloads the current episode at its saved position. A failure from an older Play request must not stop a newer request. A stalled native audio load must time out after 30 seconds without blocking Stop or a new selection. If saving an episode's completion fails, playback must stop with Retry available; the episode must not be marked played or removed from Up next. Pause at the end of an episode must prevent autoplay without leaving the finished episode in Now playing.
- Downloads: Wi-Fi/mobile policy, automatic/manual download, pause, resume, retry, completion, keep, item and byte totals, played-only bulk removal, all-download removal, and every cleanup policy. Resume should appear only after the downloader confirms Pause. Late progress must not change completed byte counts or cancel a replaced download. If playback finds a missing or unusable file, it should try streaming and offer Retry download without a restart. Manually downloading a played episode should keep the new file until you allow automatic removal.
- Backup playback state: restore newer progress for a paused episode, then close and reopen the app. Now playing must use the restored position and stay paused. Restore a backup made before finishing a queued episode; Up next must not re-add that episode. A newer backup containing an unfinished replay must restore its progress and queue entry. Try reordering or removing an episode while a backup is being applied; Up next must allow edits once the queue reloads.
- Private feeds: restore a portable private feed on a fresh install. Re-add a private feed restored by an older version and verify that saved items, playback positions, and older retained episode URLs survive refresh. Without GUIDs, rotating recognized URL tokens must preserve the original items, while different article links and media selectors stay separate.
- Catalog playback: play an episode before subscribing, then subscribe. Playback progress should stay on one episode even if the catalog address first opens a website that links to the feed. If that exact feed is already private, preview playback must not create a public copy or merge accounts with different credentials. A slow preview must not override a later Play, Pause, or video selection.
- Queue and extras: reorder, remove, persistence, cancel a drag if the queue order changes without losing newly queued items, automatic additions merged once after the current queue, staged episodes retained on unsubscribe and removed by Clear Up next, download retries that never re-add a removed episode, sleep timers, intro/outro skip, repeat-one, chapters, searchable timed and untimed transcripts, tap-to-seek, and bookmarks
- Queue conflicts: add an episode, clear Up next, and add a different episode in quick succession. Only the last addition should remain. If a background refresh has staged an episode you add and then remove manually, it must not reappear after the next refresh.
- Download recovery: reopen trickle after an interrupted transfer. If the native downloader cannot restart the task, the row must offer Retry download rather than stay on Downloading. Removing a download during recovery must not restart it. An automatic download skipped for low storage should retry on refresh after storage is freed.
- Sleep timer: cancel during the fade and confirm the podcast keeps playing. If system audio has lowered the podcast volume, canceling the timer should keep it lowered until the interruption ends. The podcast timer must not pause video playback.
- Playback speed: change speed while listening, start another episode, and restart the app. The selected speed should agree with playback throughout. Restore a backup with a different speed and verify it applies on the next play.
- Replay: start a played episode, pause after listening partway, and reopen the app. The replay should appear in In progress and return paused at its saved position. A failed attempt to replay it must not clear Played.
- Subscriptions: complete catalog previews before subscription and after in-place unsubscribe, concurrent row-level catalog subscriptions, catalog recognition of public podcasts imported through OPML, capitalization-stable search, automatic podcast/feed classification with mismatch feedback, public/private direct URLs, query/path credentials, website discovery with multiple advertised feeds, system share-in with editable confirmation, Nostr `npub`/`nprofile`, malformed feeds, redirects, UTF-8/UTF-16 OPML import, reader-category OPML folder round-trips, one OPML scope chooser for podcasts, feeds, or all compatible subscriptions, versioned local backup/restore with duplicate-picker protection and actionable picker/read failures, and unsubscribe cleanup with retained saved or in-progress items
- Reader: RSS, Atom, JSON Feed, YouTube channel and playlist discovery, verified Nostr root posts without replies or reposts, relay timeouts, early closure, conflicting duplicate IDs, stale-response rejection, category assignment while subscribing and from source details, bulk category moves, confirmed category merges, category unread counts, category timelines and bulk-read actions, per-source search/filter/sort, persistent text size, offline saved article text, Markdown, content warnings, post attachments, native post audio, direct post video, unread/read/saved state, reader extraction, preview images, local search, remote-image toggle, sharing, and external links
- Reader layout: ordinary HTML5 pages with omitted optional closing tags, tables, nested lists, linked images, code blocks, large text, and long articles. A long feed summary must still fetch the page; a short cached article must reopen offline. Failed refresh must keep the last readable text. Private image headers must not reach unrelated hosts
- Resubscription: unsubscribe from a public feed, a retained private podcast, or a Nostr profile during a slow refresh, then add it again. The new refresh must not wait for the old response. Saved items must remain, and the old response must not overwrite the new subscription.
- Nostr video: play an attachment through a redirected or fallback URL. Open video player should return to that session. If a refreshed post removes the attachment, the player must close even when the post stays in the feed.
- Nostr refresh: an older signed edit must not replace a newer one. A relay that still returns a deleted post must not bring it back, but an edit published after an address deletion should appear. Importing an older backup must not restore a locally deleted post or reattach media removed by a newer edit. Saved state can still merge into a surviving post.
- Backup merge: restore an older backup after unsubscribing from a retained feed or podcast. The subscription must remain off and untouched items must stay out of search. Saved items and episodes with library state can still be restored.
- Video: initial-page loading, official-source fallback only after failure, minimize/expand without reload, a live minimized preview, a thumbnail-only in-app bar during user-started system Picture in Picture, foreground system-window dismissal and restoration to the same live minimized player, background system-window dismissal that fully closes the player, background audio only during Picture in Picture, foreground-only behavior otherwise, network loss, and close/reopen. Try backgrounding during startup and pausing immediately after closing foreground Picture in Picture: a late callback must not restart the video, and a missing playback reply must not leave the mini-player stuck on Buffering. Closing the player cancels pending media selection, and a stalled command from the closed player must not delay the next video. Removing the item or replacing its YouTube video closes the old session; an equivalent URL for the same video does not.
- Loading and failures: initial, inline, row-level, and pull-to-refresh progress; repeated-tap prevention; coalesced duplicate refreshes; stale-response rejection; 10-second video-source attempts; a shared 15-second background network budget for feed and automatic-download requests; 30-second document and per-feed deadlines; partial refresh results; actionable retry controls; safe malformed-file messages; and replacement rather than stacking of transient messages
- Live lists: repeated and large refresh batches preserve the visible item, defer row changes until active scrolling ends, keep open menus and pending actions attached to their item, and remove deleted rows. Home's episode shelf must preserve its horizontal position, including at accessibility text sizes
- System behavior: notification denied/granted, per-feed notifications, background refresh, airplane mode, DNS failure, and server errors
- Accessibility and layout: VoiceOver, TalkBack, dynamic text, small/large phones, portrait/landscape, contrast, and smooth long-list scrolling. Publication timestamps use minutes or hours ago until 24 hours and then a calendar date across lists and details. Dates must remain readable on narrow screens and at large text sizes. Episode overflow actions stay in the trailing toolbar. Navigation glitches are sampled once with a one-in-four chance and never appear with Reduce Motion
- Packaging: signed main app and share extension, matching App Group entitlements and distribution profiles, privacy report, no cleartext traffic, no committed secret material, and production signing. Verify Android media controls on the optimized release APK; the resource shrinker must retain the audio-service icons referenced by name.
