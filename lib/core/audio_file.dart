import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const downloadMediaDirectory = 'media';

Future<File?> storedAudioFile(String? path) async {
  if (path == null) return null;
  final filename = p.basename(path);
  final parent = p.dirname(path);
  // Older releases stored the full sandbox path. Rebase only files written
  // directly to our media directory; the iOS container can move on update.
  if (filename.isEmpty ||
      filename == '.' ||
      filename == '..' ||
      (parent != downloadMediaDirectory &&
          !(p.isAbsolute(parent) &&
              p.basename(parent) == downloadMediaDirectory))) {
    return null;
  }
  final support = await getApplicationSupportDirectory();
  return File(p.join(support.path, downloadMediaDirectory, filename));
}

Future<bool> isUsableAudioFile(File file) async {
  try {
    final length = await file.length();
    if (length <= 0) return false;
    final bytes = await file
        .openRead(0, math.min(length, 512))
        .fold<List<int>>(<int>[], (buffer, chunk) => buffer..addAll(chunk));
    final prefix = utf8
        .decode(bytes, allowMalformed: true)
        .trimLeft()
        .toLowerCase();
    return !prefix.startsWith('<!doctype html') &&
        !prefix.startsWith('<html') &&
        !prefix.startsWith('<?xml');
  } on Object {
    return false;
  }
}
