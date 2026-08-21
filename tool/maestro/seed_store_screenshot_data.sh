#!/usr/bin/env bash
set -euo pipefail

readonly bundle_id="com.parmscript.trickle"
readonly simulator_id="${1:-$(xcrun simctl list devices booted -j | plutil -extract devices raw -o - - | sed -n 's/.*"udid" : "\([^"]*\)".*/\1/p' | head -1)}"

if [[ -z "$simulator_id" ]]; then
  echo "No booted iOS Simulator found." >&2
  exit 1
fi

xcrun simctl terminate "$simulator_id" "$bundle_id" 2>/dev/null || true
readonly container="$(xcrun simctl get_app_container "$simulator_id" "$bundle_id" data)"
readonly database="$container/Library/Application Support/trickle.sqlite"

if [[ ! -f "$database" ]]; then
  echo "Launch trickle once before seeding screenshot data." >&2
  exit 1
fi

sqlite3 "$database" <<'SQL'
PRAGMA foreign_keys = ON;
BEGIN IMMEDIATE;

DELETE FROM search_index;
DELETE FROM queue_entries;
DELETE FROM playback_progresses;
DELETE FROM media_downloads;
DELETE FROM chapters;
DELETE FROM transcripts;
DELETE FROM bookmarks;
DELETE FROM article_attachments;
DELETE FROM articles;
DELETE FROM episodes;
DELETE FROM nostr_relays;
DELETE FROM nostr_profiles;
DELETE FROM feeds;

INSERT INTO feeds (
  id, title, description, feed_url, site_url, image_url, author, category,
  kind, protocol, subscribed, is_private, last_refresh, auto_download,
  auto_download_limit, notifications, intro_skip_ms, outro_skip_ms,
  auto_queue, created_at, updated_at
) VALUES (
  'store-podcast',
  'Neon Dispatch',
  'Small, practical conversations about calmer technology, thoughtful design, and listening on your own terms.',
  'https://raw.githubusercontent.com/therealparmesh/trickle/main/store/apple/fixtures/neon-dispatch.xml',
  'https://example.com/neon-dispatch',
  'https://raw.githubusercontent.com/therealparmesh/trickle/main/store/apple/fixtures/neon-dispatch.png',
  'trickle studio',
  'Originals',
  0, 0, 1, 0, unixepoch('now'), 0, 3, 0, 0, 0, 0,
  unixepoch('now') - 1209600,
  unixepoch('now')
), (
  'store-feed',
  'Field Notes',
  'Short notes on reading, systems, and keeping a personal library useful.',
  'https://raw.githubusercontent.com/therealparmesh/trickle/main/store/apple/fixtures/field-notes.xml',
  'https://example.com/field-notes',
  'https://raw.githubusercontent.com/therealparmesh/trickle/main/store/apple/fixtures/field-notes.png',
  'trickle studio',
  'Design',
  1, 0, 1, 0, unixepoch('now'), 0, 3, 0, 0, 0, 0,
  unixepoch('now') - 1209600,
  unixepoch('now')
);

INSERT INTO episodes (
  id, feed_id, guid, title, description, enclosure_url, mime_type, image_url,
  published_at, discovered_at, duration_ms, explicit, played, starred,
  automation_applied
) VALUES (
  'store-episode-signal',
  'store-podcast',
  'store-episode-signal',
  'Signal Check: Listening without friction',
  '<p>What makes an audio app disappear into the background? We look at queues, sensible defaults, and the tiny details that keep listening moving.</p><p>This fictional episode was created for trickle store screenshots.</p>',
  'https://example.com/audio/signal-check.mp3',
  'audio/mpeg',
  'https://raw.githubusercontent.com/therealparmesh/trickle/main/store/apple/fixtures/signal-check.png',
  unixepoch('now') - 10800,
  unixepoch('now') - 10800,
  2520000,
  0, 0, 0, 1
), (
  'store-episode-offline',
  'store-podcast',
  'store-episode-offline',
  'Offline First: A library that stays yours',
  '<p>A practical tour of downloads, local state, and resilient reading and listening when the network disappears.</p>',
  'https://example.com/audio/offline-first.mp3',
  'audio/mpeg',
  'https://raw.githubusercontent.com/therealparmesh/trickle/main/store/apple/fixtures/offline-first.png',
  unixepoch('now') - 93600,
  unixepoch('now') - 93600,
  2880000,
  0, 0, 0, 1
), (
  'store-episode-queue',
  'store-podcast',
  'store-episode-queue',
  'Queue Craft: Decide once, keep listening',
  '<p>How a clear Up Next list can reduce taps without taking control away from the listener.</p>',
  'https://example.com/audio/queue-craft.mp3',
  'audio/mpeg',
  'https://raw.githubusercontent.com/therealparmesh/trickle/main/store/apple/fixtures/queue-craft.png',
  unixepoch('now') - 266400,
  unixepoch('now') - 266400,
  2280000,
  0, 0, 1, 1
);

INSERT INTO playback_progresses (
  episode_id, position_ms, duration_ms, completed, updated_at
) VALUES (
  'store-episode-offline', 1140000, 2880000, 0, unixepoch('now') - 5400
);

INSERT INTO queue_entries (id, episode_id, sort_key, added_at) VALUES (
  'store-queue-signal', 'store-episode-signal', 1000, unixepoch('now') - 1800
), (
  'store-queue-offline', 'store-episode-offline', 2000, unixepoch('now') - 1200
);

INSERT INTO articles (
  id, feed_id, guid, title, author, summary, content_html, canonical_url,
  image_url, content_format, media_kind, published_at, discovered_at, starred
) VALUES (
  'store-article-calm',
  'store-feed',
  'store-article-calm',
  'A calmer way to follow the web',
  'Mara Vale',
  'A focused feed can turn a noisy web into a library you actually want to revisit.',
  '<img src="https://raw.githubusercontent.com/therealparmesh/trickle/main/store/apple/fixtures/calm-web.png" alt="Abstract reader window in cyan and magenta"><h2>Start with the signal</h2><p>A good reader should help you keep the sources you value without rebuilding the noise of the open web. The simplest tools do three things well: collect, clarify, and get out of the way.</p><p>Save what matters, mark the rest read, and return when you are ready. Your library should feel quieter after every visit.</p><h2>Make it yours</h2><p>Categories give broad shape to a collection. Reader mode gives each article room to breathe. Offline storage keeps the useful parts close.</p>',
  'https://example.com/field-notes/calm-web',
  'https://raw.githubusercontent.com/therealparmesh/trickle/main/store/apple/fixtures/calm-web.png',
  0, 1,
  unixepoch('now') - 7200,
  unixepoch('now') - 7200,
  0
), (
  'store-article-library',
  'store-feed',
  'store-article-library',
  'Build a library that stays fast',
  'Ivo North',
  'A few durable rules for keeping a growing collection quick to search and easy to scan.',
  '<img src="https://raw.githubusercontent.com/therealparmesh/trickle/main/store/apple/fixtures/local-library.png" alt="Abstract local library"><p>Fast libraries begin with predictable structure. Keep navigation shallow, make state visible, and let local data answer the common questions first.</p>',
  'https://example.com/field-notes/local-library',
  'https://raw.githubusercontent.com/therealparmesh/trickle/main/store/apple/fixtures/local-library.png',
  0, 1,
  unixepoch('now') - 97200,
  unixepoch('now') - 97200,
  0
), (
  'store-article-reader',
  'store-feed',
  'store-article-reader',
  'Reader mode without the clutter',
  'Sera Lin',
  'Typography, spacing, and a direct route back to the original page.',
  '<img src="https://raw.githubusercontent.com/therealparmesh/trickle/main/store/apple/fixtures/reader-mode.png" alt="Abstract reader page"><p>Reader mode works best when it preserves the article and removes only the surrounding clutter. Clear typography and honest escape hatches matter more than clever controls.</p>',
  'https://example.com/field-notes/reader-mode',
  'https://raw.githubusercontent.com/therealparmesh/trickle/main/store/apple/fixtures/reader-mode.png',
  0, 1,
  unixepoch('now') - 180000,
  unixepoch('now') - 180000,
  1
);

INSERT OR REPLACE INTO app_settings (key, value, updated_at) VALUES
  ('remote_images', 'true', unixepoch('now')),
  ('refresh_interval', 'weekly', unixepoch('now'));

INSERT INTO search_index (entity_id, kind, title, body, feed_title)
SELECT id, 'feed', title, COALESCE(description, ''), title FROM feeds;
INSERT INTO search_index (entity_id, kind, title, body, feed_title)
SELECT episodes.id, 'episode', episodes.title, COALESCE(episodes.description, ''), feeds.title
FROM episodes JOIN feeds ON feeds.id = episodes.feed_id;
INSERT INTO search_index (entity_id, kind, title, body, feed_title)
SELECT articles.id, 'article', articles.title,
  COALESCE(articles.author, '') || ' ' || COALESCE(articles.summary, ''), feeds.title
FROM articles JOIN feeds ON feeds.id = articles.feed_id;

COMMIT;
PRAGMA wal_checkpoint(TRUNCATE);
SQL

echo "Seeded copyright-safe App Store screenshot data on $simulator_id."
