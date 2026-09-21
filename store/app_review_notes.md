# App Review Notes

trickle is a podcast player and RSS reader. No account, login, purchase, subscription, or reviewer credentials are required.

## Review steps

1. Launch trickle and tap Add podcast in the Library grid. The corner Search button searches the local library instead.
2. Search the Apple podcast catalog for a public podcast. Its description and episodes are available before subscription. Subscribe from that screen.
3. Open an episode and tap Play to stream it.
4. Download or save it. Use More to add it to Up next or mark it played.
5. From Home, tap Add feed in Library to enter a public RSS, Atom, JSON Feed, website URL, or Nostr `npub`/`nprofile`. Add podcast URL accepts a podcast RSS URL. If a feed is entered through the wrong action, trickle explains and adds it to the appropriate collection. Nostr profile feeds show verified root posts and omit replies and reposts.
6. Tap Add YouTube feed to enter a public YouTube channel or playlist URL. Both actions use the same feed subscription pipeline.
7. Open an article in reader view. Text size persists. The toolbar can share or open the article; saving stores its readable text for offline use.
8. Open a YouTube feed entry to use its in-app web player. It can be minimized, restored without reloading, closed, or placed in system Picture in Picture. Video audio continues outside the app only during Picture in Picture; otherwise video pauses. A failed initial page falls back inside the same player to the official URL from the feed.
9. Open a podcast or feed to search, filter, and sort its items. Non-podcast feeds can be categorized while subscribing or from feed details. The Feeds tab can move several feeds or rename a category. Feed items can be filtered by category and marked read by feed or category.
10. In Now playing, open Transcript. Search timed segments or tap one to seek.
11. Settings contains playback speed, download cleanup, OPML import and export, reader text size, and local backup controls.
12. Share a feed or website URL to trickle from another app, then open trickle if it is not already visible. An editable Add feed confirmation appears before anything is subscribed.

Network access is required for catalog search, feed refresh, initial article extraction, artwork, and streaming. Downloaded episodes and saved readable article text remain available offline; publisher-hosted images may still require a connection.

## Background audio and downloads

Podcasts support background and Lock Screen playback. Web-video background audio requires system Picture in Picture and remains subject to the active player and device settings. Episode downloads use app-private storage and the operating system's download scheduler. trickle does not access Photos or the user's media library.

## Private feeds

Private-feed support is optional and is not required for review. Credentials entered by the user are stored in the device Keychain or Keystore and are sent only to the selected feed or media host. No private-feed credentials are provided with the review build.

## Content

trickle is a general-purpose app for user-selected content. Podcast search uses Apple's public catalog. Public YouTube URLs resolve to YouTube Atom feeds. Videos play in an embedded web player that falls back to the official feed URL if needed. Nostr profile feeds request signed public events and verify them on the device. trickle does not host or sell third-party content. Episode downloads and saved article text stay on the user's device; videos play through the embedded player.

The App Store screenshots contain only the fictional “Neon Dispatch” podcast and “Field Notes” feed. Their titles, descriptions, articles, and artwork were created specifically for trickle and are owned by the developer; no third-party content or branding appears in the screenshots.
