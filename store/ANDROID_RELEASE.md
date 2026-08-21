# Android release plan

This is the executable plan for publishing trickle to Google Play and Zapstore. The shared release checklist remains in [RELEASE.md](RELEASE.md).

## Agent handoff

The objective is to ship one Android release from one source commit to both stores, with repeatable command-line releases afterward. A future agent should execute this document rather than redesign the release process.

Start every session from `/Users/parmesh/code/trickle`:

```sh
git fetch origin --prune
git status --short
test "$(git branch --show-current)" = main
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
rg '^version:' pubspec.yaml
```

Stop before publishing if the tree is dirty, local `main` differs from `origin/main`, the package/version is unexpected, a credential is missing, a certificate fingerprint differs, or a store has already consumed the candidate version code.

Do not create a new package, signing identity, Google Cloud project, Play record, or Nostr publisher identity when an existing one may exist. Search the repository and local secure configuration first, then ask the owner only for a choice that cannot be recovered.

### CLI boundary

Recurring releases are command-line driven. Google does not expose every first-release operation through its Publishing API, so these one-time Play Console gates remain:

- Developer enrollment, agreements, identity, and legal declarations
- Initial app record
- Play App Signing enrollment and first binary upload
- Granting the publisher service account access inside Play Console
- First production publication; managed publishing is unavailable until the app has already been published

The future agent should operate those gates through an authenticated browser session when available rather than asking the owner to perform routine clicks. After the first public release, builds, metadata, screenshots, test-track uploads, track promotion, GitHub releases, and Zapstore publication are CLI-driven. Google review state and the final managed-publishing action may still require Play Console because the Publishing API does not expose every console workflow.

## Current state

- Package: `com.parmscript.trickle`
- Candidate release: `1.0.0` (`versionCode` 47)
- Android support: API 24 or later
- Target SDK: API 36
- Google Play: no locally verifiable app record, production signing, upload credential, or release
- Zapstore: no `zapstore.yaml`, publisher identity, signed APK, or release
- Store media: the copyright-safe iPhone fixtures exist, but Google Play needs Android captures with a supported aspect ratio

Build 47 can be the first Android release if live Play and Zapstore checks confirm that neither has consumed it. Before building, query every available track and the Zapstore listing; repository history alone is not proof.

## Distribution decisions

1. Use the same package name and app-signing certificate on Google Play and Zapstore. Android can then accept an update from either store.
2. Generate and retain the app-signing key outside the repository. Transfer an encrypted copy to Play App Signing during initial setup.
3. Use a separate upload key for bundles sent to Google Play. A compromised upload key can then be replaced without changing the installed-app identity.
4. Sign the Zapstore APK with the app-signing key, not the Play upload key.
5. Build the Play AAB and Zapstore APK from the same clean commit, version, dependencies, and Flutter toolchain.
6. Enable Managed Publishing after Google's first public release and keep later production releases manual. Zapstore publication remains an explicit CLI action.
7. Publish the APK as a GitHub release asset so Zapstore users receive an immutable artifact tied to the public source commit.

Google can generate the app-signing key and provide a signed universal APK for other stores, but that would make every Zapstore release wait for Google. Retaining the shared app-signing key is the cleaner multi-store design.

## Secrets and signing

Create two RSA keys:

- App-signing key: signs installable Zapstore APKs and is transferred securely to Play App Signing.
- Play upload key: signs AAB files submitted to Google Play.

Requirements:

- Use RSA 4096-bit keys with a validity of 10,000 days. This exceeds Android's 25-year recommendation without relying on default keytool values.
- Give the keys different aliases and passwords.
- Keep both keystores and recovery information outside the repository.
- Keep two encrypted backups in separate locations and test recovery before the first public upload.
- Store local properties under `~/.config/trickle/android/` with owner-only permissions:
  - `app-signing.jks`
  - `app-signing.properties`
  - `play-upload.jks`
  - `play-upload.properties`
  - `play-service-account.json`
- Never commit keystores, passwords, Play credentials, Nostr private keys, bunker URLs, generated `.aab` files, or generated `.apk` files.
- Record the SHA-256 certificate fingerprint in the private release record and compare it with both stores before publishing.

Create the keystores interactively so passwords never enter shell history:

```sh
install -d -m 700 "$HOME/.config/trickle/android"
keytool -genkeypair -v \
  -keystore "$HOME/.config/trickle/android/app-signing.jks" \
  -alias trickle-app -keyalg RSA -keysize 4096 -validity 10000
keytool -genkeypair -v \
  -keystore "$HOME/.config/trickle/android/play-upload.jks" \
  -alias trickle-upload -keyalg RSA -keysize 4096 -validity 10000
chmod 600 "$HOME/.config/trickle/android/"*.jks
```

Each external properties file uses the same four keys as `android/key.properties.example`: `storePassword`, `keyPassword`, `keyAlias`, and absolute `storeFile`. Never print either file.

Add a small Android release command that selects one of two external signing profiles without copying secrets into the repository:

- `play`: signs an AAB with the upload key.
- `distribution`: signs an APK with the app-signing key.

The command must refuse to run from a dirty tree, refuse missing credentials, print the package/version/certificate fingerprint, and never fall back to the debug key.

Update Gradle once to read the properties path from `TRICKLE_ANDROID_KEY_PROPERTIES`. Verification builds remain unsigned when that variable is absent. The release command sets it to `play-upload.properties` for the AAB and `app-signing.properties` for the APK. This avoids swapping `android/key.properties` and makes the chosen signing role explicit in every build.

## Phase 1: Publisher setup

### Google Play

The Publishing API works only after the app exists and at least one binary has been uploaded through Play Console. It also cannot complete the legal consents required for first publication.

1. Confirm the Play developer account is enrolled, verified, and has current agreements.
2. Create an app named `trickle: podcasts & RSS` with package `com.parmscript.trickle`.
3. Select app, free, and News & Magazines. Do not create a production release yet.
4. Enroll in Play App Signing and choose the option to provide the existing app-signing key.
5. Download the current PEPK tool and use the exact encryption-key command generated by Play Console to transfer the app-signing key. Do not invent or save the console's encryption parameters in the repository.
6. Register the separate upload-key certificate.
7. Confirm Play's app-signing certificate fingerprint equals the local distribution certificate fingerprint.
8. Note the linked Google Cloud project ID from Play Console. Install `gcloud` if needed, authenticate, then create the least-privileged publisher identity:

   ```sh
   gcloud services enable androidpublisher.googleapis.com --project "$GOOGLE_CLOUD_PROJECT"
   gcloud iam service-accounts create trickle-play-publisher \
     --display-name='trickle Play publisher' \
     --project "$GOOGLE_CLOUD_PROJECT"
   gcloud iam service-accounts keys create \
     "$HOME/.config/trickle/android/play-service-account.json" \
     --iam-account "trickle-play-publisher@${GOOGLE_CLOUD_PROJECT}.iam.gserviceaccount.com" \
     --project "$GOOGLE_CLOUD_PROJECT"
   chmod 600 "$HOME/.config/trickle/android/play-service-account.json"
   ```

9. Grant that service account only store-presence, testing-release, and production-release permissions for trickle inside Play Console. Do not grant account-wide administration.
10. Determine whether the account requires the 12-tester, 14-continuous-day closed test that applies to newer personal accounts. Record the console's answer rather than assuming eligibility.

The credential cannot be validated against the Publishing API until the first binary has been uploaded in Phase 7.

### Zapstore

1. Search the public catalog for the exact package `com.parmscript.trickle`. If another publisher has claimed it, stop and resolve ownership rather than creating a duplicate identity.
2. Choose the long-lived Nostr identity that will represent trickle releases.
3. Use a NIP-46 bunker for release signing. Do not place an `nsec` in shell history, repository files, CI configuration, or ordinary environment files.
4. Install a pinned `zsp` release and record its version in the release manifest. Do not use an unpinned `@latest` during a production release.
5. Run the first-time wizard to produce `zapstore.yaml`.
6. Commit only the public configuration, including the repository URL and publisher `npub`.
7. Link the Android app-signing certificate to the Nostr identity with `zsp identity --link-key`.
8. Verify repository-based publisher whitelisting before the first public release.

Store the bunker connection in macOS Keychain under service `trickle-zapstore-bunker`. Load it only for the `zsp` process:

```sh
SIGN_WITH="$(security find-generic-password \
  -s trickle-zapstore-bunker -a trickle -w)" \
  zsp publish --check zapstore.yaml
```

The committed `zapstore.yaml` should follow this shape; replace the public `npub` through the wizard and use reviewed copy from `store/metadata.md`:

```yaml
repository: https://github.com/therealparmesh/trickle
pubkey: npub1replace_with_trickle_publisher
name: trickle
summary: Play podcasts and read RSS, Atom, JSON, YouTube, and Nostr feeds
tags:
  - podcast
  - rss
  - news
  - nostr
metadata_sources:
  - fastlane
icon: fastlane/metadata/android/en-US/images/icon.png
images:
  - fastlane/metadata/android/en-US/images/phoneScreenshots/01-home.png
  - fastlane/metadata/android/en-US/images/phoneScreenshots/02-podcast.png
  - fastlane/metadata/android/en-US/images/phoneScreenshots/03-episode.png
  - fastlane/metadata/android/en-US/images/phoneScreenshots/04-unread.png
  - fastlane/metadata/android/en-US/images/phoneScreenshots/05-reader.png
match: '^trickle-.*-universal\.apk$'
```

Do not run publication while the placeholder `npub` remains. The repository release asset is the default APK source, so do not add a mutable direct-download URL.

## Phase 2: Repository release support

Implement these narrow, removable release-only additions:

- `tool/release_android.sh`: preflight, signed AAB/APK builds, signature inspection, and checksums
- `Gemfile` and `Gemfile.lock`: pin Fastlane rather than relying on the machine-global Ruby
- `fastlane/Appfile`: package name plus `GOOGLE_PLAY_JSON_KEY` lookup; no credential value
- `fastlane/Fastfile`: status, validation, metadata, internal-test, and production-promotion lanes
- `fastlane/metadata/android/en-US/`: canonical Google listing text, release notes, and media
- `tool/maestro/seed_store_screenshot_data_android.sh`: seed only a selected debuggable emulator through `adb run-as`
- `tool/maestro/capture_store_screenshots_android.yaml`: capture the five Android listing screens
- `zapstore.yaml`: public Zapstore configuration
- `store/google/declarations.md`: the final Play Console answers and the evidence used for them

The release command should support:

```sh
tool/release_android.sh verify
tool/release_android.sh play
tool/release_android.sh distribution
```

`verify` runs all non-publishing checks. `play` creates only the Play AAB. `distribution` creates only the Zapstore APK. Upload and publication remain separate commands so a build cannot accidentally release itself.

Use these Fastlane lanes and no overlapping upload scripts:

- `play_status`: read internal, closed, and production version codes without mutation
- `play_validate`: run `validate_only` against metadata and media without a binary
- `play_metadata`: upload only reviewed listing text and media
- `play_internal`: upload the supplied AAB to Internal testing as `completed`
- `play_promote`: promote an already-tested version code to production; it must require `CONFIRM_PRODUCTION=1`

All lanes read the credential from `GOOGLE_PLAY_JSON_KEY`, defaulting to `~/.config/trickle/android/play-service-account.json`, and fail if it is absent. Production lanes must call `ensure_git_status_clean`, verify `main == origin/main`, query existing version codes first, and never default to production or a 100-percent rollout.

Bootstrap Fastlane with a managed Ruby 3.3 or later and Bundler, commit the lockfile, and always invoke it through `bundle exec fastlane`. Do not use macOS system Ruby 2.6.

Flutter writes the first two paths below; the release command copies verified artifacts into ignored `build/releases/` names used by upload commands:

- Play source: `build/app/outputs/bundle/release/app-release.aab`
- Zapstore source: `build/app/outputs/flutter-apk/app-release.apk`
- Play upload: `build/releases/trickle-1.0.0-47.aab`
- GitHub/Zapstore: `build/releases/trickle-1.0.0-47-universal.apk`
- Checksums: one matching `.sha256` file per published artifact
- Local evidence: `build/releases/release-manifest.json`, copied to the encrypted release archive after publication

## Phase 3: Store media and copy

1. Capture at least five copyright-safe Android screenshots from a 1080×1920 phone profile using the existing fictional podcast and feed fixtures.
2. Show Home, podcast details, episode actions, unread feeds, and reader mode in the same order as Apple.
3. Confirm each image is JPEG or 24-bit PNG without alpha, between 320 and 3840 pixels, and no side exceeds twice the other side.
4. Create the required Play assets from the existing trickle brand sources: a 512×512 32-bit PNG icon with alpha under 1024KB, and a 1024×500 JPEG or 24-bit PNG feature graphic without alpha.
5. Use human copy from `store/metadata.md`, adjusted only for Play field limits.
6. Do not show or name third-party podcasts, feeds, creators, trademarks, storefronts, or copyrighted artwork.
7. Do not imply affiliation with YouTube or promise behavior the official fallback cannot guarantee.
8. Keep Zapstore metadata explicit in `zapstore.yaml`; do not let enrichment silently replace reviewed copy or images.
9. Write concise alt text of 140 characters or fewer for every graphic and screenshot, record it beside the declarations, and add it in Play Console where the Publishing API cannot.
10. Keep the feature graphic recognizably cyberpunk with trickle's cyan/magenta geometry and a centered focal point; avoid pure black edges that disappear into Play surfaces, tiny copy, device frames, or duplicated icon art.

Use a dedicated API 36 Android Virtual Device with a native 1080×1920 phone profile. Launch a debuggable build once, seed only that emulator, and capture through Maestro:

```sh
export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
export PATH="$ANDROID_SDK_ROOT/platform-tools:$PATH"
SERIAL="$(adb devices | awk 'NR > 1 && $2 == "device" {print $1; exit}')"
test -n "$SERIAL"
flutter build apk --debug
adb -s "$SERIAL" install -r build/app/outputs/flutter-apk/app-debug.apk
tool/maestro/seed_store_screenshot_data_android.sh "$SERIAL"
maestro --device "$SERIAL" test \
  tool/maestro/capture_store_screenshots_android.yaml
```

The seed script must fail unless the selected target is an emulator, launch the app and wait no more than 10 seconds for its database, use `adb -s "$SERIAL" run-as com.parmscript.trickle`, and change only that app's local database. It must reuse the existing fictional fixtures and never add fixture code or assets to the release bundle. Verify there is no debug banner in captures; if the app does not already suppress it, use a profile build that remains accessible to the seed command rather than editing production UI for screenshots.

Save Play assets in Fastlane's standard layout:

```text
fastlane/metadata/android/en-US/title.txt
fastlane/metadata/android/en-US/short_description.txt
fastlane/metadata/android/en-US/full_description.txt
fastlane/metadata/android/en-US/changelogs/47.txt
fastlane/metadata/android/en-US/images/icon.png
fastlane/metadata/android/en-US/images/featureGraphic.png
fastlane/metadata/android/en-US/images/phoneScreenshots/01-home.png
fastlane/metadata/android/en-US/images/phoneScreenshots/02-podcast.png
fastlane/metadata/android/en-US/images/phoneScreenshots/03-episode.png
fastlane/metadata/android/en-US/images/phoneScreenshots/04-unread.png
fastlane/metadata/android/en-US/images/phoneScreenshots/05-reader.png
```

Fastlane replaces a screenshot set in filename order. The `play_validate` lane must run before any media upload, and `play_metadata` must enable image hash synchronization so unchanged images are not resent.

## Phase 4: Policy declarations

Complete these against the final signed APK, not assumptions from the iOS submission:

- Privacy policy and support URLs
- Data safety
- Ads
- Target audience and content
- Content rating
- App access
- News and user-generated or open-web content declarations, if presented by Play Console
- Copyright and content-rights declarations

Specific rules for trickle:

- The app itself has no ad SDK or developer-run advertising, but the official web fallback can display third-party ads. The conservative initial declaration is “contains ads” unless the final Android build cannot display any ad.
- Open feeds and linked pages can contain third-party content. Store policies apply to content displayed or linked by the app.
- Verify the final APK manifest and dependency inventory before selecting “no data collected.” Document any third-party processing separately from data collected by the developer.
- State that no account is required and therefore account deletion is not applicable.
- Reviewer notes must explain podcast playback, reader mode, external feeds, video fallback, Picture in Picture, background audio, and how to reach each feature without private credentials.

Before uploading the first binary, create a dated decision record in `store/google/declarations.md` for the alternate YouTube frontend, official fallback, background playback, third-party page ads, and content rights. Google policies cover linked and WebView content. Do not infer permission from another app's behavior, and do not describe the release as legally or policy-approved without evidence. An unresolved content-rights or platform-terms question is a release blocker for Google Play, not something to hide in copy.

## Phase 5: Reproducible candidate build

From a clean, pushed `main` commit:

```sh
export JAVA_HOME="$(mise where java@openjdk-21.0.2)"
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
export GOOGLE_PLAY_JSON_KEY="$HOME/.config/trickle/android/play-service-account.json"
tool/release_android.sh verify
tool/release_android.sh play
tool/release_android.sh distribution
```

Run `bundle exec fastlane android play_status` before building only when the Publishing API has already been activated by an earlier Play upload. For the first Android release, confirm unused package/version state in Play Console and Zapstore instead.

`verify` runs `flutter pub get`, documentation and Dart formatting checks, `flutter analyze`, `flutter test`, Android `lintRelease`, an unsigned release bundle build, tool/version checks, and secret scans exactly once. The signed build modes depend on a successful `verify` result from the same commit and toolchain.

The release script must resolve `apksigner` from `$ANDROID_SDK_ROOT/build-tools` and fail if API 36 build tools are unavailable. Pin `bundletool` and `zsp` versions in the release manifest before using them; do not silently download latest binaries during a release.

The release command must then verify:

- Package is exactly `com.parmscript.trickle`.
- Version name is `1.0.0` and version code is 47.
- Minimum SDK is 24 and target SDK is 36.
- AAB is signed by the Play upload certificate.
- APK is signed by the shared app-signing certificate.
- APK signature schemes and certificate chain pass `apksigner verify`.
- AAB passes `jarsigner -verify` and bundle manifest inspection.
- Release artifacts contain no debug certificate, secrets, screenshot fixtures, or capture tooling.
- SHA-256 checksums, Git commit, Flutter version, Java version, and artifact sizes are written to a local release manifest.
- The two artifacts report the same application ID, version name, version code, minimum SDK, and target SDK; the release manifest maps both artifact hashes to the same source commit.
- The only expected byte difference between rebuilt identical artifacts is signing or nondeterministic tool output documented in the manifest; compare extracted manifests and file inventories rather than assuming equality.

Install and test both delivery forms:

1. Generate a device APK set from the AAB with `bundletool`, explicitly sign the generated APKs with the retained app-signing key, verify that fingerprint, and install it on an Android 7/API 24 target and a current Android target. Never accept bundletool's debug-signing fallback.
2. Install the signed Zapstore APK on the same current Android target.
3. On one disposable emulator snapshot, install an AAB-derived APK and update it with a higher-version distribution APK.
4. On a separate disposable snapshot, install a distribution APK and update it with a higher-version AAB-derived APK.
5. Use temporary version overrides that are never uploaded, then wipe both snapshots so their higher version codes cannot block public build 47.

## Phase 6: Acceptance test

Run the complete acceptance checklist in [RELEASE.md](RELEASE.md) against both signed delivery forms, not a debug build. Add Android-specific evidence for API 24, a current Android version, TalkBack, predictive back, notification permission, background restrictions, Picture in Picture, Play-delivered installation, direct APK installation, and both cross-store update directions.

Record pass/fail evidence in the private release archive. Any code, dependency, manifest, resource, or runtime configuration change invalidates both candidate artifacts. Rebuild both from the new commit; retain version code 47 only if neither store has consumed it, otherwise increment the version code.

## Phase 7: Google Play rollout

1. Upload the verified candidate AAB from `build/releases/trickle-1.0.0-47.aab` to Internal testing through Play Console. Install it once. This activates Publishing API access and consumes version code 47; any later binary change requires 48.
2. Validate the publisher credential:

   ```sh
   bundle exec fastlane run validate_play_store_json_key \
     json_key:"$HOME/.config/trickle/android/play-service-account.json"
   ```

3. Use Fastlane to upload the reviewed listing, Android screenshots, icon, feature graphic, and release notes.
4. Install from Play Internal testing and repeat the critical acceptance paths.
5. Resolve Pre-launch report, policy, signing, compatibility, and Android vitals findings.
6. If required, run the closed test with at least 12 opted-in testers continuously for 14 days and then request production access.
7. Run `bundle exec fastlane android play_status` and confirm production has no version 47 before promotion.
8. Prepare and validate the production track through the CLI, but complete all first-publication legal consents and the final publication in Play Console. Google's API cannot publish a draft app, and Managed Publishing is unavailable for the first release.
9. Expect the first approved production release to become public without a managed-publishing hold. Confirm the live package, version, listing, privacy link, and install before publishing Zapstore.

After the one-time console upload has activated API access, the intended CLI flow is:

```sh
bundle exec fastlane android play_status
bundle exec fastlane android play_validate
bundle exec fastlane android play_metadata

# Later releases upload the verified AAB to Internal testing.
bundle exec fastlane android play_internal \
  aab:build/releases/trickle-1.0.0-48.aab

# Promotion requires an explicit version and production confirmation.
CONFIRM_PRODUCTION=1 bundle exec fastlane android play_promote \
  version_code:48 rollout:0.1
```

The lane must reject a rollout outside `0 < rollout < 1`; completion to 100 percent is a separate deliberate operation after vitals review. Build 47's first production transition remains a Play Console gate rather than pretending the API can publish a draft app.

Do not reuse a rejected version code. If Play consumes 47 and requires another binary, increment `pubspec.yaml`, commit `chore: prepare 1.0.0 build 48`, rebuild both artifacts, and publish the matching version to both stores.

## Phase 8: Zapstore rollout

1. Create Git tag `v1.0.0-android.47` at the exact release commit.
2. Create a GitHub release without auto-generated or unreviewed copy.
3. Attach the signed universal APK, its SHA-256 checksum, and concise release notes.
4. Run `zsp publish --check zapstore.yaml` and confirm package, version, source, APK selection, and certificate.
5. Publish with the NIP-46 bunker only after the preview matches the reviewed metadata.
6. Verify the application and release events reached the intended relay.
7. Open the public Zapstore listing, download the APK, compare its hash with the GitHub asset, verify its certificate, install it, and repeat the critical acceptance paths.

The first release command sequence is:

```sh
SHA="$(git rev-parse HEAD)"
VERSION=1.0.0
BUILD=47
TAG="v${VERSION}-android.${BUILD}"
APK="build/releases/trickle-${VERSION}-${BUILD}-universal.apk"

git tag "$TAG" "$SHA"
git push origin "$TAG"
(cd "$(dirname "$APK")" && \
  shasum -a 256 "$(basename "$APK")" > "$(basename "$APK").sha256")
gh release create "$TAG" "$APK" "${APK}.sha256" \
  --repo therealparmesh/trickle \
  --title "trickle ${VERSION}" \
  --notes-file "fastlane/metadata/android/en-US/changelogs/${BUILD}.txt" \
  --verify-tag

export SIGN_WITH="$(security find-generic-password \
  -s trickle-zapstore-bunker -a trickle -w)"
zsp publish --check --commit "$SHA" zapstore.yaml
zsp publish --commit "$SHA" zapstore.yaml
unset SIGN_WITH
```

Before creating the tag, verify `git tag --list "$TAG"` and `gh release view "$TAG"` are both empty. If either exists, stop; never move a published release tag or overwrite an APK. If publication fails after the GitHub release is created, rerun only the idempotent `zsp` check/publish steps against the same immutable asset.

For the first launch, keep the Zapstore event ready but unpublished until Google Play is visibly live, then publish it immediately. This order is necessary because Google does not offer Managed Publishing for an app's first production release.

## Subsequent releases

For every Android update:

1. Enable Managed Publishing in Play Console after the first public release and leave it enabled.
2. Increment the shared version code exactly once.
3. Build both artifacts from the same clean commit.
4. Compare both manifests and the Zapstore certificate against the recorded identities.
5. Test the Play AAB through Internal testing.
6. Submit Google Play through Fastlane with a staged rollout below 100 percent and wait until Play reports it ready to publish.
7. Create the immutable GitHub APK release and publish the matching Zapstore release.
8. Use Play Console's Managed Publishing action only when both channels are ready.
9. Inspect Android vitals before expanding the staged rollout; increasing a rollout to 100 percent is not held by Managed Publishing.
10. Keep prior GitHub APKs and Zapstore release events available unless a security issue requires withdrawal.

## Recovery and idempotency

After a timeout, crash, or interrupted session, assume the remote mutation may have succeeded. Query before retrying:

```sh
git status --short
git fetch origin --prune --tags
bundle exec fastlane android play_status
gh release view "$TAG" --repo therealparmesh/trickle
zsp publish --check --commit "$(git rev-parse HEAD)" zapstore.yaml
```

- Never re-upload a version code already accepted by Play.
- Never move a pushed tag or replace an attached APK.
- Never generate a second Android app-signing key for this package.
- If metadata upload partially succeeds, compare the live listing with the committed Fastlane tree and rerun metadata only.
- If Play review is active, do not commit another API edit; a new edit can cancel or supersede the review.
- If Zapstore publish is uncertain, verify the relay event and asset hash before republishing.
- If the app-signing fingerprint differs anywhere, stop. Do not attempt key rotation as a release fix.

## Completion criteria

The Android launch is complete only when:

- Google Play production and Zapstore distribute the same app version from the same source commit.
- Both installed APKs use the recorded app-signing certificate.
- Google Play remains manual-release controlled.
- Store listings use the reviewed copyright-safe Android media and current human copy.
- Privacy, ads, content, and access declarations match the shipped behavior.
- Fresh installs and cross-store updates pass on supported Android versions.
- Git is clean, pushed, and contains no secret or generated release artifact.

## Authoritative references

- [Google Play app signing](https://support.google.com/googleplay/android-developer/answer/9842756)
- [Android app signing](https://developer.android.com/studio/publish/app-signing)
- [Google Play preview assets](https://support.google.com/googleplay/android-developer/answer/9866151)
- [Google Play app review preparation](https://support.google.com/googleplay/android-developer/answer/9859455)
- [Google Play Publishing API edits and first-upload limits](https://developers.google.com/android-publisher/edits)
- [Google Play Managed Publishing](https://support.google.com/googleplay/android-developer/answer/9859654)
- [Google Play testing requirements for new personal accounts](https://support.google.com/googleplay/android-developer/answer/14151465)
- [Fastlane Play Store upload](https://docs.fastlane.tools/actions/upload_to_play_store/)
- [Zapstore publishing](https://zapstore.dev/docs/publish)
- [`zsp` publisher](https://github.com/zapstore/zsp)
