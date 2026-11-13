import 'package:flutter/services.dart';

final class IncomingShareService {
  IncomingShareService({required void Function() onAvailable}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shareAvailable') onAvailable();
    });
  }

  static const _channel = MethodChannel(
    'com.parmscript.trickle/incoming-share',
  );

  Future<String?> takePendingText() =>
      _channel.invokeMethod<String>('takePendingText');

  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}

String? feedInputFromSharedText(String? shared) {
  final value = shared?.trim();
  if (value == null || value.isEmpty) return null;
  final directUrl = Uri.tryParse(value);
  if ((directUrl?.scheme == 'https' || directUrl?.scheme == 'http') &&
      directUrl!.host.isNotEmpty &&
      !value.contains(RegExp(r'\s'))) {
    return value;
  }
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
