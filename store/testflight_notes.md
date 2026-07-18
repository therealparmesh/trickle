# TestFlight Notes

Please test the combined podcast and feed-reader flow:

- Search for multiple podcasts and subscribe to more than one; only the tapped row should show progress, and the rest of the results should remain usable
- Stream, seek, pause, resume, and change the global playback speed
- Add episodes to Up Next, reorder the queue, and verify it survives relaunch
- Download an episode, use it offline, and test automatic cleanup after playback
- Add a public RSS feed and test unread, read, and saved states
- Open an article in reader mode, share it, and open it in the browser
- Open the OPML importer and select a standard `.opml` or `.xml` file; verify UTF-8 and UTF-16 files import
- Export podcast subscriptions, reading subscriptions, and all subscriptions separately; verify each file contains the expected feeds
- Lock the screen during playback and verify system media controls
- Interrupt playback or disconnect headphones and confirm playback pauses appropriately
- Try large system text and VoiceOver or TalkBack on the primary views

Please include the device model, operating-system version, network state, and the feed or episode involved when reporting a problem. Never include private-feed credentials or complete private-feed URLs.
