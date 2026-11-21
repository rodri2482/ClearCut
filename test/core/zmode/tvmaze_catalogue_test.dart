import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/zmode/tvmaze_catalogue.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

void main() {
  const show = {
    'id': 169,
    'name': 'Breaking Bad',
    'genres': ['Drama', 'Crime'],
    'status': 'Ended',
    'premiered': '2008-01-20',
    'externals': {'imdb': 'tt0903747'},
    'image': {'original': 'https://example.com/poster.jpg'},
    'summary': '<p>A chemistry teacher.</p>',
  };

  test('TVmaze search and detail need no key and produce zm://tv/tvmaze ids',
      () async {
    final cat = TvmazeCatalogue((path) async {
      if (path.startsWith('/singlesearch/shows')) return show;
      if (path == '/shows/169') return show;
      if (path == '/shows/169/episodes') {
        return [
          {'id': 1, 'name': 'Pilot'},
          {'id': 2, 'name': "Cat's in the Bag..."},
        ];
      }
      return null;
    });

    expect(cat.supportsFilters, isFalse);
    final hits = await cat.search('breaking bad');
    expect(hits, hasLength(1));
    expect(hits.single.id, 'tvmaze:169');
    expect(hits.single.url, ZmodeIds.showUrl(
      const ZCanonical(ZKind.tv, 'tvmaze:169'),
    ));

    final d = await cat.detail(const ZCanonical(ZKind.tv, 'tvmaze:169'));
    expect(d.title, 'Breaking Bad');
    expect(d.imdbId, 'tt0903747');
    expect(d.year, '2008');
    expect(d.episodes, hasLength(2));
    expect(d.episodes.first.url, ZmodeIds.episodeUrl(
      const ZCanonical(ZKind.tv, 'tvmaze:169'),
      1,
    ));
    expect(d.episodes.last.number, 2);
  });
}
