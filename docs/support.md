---
title: trickle Support
---

# trickle support

_Last updated: July 18, 2026_

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

### Playback

Confirm the device is online and the publisher's media URL is still available. Retry the episode after changing networks.

### Background refresh or downloads

Allow background activity for trickle in system settings. Android battery restrictions and iOS Low Power Mode can delay operating-system scheduled work.

### Notifications

Enable notifications for trickle in system settings, then enable notifications for the individual feed inside trickle.

### Storage

Remove completed downloads from the library or choose a shorter automatic cleanup policy in Settings.

## Backup and migration

Podcast and feed subscriptions can be exported as OPML. Settings also provides a local ZIP backup for subscriptions, reading and playback state, queue entries, bookmarks, and settings. Private-feed credentials and downloaded media are not included in that ZIP.

## Project

- GitHub: [therealparmesh/trickle](https://github.com/therealparmesh/trickle)
