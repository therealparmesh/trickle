import 'dart:convert';

const _bech32Alphabet = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
const _hexPattern = r'^[0-9a-f]{64}$';

final class NostrProfileAddress {
  const NostrProfileAddress({
    required this.publicKey,
    required this.relays,
    required this.displayAddress,
  });

  final String publicKey;
  final List<Uri> relays;
  final String displayAddress;
}

bool looksLikeNostrProfile(String input) {
  final normalized = input.trim().toLowerCase();
  return normalized.startsWith('npub1') ||
      normalized.startsWith('nprofile1') ||
      normalized.startsWith('nostr:npub1') ||
      normalized.startsWith('nostr:nprofile1') ||
      RegExp(_hexPattern).hasMatch(normalized);
}

NostrProfileAddress parseNostrProfile(String input) {
  var value = input.trim();
  if (value.toLowerCase().startsWith('nostr:')) value = value.substring(6);
  final normalized = value.toLowerCase();
  if (RegExp(_hexPattern).hasMatch(normalized)) {
    return NostrProfileAddress(
      publicKey: normalized,
      relays: const [],
      displayAddress: encodeNpub(normalized),
    );
  }
  final decoded = _decodeBech32(value);
  if (decoded.hrp == 'npub' && decoded.bytes.length == 32) {
    final publicKey = _hex(decoded.bytes);
    return NostrProfileAddress(
      publicKey: publicKey,
      relays: const [],
      displayAddress: normalized,
    );
  }
  if (decoded.hrp != 'nprofile') {
    throw const FormatException('Enter an npub or nprofile address.');
  }
  String? publicKey;
  final relays = <Uri>[];
  var offset = 0;
  while (offset < decoded.bytes.length) {
    if (offset + 2 > decoded.bytes.length) {
      throw const FormatException('That Nostr profile address is incomplete.');
    }
    final type = decoded.bytes[offset++];
    final length = decoded.bytes[offset++];
    if (offset + length > decoded.bytes.length) {
      throw const FormatException('That Nostr profile address is incomplete.');
    }
    final field = decoded.bytes.sublist(offset, offset + length);
    offset += length;
    if (type == 0 && length == 32 && publicKey == null) {
      publicKey = _hex(field);
    } else if (type == 1) {
      final relay = _safeRelay(utf8.decode(field, allowMalformed: true));
      if (relay != null && !relays.contains(relay)) relays.add(relay);
    }
  }
  if (publicKey == null) {
    throw const FormatException(
      'That Nostr profile address has no public key.',
    );
  }
  return NostrProfileAddress(
    publicKey: publicKey,
    relays: List.unmodifiable(relays.take(4)),
    displayAddress: normalized,
  );
}

String encodeNpub(String publicKey) {
  return _encodeHex('npub', publicKey);
}

String encodeNote(String eventId) => _encodeHex('note', eventId);

String _encodeHex(String hrp, String value) {
  if (!RegExp(_hexPattern).hasMatch(value)) {
    throw const FormatException('Invalid Nostr identifier.');
  }
  final bytes = <int>[
    for (var index = 0; index < value.length; index += 2)
      int.parse(value.substring(index, index + 2), radix: 16),
  ];
  final data = _convertBits(bytes, 8, 5, pad: true);
  final checksum = _createChecksum(hrp, data);
  return '${hrp}1${[...data, ...checksum].map((value) => _bech32Alphabet[value]).join()}';
}

Uri? normalizeNostrRelay(String raw) => _safeRelay(raw);

({String hrp, List<int> bytes}) _decodeBech32(String input) {
  if (input.length > 5000 ||
      input.toLowerCase() != input && input.toUpperCase() != input) {
    throw const FormatException('Invalid Nostr profile address.');
  }
  final value = input.toLowerCase();
  final separator = value.lastIndexOf('1');
  if (separator < 1 || separator + 7 > value.length) {
    throw const FormatException('Invalid Nostr profile address.');
  }
  final hrp = value.substring(0, separator);
  final data = <int>[];
  for (final codeUnit in value.substring(separator + 1).codeUnits) {
    final digit = _bech32Alphabet.indexOf(String.fromCharCode(codeUnit));
    if (digit < 0) {
      throw const FormatException('Invalid Nostr profile address.');
    }
    data.add(digit);
  }
  if (_polymod([..._expandHrp(hrp), ...data]) != 1) {
    throw const FormatException('Invalid Nostr profile checksum.');
  }
  return (
    hrp: hrp,
    bytes: _convertBits(data.sublist(0, data.length - 6), 5, 8, pad: false),
  );
}

List<int> _convertBits(
  List<int> data,
  int fromBits,
  int toBits, {
  required bool pad,
}) {
  var accumulator = 0;
  var bits = 0;
  final result = <int>[];
  final maxValue = (1 << toBits) - 1;
  final maxAccumulator = (1 << (fromBits + toBits - 1)) - 1;
  for (final value in data) {
    if (value < 0 || value >> fromBits != 0) {
      throw const FormatException('Invalid Nostr profile data.');
    }
    accumulator = ((accumulator << fromBits) | value) & maxAccumulator;
    bits += fromBits;
    while (bits >= toBits) {
      bits -= toBits;
      result.add((accumulator >> bits) & maxValue);
    }
  }
  if (pad && bits > 0) {
    result.add((accumulator << (toBits - bits)) & maxValue);
  } else if (!pad &&
      (bits >= fromBits ||
          ((accumulator << (toBits - bits)) & maxValue) != 0)) {
    throw const FormatException('Invalid Nostr profile padding.');
  }
  return result;
}

List<int> _createChecksum(String hrp, List<int> data) {
  final values = [..._expandHrp(hrp), ...data, 0, 0, 0, 0, 0, 0];
  final polymod = _polymod(values) ^ 1;
  return [
    for (var index = 0; index < 6; index++) (polymod >> (5 * (5 - index))) & 31,
  ];
}

List<int> _expandHrp(String hrp) => [
  ...hrp.codeUnits.map((value) => value >> 5),
  0,
  ...hrp.codeUnits.map((value) => value & 31),
];

int _polymod(List<int> values) {
  const generators = [
    0x3b6a57b2,
    0x26508e6d,
    0x1ea119fa,
    0x3d4233dd,
    0x2a1462b3,
  ];
  var checksum = 1;
  for (final value in values) {
    final top = checksum >> 25;
    checksum = ((checksum & 0x1ffffff) << 5) ^ value;
    for (var index = 0; index < 5; index++) {
      if ((top >> index) & 1 == 1) checksum ^= generators[index];
    }
  }
  return checksum;
}

Uri? _safeRelay(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null ||
      uri.scheme.toLowerCase() != 'wss' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.hasQuery) {
    return null;
  }
  return uri.replace(scheme: 'wss');
}

String _hex(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
