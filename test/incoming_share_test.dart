import 'package:flutter_test/flutter_test.dart';
import 'package:trickle/services/incoming_share_service.dart';

void main() {
  test('shared text extracts a usable feed address without trailing prose', () {
    expect(
      feedInputFromSharedText(
        'Worth following: (https://example.test/feed.xml). Sent from Safari',
      ),
      'https://example.test/feed.xml',
    );
    expect(
      feedInputFromSharedText(
        'Profile nprofile1qqsp9z7s4s2z7s4s2z7s4s2z7s4s2z7s4s2z7s4s2z7s4s2z7s4s2z7',
      ),
      startsWith('nprofile1'),
    );
    expect(
      feedInputFromSharedText('“https://example.test/feed.xml”'),
      'https://example.test/feed.xml',
    );
    expect(
      feedInputFromSharedText(
        'Profile npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq https://example.test/profile.xml',
      ),
      'https://example.test/profile.xml',
    );
    expect(feedInputFromSharedText('   '), isNull);
  });
}
