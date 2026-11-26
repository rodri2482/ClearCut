// Auto Resolve had two failures stacked on top of each other, and the device
// logs proved both:
//
//  * FrameXTV is appended LAST in the sweep (deliberately — nothing may be
//    promoted above the viewer's Source Priority), and the video sweep is not
//    capped at all. On a real library that is 416 pickable sources behind one
//    JS engine, so candidate "last" is candidate "never": the search was
//    abandoned before the walk got there.
//  * When a walk was superseded, FrameXTV's own search had already returned
//    the title over HTTP — and the results were dropped with no log line at
//    all, which is why this looked like "FrameXTV has nothing" rather than
//    like a scheduler that never finishes.
//
// These tests drive `SourceMatcher.resolve` the way the player does, with the
// sweep budget shortened so the starvation is reproducible in milliseconds
// instead of thirty seconds of real network.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/provider/bundled_sources.dart'
    show frameXtvSourceId;
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/zmode/automatic_fallbacks.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/source_order_prefs.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';

const title = "The World's Strongest Witch";
const show = ZCanonical(ZKind.anime, 'mal:5114');

MediaItem _hit(String src) => MediaItem(
  id: 'wl-$src',
  title: title,
  url: 'https://$src/show',
  type: ProviderType.anime,
  sourceId: src,
);

/// Everything the matcher asks a source repository for, with per-source
/// latency so a test can make the walk slow on purpose.
class _FakeSources implements SourceRepository {
  _FakeSources({required this.hits, this.latency = const {}, List<String>? installed})
    : installed = installed ?? [...hits.keys, ...latency.keys];

  final Map<String, List<MediaItem>> hits;
  final Map<String, Duration> latency;
  final List<String> installed;
  final searched = <String>[];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  bool hasSource(String sourceId) => installed.contains(sourceId);

  @override
  List<({String id, String name})> get pickableSources =>
      [for (final id in installed) (id: id, name: id)];

  @override
  Future<List<MediaItem>> search(
    String query, {
    String category = 'sub',
    String? sourceId,
  }) async {
    searched.add(sourceId!);
    final d = latency[sourceId];
    if (d != null) await Future<void>.delayed(d);
    return hits[sourceId] ?? const [];
  }
}

class _FakeOrderPrefs implements SourceOrderPrefs {
  _FakeOrderPrefs({this.excludedIds = const {}});

  final Set<String> excludedIds;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<String> get(ZKind kind) => const [];

  @override
  Set<String> excluded(ZKind kind) => excludedIds;
}

void main() {
  late Directory dir;
  late MatchStore store;
  late ZSourcePrefs prefs;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fallback-reach');
    Hive.init(dir.path);
    store = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
  });

  tearDown(() async {
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  /// The sweep list exactly as production builds it for video: the viewer's
  /// own order, then `withAutomaticFallbacks` appending the bundled source
  /// last — honouring the same exclusions and availability checks. Building it
  /// here by hand would let the test pass against a fallback the real sweep
  /// would never have contained.
  List<({String id, String name})> sweepOf(List<String> ordered) =>
      withAutomaticFallbacks([
        for (final id in ordered) (id: id, name: id),
      ], ZKind.anime);

  void register({
    required _FakeSources sources,
    Set<String> excluded = const {},
  }) {
    sl.registerSingleton<SourceRepository>(sources);
    sl.registerSingleton<SourceOrderPrefs>(_FakeOrderPrefs(
      excludedIds: excluded,
    ));
  }

  SourceMatcher matcherFor(
    _FakeSources sources,
    List<String> ordered, {
    Duration budget = const Duration(seconds: 30),
  }) {
    final list = sweepOf(ordered);
    return SourceMatcher(
      sources: sources,
      store: store,
      prefs: prefs,
      candidates: (_) => list,
      sweepCandidates: (_) => list,
      videoSearchConcurrency: 4,
      sweepBudget: budget,
    );
  }

  // The bug as measured on a phone: the walk cannot reach the last candidate,
  // so a title the bundled source HAS is reported as one nobody has. Fails
  // against a matcher that only discovers the fallback by walking to it.
  test('the appended fallback is reached even when the walk cannot get there',
      () async {
    // 60 sources at 5ms each, concurrency 4, budget spent after ~30ms: only a
    // handful can possibly be asked.
    final ordered = [for (var i = 0; i < 60; i++) 'p$i'];
    final sources = _FakeSources(
      hits: {frameXtvSourceId: [_hit(frameXtvSourceId)]},
      latency: {for (final id in ordered) id: const Duration(milliseconds: 5)},
      installed: [...ordered, frameXtvSourceId],
    );
    register(sources: sources);

    final match = await matcherFor(
      sources,
      ordered,
      budget: const Duration(milliseconds: 30),
    ).resolve(show, title: title);

    expect(match?.sourceId, frameXtvSourceId);
    expect(sources.searched, contains(frameXtvSourceId),
        reason: 'asked from the start, not at the end of a doomed walk');
    expect(sources.searched.where((id) => id != frameXtvSourceId).length,
        lessThan(ordered.length),
        reason: 'the budget really did cut the walk short');
  });

  // The other half of the promise: asking early must not mean ACCEPTING early.
  // A source the viewer put above the fallback still wins even when the
  // fallback had its answer first.
  test('asking the fallback first never lets it outrank the viewer\'s order',
      () async {
    final sources = _FakeSources(
      hits: {
        'p1': [_hit('p1')],
        frameXtvSourceId: [_hit(frameXtvSourceId)],
      },
      latency: {'p1': const Duration(milliseconds: 40)},
      installed: ['p1', 'p2', frameXtvSourceId],
    );
    register(sources: sources);

    final match = await matcherFor(
      sources,
      ['p1', 'p2'],
      budget: const Duration(seconds: 5),
    ).resolve(show, title: title);

    expect(match?.sourceId, 'p1');
    expect(sources.searched, contains(frameXtvSourceId),
        reason: 'the fallback was asked in parallel...');
    expect(match?.showUrl, 'https://p1/show');
  });

  // A fallback that has nothing must not become a fake answer: the sweep still
  // reports a genuine miss.
  test('nothing is invented when the fallback misses too', () async {
    final ordered = [for (var i = 0; i < 20; i++) 'p$i'];
    final sources = _FakeSources(
      hits: const {},
      latency: {for (final id in ordered) id: const Duration(milliseconds: 5)},
      installed: [...ordered, frameXtvSourceId],
    );
    register(sources: sources);

    final match = await matcherFor(
      sources,
      ordered,
      budget: const Duration(milliseconds: 30),
    ).resolve(show, title: title);

    expect(match, isNull);
  });

  // The viewer leaving is not a miss to paper over. Cancelling must still mean
  // "no answer", even with a fallback sitting ready.
  test('a viewer who left does not get handed the fallback', () async {
    final ordered = [for (var i = 0; i < 20; i++) 'p$i'];
    final sources = _FakeSources(
      hits: {frameXtvSourceId: [_hit(frameXtvSourceId)]},
      // 20 sources at 50ms, four at a time: ~250ms of walking, so the flip
      // below lands in the middle of it rather than after it.
      latency: {for (final id in ordered) id: const Duration(milliseconds: 50)},
      installed: [...ordered, frameXtvSourceId],
    );
    register(sources: sources);

    var gone = false;
    // Long enough that flipping `gone` lands mid-walk for a reason, short
    // enough to stay deterministic: 20 sources at 50ms, four at a time.
    final pending = matcherFor(
      sources,
      ordered,
      budget: const Duration(seconds: 5),
    ).resolve(show, title: title, abandoned: () => gone);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    gone = true;

    final match = await pending;
    expect(match, isNull,
        reason: 'abandoned means the caller is gone, not that FrameXTV wins');
    expect(sources.searched, contains(frameXtvSourceId),
        reason: 'the parallel ask is deliberately not abandoned, so the '
            'answer is simply not used');
  });

  // Guarding the guards: an exclusion the viewer made must remove the fallback
  // from the parallel ask too, or "never force it above my order" would become
  // "it is always searched whether you like it or not".
  test('a fallback the viewer excluded is not asked at all', () async {
    final ordered = [for (var i = 0; i < 20; i++) 'p$i'];
    final sources = _FakeSources(
      hits: {frameXtvSourceId: [_hit(frameXtvSourceId)]},
      installed: [...ordered, frameXtvSourceId],
    );
    register(sources: sources, excluded: {frameXtvSourceId});

    final match = await matcherFor(
      sources,
      ordered,
      budget: const Duration(milliseconds: 30),
    ).resolve(show, title: title);

    expect(sources.searched, isNot(contains(frameXtvSourceId)));
    expect(match, isNull);
  });
}
