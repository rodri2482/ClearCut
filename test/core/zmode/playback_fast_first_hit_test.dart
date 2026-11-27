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
import 'package:watch_app/core/zmode/source_order_prefs.dart';
import 'package:watch_app/core/zmode/stream_probe.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

const _show = ZCanonical(ZKind.anime, 'mal:100');
const _ep2 = 'zm://anime/mal:100/ep/2';

class _AllSources implements SourceOrderPrefs {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<String> get(ZKind kind) => const [];

  @override
  int cap(ZKind kind) => SourceOrderPrefs.allSourcesCap;
}

/// src-a is the higher-priority source but its episode list never answers.
/// src-b has a working link immediately. Play must start on B without waiting
/// for A to time out — the bug the "All" setting exposed on a real device.
class _SlowSourceRepo implements SourceRepository {
  _SlowSourceRepo(this.gate);

  final Future<List<Episode>> gate;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<({String id, String name})> get loadedSources => [
    (id: 'src-a', name: 'A'),
    (id: 'src-b', name: 'B'),
  ];

  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  bool hasSource(String sourceId) => true;

  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  String displayName(String sourceId) => sourceId;

  @override
  Future<List<MediaItem>> search(
    String q, {
    String category = 'sub',
    String? sourceId,
  }) async {
    return [
      MediaItem(
        id: sourceId ?? 'x',
        title: 'FMA',
        url: 'https://${sourceId ?? 'x'}/show',
        type: ProviderType.anime,
        sourceId: sourceId ?? 'x',
      ),
    ];
  }

  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async {
    if (sourceId == 'src-a') return gate;
    return [
      const Episode(id: '1', title: 'Ep 1', number: 1, url: 'https://b/1'),
      const Episode(id: '2', title: 'Ep 2', number: 2, url: 'https://b/2'),
    ];
  }

  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) async {
    return [VideoSource(url: 'https://${sourceId ?? 'x'}/stream')];
  }
}

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fast-first-hit');
    Hive.init(dir.path);
    await SourceHealthStore.init();
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
  });

  tearDown(() async {
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('with All enabled, the first working source plays before a slow '
      'higher-priority source times out', () async {
    final gate = Completer<List<Episode>>();
    final src = _SlowSourceRepo(gate.future);
    sl.registerSingleton<SourceOrderPrefs>(_AllSources());

    final matcher = SourceMatcher(
      sources: src,
      store: store,
      prefs: prefs,
      candidates: (_) => src.loadedSources,
    );
    final resolver = PlaybackResolver(
      probe: TrustingStreamProbe(),
      matcher: matcher,
      sources: src,
      store: store,
      prefs: prefs,
      health: SourceHealthStore(),
      candidates: (_) => src.loadedSources,
      perSourceBudget: const Duration(seconds: 5),
    );
    resolver.bindTitleLookup(
      (_) async => (title: 'FMA', alt: null, malId: 100),
    );

    final events = <ProgressiveResolve>[];
    final sub = resolver.resolveProgressive(_ep2).listen(events.add);
    try {
      // Long enough for src-b to resolve even when the suite runs several
      // isolates at once, far shorter than src-a's 5s budget. 150ms was
      // enough on an idle machine and flaked under load — this is a timing
      // guard for the test, not a longer allowance for the product.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(
        events,
        isNotEmpty,
        reason:
            'Play must not wait for the slow '
            'source to time out',
      );
      expect(events.first.match.sourceId, 'src-b');
    } finally {
      if (!gate.isCompleted) gate.complete(const []);
      await sub.cancel();
    }
  });
}
