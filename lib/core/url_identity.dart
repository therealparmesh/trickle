String credentialAgnosticUrl(Uri uri) {
  final parameters = <MapEntry<String, String>>[];
  for (final entry in uri.queryParametersAll.entries) {
    if (_looksLikeCredential(entry.key)) continue;
    for (final value in entry.value) {
      parameters.add(MapEntry(entry.key, value));
    }
  }
  parameters.sort((left, right) {
    final key = left.key.compareTo(right.key);
    return key == 0 ? left.value.compareTo(right.value) : key;
  });
  final query = parameters
      .map(
        (entry) =>
            '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
      )
      .join('&');
  final normalized = uri
      .replace(userInfo: '', query: query)
      .removeFragment()
      .toString();
  return query.isEmpty && normalized.endsWith('?')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
}

bool sameOrigin(Uri left, Uri right) {
  return left.scheme == right.scheme &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;
}

bool _looksLikeCredential(String key) {
  final compact = key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return compact.contains('token') ||
      compact == 'auth' ||
      compact.endsWith('auth') ||
      compact.contains('authorization') ||
      compact.contains('authentication') ||
      compact == 'authcode' ||
      compact == 'authkey' ||
      compact.contains('signature') ||
      compact == 'sig' ||
      compact == 'key' ||
      compact.contains('secret') ||
      compact.contains('expires') ||
      compact.contains('expiry') ||
      compact.startsWith('xamz') ||
      compact == 'googleaccessid';
}
