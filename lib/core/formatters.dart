import 'package:html/parser.dart' as html_parser;
import 'package:intl/intl.dart';

String plainText(String? html) {
  if (html == null || html.isEmpty) return '';
  return (html_parser.parseFragment(html).text ?? '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String formatDuration(Duration duration) {
  final seconds = duration.inSeconds.clamp(0, 1 << 31);
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remaining = seconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}';
  }
  return '$minutes:${remaining.toString().padLeft(2, '0')}';
}

String compactDuration(int? milliseconds) {
  if (milliseconds == null || milliseconds <= 0) return '';
  final duration = Duration(milliseconds: milliseconds);
  if (duration.inHours > 0) {
    final minutes = duration.inMinutes.remainder(60);
    return '${duration.inHours}h ${minutes == 0 ? '' : '${minutes}m'}'.trim();
  }
  if (duration.inMinutes == 0) return '<1m';
  return '${duration.inMinutes}m';
}

String itemTimestamp(DateTime? value, {DateTime? now}) {
  if (value == null) return '';
  final local = value.toLocal();
  final current = (now ?? DateTime.now()).toLocal();
  final difference = current.difference(local);
  if (!difference.isNegative) {
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes}m ago';
    if (difference.inHours < 24) return '${difference.inHours}h ago';
  }
  return (local.year == current.year ? DateFormat.MMMd() : DateFormat.yMMMd())
      .format(local);
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
}

String speedLabel(int percent) {
  final value = percent / 100;
  return value == value.roundToDouble()
      ? '${value.toInt()}x'
      : '${value.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '')}x';
}

String metadataLine(Iterable<String?> parts) {
  final seen = <String>{};
  final values = <String>[];
  for (final part in parts) {
    final value = part?.trim();
    if (value == null || value.isEmpty) continue;
    if (seen.add(value.toLowerCase())) values.add(value);
  }
  return values.join(' · ');
}
