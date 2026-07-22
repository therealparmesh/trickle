import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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
