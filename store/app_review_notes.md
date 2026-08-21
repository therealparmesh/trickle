# App Review Notes

trickle is a podcast player and RSS reader. No account, login, purchase, subscription, or reviewer credentials are required.

## Review steps

1. Launch trickle and open Search.
2. Search the Apple podcast catalog for a public podcast and open it. Its description and episode list are available before subscription. Subscribe from that screen.
3. Open an episode. The detail screen does not begin playback automatically; tap Play to stream it.
4. Use the episode menu to download it or add it to Up Next.
5. From Home, tap Add Feed under Feeds to enter a public RSS, Atom, JSON Feed, website URL, or Nostr `npub`/`nprofile`. Nostr profile feeds show verified root posts and omit replies and reposts.
6. Tap Add YouTube to enter a public YouTube channel or playlist URL. Both actions use the same feed subscription pipeline.
7. Open an article to use the extracted reader view. Share and Open in browser are available from the reader toolbar.
8. Open a YouTube feed entry to use its in-app web player. It can be minimized, restored without reloading, closed, or placed in system Picture in Picture. Video audio continues outside the app only during Picture in Picture; otherwise video pauses. A failed initial page falls back inside the same player to the official URL from the feed.
9. Settings contains global playback speed, download cleanup, OPML import and scoped exports, and local backup controls.

Network access is required for catalog search, feed refresh, article extraction, artwork, and streaming. Downloaded episodes and previously cached content remain available offline.

## Background audio and downloads

Background audio is active for podcast playback. Web-video background audio is enabled only after the user starts system Picture in Picture, including while the screen is locked, and remains subject to the active player and device settings. App-private episode downloads may continue through the operating system's download scheduler. trickle does not access the user's Photos or media library.

## Private feeds

Private-feed support is optional and is not required for review. Credentials entered by the user are stored in the device Keychain or Keystore and are sent only to the selected feed or media host. No private-feed credentials are provided with the review build.

## Content

trickle is a general-purpose client for content selected by the user. Podcast search uses Apple's public catalog. Public YouTube channel and playlist URLs resolve to YouTube's Atom feeds. Video entries play in an embedded web player. If the initial page cannot load, the same player falls back to the official source URL from the feed. Nostr profile feeds request signed public events from secure relays and verify them on the device. trickle does not download, extract, host, or modify video streams. The app does not host, sell, or modify third-party audio, articles, or posts.

The App Store screenshots contain only the fictional “Neon Dispatch” podcast and “Field Notes” feed. Their titles, descriptions, articles, and artwork were created specifically for trickle and are owned by the developer; no third-party content or branding appears in the screenshots.
