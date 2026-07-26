# TestFlight Notes

Please test the combined podcast and feed flow:

- Check the cyberpunk visual hierarchy; rows should stay aligned and readable without unnecessary boxes or dividers
- Cold-launch trickle, open Library, Podcasts, Feeds, Search, or Settings, and open podcast, feed, and episode details; each pushed screen should have a clear, brief signal-lock transition without flashing, duplicate controls, or delayed interaction, and enabling system Reduce Motion should disable it
- On Home, verify four-button collections are evenly spaced, Add YouTube is fully visible, and Feeds See all opens the reader
- Verify badge rules: Podcasts and Sources count subscriptions; other collection shortcuts count their own items; zero counts and Add actions show no badge
- At the largest system text size, verify controls, shortcuts, the mini player, and tab navigation reflow without clipping or overlap
- With a large library, scroll primary lists during refresh or queue automation; they should remain responsive
- Search for multiple podcasts and subscribe to more than one; only the tapped row should show progress, and the rest of the results should remain usable
- Open a podcast result and verify its description, art, dates, durations, and summaries appear before subscription and after unsubscribing
- Partially play an episode; verify lists change from New to In Progress, show saved progress and Resume, then change to Played after completion
- Verify a failed audio source shows a clear message and Retry action; retry after restoring the network
- Add episodes to Up Next, reorder the queue, and verify it survives relaunch
- Download an episode, use it offline, and test automatic cleanup after playback
- With several subscriptions due, confirm background refresh does not postpone unprocessed feeds
- Pause, resume, retry, keep, and remove downloads; only that row should show command progress
- Open an article in reader mode, share it, and open it in the browser
- Paste a public YouTube handle, channel, playlist, video-with-playlist, and Atom feed URL; verify each resolves correctly and does not appear in Podcasts
- Minimize a video, navigate between tabs, expand it, then close and reopen it; playback should persist without reloading until closed
- Rapidly alternate Play and Pause while expanded, minimized, and buffering; Now Playing must match the active video
- During Picture in Picture, verify Now Playing shows the entry thumbnail; restore it and verify the live minimized player returns without reloading
- With trickle visible, close Picture in Picture with its system X; the same live video and timestamp must continue in the minimized player
- With trickle backgrounded or locked, close Picture in Picture with its system X; playback and the stored video session must end
- With VoiceOver or TalkBack on the minimized video, verify only the visible expand, play or pause, and close controls are reachable; controls inside the compact page preview must not receive focus
- Close the in-app Now Playing bar with its X; it must discard the player so reopening starts fresh
- Background, lock, restore, and fully exit from expanded, minimized, and Picture in Picture video; only Picture in Picture may continue and none may crash
- Check square podcast art and landscape article and video previews; images should crop without stretching
- Fail the initial video page and verify the same player loads the official feed URL without opening a second player
- Block both playback sources or go offline and verify Try again and Open original remain available
- Open the OPML importer and select a standard `.opml` or `.xml` file; verify UTF-8 and UTF-16 files import, including large podcast lists
- Import a public podcast through OPML, repeat with a query-token feed URL, search for the same podcasts, and verify their catalog rows show Unsubscribe
- Import a podcast feed containing an announcement without audio; confirm the subscription appears only in Podcasts and does not create an article
- During refresh or OPML import, confirm the row reports progress, Settings remains usable, and Back works immediately
- During an active import, reopen Settings and tap Import OPML; it should rejoin the operation rather than open another picker
- Export podcasts, feeds, and all subscriptions separately; verify each file's contents
- Lock the screen during playback and verify system media controls
- Interrupt playback or disconnect headphones and confirm playback pauses appropriately
- Try large system text and VoiceOver or TalkBack on the primary views
- Cold-launch the app and confirm the logo appears directly on the dark background without a light square

Report the device model, OS version, network state, and affected feed or episode. Never include private-feed credentials or complete private-feed URLs.
