import 'package:flutter_test/flutter_test.dart';
import 'package:cityking_ios/main.dart';

void main() {
  test('Prague Today wrapper test harness is configured', () {
    expect('Prague Today', isNotEmpty);
  });

  test('SavedListing decodes local persistence payloads', () {
    final listing = SavedListing.fromJson({
      'title': 'Jazz night',
      'url': 'https://cityking.com/prague/events/jazz#tickets',
      'savedAt': '2026-06-26T12:00:00.000',
      'startsAt': '2026-06-26T19:30:00.000',
      'imageUrl': 'https://cityking.com/static/jazz.jpg',
    });

    expect(listing, isNotNull);
    expect(listing!.id, 'https://cityking.com/prague/events/jazz');
    expect(listing.startsAt?.hour, 19);
    expect(listing.toJson()['title'], 'Jazz night');
  });
}
