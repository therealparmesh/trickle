sealed class TrickleException implements Exception {
  const TrickleException(this.message);
  final String message;

  @override
  String toString() => message;
}

final class NetworkException extends TrickleException {
  const NetworkException(super.message);
}

final class UnsafeAddressException extends TrickleException {
  const UnsafeAddressException(super.message);
}

final class FeedParseException extends TrickleException {
  const FeedParseException(super.message);
}

final class DownloadException extends TrickleException {
  const DownloadException(super.message);
}

final class BackupException extends TrickleException {
  const BackupException(super.message);
}

String friendlyError(Object error) {
  if (error is TrickleException) return error.message;
  return 'Couldn’t complete that action. Try again.';
}
