# TestFlight Notes

Please test the combined podcast and feed flow:

- Search for multiple podcasts and subscribe to more than one; only the tapped row should show progress, and the rest of the results should remain usable
- Open podcast search results to preview their podcast detail screen, then subscribe, unsubscribe, and resubscribe without leaving that screen
- Stream, seek, pause, resume, pause while buffering, and change the global playback speed
- Verify a failed audio source shows a clear playback message and Retry action instead of an unexplained red control; retry after restoring the network
- Add episodes to Up Next, reorder the queue, and verify it survives relaunch
- Download an episode, use it offline, and test automatic cleanup after playback
- With several subscriptions due, confirm background refresh does not postpone unprocessed feeds by resetting the whole refresh interval
- Pause, resume, retry, keep, and remove downloads; only the selected download row should show progress while its command runs
- Open an article in reader mode, share it, and open it in the browser
- Paste a public YouTube handle, channel, playlist, video-with-playlist, and direct Atom feed URL; verify each resolves to the intended feed, identifies itself as a YouTube channel or playlist, and does not appear in Podcasts
- Open a video entry, minimize it, navigate between tabs, expand it again, then close and reopen it from the detail screen; playback should persist without reloading until closed
- Rapidly alternate Play and Pause in expanded and minimized video, including while buffering; the Now Playing label and icon must always match the active video
- On iPhone, tap Play and then the Picture in Picture button; repeat on Android 8 or later and Android 12 or later
- During Picture in Picture, verify the in-app Now Playing bar shows the entry thumbnail rather than a duplicate video; restore the system window and verify the live minimized player returns without reloading
- Close Picture in Picture with its system X and repeat with the in-app Now Playing X; both must end and discard the WebView so reopening starts a new player
- Background, lock, restore, and fully exit from expanded, minimized, and Picture in Picture video; only Picture in Picture may continue and none may crash
- Check square podcast art and landscape article and video previews from several feeds; every image should crop cleanly without stretching
- Block yout-ube.com and verify the existing player automatically loads the official YouTube URL from the feed without opening a second player; official-player ads must remain unmodified
- Block both playback sources or go offline and verify the player offers Try again and Open original without obscuring the rest of the app
- Open the OPML importer and select a standard `.opml` or `.xml` file; verify UTF-8 and UTF-16 files import, including large podcast lists
- Import a podcast feed containing an announcement without audio; confirm the subscription appears only in Podcasts and does not create an article
- During Refresh now or OPML import, confirm the row reports item progress, other settings remain usable, and Back works immediately while the operation continues
- Reopen Settings during an active import and tap Import OPML again; it should rejoin the existing operation instead of opening another picker
- Export podcast subscriptions, RSS and YouTube subscriptions, and all subscriptions separately; verify each file contains the expected feeds
- Lock the screen during playback and verify system media controls
- Interrupt playback or disconnect headphones and confirm playback pauses appropriately
- Try large system text and VoiceOver or TalkBack on the primary views
- Cold-launch the app and confirm the logo appears directly on the dark background without a light square

Please include the device model, operating-system version, network state, and the feed or episode involved when reporting a problem. Never include private-feed credentials or complete private-feed URLs.
