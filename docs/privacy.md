---
title: trickle Privacy Policy
---

# trickle privacy policy

Effective date: July 17, 2026

## Summary

trickle is a client-side podcast player and feed reader. The developer does not operate an application backend and does not collect, sell, rent, or share personal data through trickle. The app contains no developer analytics, advertising, tracking, or crash-reporting SDK.

## Data stored on the device

Subscriptions, reading state, playback progress, queue entries, settings, bookmarks, article cache, and downloaded media are stored locally. Android backup and device transfer exclude trickle application data. On Apple platforms, trickle excludes its Application Support directory from iCloud backup.

Private-feed URLs and authorization headers are stored using the operating system's Keychain or Keystore. Apple Keychain entries are restricted to the current device. An active authenticated media download may require the operating system's app-private download scheduler to retain its URL and request headers until that task ends.

Deleting a feed removes its local content, files, and stored secrets. Uninstalling removes the application database and media. If an operating system retains Keychain entries across uninstall, trickle clears stale private-feed entries before a later fresh installation is used.

## Network requests

trickle makes direct requests to third parties only to perform actions requested by the user:

- Apple receives podcast discovery search terms and standard network metadata when catalog search is used.
- Feed publishers and their hosting providers receive feed, article, artwork, transcript, chapter, and media requests, plus standard network metadata such as the device IP address.
- The operating system and the destination selected by the user handle data when the user imports, exports, shares, or opens a link.

## Private feeds

Private-feed credentials are never sent to the trickle developer. They are sent only to the feed or media host selected by the user. Cross-origin redirects do not receive sensitive authorization or cookie headers.

## Exports and backups

The user-initiated trickle ZIP export is the only built-in portable full backup. It excludes private-feed credentials and downloaded media. OPML export includes ordinary public feed URLs and private URLs whose access is contained entirely in the URL; it excludes feeds that require authorization headers.

## Background processing and notifications

Background refresh, downloads, and local notifications are scheduled by the device operating system and are best effort. trickle does not use a push-notification or analytics service operated by the developer.

## Changes and contact

This policy may be updated when the application's behavior changes. Questions can be sent to [parmesh@hey.com](mailto:parmesh@hey.com).

- GitHub: [therealparmesh/trickle](https://github.com/therealparmesh/trickle)
