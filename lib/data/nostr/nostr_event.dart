import 'dart:convert';

import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart';

import '../../core/constants.dart';

const nostrPostKinds = <int>{1, 20, 21, 22, 1222, 30023, 34235, 34236};

final class NostrEvent {
  const NostrEvent({
    required this.id,
    required this.publicKey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
  });

  final String id;
  final String publicKey;
  final DateTime createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;

  String? firstTag(String name) {
    for (final tag in tags) {
      if (tag.length >= 2 && tag.first == name && tag[1].trim().isNotEmpty) {
        return tag[1].trim();
      }
    }
    return null;
  }

  bool get isReply => tags.any(
    (tag) =>
        tag.isNotEmpty &&
        (tag.first == 'e' || tag.first == 'a') &&
        (tag.length < 4 ||
            tag[3].isEmpty ||
            tag[3] == 'root' ||
            tag[3] == 'reply'),
  );

  String? get address {
    if (kind < 30000 || kind >= 40000) return null;
    return '$kind:$publicKey:${firstTag('d') ?? ''}';
  }
}

final class NostrAttachmentData {
  const NostrAttachmentData({
    required this.url,
    required this.mimeType,
    required this.previewUrl,
    required this.alt,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.fallbackUrls,
  });

  final String url;
  final String? mimeType;
  final String? previewUrl;
  final String? alt;
  final int? width;
  final int? height;
  final int? durationMs;
  final List<String> fallbackUrls;
}

final class NostrPostData {
  const NostrPostData({
    required this.eventId,
    required this.address,
    required this.title,
    required this.summary,
    required this.content,
    required this.contentFormat,
    required this.contentWarning,
    required this.mediaKind,
    required this.publishedAt,
    required this.attachments,
  });

  final String eventId;
  final String? address;
  final String title;
  final String? summary;
  final String content;
  final ArticleContentFormat contentFormat;
  final String? contentWarning;
  final ArticleMediaKind mediaKind;
  final DateTime publishedAt;
  final List<NostrAttachmentData> attachments;
}

final class NostrProfileData {
  const NostrProfileData({
    required this.name,
    required this.about,
    required this.picture,
  });

  final String? name;
  final String? about;
  final String? picture;
}

final class NostrRefreshData {
  const NostrRefreshData({
    required this.profile,
    required this.posts,
    required this.deletedEvents,
    required this.deletedAddresses,
    required this.advertisedRelays,
  });

  final NostrProfileData? profile;
  final List<NostrPostData> posts;
  final Map<String, DateTime> deletedEvents;
  final Map<String, DateTime> deletedAddresses;
  final List<String> advertisedRelays;
}

NostrRefreshData parseAndVerifyNostrEvents(Map<String, Object?> input) {
  final expectedKey = input['publicKey'] as String;
  final rawEvents = (input['events'] as List? ?? const []).whereType<Map>().map(
    (event) => event.cast<String, Object?>(),
  );
  final events = <NostrEvent>[];
  for (final raw in rawEvents) {
    final event = _verifiedEvent(raw, expectedKey);
    if (event != null) events.add(event);
  }
  events.sort((left, right) => right.createdAt.compareTo(left.createdAt));

  NostrProfileData? profile;
  final deletedEvents = <String, DateTime>{};
  final deletedAddresses = <String, DateTime>{};
  var advertisedRelays = const <String>[];
  for (final event in events) {
    if (event.kind == 0 && profile == null) {
      profile = _profile(event.content);
    } else if (event.kind == 5) {
      for (final tag in event.tags) {
        if (tag.length < 2) continue;
        if (tag.first == 'e' && _isHex(tag[1], 64)) {
          _recordLatestDeletion(deletedEvents, tag[1], event.createdAt);
        } else if (tag.first == 'a' &&
            tag[1].split(':').elementAtOrNull(1) == event.publicKey) {
          _recordLatestDeletion(deletedAddresses, tag[1], event.createdAt);
        }
      }
    } else if (event.kind == 10002 && advertisedRelays.isEmpty) {
      advertisedRelays = event.tags
          .where(
            (tag) =>
                tag.length >= 2 &&
                tag.first == 'r' &&
                (tag.length < 3 || tag[2].isEmpty || tag[2] == 'write'),
          )
          .map((tag) => tag[1])
          .toList(growable: false);
    }
  }

  final newestByIdentity = <String, NostrEvent>{};
  for (final event in events) {
    if (!nostrPostKinds.contains(event.kind) ||
        event.isReply ||
        _deletedAtOrAfter(deletedEvents[event.id], event.createdAt) ||
        _deletedAtOrAfter(
          event.address == null ? null : deletedAddresses[event.address],
          event.createdAt,
        )) {
      continue;
    }
    final identity = event.address ?? event.id;
    newestByIdentity.putIfAbsent(identity, () => event);
  }
  return NostrRefreshData(
    profile: profile,
    posts: newestByIdentity.values.map(_post).toList(growable: false),
    deletedEvents: deletedEvents,
    deletedAddresses: deletedAddresses,
    advertisedRelays: advertisedRelays,
  );
}

void _recordLatestDeletion(
  Map<String, DateTime> deletions,
  String identity,
  DateTime createdAt,
) {
  final stored = deletions[identity];
  if (stored == null || createdAt.isAfter(stored)) {
    deletions[identity] = createdAt;
  }
}

bool _deletedAtOrAfter(DateTime? deletion, DateTime event) =>
    deletion != null && !deletion.isBefore(event);

NostrEvent? _verifiedEvent(Map<String, Object?> json, String expectedKey) {
  final id = json['id'];
  final publicKey = json['pubkey'];
  final createdAt = json['created_at'];
  final kind = json['kind'];
  final content = json['content'];
  final signature = json['sig'];
  final rawTags = json['tags'];
  if (id is! String ||
      publicKey is! String ||
      publicKey != expectedKey ||
      createdAt is! int ||
      kind is! int ||
      content is! String ||
      signature is! String ||
      rawTags is! List ||
      createdAt < 0 ||
      createdAt > 253402300799 ||
      !_isHex(id, 64) ||
      !_isHex(publicKey, 64) ||
      !_isHex(signature, 128) ||
      content.length > 1024 * 1024 ||
      rawTags.length > 1000) {
    return null;
  }
  final tags = <List<String>>[];
  for (final rawTag in rawTags) {
    if (rawTag is! List || rawTag.length > 32) return null;
    final tag = rawTag.whereType<String>().toList(growable: false);
    if (tag.length != rawTag.length ||
        tag.any((value) => value.length > 8192)) {
      return null;
    }
    tags.add(tag);
  }
  final serialized = jsonEncode([0, publicKey, createdAt, kind, tags, content]);
  final calculated = sha256.convert(utf8.encode(serialized)).toString();
  if (calculated != id) return null;
  try {
    if (!bip340.verify(publicKey, id, signature)) return null;
  } on Object {
    return null;
  }
  return NostrEvent(
    id: id,
    publicKey: publicKey,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      createdAt * 1000,
      isUtc: true,
    ),
    kind: kind,
    tags: tags,
    content: content,
  );
}

NostrProfileData? _profile(String content) {
  try {
    final json = jsonDecode(content);
    if (json is! Map) return null;
    final map = json.cast<Object?, Object?>();
    return NostrProfileData(
      name: _shortText(map['display_name'] ?? map['name'], 120),
      about: _shortText(map['about'], 4000),
      picture: _publicMediaUrl(map['picture'] as String?),
    );
  } on Object {
    return null;
  }
}

NostrPostData _post(NostrEvent event) {
  final titleTag = event.firstTag('title');
  final summaryTag = event.firstTag('summary');
  final attachments = _attachments(event);
  final withoutMediaUrls = _withoutAttachmentUrls(
    event.content,
    attachments.map((item) => item.url),
  ).trim();
  final titleSource = titleTag ?? summaryTag ?? withoutMediaUrls;
  final title = _postTitle(titleSource, event.kind);
  final warningTag = event.tags
      .where((tag) => tag.isNotEmpty && tag.first == 'content-warning')
      .firstOrNull;
  final warning = warningTag == null
      ? null
      : warningTag.length > 1 && warningTag[1].trim().isNotEmpty
      ? warningTag[1].trim()
      : 'Sensitive content';
  return NostrPostData(
    eventId: event.id,
    address: event.address,
    title: title,
    summary: summaryTag ?? (event.kind == 30023 ? null : withoutMediaUrls),
    content: withoutMediaUrls,
    contentFormat: event.kind == 30023
        ? ArticleContentFormat.markdown
        : ArticleContentFormat.plainText,
    contentWarning: warning,
    mediaKind: _mediaKind(attachments),
    publishedAt: event.createdAt,
    attachments: attachments,
  );
}

ArticleMediaKind _mediaKind(List<NostrAttachmentData> attachments) {
  final kinds = <ArticleMediaKind>{};
  for (final attachment in attachments) {
    final mime = attachment.mimeType?.toLowerCase();
    final path = Uri.tryParse(attachment.url)?.path.toLowerCase() ?? '';
    if (mime?.startsWith('image/') == true ||
        RegExp(r'\.(avif|gif|jpe?g|png|webp)$').hasMatch(path)) {
      kinds.add(ArticleMediaKind.image);
    } else if (mime?.startsWith('audio/') == true ||
        RegExp(r'\.(aac|flac|m4a|mp3|ogg|opus|wav)$').hasMatch(path)) {
      kinds.add(ArticleMediaKind.audio);
    } else if (mime?.startsWith('video/') == true ||
        RegExp(r'\.(m3u8|m4v|mov|mp4|webm)$').hasMatch(path)) {
      kinds.add(ArticleMediaKind.video);
    }
  }
  return kinds.isEmpty
      ? ArticleMediaKind.none
      : kinds.length == 1
      ? kinds.single
      : ArticleMediaKind.mixed;
}

List<NostrAttachmentData> _attachments(NostrEvent event) {
  const maxAttachments = 20;
  final result = <NostrAttachmentData>[];
  final seen = <String>{};
  for (final tag in event.tags) {
    if (result.length == maxAttachments) break;
    if (tag.length < 2 || tag.first != 'imeta') continue;
    final fields = <String, List<String>>{};
    for (final value in tag.skip(1)) {
      final separator = value.indexOf(' ');
      if (separator <= 0) continue;
      final name = value.substring(0, separator);
      final field = value.substring(separator + 1).trim();
      if (field.isNotEmpty) fields.putIfAbsent(name, () => []).add(field);
    }
    final url = _publicMediaUrl(fields['url']?.firstOrNull);
    if (url == null || !seen.add(url)) continue;
    final dimensions = fields['dim']?.firstOrNull?.split('x');
    result.add(
      NostrAttachmentData(
        url: url,
        mimeType: fields['m']?.firstOrNull,
        previewUrl: _publicMediaUrl(
          fields['image']?.firstOrNull ?? fields['thumb']?.firstOrNull,
        ),
        alt: _shortText(fields['alt']?.firstOrNull, 1000),
        width: _positiveInt(dimensions?.firstOrNull),
        height: _positiveInt(dimensions?.elementAtOrNull(1)),
        durationMs: _durationMs(fields['duration']?.firstOrNull),
        fallbackUrls: [
          for (final fallback in fields['fallback'] ?? const <String>[])
            ?_publicMediaUrl(fallback),
        ].take(10).toList(growable: false),
      ),
    );
  }
  if (result.isEmpty) {
    final taggedUrl = _publicMediaUrl(event.firstTag('url'));
    if (taggedUrl != null) {
      result.add(
        NostrAttachmentData(
          url: taggedUrl,
          mimeType: event.firstTag('m'),
          previewUrl: _publicMediaUrl(event.firstTag('image')),
          alt: _shortText(event.firstTag('alt'), 1000),
          width: null,
          height: null,
          durationMs: _durationMs(event.firstTag('duration')),
          fallbackUrls: const [],
        ),
      );
    }
  }
  return result;
}

String _postTitle(String source, int kind) {
  final compact = source.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (compact.isEmpty) {
    return switch (kind) {
      20 => 'Picture',
      21 || 22 || 34235 || 34236 => 'Video',
      1222 => 'Voice note',
      _ => 'Post',
    };
  }
  return compact.length <= 120 ? compact : '${compact.substring(0, 119)}…';
}

String _withoutAttachmentUrls(String content, Iterable<String> urls) {
  var value = content;
  for (final url in urls) {
    value = value.replaceAll(url, '');
  }
  return value;
}

String? _publicMediaUrl(String? raw) {
  final uri = Uri.tryParse(raw?.trim() ?? '');
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.toString();
}

String? _shortText(Object? value, int limit) {
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty) return null;
  return text.length <= limit ? text : text.substring(0, limit);
}

int? _positiveInt(String? raw) {
  final value = int.tryParse(raw ?? '');
  return value != null && value > 0 ? value : null;
}

int? _durationMs(String? raw) {
  final seconds = double.tryParse(raw ?? '');
  if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
  final milliseconds = (seconds * 1000).round();
  return milliseconds <= const Duration(days: 7).inMilliseconds
      ? milliseconds
      : null;
}

bool _isHex(String value, int length) =>
    value.length == length && RegExp(r'^[0-9a-f]+$').hasMatch(value);
