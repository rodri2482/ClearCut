import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/source_health_store.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/playback_resolver.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/source_score_store.dart';
import 'package:watch_app/core/zmode/source_order_prefs.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';
import 'package:watch_app/core/zmode/stream_probe.dart';

const _show = ZCanonical(ZKind.anime, 'mal:100');
const _ep2 = 'zm://anime/mal:100/ep/2';

class _SweepSrc implements SourceRepository {
  _SweepSrc({
    required this.aEps,
    required this.bEps,
    this.aStreams = const [VideoSource(url: 'https://a/stream')],
    this.bStreams = const [VideoSource(url: 'https://b/stream')],
    this.hangs = const <String>{},
    this.extraMisses = 0,
  });

  final List<Episode> aEps;
  final List<Episode> bEps;
  final List<VideoSource> aStreams;
  final List<VideoSource> bStreams;

  /// Sources whose episode call never answers — a real one measured 38s.
  final Set<String> hangs;
  final int extraMisses;
  final log = <String>[];
  bool failAStreams = false;

  /// Every category this source was asked for.
  final cats = <String>[];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<({String id, String name})> get loadedSources => [
    (id: 'src-a', name: 'A'),
    for (var i = 0; i < extraMisses; i++) (id: 'miss-$i', name: 'Miss $i'),
    (id: 'src-b', name: 'B'),
  ];

  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  bool hasSource(String sourceId) => true;

  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  // Shown per row by the "Where to watch" sheet.
  @override
  String displayName(String sourceId) => sourceId;

  @override
  Future<List<MediaItem>> search(
    String q, {
    String category = 'sub',
    String? sourceId,
  }) async {
    log.add('search:$sourceId');
    if (sourceId == 'src-a') {
      return [
        MediaItem(
          id: 'a',
          title: 'FMA',
          url: 'https://a/show',
          type: ProviderType.anime,
          sourceId: 'src-a',
        ),
      ];
    }
    if (sourceId == 'src-b') {
      return [
        MediaItem(
          id: 'b',
          title: 'FMA',
          url: 'https://b/show',
          type: ProviderType.anime,
          sourceId: 'src-b',
        ),
      ];
    }
    return const [];
  }

  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async {
    log.add('episodes:$url:$sourceId');
    cats.add(category);
    if (hangs.contains(sourceId)) return Completer<List<Episode>>().future;
    if (sourceId == 'src-a') return aEps;
    if (sourceId == 'src-b') return bEps;
    return const [];
  }

  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) async {
    log.add('sources:$episodeUrl:$sourceId');
    if (sourceId == 'src-a' && failAStreams) throw StateError('expired stream');
    if (sourceId == 'src-a') return aStreams;
    if (sourceId == 'src-b') return bStreams;
    return const [];
  }
}

/// A source whose first stream lookup comes back empty (a cold CDN or a
/// transient extractor failure) but whose second one works — exactly the title
/// the viewer used to fix by pressing Retry.
class _FlakyStreamsSrc extends _SweepSrc {
  _FlakyStreamsSrc({required List<Episode> aEps, required List<Episode> bEps})
    : super(aEps: aEps, bEps: bEps);

  final Map<String, int> _calls = {};

  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) async {
    final key = sourceId ?? '';
    final n = (_calls[key] ?? 0) + 1;
    _calls[key] = n;
    log.add('sources:$episodeUrl:$sourceId');
    if (n == 1) return const [];
    return key == 'src-a'
        ? const [VideoSource(url: 'https://a/stream')]
        : const <VideoSource>[];
  }
}

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;
  late SourceHealthStore health;
  late SourceScoreStore scores;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('playback-resolver');
    Hive.init(dir.path);
    await SourceHealthStore.init();
    health = SourceHealthStore();
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    scores = await SourceScoreStore.open();
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  PlaybackResolver resolver({
    required SourceRepository sources,
    required SourceMatcher matcher,
    String? preferred,
    Duration? budget,
  }) {
    if (preferred != null) prefs.set(_show.kind, preferred);
    final r = PlaybackResolver(
      probe: TrustingStreamProbe(),
      matcher: matcher,
      sources: sources,
      store: store,
      prefs: prefs,
      health: health,
      candidates: (_) => sources.loadedSources,
      perSourceBudget: budget,
      scores: scores,
    );
    r.bindTitleLookup((_) async => (title: 'FMA', alt: null, malId: 100));
    return r;
  }

  test(
    'alternative streams are labelled and keep the active provider',
    () async {
      const episodes = [
        Episode(id: '1', title: 'Ep 1', url: 'https://episode/1'),
        Episode(id: '2', title: 'Ep 2', url: 'https://episode/2'),
      ];
      final source = _SweepSrc(aEps: episodes, bEps: episodes);
      final matcher = SourceMatcher(
        sources: source,
        store: store,
        prefs: prefs,
        candidates: (_) => source.loadedSources,
      );
      final playback = resolver(
        sources: source,
        matcher: matcher,
        preferred: 'src-a',
      );
      expect((await playback.sources(_ep2)).single.url, 'https://a/stream');
      final results = await playback
          .alternativeStreams(_ep2)
          .expand((items) => items)
          .toList();
      expect(results.single.url, 'https://b/stream');
      expect(results.single.label, 'src-b');
      expect(playback.resolvedSourceId(_ep2), 'src-a');
    },
  );

  test(
    'a source selected in the episode sheet is reused for the chosen audio cut',
    () async {
      final source = _SweepSrc(aEps: const [], bEps: const []);
      final matcher = SourceMatcher(
        sources: source,
        store: store,
        prefs: prefs,
        candidates: (_) => source.loadedSources,
      );
      final playback = resolver(sources: source, matcher: matcher);
      await playback.useProbed(
        _ep2,
        const SourceProbe(
          sourceId: 'src-b',
          name: 'B',
          episodeUrl: 'https://b/dub/2',
          match: SourceMatch(
            sourceId: 'src-b',
            showId: 'fma',
            showTitle: 'FMA',
            showUrl: 'https://b/show',
            pinned: false,
          ),
        ),
        category: 'dub',
      );
      expect(playback.resolvedSourceId(_ep2, category: 'dub'), 'src-b');
      expect(playback.resolvedSourceId(_ep2), isNull);
      expect(
        (await playback.sources(_ep2, fast: true, category: 'dub')).single.url,
        'https://b/stream',
      );
      expect(source.log, ['sources:https://b/dub/2:src-b']);
    },
  );

  test(
    'numbered gaps cannot substitute episode four for episode two',
    () async {
      const show = ZCanonical(ZKind.tv, 'tmdb:42');
      const url = 'zm://tv/tmdb:42/ep/2';
      const first = Episode(
        id: '1',
        title: 'Episode 1',
        url: 'https://episode/1',
        number: 1,
      );
      final source = _SweepSrc(
        aEps: const [
          first,
          Episode(
            id: '4',
            title: 'Episode 4',
            url: 'https://episode/4',
            number: 4,
          ),
        ],
        bEps: const [
          first,
          Episode(
            id: '2',
            title: 'Episode 2',
            url: 'https://episode/2',
            number: 2,
          ),
        ],
      );
      final matcher = SourceMatcher(
        sources: source,
        store: store,
        prefs: prefs,
        candidates: (_) => source.loadedSources,
      );
      final playback = resolver(
        sources: source,
        matcher: matcher,
        preferred: 'src-a',
      );
      for (final id in ['src-a', 'src-b']) {
        await store.save(
          show,
          SourceMatch(
            sourceId: id,
            showTitle: 'FMA',
            showId: 'show',
            showUrl: 'https://$id/show',
            pinned: false,
          ),
        );
      }
      expect(await playback.sourcesFrom(url, 'src-a'), isEmpty);
      expect((await playback.sources(url)).single.url, 'https://b/stream');
      expect(source.log, isNot(contains('sources:https://episode/4:src-a')));
    },
  );

  test(
    'TV resolver uses the exact season and episode even when rows are sparse',
    () async {
      const url = 'zm://tv/tmdb:42/ep/2';
      final source = _SweepSrc(
        aEps: const [
          Episode(
            id: 'S2E2',
            title: 'Episode Two',
            url: 'https://right/2',
            number: 2,
            season: 2,
          ),
          Episode(
            id: 'S1E4',
            title: 'Episode Four',
            url: 'https://wrong/4',
            number: 4,
            season: 1,
          ),
        ],
        bEps: const [],
      );
      final matcher = SourceMatcher(
        sources: source,
        store: store,
        prefs: prefs,
        candidates: (_) => source.loadedSources,
      );
      final playback = resolver(sources: source, matcher: matcher);
      await store.pin(
        const ZCanonical(ZKind.tv, 'tmdb:42'),
        const SourceMatch(
          sourceId: 'src-a',
          showId: 'show',
          showTitle: 'Test series',
          showUrl: 'https://a/show',
          pinned: true,
        ),
      );
      playback.bindTvEpisodeLookup((_, __) async => (season: 2, number: 2));
      await playback.sourcesFrom(url, 'src-a');
      expect(source.log, contains('sources:https://right/2:src-a'));
      expect(source.log, isNot(contains('sources:https://wrong/4:src-a')));
    },
  );

  test(
    'fast Play uses a ready stream while a higher-ranked source is stalled',
    () async {
      final source = _SweepSrc(
        aEps: const [],
        bEps: const [
          Episode(id: '1', title: 'Ep 1', url: 'https://b/1'),
          Episode(id: '2', title: 'Ep 2', url: 'https://b/2'),
        ],
        hangs: const {'src-a'},
      );
      final matcher = SourceMatcher(
        sources: source,
        store: store,
        prefs: prefs,
        candidates: (_) => source.loadedSources,
      );
      final playback = resolver(
        sources: source,
        matcher: matcher,
        budget: const Duration(seconds: 2),
      );
      final streams = await playback
          .sources(_ep2, fast: true)
          .timeout(const Duration(milliseconds: 500));
      expect(streams.single.url, 'https://b/stream');
      expect(playback.resolvedSourceId(_ep2), 'src-b');
    },
  );

  test(
    'fast Play abandons a cached source that throws and registers its replacement',
    () async {
      const episodes = [
        Episode(id: '1', title: 'Ep 1', url: 'https://episode/1'),
        Episode(id: '2', title: 'Ep 2', url: 'https://episode/2'),
      ];
      final source = _SweepSrc(aEps: episodes, bEps: episodes);
      final matcher = SourceMatcher(
        sources: source,
        store: store,
        prefs: prefs,
        candidates: (_) => source.loadedSources,
      );
      final playback = resolver(sources: source, matcher: matcher);
      expect((await playback.resolveForPlayback(_ep2)).match.sourceId, 'src-a');
      source.failAStreams = true;
      final streams = await playback.sources(_ep2, fast: true);
      expect(streams.single.url, 'https://b/stream');
      expect(playback.resolvedSourceId(_ep2), 'src-b');
    },
  );

  test(
    'automatic Play reaches sources beyond the configured manual limit',
    () async {
      final order = await SourceOrderPrefs.open();
      await order.setCap(_show.kind, 3);
      sl.registerSingleton<SourceOrderPrefs>(order);
      addTearDown(() => sl.unregister<SourceOrderPrefs>());

      final source = _SweepSrc(
        aEps: const [],
        bEps: const [
          Episode(id: '1', title: 'Ep 1', url: 'https://b/1'),
          Episode(id: '2', title: 'Ep 2', url: 'https://b/2'),
        ],
        extraMisses: 8,
        hangs: const {'src-a'},
      );
      final matcher = SourceMatcher(
        sources: source,
        store: store,
        prefs: prefs,
        candidates: (_) => source.loadedSources,
      );
      final playback = resolver(
        sources: source,
        matcher: matcher,
        budget: const Duration(seconds: 2),
      );
      final streams = await playback
          .sources(_ep2, fast: true)
          .timeout(const Duration(milliseconds: 600));
      expect(streams.single.url, 'https://b/stream');
      expect(playback.resolvedSourceId(_ep2), 'src-b');
    },
  );

  test('switching a title\'s source drops its cached winners', () async {
    // The reported bug: play an episode, change source, press play — and the
    // OLD source's stream came back until the app was restarted. The episode
    // list refreshed, so the screen looked right; only playback was stale,
    // because sources() answers from _winners before consulting the pin.
    final src = _SweepSrc(
      aEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://a/2'),
      ],
      bEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://b/2'),
      ],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final r = resolver(sources: src, matcher: matcher, preferred: 'src-a');
    matcher.bindSourceChanged(r.invalidateShow);

    // Played once on A — the winner is now cached for this episode.
    expect((await r.resolveForPlayback(_ep2)).match.sourceId, 'src-a');
    expect(r.resolvedSourceId(_ep2), 'src-a');

    // The user switches this title to B.
    await matcher.pinTitleToSource(_show, 'src-b', title: 'FMA');

    // Without the invalidation this still answered from A's cached winner.
    expect(r.resolvedSourceId(_ep2), isNull, reason: 'cached winner survived');
    final streams = await r.sources(_ep2);
    expect(streams.single.url, 'https://b/stream');
  });

  test('a resolved playback credits the source that served it', () async {
    final src = _SweepSrc(
      aEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://a/2'),
      ],
      bEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://b/2'),
      ],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final r = resolver(sources: src, matcher: matcher, preferred: 'src-a');

    expect((await r.resolveForPlayback(_ep2)).match.sourceId, 'src-a');

    expect(scores.plays('src-a'), 1);
    expect(
      scores.plays('src-b'),
      0,
      reason: 'only the source that served the stream is credited',
    );
  });

  test('a different show keeps its cached winner', () async {
    // invalidateShow is prefix-matched, so it must not empty the cache for
    // every title that happens to be resolved.
    final src = _SweepSrc(
      aEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://a/2'),
      ],
      bEps: const [],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final r = resolver(sources: src, matcher: matcher, preferred: 'src-a');
    matcher.bindSourceChanged(r.invalidateShow);

    await r.resolveForPlayback(_ep2);
    expect(r.resolvedSourceId(_ep2), 'src-a');

    r.invalidateShow(const ZCanonical(ZKind.anime, 'mal:999'));
    expect(r.resolvedSourceId(_ep2), 'src-a', reason: 'wrong show cleared');
  });

  test('tries second source when first lacks the episode', () async {
    final src = _SweepSrc(
      aEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
      ],
      bEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://b/2'),
      ],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final r = resolver(sources: src, matcher: matcher, preferred: 'src-a');
    final out = await r.resolveForPlayback(_ep2);
    expect(out.match.sourceId, 'src-b');
    expect(out.episodeUrl, 'https://b/2');
    expect(src.log, contains('sources:https://b/2:src-b'));
  });

  test('prefers pinned source over preferred', () async {
    await store.pin(
      _show,
      const SourceMatch(
        sourceId: 'src-a',
        showUrl: 'https://a/show',
        showId: 'a',
        showTitle: 'FMA',
        pinned: true,
      ),
    );
    final src = _SweepSrc(
      aEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://a/2'),
      ],
      bEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://b/2'),
      ],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    prefs.set(_show.kind, 'src-b');
    final r = resolver(sources: src, matcher: matcher);
    final out = await r.resolveForPlayback(_ep2);
    expect(out.match.sourceId, 'src-a');
  });

  test('Continue Watching prewarm asks only the remembered source', () async {
    await store.pin(
      _show,
      const SourceMatch(
        sourceId: 'src-a',
        showUrl: 'https://a/show',
        showId: 'a',
        showTitle: 'FMA',
        pinned: true,
      ),
    );
    final src = _SweepSrc(
      aEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://a/2'),
      ],
      bEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://b/2'),
      ],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final r = resolver(sources: src, matcher: matcher);

    final streams = await r.prewarmRememberedSource(_ep2);

    expect(streams, isEmpty);
    expect(src.log.where((call) => call.startsWith('sources:')), isEmpty);
    expect(src.log.where((call) => call.endsWith(':src-b')), isEmpty);
  });

  test('throws EpisodeNotAvailable when episode missing everywhere', () async {
    final src = _SweepSrc(
      aEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
      ],
      bEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
      ],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final r = resolver(sources: src, matcher: matcher);
    expect(
      () => r.resolveForPlayback('zm://anime/mal:100/ep/5'),
      throwsA(
        isA<EpisodeNotAvailable>().having(
          (e) => e.hadTitleMatch,
          'hadTitleMatch',
          isTrue,
        ),
      ),
    );
  });

  test('dedupes in-flight resolves for the same episode url', () async {
    final src = _SweepSrc(
      aEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://a/2'),
      ],
      bEps: const [],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final r = resolver(sources: src, matcher: matcher, preferred: 'src-a');
    final a = r.resolveForPlayback(_ep2);
    final b = r.resolveForPlayback(_ep2);
    expect(identical(await a, await b), isTrue);
  });

  test(
    'a source that hangs is abandoned at the budget, and the sweep goes on',
    () async {
      // The freeze this budget exists for: on a real device one provider held
      // the sweep 38 seconds and the whole tap took 100. src-a never answers.
      final src = _SweepSrc(
        aEps: const [],
        bEps: const [
          Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
          Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://b/2'),
        ],
        hangs: const {'src-a'},
      );
      final matcher = SourceMatcher(
        sources: src,
        store: store,
        prefs: prefs,
        candidates: (_) => src.loadedSources,
      );
      final r = resolver(
        sources: src,
        matcher: matcher,
        preferred: 'src-a',
        budget: const Duration(milliseconds: 60),
      );

      final out = await r.resolveForPlayback(_ep2);
      expect(out.match.sourceId, 'src-b');
      expect(out.episodeUrl, 'https://b/2');
    },
  );

  test('a source that blew the budget is skipped on the next sweep', () async {
    // Without this the very next resolve pays the same wait again — which is
    // exactly what the device log showed, the same source twice in a row.
    final src = _SweepSrc(
      aEps: const [],
      bEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://b/2'),
        Episode(id: '3', title: 'Ep 3', number: 3, url: 'https://b/3'),
      ],
      hangs: const {'src-a'},
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final r = resolver(
      sources: src,
      matcher: matcher,
      preferred: 'src-a',
      budget: const Duration(milliseconds: 60),
    );

    await r.resolveForPlayback(_ep2);
    src.log.clear();
    await r.resolveForPlayback('zm://anime/mal:100/ep/3');

    expect(
      src.log.where((l) => l.endsWith(':src-a')),
      isEmpty,
      reason: 'src-a blew the budget once; it must not be asked again',
    );
    expect(src.log, contains('sources:https://b/3:src-b'));
  });

  test(
    'invalidateWinner clears over-budget so an episode tap retries',
    () async {
      // A tap / Retry is intentional: sources that timed out must be eligible
      // again. The cooldown only protects automatic follow-on sweeps.
      final src = _SweepSrc(
        aEps: const [
          Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
          Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://a/2'),
          Episode(id: '3', title: 'Ep 3', number: 3, url: 'https://a/3'),
        ],
        // b can serve ep2 (so the first sweep finishes) but not ep3 — the retry
        // must fall through to src-a, which is only possible if the cooldown
        // was cleared.
        bEps: const [
          Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
          Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://b/2'),
        ],
        hangs: const {'src-a'},
      );
      final matcher = SourceMatcher(
        sources: src,
        store: store,
        prefs: prefs,
        candidates: (_) => src.loadedSources,
      );
      final r = resolver(
        sources: src,
        matcher: matcher,
        preferred: 'src-a',
        budget: const Duration(milliseconds: 60),
      );

      await r.resolveForPlayback(_ep2);
      src.log.clear();
      r.invalidateWinner('zm://anime/mal:100/ep/3');
      await expectLater(
        r.resolveForPlayback('zm://anime/mal:100/ep/3'),
        throwsA(isA<EpisodeNotAvailable>()),
      );

      expect(
        src.log.where((l) => l.endsWith(':src-a')),
        isNotEmpty,
        reason: 'after invalidateWinner, src-a must be tried again',
      );
    },
  );

  test('dub and sub are resolved and cached separately', () async {
    // The reported bug lives here. sub and dub are different episode lists
    // for the SAME zm:// url, so a cache keyed on the url alone hands a dub
    // request whatever sub resolved earlier — and the category never reached
    // the source at all, so every fetch came back sub regardless.
    final src = _SweepSrc(
      aEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://a/2'),
      ],
      bEps: const [],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final r = resolver(sources: src, matcher: matcher, preferred: 'src-a');

    // Play once as sub. This is what fills the winner cache.
    await r.sources(_ep2);
    expect(r.resolvedSourceId(_ep2), 'src-a');
    // Nothing is remembered for dub yet — a shared key would claim otherwise.
    expect(
      r.resolvedSourceId(_ep2, category: 'dub'),
      isNull,
      reason: 'the sub winner was returned for dub',
    );

    src.log.clear();
    src.cats.clear();

    // sources() answers from _winners BEFORE consulting anything else, so on
    // a shared key this returns the sub stream and never asks the source.
    await r.sources(_ep2, category: 'dub');
    expect(
      src.cats,
      contains('dub'),
      reason: 'dub was served from the sub cache without asking the source',
    );
    expect(r.resolvedSourceId(_ep2, category: 'dub'), 'src-a');
  });

  test('the category reaches the source', () async {
    final src = _SweepSrc(
      aEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://a/2'),
      ],
      bEps: const [],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final r = resolver(sources: src, matcher: matcher, preferred: 'src-a');
    await r.resolveForPlayback(_ep2, category: 'dub');
    // Zangetsu JS and CloudStream sources key their episode list on this and
    // quietly answer with sub when it is missing, which is why Dub never
    // played: the argument was never sent.
    expect(src.cats, contains('dub'));
  });

  test('a sweep that found nothing is remembered, not repeated', () async {
    // The catalogue lists an episode no source has (an airing show's announced
    // count). Rediscovering that cost a real episode-list fetch against every
    // candidate — and ran again the moment Home re-asked after backing out of
    // the player.
    final src = _SweepSrc(
      aEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
      ],
      bEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
      ],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final r = resolver(sources: src, matcher: matcher);

    await expectLater(
      r.resolveForPlayback(_ep2),
      throwsA(isA<EpisodeNotAvailable>()),
    );
    expect(src.log.where((l) => l.startsWith('episodes:')), isNotEmpty);

    src.log.clear();
    await expectLater(
      r.resolveForPlayback(_ep2),
      throwsA(isA<EpisodeNotAvailable>()),
    );
    expect(
      src.log,
      isEmpty,
      reason: 'the second ask must answer from memory, not 36 more fetches',
    );

    // Retry / a source switch has to get a real sweep back.
    r.invalidateWinner(_ep2);
    await expectLater(
      r.resolveForPlayback(_ep2),
      throwsA(isA<EpisodeNotAvailable>()),
    );
    expect(src.log.where((l) => l.startsWith('episodes:')), isNotEmpty);
  });

  test('probeEach is bounded by time, not by a count of sources', () async {
    // Counting sources was the wrong dial: most answer in 0-1ms from a
    // remembered miss, so a count cap spent itself on free questions and
    // stopped before the slow ones that actually matter.
    final src = _SweepSrc(
      aEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://a/2'),
      ],
      bEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://b/2'),
      ],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final r = resolver(sources: src, matcher: matcher);

    final asked = await r
        .probeEach(_ep2, wallClock: Duration.zero)
        .where((p) => !p.checking)
        .toList();
    expect(asked, isEmpty, reason: 'no time left, so nothing is asked');

    final full = await r.probeEach(_ep2).where((p) => !p.checking).toList();
    expect(full.length, 2, reason: 'with time, every candidate is asked');
    // Auto Find now also probes the links before reporting a hit, so resolving
    // streams is expected here (with a short per-source budget). The trust fake
    // stands in for a live link check in this unit test.
    expect(src.log.where((l) => l.startsWith('sources:')), isNotEmpty);
    expect(full.every((p) => p.hasEpisode), isTrue);
    expect(full.every((p) => p.playable), isTrue);

    // …and `skip` resumes past one rather than asking it again.
    final rest = await r
        .probeEach(_ep2, skip: {full.first.sourceId})
        .where((p) => !p.checking)
        .toList();
    expect(rest.map((p) => p.sourceId), isNot(contains(full.first.sourceId)));
    expect(rest, isNotEmpty);
  });

  test('cancelling probeEach stops it asking more sources', () async {
    // The Stop button, and closing the dialog: this is real work on a shared
    // isolate, so abandoning it has to actually abandon it.
    final src = _SweepSrc(
      aEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://a/2'),
      ],
      bEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://b/2'),
      ],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final r = resolver(sources: src, matcher: matcher);

    final sub = r.probeEach(_ep2).listen(null);
    await sub.cancel();
    src.log.clear();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(src.log, isEmpty, reason: 'cancelled means cancelled');
  });

  test('Play uses the source Auto Resolve found on Detail instead of '
      're-sweeping into a different source', () async {
    final src = _SweepSrc(
      aEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://a/2'),
      ],
      bEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://b/2'),
      ],
      // The auto-found source has the working link; the other one does not.
      aStreams: const [],
      bStreams: const [VideoSource(url: 'https://b/stream')],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    await store.save(
      _show,
      const SourceMatch(
        sourceId: 'src-b',
        showUrl: 'https://b/show',
        showId: 'b',
        showTitle: 'FMA',
        pinned: false,
      ),
    );
    final r = resolver(sources: src, matcher: matcher);

    final resolved = await r.resolveForPlayback(_ep2);
    expect(resolved.match.sourceId, 'src-b');
    expect(
      src.log.where((l) => l.startsWith('sources:') && l.endsWith(':src-b')),
      isNotEmpty,
    );
    expect(
      src.log.where((l) => l.startsWith('sources:') && l.endsWith(':src-a')),
      isEmpty,
      reason: 'the auto-found source must be asked before any sweep source',
    );
  });

  test('a matched source with a cold first stream lookup is retried '
      'automatically, without the viewer pressing Retry', () async {
    final src = _FlakyStreamsSrc(
      aEps: const [
        Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://a/1'),
        Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://a/2'),
      ],
      bEps: const [],
    );
    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final r = resolver(sources: src, matcher: matcher, preferred: 'src-a');

    final events = await r.resolveProgressive(_ep2).toList();
    expect(events, isNotEmpty);
    expect(events.last.done, isTrue);
    expect(events.last.streams.single.url, 'https://a/stream');
    expect(
      src.log.where((l) => l.startsWith('sources:')).length,
      greaterThanOrEqualTo(2),
      reason: 'the same source must have been asked twice',
    );
  });
}
