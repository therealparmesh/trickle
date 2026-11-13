---
title: trickle Support
---

# trickle support

_Last updated: October 7, 2026_

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

### Finding and adding content

Home’s Search button searches your library. Tap Add next to Library, then Add podcast to search Apple’s podcast catalog, or Add podcast URL to paste an RSS URL. The same menu has Add feed for RSS, Atom, JSON Feed, website, and Nostr profile addresses, and Add YouTube feed for public channels and playlists. If a podcast URL is entered under Add feed, or a regular feed under Add podcast URL, trickle explains the mismatch and adds it to the right collection.

Home shows your 20 most recent episodes and 20 most recent feed items, including items you have played or read. Opening an article marks it read but leaves it on Home. See all episodes and See all feed items open the full lists with All selected. Full lists have Load more controls for older items. Episode cards show their podcast, date, duration, and status; their actions menu offers queueing, downloads, saving, and Mark played.

Library sits between the two lists, with six shortcuts in two columns. Cyan identifies podcast actions and magenta identifies feed actions. On narrow screens or at accessibility text sizes, the shortcuts become full-width rows. At accessibility text sizes, the episode shelf also changes to one wider row and article thumbnails move above the text. The Add menu scrolls when needed.

Podcasts has a badge for new episodes you have not started. Feeds has a badge for unread feed items. Both show the full count and disappear at zero. In-progress and completed episodes are not included in the Podcasts badge.

Article thumbnails come from the feed's image, an image in its content, or the linked webpage. Some publishers provide no usable picture or block previews. In those cases, trickle shows source artwork or a placeholder. Turn on Remote images in Settings to load pictures.

### Feed refresh

Confirm the feed uses HTTPS and opens in a browser. For a private feed, verify its URL and authorization values in the feed settings.

If a refresh finishes with failed feeds, tap Review in the message to see the affected subscriptions. Open one to see its refresh error and try again. Other subscriptions and existing items remain available.

### Feed categories

Choose an existing category or enter a new one while adding a feed. To change it later, tap the category in feed details or open Feed settings. Clear the Category field to move a feed back to Uncategorized. Podcasts do not use categories.

To move several feeds at once, open the Feeds tab and choose Organize feeds. Rename changes every feed in a category; renaming to an existing category asks before merging them.

The Feed items tab can show one category at a time, with unread counts in the category picker. Clear your search to mark the whole category read from the Unread view.

### Playback

Confirm the device is online and the publisher's media URL is still available. Retry the episode after changing networks.

Episodes are marked New until they have saved listening progress, In progress while unfinished, and Played after completion or Mark played. Replaying a finished episode puts it back In progress once you have a saved position to resume from. Position is saved every 15 seconds and when playback is paused, changed, or closed. The last unfinished audio returns paused in the footer when you reopen trickle. Clearing Up next keeps it available to resume; removing it from your library removes it from the player.

After a system interruption, audio can resume if the system allows it and you haven't paused it or switched to something else. Unplugging headphones pauses playback until you press Play again.

Open Podcasts, choose Episodes, then In progress to find unfinished episodes, including those kept after unsubscribing. Removing an unsaved video item also closes its player; saved items remain available after unsubscribing.

If a completed download is missing or unusable, trickle tries the publisher's stream. Use Retry download to get a new offline copy.

If the operating system stops an episode that was still playing, trickle tries once to restore the audio session and continue. If it still cannot play, the player leaves the loading state and shows Retry.

### Video feeds

Use Add YouTube feed to add a public channel, playlist, or YouTube Atom feed. Private and members-only feeds are not supported.

Video items use Opened and Unopened instead of Watched: opening an item does not mean you finished watching it. Unopened videos count toward the Feeds badge. The item menu can change this status manually.

Video requires a network connection. Public YouTube videos play without ads when supported. If that player fails, trickle tries the official source. If neither works, choose Try again or Open original. Minimize the player to keep watching while using trickle.

Use the Picture in Picture button on a supported device to keep video and audio playing outside trickle or when the screen is locked. Closing or restoring Picture in Picture while trickle is visible returns the video to the minimized player. Closing it while trickle is in the background ends playback. Without Picture in Picture, hiding trickle pauses video. Podcast audio continues normally in the background.

### Nostr profile feeds

Paste an `npub`, `nprofile`, or `nostr:` profile address into Add feed. trickle reads verified root posts from a small finite set of secure relays. Replies and reposts are omitted so the feed stays focused on the profile's own posts.

Posts can contain text, Markdown articles, content warnings, images, audio, and direct video. Audio uses the native player and saves progress. Relay and media availability remain controlled by their respective operators; retry the feed or attachment if one is temporarily unavailable.

### Background refresh or downloads

Allow background activity for trickle in system settings. The selected interval applies to each subscription from its last refresh. Work is time-bounded; subscriptions that do not fit remain eligible for the next opportunity. Android battery restrictions and iOS Low Power Mode can delay operating-system scheduled work.

### Notifications

Enable notifications for trickle in system settings, then enable notifications for the individual feed inside trickle.

### Transcripts

Open Transcript in Now playing. Search works for every supplied transcript. Timed VTT, SRT, and Podcasting 2.0 JSON segments can be tapped to seek; plain-text transcripts remain selectable but cannot seek without publisher timing.

### Storage

Open Downloads to see the number of downloads and their stored size. Its menu can remove played downloads or all downloads. Downloads marked Keep are excluded from played-only and automatic cleanup. If you manually download an episode you already played, trickle keeps it by default. Choose Allow automatic removal to let the cleanup timing in Settings apply again.

## Backup and migration

Settings can import and export standard OPML files. Before importing, choose Podcasts, Feeds, or Mixed subscriptions. Use Podcasts for a podcast-player export; mixed files use saved types when available and detect the rest. Export offers podcasts, feeds, or all compatible subscriptions. trickle exports preserve subscription types and store feed categories as OPML folders. Portable URLs with embedded tokens are included; feeds that require separate authorization headers are skipped. Nostr profiles are stored only in trickle backups because OPML does not support them.

You can also share a feed, website, podcast RSS, YouTube, `npub`, or `nprofile` address to trickle from another app. On iOS, open trickle after sharing. Review or edit the address in Add feed before subscribing.

If a public feed permanently moves, refreshing it can update the address without losing saved items or listening progress. A backup of the same subscription won’t roll back a newer address. trickle keeps private and temporary addresses unchanged and doesn’t combine two existing subscriptions automatically.

Articles open in reader view when the page can be downloaded and extracted. Use the text-size menu to adjust the type or refresh the article. Share and Open in browser are in the toolbar. PDF links offer Open PDF, and links without an extractable article can be opened on the original site. A failed request preserves any saved or feed text and offers a retry.

Saving an article bookmarks it immediately. When you save from a list, trickle tries to cache the readable page in the background. If a saved article only has feed text, reopen it online to download the readable page. Refresh reader view fetches a new copy of the article. Publisher-hosted images and video still require a connection unless already cached.

The local ZIP backup includes subscriptions, Nostr profiles, articles, playback and reading state, queues, bookmarks, and settings. It does not include separate authorization headers, passwords, or downloaded media.

New backups support up to 2 GiB of expanded data and are split into smaller chunks to keep large libraries manageable. Backups from older versions are still supported, with their original 50 MiB expanded-data limit. If an older backup exceeds that limit, export a new one from an updated copy of trickle. Keep the ZIP intact; removing a chunk makes it incomplete.

Restore accepts only trickle ZIP backups and merges them into your library. While the backup is applied, podcast playback pauses and Up next edits wait until the queue reloads. Restored episodes are appended after existing Up next entries, including episodes added in the background. An old queue entry is skipped if the episode was marked played more recently on this device and is no longer queued. Restore keeps the more recent playback progress and settings, and keeps the read or unread status of articles already on this device. Saved items and bookmarks merge without duplicates. Offline article text from the backup is used only if the article’s link still matches. An invalid or unsupported archive is rejected without changing existing data. Canceling the picker makes no changes. If a restore is already running, tapping Restore local backup again rejoins that operation.

If a newer local unsubscribe is still recorded, an older backup won’t refill that feed with untouched items. Saved articles and episodes with listening, queue, or bookmark state can still be restored. Private feeds that can be opened with just their URL restore with private access on a new device. Keep any backup that includes those URLs somewhere safe. Backups don’t carry separate passwords or authorization headers.

## Project

- GitHub: [therealparmesh/trickle](https://github.com/therealparmesh/trickle)
