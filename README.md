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

Home shows the 20 most recent episodes, a Library grid, then the 20 most recent feed items. Episode cards show the podcast, date, duration, playback status, and a shared actions menu. Reading or playing an item updates its status without removing it from Home. See all episodes and See all feed items open the full lists with All selected; empty sections instead offer an appropriate next step. Library has six shortcuts: Podcasts, Feeds, Up next, Downloads, Saved episodes, and Saved articles. Its Add menu offers podcast search, a podcast URL, a feed, or a YouTube feed. Podcast actions are cyan and feed actions are magenta.

At normal phone widths, episodes use a two-row scrolling shelf and Library has two columns. On narrow screens or at accessibility text sizes, Library becomes a full-width list. Accessibility text sizes also give episodes one wider row and move article thumbnails above the text. Badge counts scale with text and describe what they count to screen readers.

Live lists preserve the visible item when refreshes insert or remove rows above it. Incoming rows wait until an active drag or fling ends, then appear without losing your place. Open row menus and pending actions remain attached to their item. At the top of a list, new items appear normally.

Navigation uses Flutter's platform-adaptive page transitions, including iOS swipe-back. Each screen arrival has an independent one-in-four chance of a decorative glitch, including returning from the full-screen player. The effect waits for both the screen and its enclosing route to settle and never intercepts gestures.

The corner Search button searches the local library. Add podcast searches Apple’s catalog. Manual podcast and feed adds detect the content type, explain a mismatch, and use the correct collection. The Podcasts screen has Episodes and Podcasts tabs; its episode list has New, In progress, and All filters. The Feeds screen has Feed items and Feeds tabs. Full lists load older entries in pages. The Podcasts badge counts new episodes and the Feeds badge counts unread items; both hide at zero. The mini player keeps current playback reachable and restores the most recently played unfinished audio, paused, on launch. This uses saved progress without fetching or starting media.

Interface copy uses sentence case. Shared spacing uses 4, 8, 12, 16, 24, and 32 points, with 48-point control targets. Home section actions use 16 points above and 8 below, without extra padding around the episode shelf. Small icons and spinners use 20 points, standard icons use 24, and ordinary list artwork uses 56. Clipped controls, panels, and sheets use 8-, 12-, and 16-point corner cuts. Library shortcuts place icons beside their labels, with equal row heights and 8-point gaps. Reader typography and landscape media keep their content-specific sizing.

Publication timestamps use the same format in lists and details: Just now, minutes ago, or hours ago until 24 hours, then a localized calendar date. Dates outside the current year include the year. Podcast lengths stay separate from timestamps. Item rows wrap their metadata instead of cutting off dates. Episode details keep More actions in the trailing toolbar and left-align the quick actions below Play so wrapped buttons do not form isolated centered rows.

The visual system uses clipped control geometry, functional state rails, and a sparse signal-line backdrop instead of decorating every content row. Cyan identifies listening actions, magenta identifies feed actions, and acid green highlights the current player and saved items. Content lists remain continuous and low-chrome. The occasional navigation glitch is brief and full-surface; reduced motion disables it. Persistent audio and video hosts stay outside the effect so navigation cannot reset playback. Playback, Picture in Picture, article reading, and in-place controls remain stable through navigation. Display typography is limited to page and section hierarchy; reading and metadata use the more neutral text face. Controls reflow at accessibility text sizes rather than shrinking labels or touch targets.

On launch, the centered mark stays in place until Home's initial local data and player state are available. Home then appears without intermediate loading sections. This does not wait for network refreshes or add a timed splash delay. The navigation effect captures the rendered page only after its shader is ready.

## Prerequisites

- Flutter 3.44.4 or later with Dart 3.12.2 or later; the current release is verified with Flutter 3.47.9
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

The SQLite database uses schema version 10, WAL mode, foreign keys, indexed timeline queries, and FTS5 search backed by stable document IDs. Upgrades preserve library data and search text. Feed HTML and downloaded reader HTML are stored separately. The reader builds its own cache without converting old article content. Cache timestamps prevent stale downloads from replacing newer text. Routine refresh reads are limited to incoming items and explicit Nostr deletion targets. Verified Nostr deletions are remembered on the device for the life of the feed record, so lagging relays cannot bring those posts back. When an existing feed becomes private, its item IDs stay stable and refresh uses indexed aliases where needed. Older refresh results cannot replace newer content or settings. Automatic Up next additions are staged until the audio handler merges them. Download retries do not re-add episodes you removed from the queue. Unsubscribing retains queued episodes; clearing Up next removes staged and visible entries together.

Catalog subscriptions and typed OPML imports carry an explicit feed type. Untyped manual and mixed OPML adds use podcast metadata or an all-audio entry list to identify podcasts. Once stored, a subscription keeps its type across refreshes, including empty feeds and text-only announcements. Subscription identity uses the complete normalized URL and authorization headers; token differences do not merge different feeds. OPML exports record the type in an optional namespaced attribute while retaining standard RSS outlines and category folders.

Episodes without GUIDs use the enclosure URL and publication date (or title if no date is available). The URL comparison ignores recognized credentials but keeps parameters that select different audio. Private media URLs stay in secure storage.

Articles without GUIDs use the same rule with the article link. Without a link, trickle falls back to title and publication date. For a private feed, rotating a recognized access token keeps the saved reader text without merging different article links.

New ZIP backups use version 3: a manifest and numbered JSON chunks. Export reads a consistent database snapshot in batches; restore validates every chunk before applying an atomic merge. Portable private URLs restore to secure storage on a new device. They match an existing private subscription only when the full URL matches and no separate sign-in headers are required. The shared limits are 2 GiB of expanded records, 32 MiB per chunk, 5,000 feeds, 200,000 episodes and articles each, and 500,000 attachments. Version 1 and 2 backups remain readable within their original 50 MiB expanded-size limit. Sign-in headers and downloaded media are excluded.

### Playback

The latest audio or video selection owns playback. Up next selects episodes by ID, so reordering does not change what you tapped. Podcast playback reapplies its spoken-audio session before starting and makes one bounded recovery attempt after an unexpected stop. Downloads are resolved relative to app storage so they survive an update, and the end-of-episode sleep timer takes precedence over repeat.

Foreground and background workers share one download record per episode. Played-download cleanup checks the current retention setting and Keep status before removing a file. Manual downloads of already-played episodes start with Keep on so old playback history cannot remove them as soon as they finish. Turning off Keep makes that download eligible for cleanup again.

### Performance

Artwork uses the same fallback rules across lists and detail views. An unavailable item image falls back to source artwork. Feeds without usable artwork can use an image from their 20 most recent items, excluding content warnings. This is a bounded local query using the existing feed/date index; it does not fetch publisher pages. Refresh preserves existing source artwork when a feed omits it. Images served with a generic binary content type are decoded normally; invalid images still use the fallback. Remote images can be disabled in Settings, and private-feed headers are sent only to the matching origin.

Shared library snapshots keep rows from opening duplicate database streams. Feed timelines use ordered item indexes, and article list queries omit HTML bodies. Search-document updates use indexed identities and skip unchanged text. Expensive feed, article, Nostr verification, and backup compression work runs off the UI isolate. Lists and reader blocks render lazily, and artwork uses bounded, aspect-preserving decoding. Playback progress is saved every 15 seconds, and download progress writes are limited to once every 2 seconds.

Live vertical lists use `positioned_sliver_list` for layout-time scroll anchoring; Home's fixed-width episode shelf uses Flutter's grid. Row keys preserve identity across reordering. Only open menus and pending actions request keep-alive state.

### Reader

`reader_mode` extracts web articles using a Dart port of Mozilla Readability with its HTML5 parser backend. `flutter_widget_from_html_core` renders sanitized HTML, including tables, nested lists, links, and code blocks. The app supplies typography, safe image loading, and external link handling; it does not implement a second HTML layout engine. The reader uses a sliver list; podcast show notes use the same renderer inside their existing page layout. Scripts, embeds, and publisher styling are removed. Private headers remain restricted to the feed's origin. PDF links open in the browser, as do pages without an extractable article. Failed requests preserve saved or feed content and offer a retry. Reader extraction and fallback rules are based on the response format and content, never on a publisher or feed identity.

### Time limits

App-defined deadlines are centralized in `AppConstants`:

| Work                                                                               | Limit      |
| ---------------------------------------------------------------------------------- | ---------- |
| Auxiliary extraction, Picture in Picture response, playback recovery grace         | 3 seconds  |
| SQLite lock wait                                                                   | 5 seconds  |
| Network connection, DNS, each video-source attempt                                 | 10 seconds |
| Catalog search, media URL resolution, link previews, total background network work | 15 seconds |
| Feed, relay, reader, image, OPML, and native audio preparation                     | 30 seconds |
| Android transient audio interruption                                               | 10 minutes |

Redirects share the request's total deadline. Requests cancel unread response bodies when they finish or reject a redirect. Background feed requests and automatic-download URL checks share a 15-second budget; work that has not started stays eligible for a later run. Native downloads already handed to the OS can continue. Local searches use a 250 ms debounce; catalog search uses 500 ms. Transient player messages follow the standard four-second message duration.

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
