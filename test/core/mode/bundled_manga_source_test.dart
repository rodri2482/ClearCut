// A bundled reading source has no repo manifest and cannot borrow the
// `mihon:` prefix (that prefix routes data calls to the native Mihon bridge,
// which has no such extension). Without an explicit type exception, WEBTOON
// resolves to anime everywhere and is invisible in Manga mode.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/provider/bundled_sources.dart';
import 'package:watch_app/core/ui/source_switcher.dart';

void main() {
  test('a bundled manga source is manga in both mode resolvers', () {
    expect(
      sourceIdMatchesContentMode(webtoonSourceId, ContentMode.manga),
      isTrue,
    );
    for (final mode in [ContentMode.anime, ContentMode.novel]) {
      expect(
        sourceIdMatchesContentMode(webtoonSourceId, mode),
        isFalse,
        reason: 'a manga source must never surface in $mode',
      );
    }
    expect(sourceTypeOf(webtoonSourceId), ProviderType.manga);
  });

  test('the video bundled source keeps its streaming behaviour', () {
    expect(
      sourceIdMatchesContentMode(frameXtvSourceId, ContentMode.anime),
      isTrue,
    );
    expect(
      sourceIdMatchesContentMode(frameXtvSourceId, ContentMode.manga),
      isFalse,
    );
    // The video resolver must not promote a reading source into its JS lane.
    expect(bundledVideoSourceIds(), {frameXtvSourceId});
    expect(bundledSourceIds(), contains(webtoonSourceId));
  });
}
