# TestFlight Notes

## What's new

Requires iOS 17 or later. Podcast playback now reapplies the native audio session before playing and makes one recovery attempt after an unexpected stop. Video playback now handles unavailable Picture in Picture without entering a false background-playing state.

## What to test

Please test the combined podcast and feed flow:

- Check the cyberpunk visual hierarchy; rows should stay aligned and readable without unnecessary boxes or dividers
- Cold-launch trickle, open Library, Podcasts, Feeds, Search, or Settings, and open podcast, feed, and episode details; each route change should use one brief full-surface signal glitch that settles cleanly without persistent lines, duplicate controls, state resets, or delayed interaction
- Enable Reduce Motion and repeat several forward and back navigations; the signal effect should be skipped while navigation and playback remain unchanged
- On Home, play and resume episodes directly from the two-row shelf; verify its cards reflow at large text, four-button collections are evenly spaced, Add YouTube is fully visible, and Feeds See all opens the reader
- Verify the Podcasts episode filters: New contains untouched episodes, In Progress contains partially played episodes ordered by most recently heard, and All contains the recent combined timeline
- Verify badge rules: only the Home screen’s Sources shortcut shows a number badge; it displays the exact unread feed-item count and hides at zero
- At the largest system text size, verify controls, shortcuts, the mini player, and tab navigation reflow without clipping or overlap
- With a large library, scroll primary lists during refresh or queue automation; they should remain responsive
- While audio buffers or changes between playing and paused, scroll a long episode list; unrelated rows should remain stable and responsive
- Search for multiple podcasts and subscribe to more than one; only the tapped row should show progress, and the rest of the results should remain usable
- Type a lowercase podcast query, then allow autocorrect or capitalization to change only its letter case; results must remain visible without a new loading flash
- Open a podcast result and verify its description, art, dates, durations, and summaries appear before subscription and after unsubscribing
- Partially play an episode; verify lists change from New to In Progress, show saved progress and Resume, then change to Played after completion
- Compare explicit episodes with one-line and wrapped titles; the E marker should remain immediately before the first title line
- Verify a failed audio source shows a clear message and Retry action; retry after restoring the network
- Play a podcast, leave trickle, lock the phone for at least 30 seconds, and confirm playback and its saved position continue. Return to trickle and verify the controls still match the native player
- Add episodes to Up Next, reorder the queue, and verify it survives relaunch
- Download an episode, use it offline, and test automatic cleanup after playback
- Open Downloads and verify its item count and storage total, Remove played downloads keeps items marked Keep, and Remove all downloads cancels active work before clearing the list
- With several subscriptions due, confirm background refresh does not postpone unprocessed feeds
- Pause, resume, retry, keep, and remove downloads; only that row should show command progress
- Open an article in reader mode, change text size, close and reopen it, share it, and open it in the browser. Save the article, go offline, and verify its readable text remains available while remote media is clearly network-dependent
- Share a feed or website URL to trickle from Safari or another app, then open trickle if needed; verify Add Feed appears with an editable address and canceling makes no subscription change
- Add a Nostr profile by `npub` and `nprofile`; verify only signed root posts appear, replies and reposts are absent, content warnings require a reveal, Markdown is readable, images keep their aspect ratio, native audio saves progress, and direct video can be minimized
- Refresh a Nostr profile while offline or while its relays are unavailable; existing verified posts must remain, the source must show a retryable failure, and a late older refresh must not replace newer content
- Paste a public YouTube handle, channel, playlist, video-with-playlist, and Atom feed URL; verify each resolves correctly and does not appear in Podcasts
- Open YouTube entries from both a YouTube feed and a post attachment; both should use the same initial player path and keep any official-source fallback inside that player
- Minimize a video, navigate between tabs, expand it, then close and reopen it; playback should persist without reloading until closed
- Rapidly alternate Play and Pause while expanded, minimized, and buffering; Now Playing must match the active video
- During Picture in Picture, verify Now Playing shows the entry thumbnail; restore it and verify the live minimized player returns without reloading
- Start Picture in Picture, lock the phone without closing the system window, wait at least 15 seconds, and verify audio and playback position continue before and after unlocking
- Try Picture in Picture on a video or device where it is unavailable; the request should end with a clear message and immediately restore usable controls
- With trickle visible, close Picture in Picture with its system X; the same live video and timestamp must continue in the minimized player
- With trickle backgrounded or locked, close Picture in Picture with its system X; playback and the stored video session must end
- With VoiceOver or TalkBack on the minimized video, verify only the visible expand, play or pause, and close controls are reachable; controls inside the compact page preview must not receive focus
- Close the in-app Now Playing bar with its X; it must discard the player so reopening starts fresh
- Background, lock, restore, and fully exit from expanded, minimized, and Picture in Picture video; only Picture in Picture may continue and none may crash
- Check square podcast art and landscape article and video previews; images should crop without stretching
- Fail the initial video page and verify the same player loads the official source URL without opening a second player
- Block both playback sources or go offline and verify Try again and Open original remain available
- Open the OPML importer and select a standard `.opml` or `.xml` file; verify UTF-8 and UTF-16 files import, including large podcast lists
- Import a public podcast through OPML, repeat with a tokenized feed URL, search for the same podcasts, and verify their catalog rows show Subscribed and remain actionable
- Import a podcast feed containing an announcement without audio; confirm the subscription appears only in Podcasts and does not create an article
- Assign categories while adding RSS, YouTube, and Nostr sources; verify the field suggests previous categories case-insensitively and accepts a new category. Change a category from the source page, then use Feeds > Sources > Organize feeds to move several sources at once. Rename a category and verify every matching source moves together; merging into an existing category must ask first. In Feed items, verify category unread counts, choose a category, search and sort it, then mark it read. Podcasts must not offer categories, and clearing the field returns a source to Uncategorized
- During refresh, OPML import, or local backup restore, confirm the active row reports progress, Settings remains usable, and Back works immediately
- During an active import, reopen Settings and tap Import OPML; it should rejoin the operation rather than open another picker
- Import one mixed OPML file containing a podcast and a feed; verify each appears exactly once in its matching section. Choose each scope from Export OPML and confirm the files contain podcasts, feeds, or all compatible subscriptions with the expected category folders
- In a podcast and a feed, search with different capitalization, switch filters, change newest/oldest sorting, load another page, and verify the list and count stay consistent without a full-screen loading flash
- Open a timed VTT, SRT, or JSON transcript, search it, tap a result, and verify playback seeks to that segment. A plain transcript should remain searchable and selectable without a seek affordance
- Export and restore a local backup; verify Nostr profiles, post attachments, saved articles, audio progress, queue entries, bookmarks, settings, and tokenized private feed URLs survive, while sign-in headers and downloaded files are absent. While a restore is active, leave and reopen Settings, tap Restore local backup again, and confirm it rejoins the same restore without another picker or duplicate data
- Lock the screen during playback and verify system media controls
- Interrupt playback or disconnect headphones and confirm playback pauses appropriately
- Try large system text and VoiceOver or TalkBack on the primary views
- Cold-launch the app and confirm the logo appears directly on the dark background without a light square

Report the device model, OS version, network state, and affected feed or episode. Never include private-feed credentials or complete private-feed URLs.
