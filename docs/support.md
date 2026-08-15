---
title: trickle Support
---

# trickle support

_Last updated: August 15, 2026_

## Contact

For help with trickle, contact [parmesh@hey.com](mailto:parmesh@hey.com).

See the [privacy policy](privacy) for details about local data and network requests.

## What to include

Include the following information when reporting a problem:

- Device model
- Operating-system version
- trickle version
- A short description of what happened and the action immediately before it

Do not include private-feed passwords, bearer tokens, authorization headers, or complete private-feed URLs.

## Troubleshooting

### Feed refresh

Confirm the feed uses HTTPS and opens in a browser. For a private feed, verify its URL and authorization values in the feed settings.

If a refresh finishes with failed feeds, open the affected subscription to see its stored refresh error and try again. Other subscriptions and existing items remain available.

### Feed categories

Open a non-podcast source, open Feed settings, and choose a previously used category or enter a new one. This moves that source without affecting the others. From Reader > Feeds, choose Rename beside a category to rename it for every source in that group. Renaming to an existing category merges the groups. Suggestions and grouping match category names without regard to capitalization. Clearing a source's Category field returns it to Uncategorized. Podcasts do not use feed categories.

### Playback

Confirm the device is online and the publisher's media URL is still available. Retry the episode after changing networks.

Episode lists label untouched episodes New, partially listened episodes In Progress, and completed episodes Played. In-progress rows show saved progress and Resume. Playback resumes from a saved position after at least 10 seconds of listening.

If a completed download is missing or unusable, trickle falls back to the publisher's stream while the device is online.

### Video feeds

Use Add YouTube for focused channel and playlist guidance, or paste a public YouTube channel, playlist, or YouTube Atom feed into Add Feed. A video shared from inside a public playlist follows that playlist. Private, members-only, and account-specific lists are not supported by public feeds.

Video entries require a network connection. If the initial video page cannot load, the same in-app player falls back to the official source URL from the feed. If neither attempt loads, use Try again or Open original. Minimize the player to keep the same live video in the Now Playing bar while navigating trickle.

Use the player’s Picture in Picture button to start the system window on a supported iPhone or Android 8 or later device. While Picture in Picture is active, the in-app Now Playing bar shows the video thumbnail and its close button ends the video. Locking the screen without closing Picture in Picture keeps its audio and playback position moving. If trickle is visible, closing or restoring the system window returns the same video and timestamp to the live minimized player. Closing the system window while trickle is in the background or the screen is locked ends playback. Video audio can continue while the app is hidden or locked only during Picture in Picture. Otherwise, hiding trickle pauses the video. Podcast audio continues to use native background playback.

### Nostr profile feeds

Paste an `npub`, `nprofile`, or `nostr:` profile address into Add Feed. trickle reads verified root posts from a small finite set of secure relays. Replies and reposts are omitted so the feed stays focused on the profile's own posts.

Posts can contain text, Markdown articles, content warnings, images, audio, and direct video. Audio uses the native player and saves progress. Relay and media availability remain controlled by their respective operators; retry the feed or attachment if one is temporarily unavailable.

### Background refresh or downloads

Allow background activity for trickle in system settings. The selected interval applies to each subscription from its last refresh. Work is time-bounded; subscriptions that do not fit remain eligible for the next opportunity. Android battery restrictions and iOS Low Power Mode can delay operating-system scheduled work.

### Notifications

Enable notifications for trickle in system settings, then enable notifications for the individual feed inside trickle.

### Storage

Remove completed downloads from the library or choose a shorter automatic cleanup policy in Settings.

## Backup and migration

Settings can import standard OPML files containing podcasts, RSS feeds, and YouTube feeds together. Each source is classified from its feed contents and appears in the matching section. Separate exports are available for podcast subscriptions, RSS and YouTube subscriptions, or all OPML-compatible subscriptions. Reader categories use standard OPML folders and survive import and export. Portable tokenized feed URLs are included; feeds that require separate authorization headers are skipped. Nostr profiles are not representable in standard OPML. Imported public podcasts are recognized as subscribed when the same feed appears in podcast search.

The local ZIP backup includes portable podcast and feed subscriptions, Nostr profiles and relay choices, articles and attachments, reading and playback state, queue entries, bookmarks, and settings. A private feed whose token is entirely in its URL is portable and included. Authorization headers, passwords entered separately from a URL, and downloaded media files are excluded.

Restore accepts only trickle ZIP backups. An invalid or unsupported archive is rejected without changing existing data. Canceling the picker makes no changes. If a restore is already running, tapping Restore local backup again rejoins that operation instead of opening another picker or applying the backup twice.

## Project

- GitHub: [therealparmesh/trickle](https://github.com/therealparmesh/trickle)
