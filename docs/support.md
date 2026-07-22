---
title: trickle Support
---

# trickle support

_Last updated: July 21, 2026_

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

### Playback

Confirm the device is online and the publisher's media URL is still available. Retry the episode after changing networks.

If a completed download is missing or unusable, trickle falls back to the publisher's stream while the device is online.

### Video feeds

Use Add YouTube for focused channel and playlist guidance, or paste a public YouTube channel, playlist, or YouTube Atom feed into Add Feed. A video shared from inside a public playlist follows that playlist. Private, members-only, and account-specific lists are not supported by public feeds.

Video entries require a network connection. The in-app player tries yout-ube first. Only if that attempt fails does the same player load the official YouTube link from the feed; the official player may show ads. If neither attempt loads, use Try again or Open original. The mini-player remains available while navigating trickle. Background continuation depends on the operating system and the loaded web player.

### Background refresh or downloads

Allow background activity for trickle in system settings. The selected interval applies to each subscription from its last refresh. Work is time-bounded; subscriptions that do not fit remain eligible for the next opportunity. Android battery restrictions and iOS Low Power Mode can delay operating-system scheduled work.

### Notifications

Enable notifications for trickle in system settings, then enable notifications for the individual feed inside trickle.

### Storage

Remove completed downloads from the library or choose a shorter automatic cleanup policy in Settings.

## Backup and migration

Settings can import standard OPML and export podcast subscriptions, reading subscriptions, or both as OPML. It also provides a local ZIP backup for subscriptions, reading and playback state, queue entries, bookmarks, and settings. Private-feed credentials and downloaded media are not included in that ZIP.

Restore accepts only trickle ZIP backups. An invalid or unsupported archive is rejected without changing existing data.

## Project

- GitHub: [therealparmesh/trickle](https://github.com/therealparmesh/trickle)
