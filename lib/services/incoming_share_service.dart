import 'package:flutter/services.dart';

final class IncomingShareService {
  IncomingShareService() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedText') {
        _pendingText = (call.arguments as String?)?.trim();
      }
    });
  }

  static const _channel = MethodChannel(
    'com.parmscript.trickle/incoming-share',
  );

  String? _pendingText;

  Future<String?> takePendingText() async {
    final current = _pendingText;
    _pendingText = null;
    try {
      final native = (await _channel.invokeMethod<String>(
        'takePendingText',
      ))?.trim();
      return current?.isNotEmpty == true ? current : native;
    } on Object {
      // Do not lose an event already delivered to Dart if the native handoff
      // is temporarily unavailable. A newer event always wins.
      _pendingText ??= current;
      rethrow;
    }
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}

String? feedInputFromSharedText(String? shared) {
  final value = shared?.trim();
  if (value == null || value.isEmpty) return null;
  final url = RegExp(
    r'https?://[^\s<>]+',
    caseSensitive: false,
  ).firstMatch(value);
  if (url != null) {
    return url.group(0)?.replaceFirst(RegExp(r'''[,.;:!?\)\]\}>"'”’]+$'''), '');
  }
  final nostr = RegExp(
    r'\b(?:npub1|nprofile1)[023456789acdefghjklmnpqrstuvwxyz]+\b',
    caseSensitive: false,
  ).firstMatch(value);
  if (nostr != null) return nostr.group(0);
  return value;
}
