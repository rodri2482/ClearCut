import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/metadata/age_rating_service.dart';

void main() {
  test('Jikan ratings become short, stable badges', () {
    expect(AgeRatingService.normalize('R - 17+ (violence & profanity)'), 'R');
    expect(AgeRatingService.normalize('PG-13 - Teens 13 or older'), 'PG-13');
    expect(AgeRatingService.normalize('R+ - Mild Nudity'), 'R+');
    expect(AgeRatingService.normalize('G - All Ages'), 'G');
    expect(AgeRatingService.normalize(''), isNull);
  });
}
