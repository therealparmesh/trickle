# trickle

trickle is a podcast player and RSS reader for iOS and Android. It combines compact information design with a restrained cyberpunk visual system.

## Features

- Apple podcast catalog search, direct feed subscription, website feed discovery, standard OPML import, and podcast-only, reading-only, or combined OPML export
- RSS 2.0, RSS 1.0, Atom, and JSON Feed parsing, including hybrid audio/article feeds
- Streaming, resumable app-private downloads, persistent Up Next, automatic download cleanup, and per-feed automation
- Native system playback, background audio, lock-screen controls, interruptions, headphone-disconnect pause, repeat-one, sleep timer, bookmarks, chapters, publisher transcripts, and per-feed intro/outro skip
- One global playback speed with `1x`, `1.25x`, `1.5x`, `1.75x`, and `2x`
- Unread, all, and saved article views; reader-mode extraction; link previews; local full-text search; and external share/browser actions
- Episode details with full show notes, explicit Play/Resume controls, no play-on-open side effect, and separate quick-play buttons throughout episode lists
- Public and private feeds, including credentials in URL query strings or opaque paths and Basic or Bearer authorization
- Local ZIP backup/restore, local notifications, and best-effort operating-system background refresh
- trickle does not collect your information

## Supported platforms

- Android 7.0 (API 24) or later
- iOS 14.0 or later on iPhone

Desktop, web, CarPlay, Android Auto, and Android Automotive are intentionally out of scope.

## Prerequisites

- Flutter 3.44.4 stable with Dart 3.12.2
- oxfmt 0.57.0 for Markdown formatting
- Android SDK 36 for Android builds
- Xcode 26 or later and CocoaPods for iOS builds

## Getting started

```sh
flutter pub get
flutter run
```

Select an Android emulator/device or an iOS Simulator/device when Flutter prompts for a target.

Generated Drift sources are committed. Regenerate them only after changing the database schema:

```sh
dart run build_runner build --delete-conflicting-outputs
```

## Quality checks

Run the same checks used before release:

```sh
oxfmt --check README.md 'docs/**/*.md' 'store/**/*.md'
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build appbundle --release
flutter build ios --release --no-codesign
```

The unsigned build commands verify compilation without requiring publisher credentials. Store uploads must use production signing; see [store/RELEASE.md](store/RELEASE.md).

## Architecture

- `lib/core`: product rules, constants, formatting, URL identity, and user-safe errors
- `lib/data`: Drift/SQLite persistence, hardened HTTPS networking, feed parsing, private-feed storage, and repositories
- `lib/features`: background downloads and the long-lived audio handler
- `lib/services`: refresh scheduling, feed automation, notifications, OPML, and local backup
- `lib/presentation`: Riverpod-driven screens, reusable content components, and the floating player shell

The SQLite database uses WAL mode, indexed timeline queries, foreign keys, and FTS5. Potentially expensive feed and article parsing runs away from the UI isolate. Lists are lazy, reader content is revealed in bounded fragments, artwork is memory-sized, playback progress is checkpointed every 15 seconds, and download progress writes are throttled to once every 2 seconds.

## Project layout

- `android/` and `ios/`: native application and release configuration
- `assets/brand/`: source artwork for deterministic app/store asset generation
- `docs/`: user-facing privacy and support documents
- `store/`: release checklist, store metadata, App Store screenshots, and signing export configuration
- `test/`: unit, repository, database, network, and widget regression tests
- `tool/`: deterministic brand-asset, screenshot, and command-line release tooling

After changing a brand source, run `tool/generate_brand_assets.sh` to rebuild the required Android, iOS, launch, and store raster assets.

## Privacy and support

- [Privacy policy](https://therealparmesh.github.io/trickle/privacy)
- [Support](https://therealparmesh.github.io/trickle/support)

The repository publishes these documents from `main/docs` through GitHub Pages, matching the TrackMe release setup.

## Release

Use the [release checklist](store/RELEASE.md), [store metadata](store/metadata.md), [App Review notes](store/app_review_notes.md), and [TestFlight notes](store/testflight_notes.md). The release workflow and five 1320×2868 App Store screenshots are in `store/apple/`; private signing-key material remains outside the repository.
