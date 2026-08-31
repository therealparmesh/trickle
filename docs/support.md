---
title: trickle Support
---

# trickle support

_Last updated: August 31, 2026_

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

Choose an existing category or enter a new one while adding a feed. To change it later, tap the category on the source page or open Feed settings. Clear the Category field to move a source back to Uncategorized. Podcasts do not use categories.

To move several sources at once, open Feeds > Sources and choose Organize feeds. Rename changes every source in a category; renaming to an existing category asks before merging them.

The Feed items tab can show one category at a time, with unread counts in the category picker. Search, filter, sort, or mark the selected category read from the same screen.

### Playback

Confirm the device is online and the publisher's media URL is still available. Retry the episode after changing networks.

Episodes are marked New, In Progress, or Played. An episode becomes In Progress after 10 seconds. Position is checkpointed every 15 seconds and when playback is paused, changed, or closed.

If a completed download is missing or unusable, trickle falls back to the publisher's stream while the device is online.

If the operating system stops an episode that was still playing, trickle tries once to restore the audio session and continue. If it still cannot play, the player leaves the loading state and shows Retry.

### Video feeds

Use Add YouTube to add a public channel, playlist, or YouTube Atom feed. Private and members-only feeds are not supported.

Video requires a network connection. Public YouTube videos play without ads when supported. If that player fails, trickle tries the official source. If neither works, choose Try again or Open original. Minimize the player to keep watching while using trickle.

Use the Picture in Picture button on a supported device to keep video and audio playing outside trickle or when the screen is locked. Closing or restoring Picture in Picture while trickle is visible returns the video to the minimized player. Closing it while trickle is in the background ends playback. Without Picture in Picture, hiding trickle pauses video. Podcast audio continues normally in the background.

### Nostr profile feeds

Paste an `npub`, `nprofile`, or `nostr:` profile address into Add Feed. trickle reads verified root posts from a small finite set of secure relays. Replies and reposts are omitted so the feed stays focused on the profile's own posts.

Posts can contain text, Markdown articles, content warnings, images, audio, and direct video. Audio uses the native player and saves progress. Relay and media availability remain controlled by their respective operators; retry the feed or attachment if one is temporarily unavailable.

### Background refresh or downloads

Allow background activity for trickle in system settings. The selected interval applies to each subscription from its last refresh. Work is time-bounded; subscriptions that do not fit remain eligible for the next opportunity. Android battery restrictions and iOS Low Power Mode can delay operating-system scheduled work.

### Notifications

Enable notifications for trickle in system settings, then enable notifications for the individual feed inside trickle.

### Transcripts

Open Transcript in Now Playing. Search works for every supplied transcript. Timed VTT, SRT, and Podcasting 2.0 JSON segments can be tapped to seek; plain-text transcripts remain selectable but cannot seek without publisher timing.

### Storage

Open Downloads to see the number of downloads and their stored size. Its menu can remove played downloads or all downloads. Played downloads marked Keep are excluded from the played-only cleanup. Automatic cleanup timing remains in Settings.

## Backup and migration

Settings can import standard OPML files containing podcasts, RSS feeds, and YouTube feeds. Export OPML opens a scope chooser for podcasts, feeds, or all compatible subscriptions. Feed categories are stored as OPML folders. Portable URLs with embedded tokens are included; feeds that require separate authorization headers are skipped. Nostr profiles are stored only in trickle backups because OPML does not support them.

You can also share a feed, website, podcast RSS, YouTube, `npub`, or `nprofile` address to trickle from another app. Review or edit the address in Add Feed before subscribing.

Saving a normal article stores its readable text for offline use. Publisher-hosted images and video still require a connection unless the operating system already cached them.

The local ZIP backup includes subscriptions, Nostr profiles, articles, playback and reading state, queues, bookmarks, and settings. It does not include separate authorization headers, passwords, or downloaded media.

Restore accepts only trickle ZIP backups. An invalid or unsupported archive is rejected without changing existing data. Canceling the picker makes no changes. If a restore is already running, tapping Restore local backup again rejoins that operation instead of opening another picker or applying the backup twice.

## Project

- GitHub: [therealparmesh/trickle](https://github.com/therealparmesh/trickle)
