# App Review Notes

trickle is a podcast player and RSS reader. No account, login, purchase, subscription, or reviewer credentials are required.

## Review steps

1. Launch trickle and open Search.
2. Search the Apple podcast catalog for a public podcast and open it. Its description and episode list are available before subscription. Subscribe from that screen.
3. Open an episode. The detail screen does not begin playback automatically; tap Play to stream it.
4. Use the episode menu to download it or add it to Up Next.
5. From Home, tap Add Feed under Feeds to enter a public RSS, Atom, JSON Feed, or website URL.
6. Tap Add YouTube to enter a public YouTube channel or playlist URL. Both actions use the same feed subscription pipeline.
7. Open an article to use the extracted reader view. Share and Open in Browser are available from the reader toolbar.
8. Open a YouTube feed entry to use its in-app web player. It can be minimized to a persistent live Now Playing preview while navigating the app, expanded again without reloading, closed, or opened at its original URL. Its explicit Picture in Picture button starts the system presentation on supported devices. During Picture in Picture, the in-app bar uses the entry thumbnail. Closing either the bar or system window ends the video. Video audio continues while the app is hidden only during Picture in Picture; otherwise the video pauses. If the initial video page cannot load, the same player falls back to the official source URL from the feed.
9. Settings contains global playback speed, download cleanup, standard OPML import, separate OPML exports for podcasts, feeds (RSS and YouTube), and all subscriptions, plus local backup controls.

Network access is required for catalog search, feed refresh, article extraction, artwork, and streaming. Downloaded episodes and previously cached content remain available offline.

## Background audio and downloads

Background audio is active for podcast playback. Web-video background audio is enabled only after the user starts system Picture in Picture and remains subject to the active player and device settings. App-private episode downloads may continue through the operating system's download scheduler. trickle does not access the user's Photos or media library.

## Private feeds

Private-feed support is optional and is not required for review. Credentials entered by the user are stored in the device Keychain or Keystore and are sent only to the selected feed or media host. No private-feed credentials are provided with the review build.

## Content

trickle is a general-purpose client for content selected by the user. Podcast search uses Apple's public catalog. Public YouTube channel and playlist URLs resolve to YouTube's Atom feeds. Video entries play in an embedded web player. If the initial page cannot load, the same player falls back to the official source URL from the feed. trickle does not download, extract, host, or modify video streams. The app does not host, sell, or modify third-party audio or articles.
