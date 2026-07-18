import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/core/constants.dart';
import 'package:trickle/core/errors.dart';
import 'package:trickle/data/parsing/feed_parser.dart';

void main() {
  const parser = FeedParser();

  test('parses a hybrid RSS feed and upgrades item URLs to HTTPS', () {
    final parsed = parser.parse('''
      <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
        <channel>
          <title>Signal</title>
          <link>http://example.com</link>
          <itunes:image href="https://images.example.com/show.jpg" />
          <item>
            <guid>ep-1</guid>
            <title>Episode one</title>
            <itunes:image href="https://images.example.com/episode-one.jpg" />
            <itunes:duration>1:02:03</itunes:duration>
            <enclosure url="http://cdn.example.com/one.mp3" type="audio/mpeg" length="42" />
          </item>
          <item>
            <guid>article-1</guid>
            <title>Dispatch</title>
            <link>http://example.com/dispatch</link>
            <description>Readable text</description>
          </item>
        </channel>
      </rss>
    ''', Uri.parse('https://example.com/feed.xml'));

    expect(parsed.kind, FeedKind.hybrid);
    expect(parsed.episodes, hasLength(1));
    expect(parsed.articles, hasLength(1));
    expect(
      parsed.episodes.single.duration,
      const Duration(hours: 1, minutes: 2, seconds: 3),
    );
    expect(
      parsed.episodes.single.enclosureUrl.toString(),
      'https://cdn.example.com/one.mp3',
    );
    expect(parsed.imageUrl.toString(), 'https://images.example.com/show.jpg');
    expect(
      parsed.episodes.single.imageUrl.toString(),
      'https://images.example.com/episode-one.jpg',
    );
    expect(
      parsed.articles.single.canonicalUrl.toString(),
      'https://example.com/dispatch',
    );
  });

  test('uses media images but never treats audio media as artwork', () {
    final parsed = parser.parse('''
      <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
        <channel>
          <title>Media</title>
          <image><url>https://images.example.com/show.jpg</url></image>
          <item>
            <guid>episode</guid>
            <title>Episode</title>
            <media:content
              url="https://cdn.example.com/episode.mp3"
              type="audio/mpeg" />
          </item>
          <item>
            <guid>article</guid>
            <title>Article</title>
            <link>https://example.com/article</link>
            <media:group>
              <media:content
                url="https://images.example.com/article.webp"
                type="image/webp" />
            </media:group>
          </item>
        </channel>
      </rss>
    ''', Uri.parse('https://example.com/feed.xml'));

    expect(
      parsed.episodes.single.imageUrl.toString(),
      'https://images.example.com/show.jpg',
    );
    expect(
      parsed.articles.single.imageUrl.toString(),
      'https://images.example.com/article.webp',
    );
  });

  test('uses RSS image enclosures for article and episode artwork', () {
    final parsed = parser.parse('''
      <rss version="2.0">
        <channel>
          <title>Enclosure images</title>
          <item>
            <guid>article</guid>
            <title>Article</title>
            <enclosure
              url="https://images.example.com/article.jpg"
              type="image/jpeg" />
          </item>
          <item>
            <guid>episode</guid>
            <title>Episode</title>
            <enclosure
              url="https://cdn.example.com/episode.mp3"
              type="audio/mpeg" />
            <enclosure
              url="https://images.example.com/episode.webp"
              type="image/webp" />
          </item>
        </channel>
      </rss>
    ''', Uri.parse('https://example.com/feed.xml'));

    expect(
      parsed.articles.single.imageUrl.toString(),
      'https://images.example.com/article.jpg',
    );
    expect(
      parsed.episodes.single.imageUrl.toString(),
      'https://images.example.com/episode.webp',
    );
  });

  test('rejects non-web enclosure schemes', () {
    final parsed = parser.parse('''
      <rss><channel><title>Signal</title><item><title>Bad</title>
      <enclosure url="file:///private/audio.mp3" type="audio/mpeg" />
      </item></channel></rss>
    ''', Uri.parse('https://example.com/feed.xml'));

    expect(parsed.episodes, isEmpty);
    expect(parsed.articles, hasLength(1));
  });

  test('parses numeric RFC 822 time zones and tolerates invalid dates', () {
    final parsed = parser.parse('''
      <rss><channel><title>Dates</title>
        <item><guid>valid</guid><title>Valid</title>
          <pubDate>Wed, 15 Jul 2026 09:30:00 +0530</pubDate>
          <enclosure url="https://cdn.example.com/valid.mp3" type="audio/mpeg" />
        </item>
        <item><guid>invalid</guid><title>Invalid</title>
          <pubDate>not a date</pubDate>
          <enclosure url="https://cdn.example.com/invalid.mp3" type="audio/mpeg" />
        </item>
      </channel></rss>
    ''', Uri.parse('https://example.com/feed.xml'));

    expect(parsed.episodes, hasLength(2));
    expect(parsed.episodes.first.publishedAt, DateTime.utc(2026, 7, 15, 4));
    expect(parsed.episodes.last.publishedAt, isNull);
  });

  test('matches podcast namespaces by URI instead of hard-coded prefix', () {
    final parsed = parser.parse('''
      <rss version="2.0"
        xmlns:apple="http://www.itunes.com/dtds/podcast-1.0.dtd"
        xmlns:pi="https://podcastindex.org/namespace/1.0"
        xmlns:body="http://purl.org/rss/1.0/modules/content/">
        <channel>
          <title>Namespaced</title>
          <item>
            <guid>ep</guid>
            <title>Episode</title>
            <body:encoded><![CDATA[<p>Full notes</p>]]></body:encoded>
            <apple:duration>1:02</apple:duration>
            <pi:chapters url="https://example.com/chapters.json" />
            <pi:transcript url="https://example.com/transcript.vtt" type="text/vtt" />
            <enclosure url="https://example.com/episode.mp3" type="audio/mpeg" />
          </item>
        </channel>
      </rss>
    ''', Uri.parse('https://example.com/feed.xml'));

    final episode = parsed.episodes.single;
    expect(episode.description, contains('Full notes'));
    expect(episode.duration, const Duration(minutes: 1, seconds: 2));
    expect(episode.chaptersUrl.toString(), 'https://example.com/chapters.json');
    expect(episode.transcripts.single.mimeType, 'text/vtt');
  });

  test('skips malformed JSON Feed items but keeps valid siblings', () {
    final parsed = parser.parse('''
      {
        "version": "https://jsonfeed.org/version/1.1",
        "title": "JSON",
        "items": [
          {"id": "bad", "title": 42, "attachments": "invalid"},
          {
            "id": "episode",
            "title": "Valid episode",
            "attachments": [{
              "url": "https://example.com/episode.mp3",
              "mime_type": "audio/mpeg",
              "duration_in_seconds": -1,
              "size_in_bytes": -10
            }]
          },
          {"id": "article", "title": "Valid article", "content_text": "Body"}
        ]
      }
    ''', Uri.parse('https://example.com/feed.json'));

    expect(parsed.episodes, hasLength(1));
    expect(parsed.episodes.single.duration, isNull);
    expect(parsed.episodes.single.fileSize, isNull);
    expect(parsed.articles, hasLength(1));
  });

  test('rejects fractional and out-of-range enclosure sizes', () {
    final parsed = parser.parse('''
      {
        "version": "https://jsonfeed.org/version/1.1",
        "title": "Sizes",
        "items": [
          {
            "id": "fractional",
            "title": "Fractional",
            "attachments": [{
              "url": "https://example.com/fractional.mp3",
              "mime_type": "audio/mpeg",
              "size_in_bytes": 10.5
            }]
          },
          {
            "id": "overflow",
            "title": "Overflow",
            "attachments": [{
              "url": "https://example.com/overflow.mp3",
              "mime_type": "audio/mpeg",
              "size_in_bytes": 1e30
            }]
          }
        ]
      }
    ''', Uri.parse('https://example.com/feed.json'));

    expect(parsed.episodes, hasLength(2));
    expect(
      parsed.episodes.every((episode) => episode.fileSize == null),
      isTrue,
    );
  });

  test('preserves fractional JSON Feed durations to the millisecond', () {
    final parsed = parser.parse('''
      {
        "version": "https://jsonfeed.org/version/1.1",
        "title": "Durations",
        "items": [{
          "id": "fractional",
          "title": "Fractional duration",
          "attachments": [{
            "url": "https://example.com/fractional.mp3",
            "mime_type": "audio/mpeg",
            "duration_in_seconds": 1.25
          }]
        }]
      }
    ''', Uri.parse('https://example.com/feed.json'));

    expect(parsed.episodes.single.duration, const Duration(milliseconds: 1250));
  });

  test('parses RSS 1.0 items that are siblings of the channel', () {
    final parsed = parser.parse('''
      <rdf:RDF
        xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        xmlns="http://purl.org/rss/1.0/"
        xmlns:media="http://search.yahoo.com/mrss/">
        <channel rdf:about="https://example.com/feed">
          <title>RDF Signal</title>
          <link>http://example.com</link>
          <description><![CDATA[<p>A <strong>plain</strong> summary.</p>]]></description>
        </channel>
        <item rdf:about="https://example.com/story">
          <title>Root-level story</title>
          <link>http://example.com/story</link>
          <description>Readable body</description>
        </item>
        <item rdf:about="https://example.com/episode">
          <title>Root-level episode</title>
          <media:content
            url="http://cdn.example.com/episode.mp3"
            type="audio/mpeg" />
        </item>
      </rdf:RDF>
    ''', Uri.parse('https://example.com/feed.rdf'));

    expect(parsed.title, 'RDF Signal');
    expect(parsed.description, 'A plain summary.');
    expect(parsed.kind, FeedKind.hybrid);
    expect(parsed.articles.single.title, 'Root-level story');
    expect(
      parsed.articles.single.canonicalUrl.toString(),
      'https://example.com/story',
    );
    expect(parsed.episodes.single.title, 'Root-level episode');
    expect(
      parsed.episodes.single.enclosureUrl.toString(),
      'https://cdn.example.com/episode.mp3',
    );
  });

  test('preserves Atom HTML and XHTML but escapes plain text content', () {
    final parsed = parser.parse('''
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title type="html">&lt;strong&gt;Typed&lt;/strong&gt; feed</title>
        <subtitle type="html">&lt;p&gt;A &lt;b&gt;clean&lt;/b&gt; summary.&lt;/p&gt;</subtitle>
        <entry>
          <id>text</id>
          <title>Plain text</title>
          <content type="text">Literal &lt;b&gt;markup&lt;/b&gt; &amp; text</content>
        </entry>
        <entry>
          <id>html</id>
          <title>HTML</title>
          <summary type="html">&lt;p&gt;Short &lt;em&gt;summary&lt;/em&gt;.&lt;/p&gt;</summary>
          <content type="html">&lt;p&gt;Full &lt;strong&gt;HTML&lt;/strong&gt;.&lt;/p&gt;</content>
        </entry>
        <entry>
          <id>xhtml</id>
          <title>XHTML</title>
          <content type="xhtml">
            <div xmlns="http://www.w3.org/1999/xhtml">
              <p>Structured <em>body</em>.</p>
              <img src="https://example.com/image.jpg" alt="Preview" />
            </div>
          </content>
        </entry>
        <entry>
          <id>episode</id>
          <title>Audio</title>
          <content type="text">Notes with &lt;script&gt;literal text&lt;/script&gt;</content>
          <link rel="enclosure" href="https://example.com/audio.mp3" type="audio/mpeg" />
        </entry>
      </feed>
    ''', Uri.parse('https://example.com/feed.atom'));

    expect(parsed.title, 'Typed feed');
    expect(parsed.description, 'A clean summary.');
    expect(parsed.kind, FeedKind.hybrid);
    expect(parsed.articles, hasLength(3));
    expect(
      parsed.articles[0].contentHtml,
      'Literal &lt;b&gt;markup&lt;/b&gt; &amp; text',
    );
    expect(
      parsed.articles[1].contentHtml,
      '<p>Full <strong>HTML</strong>.</p>',
    );
    expect(parsed.articles[1].summary, 'Short summary.');
    expect(parsed.articles[2].contentHtml, contains('<p>'));
    expect(parsed.articles[2].contentHtml, contains('<em>body</em>'));
    expect(parsed.articles[2].contentHtml, contains('<img'));
    expect(
      parsed.episodes.single.description,
      'Notes with &lt;script&gt;literal text&lt;/script&gt;',
    );
  });

  test('uses Atom entry media and image enclosures as artwork', () {
    final parsed = parser.parse('''
      <feed xmlns="http://www.w3.org/2005/Atom"
        xmlns:media="http://search.yahoo.com/mrss/">
        <title>Atom artwork</title>
        <entry>
          <id>article</id>
          <title>Article</title>
          <media:content
            url="https://images.example.com/article.png"
            type="image/png" />
        </entry>
        <entry>
          <id>episode</id>
          <title>Episode</title>
          <link rel="enclosure"
            href="https://cdn.example.com/episode.mp3"
            type="audio/mpeg" />
          <link rel="enclosure"
            href="https://images.example.com/episode.jpg"
            type="image/jpeg" />
        </entry>
      </feed>
    ''', Uri.parse('https://example.com/feed.atom'));

    expect(
      parsed.articles.single.imageUrl.toString(),
      'https://images.example.com/article.png',
    );
    expect(
      parsed.episodes.single.imageUrl.toString(),
      'https://images.example.com/episode.jpg',
    );
  });

  test('ignores unsupported and malformed Atom content constructs', () {
    final parsed = parser.parse('''
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title>Atom</title>
        <entry>
          <id>binary</id><title>Binary</title>
          <content type="image/png">not-html</content>
        </entry>
        <entry>
          <id>broken-xhtml</id><title>Broken XHTML</title>
          <content type="xhtml"><p>Missing required div</p></content>
        </entry>
      </feed>
    ''', Uri.parse('https://example.com/feed.atom'));

    expect(parsed.articles, hasLength(2));
    expect(
      parsed.articles.every((article) => article.contentHtml == null),
      isTrue,
    );
  });

  test('escapes JSON Feed content_text and preserves content_html', () {
    final parsed = parser.parse('''
      {
        "version": "https://jsonfeed.org/version/1.1",
        "title": "JSON",
        "description": "<p>A <strong>plain</strong> description.</p>",
        "items": [
          {
            "id": "text",
            "title": "Text",
            "content_text": "<h1>Not markup</h1> & still text"
          },
          {
            "id": "html",
            "title": "HTML",
            "content_html": "<p>Actual <em>markup</em>.</p>"
          },
          {
            "id": "audio",
            "title": "Audio",
            "content_text": "<b>Literal notes</b>",
            "attachments": [{
              "url": "https://example.com/audio.mp3",
              "mime_type": "audio/mpeg"
            }]
          }
        ]
      }
    ''', Uri.parse('https://example.com/feed.json'));

    expect(parsed.description, 'A plain description.');
    expect(
      parsed.articles[0].contentHtml,
      '&lt;h1&gt;Not markup&lt;/h1&gt; &amp; still text',
    );
    expect(parsed.articles[1].contentHtml, '<p>Actual <em>markup</em>.</p>');
    expect(
      parsed.episodes.single.description,
      '&lt;b&gt;Literal notes&lt;/b&gt;',
    );
  });

  test('uses JSON Feed banner_image when an item image is absent', () {
    final parsed = parser.parse('''
      {
        "version": "https://jsonfeed.org/version/1.1",
        "title": "JSON artwork",
        "items": [
          {
            "id": "article",
            "title": "Article",
            "banner_image": "https://images.example.com/article-banner.jpg"
          },
          {
            "id": "episode",
            "title": "Episode",
            "banner_image": "https://images.example.com/episode-banner.jpg",
            "attachments": [{
              "url": "https://cdn.example.com/episode.mp3",
              "mime_type": "audio/mpeg"
            }]
          }
        ]
      }
    ''', Uri.parse('https://example.com/feed.json'));

    expect(
      parsed.articles.single.imageUrl.toString(),
      'https://images.example.com/article-banner.jpg',
    );
    expect(
      parsed.episodes.single.imageUrl.toString(),
      'https://images.example.com/episode-banner.jpg',
    );
  });

  test('rejects RDF without a channel and malformed Atom XML', () {
    expect(
      () => parser.parse(
        '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><item /></rdf:RDF>',
        Uri.parse('https://example.com/feed.rdf'),
      ),
      throwsA(isA<FeedParseException>()),
    );
    expect(
      () => parser.parse(
        '<feed xmlns="http://www.w3.org/2005/Atom"><entry></feed>',
        Uri.parse('https://example.com/feed.atom'),
      ),
      throwsA(isA<FeedParseException>()),
    );
  });
}
