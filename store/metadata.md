# Store Metadata

## Identity

- App Store name: trickle: podcasts & RSS
- On-device name: trickle
- Apple ID: 6792352845
- Bundle ID: com.parmscript.trickle
- Version: 1.0.0
- Build: 41

## Name

trickle: podcasts & RSS

## Apple subtitle

Podcasts and feeds, distilled

## Google short description

A fast podcast and RSS app with a sharp cyberpunk interface.

## Promotional text

Podcasts and feeds in one fast, focused cyberpunk interface.

## Description

trickle brings podcasts, news, blogs, and independent feeds into one focused cyberpunk interface.

Find podcasts and inspect their descriptions and episodes before subscribing. Add any compatible RSS, Atom, or JSON Feed, paste a public YouTube channel or playlist URL, or follow a Nostr profile's verified posts. Stream or download podcast episodes, build a persistent queue, read clean extracted articles and Markdown posts, play attached audio and video, and open video entries in a persistent player without creating an account. Podcast episodes distinguish New, In Progress, and Played, with saved progress and Resume available for partial listening. Minimize video to a live Now Playing preview, or explicitly start supported system Picture in Picture for background audio. Other video pauses when trickle is hidden. If a video page cannot load, the same player falls back to the entry's official source URL. Podcast and attached audio playback use the native system audio engine and include exact global speed choices from 1x to 2x, sleep timers, bookmarks, lock-screen controls, and saved progress. Podcasts also support intro and outro skipping, chapters, publisher transcripts, and automatic download cleanup. Choose background refresh from 1 hour through 1 week and remove played downloads immediately, after 1 day, or after 1 week.

Organize non-podcast sources with reusable optional categories. Move one source from Feed settings, or rename a category for every source in its group. Categories use standard OPML folders when imported or exported.

trickle does not collect your information. Import and export standard OPML subscriptions, or create a local backup that also preserves Nostr profiles and portable local state.

## Keywords

podcast,rss,feed,reader,offline,opml,audio,news,nostr,queue

## Categories

- Apple primary: News
- Apple secondary: Entertainment
- Google Play: News & Magazines

## Supported platforms

- Android 7.0 (API 24) or later
- iOS 14.0 or later on iPhone

## Contact URLs

- Support: https://therealparmesh.github.io/trickle/support
- Privacy policy: https://therealparmesh.github.io/trickle/privacy
- Email: parmesh@hey.com

Both pages are published from `main/docs` in the public trickle repository. Verify that they load without authentication before submission.

## Screenshots

Five 1320×2868 iPhone screenshots were verified against the current visual system on July 29, 2026. Use `tool/maestro/capture_store_screenshots.yaml` after preparing its asserted podcast and feed data whenever the interface changes, then upload the images in this order:

1. Home
2. Podcast
3. Episode and playback actions
4. Unread feed items
5. Reader mode

## Pricing and availability

- Price: Free ($0.00)
- Base country or region: United States (USD)
- Distribution: Public App Store
- Release option: Manually release after App Review approval

## Version 1.0.0 release notes

Listen to podcasts and read RSS, Atom, and JSON feeds in one fast, focused app that does not collect your information. Search the Apple podcast catalog, follow public YouTube channels and playlists as feeds, stream or download episodes, build a queue, import standard OPML, export podcasts, RSS and YouTube feeds, or all subscriptions, and read articles in a clean reader view.

Follow Nostr profiles from an npub or nprofile address. trickle verifies events, shows the profile's own posts without replies or reposts, respects content warnings, renders Markdown, and supports attached images, native audio, and direct video.

Browse recent podcast episodes in a compact two-row shelf with direct Play and Resume controls, then filter the Podcasts screen by New, In Progress, or All. Move into Up Next, downloads, saved items, podcast subscriptions, and feed sources without confusing listening progress with queue order. Only the Home screen’s Sources shortcut carries a number badge, with an exact feed subscription count that hides at zero. Podcast details remain visible throughout subscribe and unsubscribe actions.

The Feeds collection now includes a consistent See all action that opens the complete reader.

Non-podcast sources can now be assigned reusable optional categories. Feed settings suggests previous categories without blocking new ones, one source can move between groups, a category can be renamed for every matching source, and standard OPML import and export preserve category folders.

Four-button Home collections now use even spacing, and longer actions such as Add YouTube remain fully visible.

Route changes now use a brief full-surface signal glitch after an instantaneous handoff, so the effect remains visible, settles immediately, preserves screen state, and respects Reduced Motion.

Podcast episodes now show distinct New, In Progress, and Played states. Partial listening displays saved progress and Resume throughout episode lists. Explicit episodes use a compact leading marker that stays aligned when titles wrap or truncate.

One-line and two-line collection shortcuts now keep identical icon, label, and touch-target alignment.

Large libraries, feed refreshes, queue automation, search indexing, and long reader pages now avoid repeated work and stay responsive as content grows.

Playback lists now ignore buffer-only engine updates and isolate current-item state, while unchanged feed settings avoid unnecessary database writes.

Video entries play in a persistent player with a live minimized preview and user-started system Picture in Picture on supported devices.

Closing Picture in Picture while trickle is visible returns the same video and timestamp to the minimized player. Closing it while trickle is backgrounded ends playback cleanly.

Every recognized YouTube video now follows the same initial player path, including video URLs discovered in post attachments, before using the official source as a fallback.

Picture in Picture requests now wait for confirmation, recover cleanly when unavailable, and never leave the player controls stuck in a loading state.

Picture in Picture now activates the correct video audio session before the system request, so playback can continue reliably when the app is hidden or the screen is locked.

Podcasts imported through OPML are recognized as subscribed in catalog search, including feeds whose query credentials stay in secure device storage.

Local ZIP backup now preserves Nostr profiles, post attachments, reading and playback state, queues, bookmarks, settings, and portable tokenized feed URLs. Standard OPML remains available for compatible podcast, RSS, and YouTube subscriptions.

Choose background refresh from 1 hour through 1 week and remove played downloads immediately, after 1 day, or after 1 week.

## Privacy declarations

- Apple App Privacy: Data Not Collected by the developer
- Tracking: No
- Google Play Data safety: No developer data collection or sharing
- Account deletion: Not applicable; the app has no account
- Encryption export compliance: Uses only operating-system and standard HTTPS encryption; `ITSAppUsesNonExemptEncryption` is false

The publisher's legal name, copyright, and review contact are configured in the store consoles. Verify them before each submission.
