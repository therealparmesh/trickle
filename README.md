# trickle

trickle is a podcast player and feed reader for iOS and Android, with a cyberpunk interface.

## Features

- Apple podcast catalog search with complete pre-subscription details, direct feed subscription, website feed discovery, YouTube channel and playlist discovery, Nostr profile feeds, and OPML import/export for podcasts, feeds, or mixed subscriptions
- RSS 2.0, RSS 1.0, Atom, and JSON Feed parsing that keeps podcasts separate from other feeds
- Verified Nostr profile posts from secure relays, with replies and reposts excluded; Markdown, content warnings, images, native audio, and direct video are supported when supplied by a post
- Streaming, resumable app-private downloads, storage totals and bulk cleanup, persistent Up next, automatic download cleanup, and per-feed automation
- Native system playback, background audio, lock-screen controls, interruptions, headphone-disconnect pause, repeat-one, sleep timer, bookmarks, chapters, searchable timed transcripts, and per-feed intro/outro skip
- One global playback speed with `1x`, `1.25x`, `1.5x`, `1.75x`, and `2x`
- Unread, all, and saved article views; category timelines; per-source search, filters, and sorting; persistent reader text size; offline saved article text; link previews; local full-text search; and external share/browser actions
- Reusable optional categories for non-podcast sources, with assignment while subscribing, one-tap reassignment from source details, bulk moves, confirmed merges, unread counts, case-insensitive suggestions and grouping, and standard OPML folder import and export
- New, in-progress, and played episode states; New, In progress, and All podcast filters; partial-progress bars and Resume actions; full show notes; no play-on-open side effect; and separate quick-play buttons throughout episode lists
- YouTube video entries and recognized YouTube attachments play without ads when supported, with an official-source fallback and a live minimized Now playing preview that does not reload; Picture in Picture supports background and locked-screen audio
- Public and private feeds, including credentials in URL query strings or opaque paths and Basic or Bearer authorization
- Add feeds from the iOS or Android system share sheet, with an editable confirmation before subscription
- Local ZIP backup/restore for portable subscriptions and local state, local notifications, and best-effort operating-system background refresh
- trickle does not collect your information

## Supported platforms

- Android 7.0 (API 24) or later
- iOS 17.0 or later on iPhone

Desktop, web, CarPlay, Android Auto, and Android Automotive are intentionally out of scope.

## Interface

Home shows the 20 most recent episodes in a two-row scrolling shelf, a Library grid, then the 20 most recent feed items. Reading or playing an item updates its status without removing it from Home. Both sections have a See all action that opens the full list with the All filter. Library has four columns at normal phone widths and fewer at larger text sizes. Podcast actions are cyan and feed actions are magenta. Shortcut labels wrap.

Navigation uses Flutter's platform-adaptive page transitions, including iOS swipe-back. The decorative glitch runs after a transition settles and never intercepts gestures.

The corner Search button searches the local library. Add podcast searches Apple’s catalog. Manual podcast and feed adds detect the content type, explain a mismatch, and use the correct collection. The Podcasts screen has Episodes and Podcasts tabs; its episode list has New, In progress, and All filters. The Feeds screen has Feed items and Feeds tabs. Full lists load older entries in pages. The Podcasts badge counts new episodes and the Feeds badge counts unread items; both hide at zero. The mini player keeps current playback reachable and restores the most recently played unfinished audio, paused, on launch. This uses saved progress without fetching or starting media.

Interface copy uses sentence case. Shared spacing uses 4, 8, 12, 16, 24, and 32 points, with 48-point control targets. Library icons are 40 points inside larger tappable tiles.

The visual system uses clipped control geometry, functional state rails, and a sparse signal-line backdrop instead of decorating every content row. Cyan identifies listening actions, magenta identifies feed actions, and acid green is reserved for active playback. Content lists remain continuous and low-chrome. Route changes use a brief full-surface signal glitch after navigation settles and skip the effect when reduced motion is enabled. Persistent audio and video hosts stay outside the effect so navigation cannot reset playback. Playback, Picture in Picture, article reading, and in-place controls remain stable through navigation. Display typography is limited to page and section hierarchy; reading and metadata use the more neutral text face. Controls reflow at accessibility text sizes rather than shrinking labels or touch targets.

On launch, the centered mark stays in place until Home's initial local data and player state are available. Home then appears without intermediate loading sections. This does not wait for network refreshes or add a timed splash delay. The navigation effect captures the rendered page only after its shader is ready.

## Prerequisites

- Flutter 3.44.4 or later with Dart 3.12.2 or later; the current release is verified with Flutter 3.47.2
- oxfmt 0.57.0 or later for Markdown formatting
- Android SDK 36 for Android builds
- JDK 17 or 21 for Android builds; JDK 26 is not supported by the current Android toolchain
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
(cd android && ./gradlew :app:lintRelease)
flutter build appbundle --release
flutter build ios --release --no-codesign
```

The unsigned build commands verify compilation without requiring publisher credentials. Store uploads must use production signing; see [store/RELEASE.md](store/RELEASE.md).

## Architecture

- `lib/core`: product rules, constants, formatting, URL identity, and user-safe errors
- `lib/data`: Drift/SQLite persistence, hardened HTTPS and secure WebSocket networking, feed and verified Nostr parsing, private-feed storage, and repositories
- `lib/features`: background downloads, long-lived audio handling, and the active video session
- `lib/services`: refresh scheduling, incoming shares, feed automation, notifications, OPML, and local backup
- `lib/presentation`: Riverpod-driven screens, the shared visual system, reusable content components, and the persistent player shell

### Data and refresh

The SQLite database uses schema version 6, WAL mode, foreign keys, indexed timeline queries, and FTS5 search backed by stable document IDs. Upgrades preserve existing content and search text; legacy feed repairs run only during migration. Refresh reads are limited to incoming items and explicit Nostr deletion targets. Older refresh results cannot replace newer content or settings. Background automation stages Up next additions, and the audio handler acknowledges them only after merging them into the active queue.

Catalog subscriptions and typed OPML imports carry an explicit feed type. Untyped manual and mixed OPML adds use podcast metadata or an all-audio entry list to identify podcasts. Once stored, a subscription keeps its type across refreshes, including empty feeds and text-only announcements. Subscription identity uses the complete normalized URL and authorization headers; token differences do not merge different feeds. OPML exports record the type in an optional namespaced attribute while retaining standard RSS outlines and category folders.

New ZIP backups use version 3: a manifest and numbered JSON chunks. Export reads a consistent database snapshot in batches; restore validates every chunk before applying an atomic merge. The shared limits are 2 GiB of expanded records, 32 MiB per chunk, 5,000 feeds, 200,000 episodes and articles each, and 500,000 attachments. Version 1 and 2 backups remain readable within their original 50 MiB expanded-size limit. Sign-in headers and downloaded media are excluded.

### Playback

The latest audio or video selection owns playback. Native player commands are ordered, and a slow media lookup cannot block a newer selection. Podcast playback reapplies its spoken-audio session before starting and makes one bounded recovery attempt after an unexpected stop.

### Performance

Artwork uses the same fallback rules across lists and detail views. An unavailable item image falls back to source artwork. Feeds without usable artwork can use an image from their 20 most recent items, excluding content warnings. This is a bounded local query using the existing feed/date index; it does not fetch publisher pages. Refresh preserves existing source artwork when a feed omits it. Remote images can be disabled in Settings, and private-feed headers are sent only to the matching origin.

Shared library snapshots keep rows from opening duplicate database streams. Feed timelines use ordered item indexes, and article list queries omit cached reader HTML. Search-document updates use indexed identities and skip unchanged text. Expensive feed, article, Nostr verification, and backup compression work runs off the UI isolate. Lists are lazy, reader content is revealed in bounded fragments, and artwork uses bounded, aspect-preserving decoding. Playback progress is saved every 15 seconds, and download progress writes are limited to once every 2 seconds.

### Time limits

App-defined deadlines are centralized in `AppConstants`:

| Work                                                                               | Limit      |
| ---------------------------------------------------------------------------------- | ---------- |
| Auxiliary extraction, Picture in Picture response, playback recovery grace         | 3 seconds  |
| SQLite lock wait                                                                   | 5 seconds  |
| Network connection, DNS, each video-source attempt                                 | 10 seconds |
| Catalog search, media URL resolution, link previews, total background network work | 15 seconds |
| Feed, relay, reader, image, and OPML documents                                     | 30 seconds |

Redirects share the request's total deadline. Local searches use a 250 ms debounce; catalog search uses 500 ms. Transient player messages follow the standard four-second message duration. Native audio buffering and background downloads follow platform timing; these request limits do not stop a long episode or download.

## Project layout

- `android/` and `ios/`: native application and release configuration
- `assets/brand/`: source artwork for deterministic app/store asset generation
- `docs/`: user-facing privacy and support documents
- `store/`: release checklist, store metadata, App Store screenshots, and signing export configuration
- `test/`: unit, repository, database, network, and widget regression tests; Nostr relay protocol tests use injected in-memory sockets and never contact public relays
- `tool/`: deterministic brand-asset generation, screenshot capture, and command-line release tooling

After changing a brand source, run `tool/generate_brand_assets.sh` to rebuild the required Android, iOS, launch, and store raster assets.

## Privacy and support

- [Privacy policy](https://therealparmesh.github.io/trickle/privacy)
- [Support](https://therealparmesh.github.io/trickle/support)

The repository publishes these documents from `main/docs` through GitHub Pages.

## Release

Use the [release checklist](store/RELEASE.md), [store metadata](store/metadata.md), [App Review notes](store/app_review_notes.md), and [TestFlight notes](store/testflight_notes.md). The release workflow and screenshot-capture tooling are in `store/apple/` and `tool/maestro/`; private signing-key material remains outside the repository.
