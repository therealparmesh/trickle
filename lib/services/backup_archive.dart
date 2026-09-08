import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/errors.dart';

/// Portable, chunked records. No archive path is used as an extraction path.
final class BackupArchive {
  BackupArchive._(this.directory);

  final Directory directory;
  int _expandedBytes = 0;
  final Map<String, int> _chunks = {};

  static Future<BackupArchive> create() async =>
      BackupArchive._(await Directory.systemTemp.createTemp('trickle-backup-'));

  static Future<BackupArchive> open(File file) async {
    final archive = await create();
    try {
      await compute(_unpackBackup, (file.path, archive.directory.path));
      return archive;
    } catch (_) {
      await archive.dispose();
      rethrow;
    }
  }

  Future<void> write(String table, Stream<Map<String, Object?>> records) async {
    final limit = _recordLimits[table]!;
    var count = 0;
    var chunk = 0;
    var size = 2;
    final lines = <String>[];
    Future<void> flush() async {
      if (lines.isEmpty) return;
      final text = '[${lines.join(',')}]';
      _expandedBytes += utf8.encode(text).length;
      if (_expandedBytes > _maxExpandedBytes) {
        throw const BackupException('Backup exceeds the 2 GiB size limit.');
      }
      await File(
        p.join(directory.path, _chunkName(table, chunk++)),
      ).writeAsString(text);
      lines.clear();
      size = 2;
    }

    await for (final record in records) {
      if (++count > limit) {
        throw const BackupException('Backup contains too many records.');
      }
      final text = jsonEncode(record);
      final bytes = utf8.encode(text).length + 1;
      if (bytes + 2 > _maxChunkBytes) {
        throw const BackupException(
          'A backup item exceeds the 32 MiB size limit.',
        );
      }
      if (lines.isNotEmpty &&
          (lines.length == 100 || size + bytes > _targetChunkBytes)) {
        await flush();
      }
      lines.add(text);
      size += bytes;
    }
    await flush();
    _chunks[table] = chunk;
  }

  Stream<Map<String, Object?>> records(String table) async* {
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((file) => p.basename(file.path).startsWith('$table-'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final rows = await compute(_readChunk, file.path);
      yield* Stream.fromIterable(rows);
    }
  }

  Future<void> save(File destination) async {
    await File(p.join(directory.path, 'manifest.json')).writeAsString(
      jsonEncode({
        'format': 'trickle-backup',
        'version': 3,
        'chunks': _chunks,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    await compute(_zipBackup, (directory.path, destination.path));
  }

  Future<void> dispose() => directory.delete(recursive: true);
}

const _recordLimits = {
  'feeds': 5000,
  'episodes': 200000,
  'articles': 200000,
  'articleAttachments': 500000,
  'nostrProfiles': 5000,
  'nostrRelays': 20000,
  'progress': 200000,
  'queue': 200000,
  'bookmarks': 500000,
  'settings': 1000,
};
const _maxExpandedBytes = 2 * 1024 * 1024 * 1024;
const _maxChunkBytes = 32 * 1024 * 1024;
const _targetChunkBytes = 1024 * 1024;
const _maxArchiveBytes = _maxExpandedBytes + 1024 * 1024;

String _chunkName(String table, int index) =>
    '$table-${index.toString().padLeft(6, '0')}.json';

List<Map<String, Object?>> _readChunk(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as List)
        .map((row) => (row as Map).cast<String, Object?>())
        .toList();

void _zipBackup((String, String) paths) {
  final destination = File(paths.$2);
  final partial = File('${destination.path}.partial');
  final encoder = ZipFileEncoder();
  try {
    encoder.create(partial.path);
    try {
      for (final file in Directory(paths.$1).listSync().whereType<File>()) {
        encoder.addFileSync(file, p.basename(file.path));
      }
    } finally {
      encoder.closeSync();
    }
    if (partial.lengthSync() > _maxArchiveBytes) {
      throw const BackupException('Backup exceeds the 2 GiB size limit.');
    }
    partial.renameSync(destination.path);
  } finally {
    if (partial.existsSync()) partial.deleteSync();
  }
}

Future<void> _unpackBackup((String, String) paths) async {
  InputFileStream? input;
  try {
    if (File(paths.$1).lengthSync() > _maxArchiveBytes) {
      throw const BackupException('Backup exceeds the 2 GiB size limit.');
    }
    input = InputFileStream(paths.$1);
    // Inspect sizes and entry types before the decoder can read link contents.
    final directory = ZipDirectory()..read(input);
    final headers = {
      for (final header in directory.fileHeaders) header.filename: header,
    };
    if (headers.length != directory.fileHeaders.length) {
      throw const FormatException('Duplicate archive entries');
    }
    var declaredSize = 0;
    for (final header in directory.fileHeaders) {
      if (header.filename != 'manifest.json') {
        declaredSize += header.uncompressedSize;
      }
      if (declaredSize > _maxExpandedBytes) {
        throw const BackupException('Backup exceeds the 2 GiB size limit.');
      }
      final limit = switch (header.filename) {
        'trickle.json' => 50 * 1024 * 1024,
        'manifest.json' => 4096,
        _ => _maxChunkBytes,
      };
      if (header.filename == 'trickle.json' &&
          header.uncompressedSize > limit) {
        throw const BackupException(
          'This older backup exceeds the 50 MiB legacy import limit. Export a new backup from an updated copy of trickle.',
        );
      }
      if (header.uncompressedSize > limit ||
          ((header.externalFileAttributes >> 16) & 0xf000) == 0xa000) {
        throw const BackupException(
          'Backup contains an oversized or unsupported entry.',
        );
      }
    }
    input.setPosition(0);
    final zip = ZipDecoder().decodeStream(input);
    if (zip.length != headers.length) {
      throw const FormatException('Inconsistent archive entries');
    }
    for (final entry in zip.files) {
      final header = headers[entry.name];
      if (header == null ||
          entry.size != header.uncompressedSize ||
          entry.crc32 != header.crc32) {
        throw const FormatException('Inconsistent archive headers');
      }
    }
    final legacy = zip.findFile('trickle.json');
    if (legacy != null) {
      final data = (jsonDecode(utf8.decode(_verifiedBytes(legacy))) as Map)
          .cast<String, Object?>();
      final version = data['version'];
      if (data['format'] != 'trickle-backup' ||
          version is! int ||
          version < 1 ||
          version > 2) {
        throw const BackupException('Unsupported trickle backup version.');
      }
      final writer = BackupArchive._(Directory(paths.$2));
      for (final table in _recordLimits.keys) {
        final rows = (data[table] as List? ?? const []).whereType<Map>().map(
          (row) => row.cast<String, Object?>(),
        );
        await writer.write(table, Stream.fromIterable(rows));
      }
      return;
    }
    final manifest = zip.findFile('manifest.json');
    if (manifest == null) {
      throw const FormatException('Missing manifest');
    }
    final metadata = jsonDecode(utf8.decode(_verifiedBytes(manifest))) as Map;
    if (metadata['format'] != 'trickle-backup' || metadata['version'] != 3) {
      throw const BackupException('Unsupported trickle backup version.');
    }
    final expectedChunks = metadata['chunks'] as Map;
    if (expectedChunks.length != _recordLimits.length ||
        _recordLimits.keys.any(
          (table) =>
              expectedChunks[table] is! int ||
              (expectedChunks[table] as int) < 0 ||
              (expectedChunks[table] as int) > _recordLimits[table]!,
        )) {
      throw const FormatException('Invalid backup manifest');
    }
    final counts = <String, int>{};
    final chunks = <String, int>{};
    final entries =
        zip.files.where((entry) => entry.name != 'manifest.json').toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    for (final entry in entries) {
      final match = RegExp(
        r'^([A-Za-z]+)-(\d{6})\.json$',
      ).firstMatch(entry.name);
      final table = match?.group(1);
      if (table == null ||
          !_recordLimits.containsKey(table) ||
          !entry.isFile ||
          entry.isSymbolicLink) {
        throw const FormatException('Unexpected archive entry');
      }
      final index = int.parse(match!.group(2)!);
      if (index != (chunks[table] ?? 0)) {
        throw const FormatException('Missing backup chunk');
      }
      chunks[table] = index + 1;
      final bytes = _verifiedBytes(entry);
      final records = jsonDecode(utf8.decode(bytes)) as List;
      if (records.any((record) => record is! Map)) {
        throw const FormatException('Invalid backup records');
      }
      counts[table] = (counts[table] ?? 0) + records.length;
      if (counts[table]! > _recordLimits[table]!) {
        throw const BackupException('Backup contains too many records.');
      }
      File(p.join(paths.$2, _chunkName(table, index))).writeAsBytesSync(bytes);
    }
    if (_recordLimits.keys.any(
      (table) => (chunks[table] ?? 0) != expectedChunks[table],
    )) {
      throw const FormatException('Missing backup chunk');
    }
  } on BackupException {
    rethrow;
  } catch (_) {
    throw const BackupException('That file isn’t a valid trickle backup.');
  } finally {
    input?.closeSync();
  }
}

List<int> _verifiedBytes(ArchiveFile entry) {
  final output = _BackupChunkOutput(entry.size);
  try {
    entry.writeContent(output);
    final bytes = output.getBytes();
    if (bytes.length != entry.size || getCrc32(bytes) != entry.crc32) {
      throw const FormatException('Damaged backup');
    }
    return bytes;
  } finally {
    entry.clear();
  }
}

final class _BackupChunkOutput extends OutputMemoryStream {
  _BackupChunkOutput(this.limit);
  final int limit;

  void _check(int additional) {
    if (length + additional > limit) {
      throw const FormatException('Invalid expanded size');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }
}
