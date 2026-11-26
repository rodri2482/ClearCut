import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/episode.dart';
import '../models/video_source.dart';
import '../playback/source_health_store.dart';
import '../playback/stream_enrichment.dart';
import '../di/injector.dart';
import '../provider/bundled_sources.dart';
import '../provider/cf_solve_needed.dart';
import '../provider/cloudstream_provider.dart';
import '../provider/js_engine.dart';
import '../provider/provider_manager.dart';
import '../repository/source_repository.dart';
import 'automatic_fallbacks.dart';
import 'episode_anchor_store.dart';
import 'match_store.dart';
import 'nsfw_guard.dart';
import 'source_matcher.dart';
import 'source_order_prefs.dart';
import 'source_score_store.dart';
import 'stream_probe.dart';
import 'zmode_ids.dart';
import 'zmode_source_prefs.dart';

/// Why one source did not end the sweep. Recorded for every candidate so a
/// failure can say what actually happened instead of "no source has this".
///
/// The distinction that matters to a viewer is whether a source ANSWERED.
/// [timedOut], [cloudflare], [unhealthy] and [cooldown] mean it never really
/// did — and telling someone an episode does not exist because four sources
/// were slow is simply untrue. [streamsDead] is a source that answered with
/// links that turned out not to play. The rest are real answers.
enum SweepReason {
  timedOut,
  cloudflare,
  unhealthy,
  cooldown,
  failed,
  streamsDead,
  noTitleMatch,
  episodeMissing,
  noStreams,
}

/// One candidate's verdict in a sweep.
typedef SweepOutcome = ({String sourceId, String name, SweepReason reason});

/// A short, true sentence about why a sweep found nothing, or null when the
/// outcomes say nothing the caller doesn't already know.
///
/// Only speaks up for the reasons that leave the question open — a source that
/// was never really asked, or one whose links turned out to be dead. If every
/// source genuinely answered and genuinely lacked the episode, the caller's
/// own message is already the right one.
String? sweepFailureDetail(List<SweepOutcome> outcomes) {
  String names(SweepReason r) {
    final n = outcomes.where((o) => o.reason == r).map((o) => o.name).toList();
    if (n.isEmpty) return '';
    if (n.length == 1) return n.first;
    if (n.length == 2) return '${n[0]} and ${n[1]}';
    return '${n.first} and ${n.length - 1} others';
  }

  final slow = names(SweepReason.timedOut);
  final deadLinks = names(SweepReason.streamsDead);
  final cf = names(SweepReason.cloudflare);
  final cooling = names(SweepReason.cooldown);
  final unwell = names(SweepReason.unhealthy);

  if (slow.isNotEmpty) return '$slow took too long to answer';
  if (deadLinks.isNotEmpty) return '$deadLinks gave links that would not open';
  if (cf.isNotEmpty) return '$cf needs a Cloudflare check';
  if (cooling.isNotEmpty) return '$cooling was skipped after a recent timeout';
  if (unwell.isNotEmpty) return '$unwell is not responding';
  return null;
}

/// Thrown when no installed source can play this metadata episode — either
/// because no source has the title, the episode is missing everywhere, or
/// every source that has it returned no streams.
class EpisodeNotAvailable implements Exception {
  const EpisodeNotAvailable(
    this.canonical,
    this.episode, {
    this.hadTitleMatch = false,
    this.outcomes = const [],
    this.selectedSourceName,
  });
  final ZCanonical canonical;
  final int episode;

  /// True when at least one source matched the show but none could serve this
  /// episode (missing or empty streams).
  final bool hadTitleMatch;

  /// What each candidate actually did. See [sweepFailureDetail].
  final List<SweepOutcome> outcomes;

  /// Set when a user-selected source alone was checked.
  final String? selectedSourceName;

  @override
  String toString() => hadTitleMatch
      ? 'Episode $episode is not available on any source for $canonical'
      : 'No installed source has $canonical';
}

/// Thrown when a sweep is abandoned because the viewer left playback.
///
/// Its own type on purpose. It is NOT a verdict about the episode: most of the
/// candidates were never asked, so it must not be recorded as a miss and must
/// not be shown to anyone — by the time it is thrown the screen that asked for
/// it is already gone.
class PlaybackAborted implements Exception {
  const PlaybackAborted();

  @override
  String toString() => 'Playback sweep abandoned — the viewer left';
}

/// Result of a successful play-time resolve for `zm://…/ep/n`.
class ResolvedPlayback {
  const ResolvedPlayback({
    required this.match,
    required this.episodeUrl,
    required this.streams,
    required this.show,
    required this.episode,
  });

  final SourceMatch match;
  final String episodeUrl;
  final List<VideoSource> streams;
  final ZCanonical show;
  final int episode;
}

/// One emission of [PlaybackResolver.resolveProgressive]: the winner so far
/// plus the streams known to date, in final-list order. `done == true` ends
/// the stream; no further events follow a done event.
class ProgressiveResolve {
  const ProgressiveResolve({
    required this.match,
    required this.episodeUrl,
    required this.streams,
    required this.done,
  });

  final SourceMatch match;
  final String episodeUrl;
  final List<VideoSource> streams;
  final bool done;
}

/// How far a playback sweep has got, for a "Checking N of M sources…" line.
///
/// [total] is the number of candidates that will actually be asked — sources
/// skipped up front for being dead, Cloudflare-blocked, unhealthy or on
/// cooldown are not counted, because "of 32" when twelve are never asked is
/// not progress, it is a lie.
class SweepProgress {
  const SweepProgress({required this.checked, required this.total});

  /// Sources handed to a candidate so far, including the ones in flight.
  final int checked;
  final int total;
}

/// Sweeps installed video sources at play time until one can serve streams for
/// a metadata episode. Winner is cached for [polledSources] and next-episode
/// prefetch on the same session.
class PlaybackResolver {
  PlaybackResolver({
    required SourceMatcher matcher,
    required SourceRepository sources,
    required MatchStore store,
    required ZSourcePrefs prefs,
    required SourceHealthStore health,
    required List<({String id, String name})> Function(ZKind) candidates,

    /// Overridable so tests don't have to wait [defaultPerSourceBudget] out.
    Duration? perSourceBudget,

    /// Likewise for [chosenSourceBudget].
    Duration? chosenBudget,

    /// Likewise for [relaxedPerSourceBudget].
    Duration? relaxedBudget,

    /// Counts a play against the source that served it. Optional — see
    /// [_scores].
    SourceScoreStore? scores,

    /// Checks stream links before a source is accepted. Tests pass a fake.
    StreamProbe? probe,

    /// Remembers the winning source and links per episode across restarts.
    /// Optional, like [scores]: tests build this resolver without one.
    EpisodeAnchorStore? anchors,
  }) : _probe = probe ?? StreamProbe(),
       _budget = perSourceBudget ?? defaultPerSourceBudget,
       _chosenBudget = chosenBudget ?? chosenSourceBudget,
       _relaxedBudget =
           relaxedBudget ?? perSourceBudget ?? relaxedPerSourceBudget,
       _matcher = matcher,
       _sources = sources,
       _store = store,
       _prefs = prefs,
       _health = health,
       _candidates = candidates,
       _scores = scores,
       _anchors = anchors;

  final StreamProbe _probe;
  final SourceMatcher _matcher;
  final SourceRepository _sources;
  final MatchStore _store;
  final ZSourcePrefs _prefs;
  final SourceHealthStore _health;
  final List<({String id, String name})> Function(ZKind) _candidates;

  /// Counts a play against the source that served it, so Auto Resolve can rank
  /// on what has actually worked. Optional: every existing test builds this
  /// resolver without one, and a missing store simply means nothing is counted.
  final SourceScoreStore? _scores;

  /// Disk-backed memory of what last played each episode. See
  /// [EpisodeAnchorStore]. `null` in tests and anywhere DI is absent.
  final EpisodeAnchorStore? _anchors;
  late Future<({String title, String? alt, int? malId})> Function(ZCanonical c)
  _titleLookup;

  /// Wired by [MetadataRepository] after construction to break the cycle.
  void bindTitleLookup(
    Future<({String title, String? alt, int? malId})> Function(ZCanonical c) fn,
  ) {
    _titleLookup = fn;
  }

  /// Alternate titles (English theatrical name, native title, synonyms) from
  /// the catalogue. Optional: tests and TV shells may not wire it.
  Future<List<String>> Function(ZCanonical c)? _aliasLookup;

  void bindAliasLookup(Future<List<String>> Function(ZCanonical c) fn) =>
      _aliasLookup = fn;

  Future<({int season, int number})?> Function(ZCanonical, int)?
  _tvEpisodeLookup;

  void bindTvEpisodeLookup(
    Future<({int season, int number})?> Function(ZCanonical, int) lookup,
  ) => _tvEpisodeLookup = lookup;

  Future<List<String>> _aliasesFor(ZCanonical c) async {
    final fn = _aliasLookup;
    if (fn == null) return const <String>[];
    try {
      return await fn(c);
    } catch (_) {
      return const <String>[];
    }
  }

  /// Cached winning source episode url per `zm://…/ep/n` for poll/prefetch.
  ///
  /// Keyed by url AND category: sub and dub are different episode lists for
  /// the same metadata url, so a single key would hand a dub request whatever
  /// sub resolved earlier — the same stale-cache shape that made a switched
  /// source keep playing the old one.
  ///
  /// The winning match is kept too, so [resolveProgressive] can replay it
  /// without re-sweeping.
  final Map<String, ({String episodeUrl, String sourceId, SourceMatch match})>
  _winners = {};

  static String _winKey(String zmEpisodeUrl, String category) =>
      '$zmEpisodeUrl|$category';

  /// Playback opens on the FIRST link that passes. Give its neighbours only a
  /// moment to join the initial list — the player's poll path and progressive
  /// events bring the rest in while the episode is already playing. Downloads
  /// keep StreamProbe's full window: a file needs every mirror up front.
  static const Duration fastFirstHitGrace = Duration(milliseconds: 350);

  /// How long an anchor replay may wait for its source to hand back fresh
  /// links, but only after the saved links have all failed.
  static const Duration anchorResolveBudget = Duration(seconds: 4);

  /// How long the saved (or freshly re-resolved) links get to answer. Short on
  /// purpose: this is a replay, so a slow host must not cost more than a normal
  /// sweep would. Anything that has not answered like video by then is
  /// dropped — the sweep takes over rather than gambling on an unchecked link.
  static const Duration anchorProbeBudget = Duration(milliseconds: 2500);

  /// In-flight resolves keyed by metadata episode url.
  final Map<String, Future<ResolvedPlayback>> _inFlight = {};

  /// How long one candidate may hold the sweep before we move on. Measured on
  /// a real device: a JS provider with its own 15s internal timeout took 15.8s
  /// and then 38s, an Aniyomi source sat 12.5s on a Cloudflare page, another
  /// 7.3s before an IOException — four sources turned a single Play tap into
  /// 100 seconds of frozen UI, because JS providers ran on the UI isolate and
  /// a second spent in one was a second of frames not drawn.
  ///
  /// That last part is no longer true where [JsEngine.runsOffUiIsolate] — the
  /// wait is now just a wait — so this 8s is now only the fallback for where
  /// it IS still true (Apple, which runs JavaScriptCore in-process). There,
  /// 8s of patience would still be 8s of frozen frames.
  ///
  /// Everywhere else, see [relaxedPerSourceBudget].
  static const Duration defaultPerSourceBudget = Duration(seconds: 8);
  final Duration _budget;

  /// What an un-chosen source gets where the wait costs no frames.
  ///
  /// 8s was never the source's fault. It bounded UI freeze, and once provider
  /// JS moved off the UI isolate it stopped bounding anything except total
  /// sweep length — while still being short enough to throw away a source that
  /// simply answers slowly. That produced the reported bug directly: a source
  /// needing ~12s was cut off by Auto Resolve and reported as having nothing,
  /// then played perfectly the moment the viewer picked it by hand, because a
  /// hand-picked source gets [chosenSourceBudget] instead.
  ///
  /// Same patience for both now, so "Auto Resolve says no, picking it says
  /// yes" cannot happen. Total sweep length is bounded by the source cap and
  /// the waves instead — by asking fewer sources and asking them together,
  /// rather than by giving up on each one early.
  /// How many candidates a sweep asks at once.
  ///
  /// Three, not ten: the sweep stops at the first source that answers, so a
  /// bigger wave spends requests on titles that were about to work anyway.
  /// Three roughly thirds the wait when nothing has the episode while asking
  /// at most two sources more than strictly needed when something does.
  ///
  /// Caveat worth knowing: the bundled JS providers share one QuickJS engine
  /// (`_serialized` in provider_manager.dart), so several of THOSE in one wave
  /// still run one after another. CloudStream, Aniyomi and Mihon sources are
  /// native and genuinely overlap, and they are the bulk of a real library.
  static const int sweepWaveSize = 3;

  static const Duration relaxedPerSourceBudget = Duration(seconds: 20);
  final Duration _relaxedBudget;

  /// What a source the viewer PICKED gets instead — pinned for this title, or
  /// set as the default for the kind. Both are an explicit "use this one", and
  /// cutting that off at 8s is what produced "nothing plays" on a source the
  /// viewer knew was fine, just slow.
  ///
  /// Only applied where provider JS runs off the UI isolate
  /// ([JsEngine.runsOffUiIsolate]). The 8s above was never about the source's
  /// patience — it bounded how long the UI could be frozen. Where that is
  /// still true, a 25s wait would still be 25 frozen seconds, so the tight
  /// budget stands.
  static const Duration chosenSourceBudget = Duration(seconds: 25);
  final Duration _chosenBudget;

  /// The budget for [sourceId] given the sources this viewer chose.
  ///
  /// Where the wait is free (JS off the UI isolate), a chosen source still gets
  /// the most patience, and everything else gets [relaxedPerSourceBudget]
  /// rather than the old 8s. Where it is not free, the tight budget applies to
  /// everything, chosen or not — exactly as before.
  Duration _budgetFor(String sourceId, Set<String> chosen) {
    if (!JsEngine.runsOffUiIsolate) return _budget;
    return chosen.contains(sourceId) ? _chosenBudget : _relaxedBudget;
  }

  /// The sources the viewer explicitly picked for [c] — the per-title pin and
  /// the kind-wide default. NOT `lastPlayed`: that is the app's own memory of
  /// a successful Auto Resolve, not a choice anybody made.
  Set<String> _chosenSources(ZCanonical c) => {
    ?_matcher.pinnedSource(c),
    ?_prefs.get(c.kind),
  };

  /// Tighter than [_budget], because the two are asking different questions.
  /// Playback is worth waiting 8s for — it is the thing you asked for. A
  /// browse list is not: a source that cannot say whether it lists an episode
  /// within 5 seconds is not the one you are about to pick.
  static const Duration probeBudget = Duration(seconds: 5);

  /// Sources that blew [perSourceBudget], and when. Without this the very next
  /// automatic sweep (next episode, probe, Home re-ask) pays the same 38
  /// seconds again — which is exactly what the device log showed, twice in a
  /// row for the same source.
  ///
  /// Cleared by [invalidateWinner] / [invalidateShow] when the viewer
  /// explicitly asks to play (episode tap, Retry). The cooldown is only for
  /// background / follow-on work — a tap means "try again".
  ///
  /// Deliberately NOT [SourceHealthStore]: a timeout there is recorded as
  /// "alive but slow" on purpose, so a slow source keeps appearing in search
  /// results (see its `record`). This is a playback-only, session-only memory
  /// with its own short cooldown, so nothing about search changes.
  final Map<String, DateTime> _overBudget = {};

  /// A source that blew one probe budget used to be shelved for TEN MINUTES,
  /// which on a large library read as "the app never asks this source again".
  /// Ninety seconds still protects the runtime from a genuinely dead provider
  /// while letting a source that was merely slow come back on the next search.
  static const Duration overBudgetCooldown = Duration(seconds: 90);

  /// Sources whose links were handed over and then would not play, per
  /// `zm://…|category`. A source can answer a sweep perfectly and still be
  /// useless: a dead CDN link resolves in two seconds and fails in the player.
  /// Without this the very next resolve hands back the same dead link, so the
  /// player had nowhere to go and said "every source failed" having asked
  /// exactly one.
  ///
  /// Episode-scoped and session-only. Cleared by [invalidateWinner], so an
  /// episode tap or Retry gives every source another chance.
  final Map<String, Set<String>> _unplayable = {};

  /// Records that [sourceId]'s links did not play for this episode, and drops
  /// it as the cached winner so the next resolve sweeps past it.
  ///
  /// Deliberately NOT [invalidateWinner]: that clears the very memory this is
  /// trying to write, and the next sweep would pick the same dead source.
  void markSourceUnplayable(
    String zmEpisodeUrl,
    String sourceId, {
    String category = 'sub',
  }) {
    final key = _winKey(zmEpisodeUrl, category);
    (_unplayable[key] ??= <String>{}).add(sourceId);
    _winners.remove(key);
    _noSource.remove(key);
    // The saved anchor names this source for this episode. Keep it and the
    // next restart hands the same dead link back before the player can fail
    // over, so forget it with the winner.
    unawaited(_anchors?.remove(zmEpisodeUrl, category) ?? Future<void>.value());
    debugPrint(
      '[playback] markSourceUnplayable · $sourceId for $zmEpisodeUrl '
      '($category) — ${_unplayable[key]!.length} now excluded',
    );
  }

  /// How many sources have been tried and found unplayable for this episode.
  /// The player says so when it finally gives up.
  int unplayableCount(String zmEpisodeUrl, {String category = 'sub'}) =>
      _unplayable[_winKey(zmEpisodeUrl, category)]?.length ?? 0;

  /// Bumped by [abortSweeps]. A sweep captures this before its loop and stops
  /// as soon as it no longer matches.
  int _sweepGen = 0;

  /// Stop the playback sweeps that are running right now, at their next
  /// candidate. Called when the viewer leaves the player.
  ///
  /// A sweep walks every installed source at up to [defaultPerSourceBudget]
  /// each, and nothing used to end it early. `.timeout` only stops WAITING:
  /// the JS call underneath keeps the single provider queue — and with it the
  /// UI isolate — busy until its own 15s limit. So backing out while the sweep
  /// was still going left every remaining candidate queueing up behind a
  /// screen nobody could touch, which is what "the app froze" was.
  ///
  /// The candidate already in flight cannot be called back; it finishes either
  /// way. This stops the ones after it, which is where the time went.
  ///
  /// Playback sweeps only. A filtered sweep (downloading) is nobody's
  /// foreground wait — closing the player must not cancel a download.
  void abortSweeps() {
    _sweepGen++;
    // Moving the generation only stops the NEXT candidate — the loop reads it
    // between candidates. The one already in flight was still waited out, up
    // to its whole budget, and at the 25s a chosen source gets that reads as a
    // frozen app. Waking the sweep is what makes leaving immediate.
    if (!_abortSignal.isCompleted) _abortSignal.complete();
    // Fresh signal, so a sweep started after this one isn't born aborted.
    _abortSignal = Completer<void>();
    // The native hunt behind the in-flight candidate is uncancellable from
    // here by waiting — tell it to stop so dead servers stop holding a pool
    // thread to their cap after the screen is gone.
    unawaited(CloudStreamProvider.cancelInFlightLinks());
  }

  /// Completed by [abortSweeps] to wake a sweep blocked on a candidate.
  /// Rotated there, so each abort only wakes the sweeps that were running.
  Completer<void> _abortSignal = Completer<void>();

  /// Sweeps that ended with nothing able to serve the episode, and when.
  ///
  /// The catalogue routinely lists more episodes than any source has — an
  /// airing show's announced count, a season pack a source hasn't finished —
  /// so the LAST episode of a title is often one nobody can play. Rediscovering
  /// that cost a real episode-list fetch against EVERY candidate, ~25s of
  /// frozen UI, and it ran again the moment Home re-asked after you backed out
  /// of the player. The answer doesn't change minute to minute; remember it.
  ///
  /// Short-lived and cleared by [invalidateWinner], so installing a source,
  /// solving a Cloudflare challenge or hitting Retry all get a fresh sweep.
  final Map<String, ({DateTime at, bool hadTitleMatch})> _noSource = {};
  static const Duration noSourceCooldown = Duration(minutes: 5);

  bool _recentlyOverBudget(String id) {
    final at = _overBudget[id];
    if (at == null) return false;
    if (DateTime.now().difference(at) < overBudgetCooldown) return true;
    _overBudget.remove(id);
    return false;
  }

  /// Resolves [zmEpisodeUrl] to playable streams, trying sources in priority
  /// order until one succeeds.
  Future<ResolvedPlayback> resolveForPlayback(
    String zmEpisodeUrl, {
    bool fast = false,
    String category = 'sub',
    bool Function(List<VideoSource> streams)? accept,
  }) {
    // A filtered sweep asks a narrower question; it must neither be answered
    // by, nor become, the shared in-flight future.
    // In-flight dedupe is per category too — a dub request must not be
    // answered by a sub resolve already running for the same url.
    final flightKey = _winKey(zmEpisodeUrl, category);
    if (accept == null) {
      final running = _inFlight[flightKey];
      if (running != null) return running;
    }
    final miss = accept == null ? _noSource[flightKey] : null;
    if (miss != null) {
      if (DateTime.now().difference(miss.at) < noSourceCooldown) {
        debugPrint(
          '[playback] resolveForPlayback · $zmEpisodeUrl → no source '
          '(remembered, skipping the sweep)',
        );
        final p = ZmodeIds.parseEpisode(zmEpisodeUrl);
        return Future.error(
          p == null || !miss.hadTitleMatch
              ? NoSourceMatch(p?.show ?? const ZCanonical(ZKind.anime, ''))
              : EpisodeNotAvailable(p.show, p.episode, hadTitleMatch: true),
        );
      }
      _noSource.remove(flightKey);
    }
    if (accept != null) {
      return _resolve(
        zmEpisodeUrl,
        fast: fast,
        category: category,
        accept: accept,
      );
    }
    final f = _resolve(zmEpisodeUrl, fast: fast, category: category)
        .whenComplete(() {
          _inFlight.remove(flightKey);
        });
    _inFlight[flightKey] = f;
    return f;
  }

  /// Progressive twin of [resolveForPlayback]: yields the first genuine hit
  /// without awaiting the rest of the sweep, then keeps yielding late
  /// arrivals until every wave settles or the viewer leaves.
  ///
  /// With Auto Resolve active, uses the same budgets, skip memory
  /// ([_overBudget]) and abort machinery as [_resolve]. An explicitly selected
  /// source is resolved alone; its later mirrors are collected by polling.
  /// The last successful source is also tried alone; failure starts the sweep.
  /// Download callers must keep using [resolveForPlayback]: a file needs every
  /// mirror upfront.
  ///
  /// Ordering is candidate order, exactly as [_resolve] reads its waves back:
  /// a wave's candidates are asked at once, but a hit is yielded only once
  /// every higher-priority candidate in its wave has answered. The pinned
  /// source is asked before its wave-mates are even started, so a fast
  /// non-pinned hit can never slip out ahead of a slow pinned miss — and a
  /// pinned miss means they are never asked at all.
  ///
  /// When a winner is already cached, the first event carries its streams
  /// immediately (same short-circuit as [sources]) and the stream ends — the
  /// poll path still collects the rest, exactly as on a replay today.
  Stream<ProgressiveResolve> resolveProgressive(
    String zmEpisodeUrl, {
    String category = 'sub',
    bool stopAfterFirstWave = false,

    /// Reports "which source of how many" as candidates are asked, so the
    /// player can say "Checking 3 of 8 sources…" instead of a bare spinner.
    void Function(SweepProgress progress)? onProgress,
  }) async* {
    // Read FIRST, before any await — same reason as [_resolve]: a generation
    // taken after one reads whatever an abort already set, so the sweep it
    // was meant to stop never sees a change.
    final gen = _sweepGen;
    // Derived ONCE per sweep, not per candidate — same reason as [_resolve].
    final abortFuture = _abortSignal.future.then<_Attempt?>((_) => null);
    final p = ZmodeIds.parseEpisode(zmEpisodeUrl);
    if (p == null) {
      throw ArgumentError('not a metadata episode url: $zmEpisodeUrl');
    }
    // A listener that throws must never take the sweep down with it.
    void report(int checked, int total) {
      final cb = onProgress;
      if (cb == null) return;
      try {
        cb(SweepProgress(checked: checked, total: total));
      } catch (_) {}
    }

    // A sweep that found nothing is remembered by the full path; a replay
    // through here answers from that memory instead of paying the sweep again.
    final flightKey = _winKey(zmEpisodeUrl, category);
    final miss = _noSource[flightKey];
    if (miss != null) {
      if (DateTime.now().difference(miss.at) < noSourceCooldown) {
        if (!miss.hadTitleMatch) throw NoSourceMatch(p.show);
        throw EpisodeNotAvailable(p.show, p.episode, hadTitleMatch: true);
      }
      _noSource.remove(flightKey);
    }
    final selectedSource = _matcher.sourceForTitle(p.show);
    final hit = _winners[flightKey];
    if (hit != null &&
        (selectedSource == hit.sourceId ||
            (selectedSource == null && !isAutoResolveBlocked(hit.sourceId)))) {
      final streams = await Future.any<List<VideoSource>>([
        (() {
          final saved = _anchors?.get(zmEpisodeUrl, category);
          return saved != null && saved.sourceId == hit.sourceId
              ? _replayAnchor(saved)
              : _verifiedWinnerLinks(hit.episodeUrl, hit.sourceId);
        })(),
        abortFuture.then<List<VideoSource>>(
          (_) => throw const PlaybackAborted(),
        ),
      ]);
      if (gen != _sweepGen) throw const PlaybackAborted();
      if (streams.isNotEmpty) {
        yield ProgressiveResolve(
          match: hit.match,
          episodeUrl: hit.episodeUrl,
          streams: streams,
          done: true,
        );
        return;
      }
      markSourceUnplayable(zmEpisodeUrl, hit.sourceId, category: category);
    }
    // Persisted anchor: the last source that worked for this episode, from an
    // earlier run. The in-memory winner died with the process, but this did
    // not — so the first Play after a restart opens on the same source
    // instead of paying the whole title-match/episode-list sweep again.
    //
    // Fresh links first (a CDN token saved an hour ago is likely dead), then
    // the saved ones. Both are bounded, and an anchor that serves nothing is
    // forgotten rather than replayed forever.
    final anchor = _anchors?.get(zmEpisodeUrl, category);
    if (anchor != null &&
        !(_unplayable[flightKey]?.contains(anchor.sourceId) ?? false) &&
        (selectedSource == anchor.sourceId ||
            (selectedSource == null &&
                !isAutoResolveBlocked(anchor.sourceId)))) {
      report(1, 1);
      final streams = await Future.any<List<VideoSource>>([
        _replayAnchor(anchor),
        abortFuture.then<List<VideoSource>>(
          (_) => throw const PlaybackAborted(),
        ),
      ]);
      if (gen != _sweepGen) throw const PlaybackAborted();
      if (streams.isNotEmpty) {
        _winners[flightKey] = (
          episodeUrl: anchor.episodeUrl,
          sourceId: anchor.sourceId,
          match: anchor.match,
        );
        // Refresh what the anchor holds: the links just checked are fresher
        // than the ones on disk.
        await _anchors?.save(
          zmEpisodeUrl,
          category,
          EpisodeAnchor(
            sourceId: anchor.sourceId,
            episodeUrl: anchor.episodeUrl,
            match: anchor.match,
            streams: streams,
            at: DateTime.now(),
          ),
        );
        debugPrint(
          '[playback] resolveProgressive · anchor hit · ${anchor.sourceId} '
          'for $zmEpisodeUrl (${anchor.streams.length} saved, '
          '${streams.length} live)',
        );
        yield ProgressiveResolve(
          match: anchor.match,
          episodeUrl: anchor.episodeUrl,
          streams: streams,
          done: true,
        );
        return;
      }
      debugPrint(
        '[playback] resolveProgressive · anchor for $zmEpisodeUrl no longer '
        'plays — sweeping',
      );
      await _anchors?.remove(zmEpisodeUrl, category);
    }
    final t = await _titleLookup(p.show);
    final ordered = _orderedCandidates(p.show, allEligible: true);
    if (ordered.isEmpty) {
      throw NoSourceMatch(p.show);
    }

    final chosen = _chosenSources(p.show);
    final dead =
        _unplayable[_winKey(zmEpisodeUrl, category)] ?? const <String>{};
    final outcomes = <SweepOutcome>[];
    void note(String sourceId, SweepReason reason) => outcomes.add((
      sourceId: sourceId,
      name: _sources.displayName(sourceId),
      reason: reason,
    ));

    var hadTitleMatch = false;

    /// Sources that recognised the title but failed later (episode list or
    /// streams). Their expensive searches are now cached, so a second ask can
    /// rescue a title the viewer would otherwise have to press Retry for.
    final matchedSources = <String>{};

    // One candidate, start to finish — same body as [_resolve]'s `ask`, minus
    // the download branch: progressive is always the foreground wait.
    final attemptedIds = <String>{};
    final total = selectedSource != null
        ? 1
        : ordered
              .where(
                (id) => !dead.contains(id) && !CfSolveNeeded.sourceFlagged(id),
              )
              .length;
    report(0, total);

    Future<_Attempt?> ask(String sourceId) async {
      if (attemptedIds.add(sourceId)) report(attemptedIds.length, total);
      _Attempt? attempt;
      final budget = _budgetFor(sourceId, chosen);
      try {
        final call = _tryCandidate(
          p,
          sourceId,
          t,
          // Playback needs the first usable link, not every mirror. CloudStream
          // can return early while its native link session keeps resolving;
          // the player picks up those later links through pollSources.
          fast: true,
          category: category,
          onTitleMatch: () {
            hadTitleMatch = true;
            matchedSources.add(sourceId);
          },
          onMiss: (reason) => note(sourceId, reason),
        ).timeout(budget);
        // Stop WAITING when the viewer leaves; the answer underneath is
        // dropped, exactly as for an over-budget candidate.
        attempt = await Future.any<_Attempt?>([call, abortFuture]);
        // The loser still completes. Swallow it, or the TimeoutException
        // nobody is waiting for surfaces as an unhandled async error.
        if (attempt == null) {
          unawaited(call.then<void>((_) {}, onError: (_) {}));
        }
      } on TimeoutException {
        _overBudget[sourceId] = DateTime.now();
        note(sourceId, SweepReason.timedOut);
      } catch (_) {
        note(sourceId, SweepReason.failed);
      }
      return attempt;
    }

    // Streams known to date, in candidate order, URL-deduped. Every event
    // carries a copy of this — never the last hit alone.
    final acc = <VideoSource>[];
    final seenUrls = <String>{};
    _Attempt? firstHit;
    var winnerWritten = false;

    // Records one genuine hit and builds its event. Winner cache, last-played
    // and score go to the FIRST genuine hit in candidate order only — the
    // single-winner bookkeeping [_resolve] does. Late arrivals only extend
    // the accumulated list.
    Future<ProgressiveResolve> recordHit(_Attempt attempt) async {
      if (!winnerWritten) {
        winnerWritten = true;
        firstHit = attempt;
        _winners[_winKey(zmEpisodeUrl, category)] = (
          episodeUrl: attempt.episodeUrl,
          sourceId: attempt.match.sourceId,
          match: attempt.match,
        );
        // Persist the winner so the next app run opens this episode on the
        // same source and link, without a sweep.
        await _anchors?.save(
          zmEpisodeUrl,
          category,
          EpisodeAnchor(
            sourceId: attempt.match.sourceId,
            episodeUrl: attempt.episodeUrl,
            match: attempt.match,
            streams: attempt.streams,
            at: DateTime.now(),
          ),
        );
        if (!attempt.match.pinned) {
          await _store.rememberLastPlayed(p.show, attempt.match.sourceId);
          await _scores?.bump(attempt.match.sourceId);
        }
      }
      for (final s in attempt.streams) {
        if (seenUrls.add(s.url)) acc.add(s);
      }
      return ProgressiveResolve(
        match: attempt.match,
        episodeUrl: attempt.episodeUrl,
        streams: [...acc],
        done: false,
      );
    }

    /// Ask the sweep's candidates and hand the player the first thing that
    /// genuinely answers.
    ///
    /// The window is eight wide and takes whichever source lands FIRST, on
    /// purpose: `Play must not wait for a slow source to time out` is a rule
    /// with tests behind it, and a title whose top source is hanging still has
    /// to open on one that answers — including sources past the configured
    /// limit, which is how a three-wide wave turned into a two-second stall.
    /// What is not left to a race is the head start: see [firstAlone].
    Stream<ProgressiveResolve> runQueue(
      List<String> queue, {
      bool firstAlone = false,
    }) async* {
      final pending = <String, Future<_Attempt?>>{};
      var next = 0;
      void fill() {
        while (pending.length < 8 && next < queue.length && gen == _sweepGen) {
          final id = queue[next++];
          pending[id] = ask(id);
        }
      }

      if (firstAlone && queue.isNotEmpty) {
        // The head start, asked ALONE and ahead of the window, exactly as the
        // non-progressive sweep does it. "Continue with episode 2" used to
        // search every candidate because episode 1 had settled on one of them
        // and this path ignored that; the remembered source's title match is
        // already stored, so this costs one cheap lookup — and when it
        // answers, nothing else gets asked at all.
        final attempt = await ask(queue[next++]);
        if (gen != _sweepGen) throw const PlaybackAborted();
        if (attempt != null) {
          yield await recordHit(attempt);
          return;
        }
      }

      fill();
      while (pending.isNotEmpty) {
        final landed = await Future.any([
          for (final entry in pending.entries)
            entry.value.then((attempt) => (id: entry.key, attempt: attempt)),
        ]);
        pending.remove(landed.id);
        if (gen != _sweepGen) throw const PlaybackAborted();
        final attempt = landed.attempt;
        if (attempt != null) {
          yield await recordHit(attempt);
          if (stopAfterFirstWave) return;
        }
        fill();
      }
    }

    // A manually selected source is the whole playback resolution, not merely
    // the first wave. Finish after its fast links; the player's poll path still
    // collects late mirrors belonging to this same winning provider.
    if (selectedSource != null && !dead.contains(selectedSource)) {
      final attempt = await ask(selectedSource);
      if (gen != _sweepGen) throw const PlaybackAborted();
      if (attempt != null) {
        final event = await recordHit(attempt);
        yield ProgressiveResolve(
          match: event.match,
          episodeUrl: event.episodeUrl,
          streams: event.streams,
          done: true,
        );
        return;
      }
    }

    // Use the title match as a head start, but race it with other eligible
    // sources so a stale or slow match cannot hold up the player.
    final autoFound = selectedSource == null ? _store.bestFor(p.show) : null;
    if (autoFound != null && ordered.remove(autoFound.sourceId)) {
      ordered.insert(0, autoFound.sourceId);
    }
    // No source gets a hardcoded head start. Source Priority belongs to the
    // viewer: promoting one bundled source above their order made every
    // movie/series try that source second, so a mislabelled entry there could
    // win before the sources they actually ranked first.
    if (selectedSource == null) {
      final queue = <String>[];
      for (final sourceId in ordered) {
        if (dead.contains(sourceId)) {
          note(sourceId, SweepReason.streamsDead);
        } else if (CfSolveNeeded.sourceFlagged(sourceId)) {
          note(sourceId, SweepReason.cloudflare);
        } else {
          queue.add(sourceId);
        }
      }
      // The same head start the non-progressive sweep gives the source that
      // just played this show, computed by the same function so the two paths
      // cannot disagree about what "remembered" means.
      final remembered = _rememberedPlaybackSource(p.show, queue);
      await for (final event in runQueue(
        queue,
        firstAlone: remembered != null,
      )) {
        yield event;
      }
    }
    // Automatic Retry. A source can recognise the title and still fail on its
    // first stream lookup — a cold CDN, a slow extractor, a transient 403. The
    // viewer used to have to press Retry for those: the second ask was fast
    // because the title/episode searches were already cached. Do that second
    // ask here, before declaring failure, with the same ordering guarantees.
    if (firstHit == null && matchedSources.isNotEmpty && gen == _sweepGen) {
      final retry = (selectedSource == null ? ordered : [selectedSource])
          .where((id) => matchedSources.contains(id) && !dead.contains(id))
          .toList();
      if (retry.isNotEmpty) {
        debugPrint(
          '[playback] second attempt for ${retry.length} matched source(s) of '
          '$zmEpisodeUrl — title lookups are cached',
        );
        await for (final event in runQueue(retry)) {
          yield event;
        }
        if (gen != _sweepGen) throw const PlaybackAborted();
      }
    }

    final done = firstHit;
    if (done == null) {
      // Nothing answered — the same verdicts the full sweep reports, and
      // the same short-lived memory so the next tap answers instantly.
      final blocked = _matcher.cfBlockedUrl(p.show.kind);
      if (blocked != null && !hadTitleMatch) {
        debugPrint(
          '[playback] resolveProgressive · CF blocked for kind=${p.show.kind} '
          'url=$blocked',
        );
      }
      _noSource[_winKey(zmEpisodeUrl, category)] = (
        at: DateTime.now(),
        hadTitleMatch: hadTitleMatch,
      );
      if (hadTitleMatch) {
        throw EpisodeNotAvailable(
          p.show,
          p.episode,
          hadTitleMatch: true,
          outcomes: outcomes,
          selectedSourceName: selectedSource == null
              ? null
              : _sources.displayName(selectedSource),
        );
      }
      throw NoSourceMatch(
        p.show,
        outcomes: outcomes,
        selectedSourceName: selectedSource == null
            ? null
            : _sources.displayName(selectedSource),
      );
    }
    // The full accumulation in candidate order — not the last hit alone.
    // `match` is the recorded winner: the first genuine hit, i.e. what the
    // full sweep would have returned.
    yield ProgressiveResolve(
      match: done.match,
      episodeUrl: done.episodeUrl,
      streams: [...acc],
      done: true,
    );
  }

  /// Warms the next episode while the current one is still playing, so a
  /// binge advances without the sweep. Resolves exactly as Play would, stops
  /// after the first wave that answers, and leaves the winner saved as the
  /// episode's [EpisodeAnchor] — so the next Play opens on the first working
  /// link while the rest of the mirrors arrive through polling.
  ///
  /// Fire-and-forget. A failure just means the next Play does the work itself.
  Future<void> prefetchEpisode(
    String zmEpisodeUrl, {
    String category = 'sub',
  }) async {
    try {
      await for (final event in resolveProgressive(
        zmEpisodeUrl,
        category: category,
        stopAfterFirstWave: true,
      )) {
        if (event.done) break;
      }
    } catch (e) {
      debugPrint('[playback] prefetchEpisode · $zmEpisodeUrl failed: $e');
    }
  }

  Future<List<VideoSource>> _verifiedWinnerLinks(
    String episodeUrl,
    String sourceId,
  ) async {
    try {
      final streams = await _sources
          .sources(episodeUrl, sourceId: sourceId, fast: true)
          .timeout(anchorResolveBudget);
      return enrichStreams(
        await _probe.liveStreams(
          streams,
          budget: anchorProbeBudget,
          firstHitGrace: fastFirstHitGrace,
        ),
      );
    } catch (_) {
      return const [];
    }
  }

  final _fastInFlight = <String, Future<List<VideoSource>>>{};

  Future<List<VideoSource>> _fastSources(String episodeUrl, String category) {
    final key = _winKey(episodeUrl, category);
    return _fastInFlight.putIfAbsent(key, () async {
      try {
        final event = await resolveProgressive(
          episodeUrl,
          category: category,
        ).first;
        return event.streams;
      } finally {
        _fastInFlight.remove(key);
      }
    });
  }

  /// Links for a remembered episode's [anchor], but ONLY ones that pass the
  /// same video probe a fresh sweep uses. A remembered source is a head start,
  /// not an excuse to hand the player a dead link.
  ///
  /// The saved links are checked first — if they still answer, nothing else is
  /// contacted and Play starts without a search of any kind. Only when every
  /// saved link has gone stale do we ask that same source for fresh links (one
  /// bounded call, still no title/episode sweep), and check those too. If both
  /// fail, the anchor is dropped and the normal sweep decides.
  Future<List<VideoSource>> _replayAnchor(EpisodeAnchor anchor) async {
    final saved = await _probe.liveStreams(
      anchor.streams,
      budget: anchorProbeBudget,
      firstHitGrace: fastFirstHitGrace,
    );
    if (saved.isNotEmpty) return enrichStreams(saved);
    try {
      final fresh = await _sources
          .sources(anchor.episodeUrl, sourceId: anchor.sourceId, fast: true)
          .timeout(anchorResolveBudget);
      if (fresh.isEmpty) return const <VideoSource>[];
      final live = await _probe.liveStreams(
        fresh,
        budget: anchorProbeBudget,
        firstHitGrace: fastFirstHitGrace,
      );
      return enrichStreams(live);
    } catch (e) {
      debugPrint(
        '[playback] anchor · ${anchor.sourceId} did not re-resolve: $e',
      );
      return const <VideoSource>[];
    }
  }

  Future<ResolvedPlayback> _resolve(
    String zmEpisodeUrl, {
    required bool fast,
    String category = 'sub',
    bool Function(List<VideoSource> streams)? accept,
  }) async {
    // Read FIRST, before any await. Taken after one and it reads whatever the
    // abort already set, so the sweep it was meant to stop never sees a change
    // and runs to the end — which is the bug, silently reintroduced.
    final gen = _sweepGen;
    // Derived ONCE per sweep, not per candidate: every `then` registers a
    // listener on the completer, and one per candidate would pile up 37 of
    // them each sweep on a signal that usually never fires.
    final abortFuture = _abortSignal.future.then<_Attempt?>((_) => null);
    final p = ZmodeIds.parseEpisode(zmEpisodeUrl);
    if (p == null) {
      debugPrint('[playback] _resolve → ArgumentError: not a zm episode url');
      throw ArgumentError('not a metadata episode url: $zmEpisodeUrl');
    }
    debugPrint(
      '[playback] _resolve · url=$zmEpisodeUrl episode=${p.episode} '
      'show=${p.show.kind}/${p.show.id} fast=$fast',
    );
    final t = await _titleLookup(p.show);
    debugPrint(
      '[playback] _resolve · titleLookup → "${t.title}" '
      '(alt="${t.alt}" malId=${t.malId})',
    );
    // The source the viewer pinned to THIS title by hand — stronger than the
    // mode-wide preference in [_chosenSources], and the only one that stops
    // the sweep below.
    final pinned = _matcher.pinnedSource(p.show);
    final ordered = _orderedCandidates(p.show);
    debugPrint(
      '[playback] _resolve · ${ordered.length} ordered candidates '
      '(${ordered.join(", ")})',
    );
    if (ordered.isEmpty) {
      debugPrint('[playback] _resolve → NoSourceMatch (no candidates)');
      throw NoSourceMatch(p.show);
    }

    final chosen = _chosenSources(p.show);
    final dead =
        _unplayable[_winKey(zmEpisodeUrl, category)] ?? const <String>{};
    final outcomes = <SweepOutcome>[];
    void note(String sourceId, SweepReason reason) => outcomes.add((
      sourceId: sourceId,
      name: _sources.displayName(sourceId),
      reason: reason,
    ));

    var hadTitleMatch = false;

    // One candidate, start to finish. Lifted out of the loop VERBATIM so the
    // sweep can run several at once without the per-source rules changing: the
    // try/catch is still per candidate, so one source throwing ("no sources in
    // response") or hanging cannot kill the others.
    Future<_Attempt?> ask(String sourceId) async {
      debugPrint('[playback] _resolve · trying $sourceId');
      _Attempt? attempt;
      final budget = _budgetFor(sourceId, chosen);
      try {
        final call = _tryCandidate(
          p,
          sourceId,
          t,
          fast: fast,
          category: category,
          onTitleMatch: () => hadTitleMatch = true,
          onMiss: (reason) => note(sourceId, reason),
        ).timeout(budget);
        if (accept == null) {
          // Stop WAITING when the viewer leaves. The request underneath is not
          // cancellable, so it finishes in the background and its answer is
          // dropped — exactly what already happens to an over-budget one.
          attempt = await Future.any<_Attempt?>([call, abortFuture]);
          // The loser still completes. Swallow it, or the TimeoutException
          // nobody is waiting for surfaces as an unhandled async error.
          if (attempt == null) {
            unawaited(call.then<void>((_) {}, onError: (_) {}));
          }
        } else {
          // A filtered sweep (downloading) is nobody's foreground wait, and
          // abortSweeps deliberately leaves it alone — see its doc. Closing
          // the player must not cancel a download.
          attempt = await call;
        }
      } on TimeoutException {
        _overBudget[sourceId] = DateTime.now();
        note(sourceId, SweepReason.timedOut);
        debugPrint(
          '[playback] _resolve · $sourceId → over ${budget.inSeconds}s '
          'budget, skipping it for ${overBudgetCooldown.inMinutes}m',
        );
      } catch (e) {
        note(sourceId, SweepReason.failed);
        debugPrint(
          '[playback] _resolve · $sourceId → error during resolution: $e',
        );
      }
      return attempt;
    }

    // Walked in WAVES rather than one at a time. A sweep that finds nothing
    // used to be the sum of every candidate's wait; now it is the sum of each
    // wave's slowest member, which is what a failing Play tap actually costs.
    //
    // Deliberately small. The sweep stops at the first source that answers, so
    // a wave of ten would fire ten requests where one would have done on every
    // title that works — paying on the common case to speed up the rare one.
    // Three is enough to cut the wait meaningfully and small enough that the
    // waste is a rounding error.
    //
    // Results are read back in CANDIDATE order, never completion order: the
    // list is the viewer's own priority, and letting whichever source answers
    // first win would quietly replace their ordering with a race.
    // Same fix as the progressive path: if Detail's Auto Resolve already
    // matched this title, play that source instead of re-sweeping every
    // installed source and letting an unrelated top-ranked one win.
    final autoFound =
        accept == null &&
            pinned == null &&
            _matcher.sourceForTitle(p.show) == null
        ? _store.bestFor(p.show)
        : null;
    if (autoFound != null && isAutoResolveBlocked(autoFound.sourceId)) {
      await _store.forget(p.show, autoFound.sourceId);
      debugPrint(
        '[playback] _resolve · ignored blocked auto-found match '
        '${autoFound.sourceId} for $zmEpisodeUrl',
      );
    }
    final safeAutoFound =
        autoFound != null && isAutoResolveBlocked(autoFound.sourceId)
        ? null
        : autoFound;
    if (safeAutoFound != null &&
        safeAutoFound.showUrl.isNotEmpty &&
        !dead.contains(safeAutoFound.sourceId) &&
        _sources.hasSource(safeAutoFound.sourceId)) {
      debugPrint(
        '[playback] _resolve · playing auto-found match '
        '${safeAutoFound.sourceId} for $zmEpisodeUrl',
      );
      final attempt = await ask(safeAutoFound.sourceId);
      if (attempt != null) {
        _winners[_winKey(zmEpisodeUrl, category)] = (
          episodeUrl: attempt.episodeUrl,
          sourceId: attempt.match.sourceId,
          match: attempt.match,
        );
        await _anchors?.save(
          zmEpisodeUrl,
          category,
          EpisodeAnchor(
            sourceId: attempt.match.sourceId,
            episodeUrl: attempt.episodeUrl,
            match: attempt.match,
            streams: attempt.streams,
            at: DateTime.now(),
          ),
        );
        if (!attempt.match.pinned) {
          await _store.rememberLastPlayed(p.show, attempt.match.sourceId);
          await _scores?.bump(attempt.match.sourceId);
        }
        return ResolvedPlayback(
          match: attempt.match,
          episodeUrl: attempt.episodeUrl,
          streams: attempt.streams,
          show: p.show,
          episode: p.episode,
        );
      }
    }

    final remembered = accept == null
        ? _rememberedPlaybackSource(p.show, ordered)
        : null;
    outer:
    for (final candidates in _candidateWaves(
      ordered,
      firstAlone: remembered != null,
    )) {
      // Once per wave rather than once per candidate. A wave already in flight
      // cannot be recalled — the requests underneath are not cancellable — so
      // leaving stops the NEXT wave, not this one. That is the same bargain as
      // before, just measured in threes.
      if (accept == null && gen != _sweepGen) {
        debugPrint(
          '[playback] _resolve · abandoned before source wave — '
          'the viewer left',
        );
        throw const PlaybackAborted();
      }

      // The cheap, synchronous rules first, so a skipped source never occupies
      // a slot in the wave. Each still notes its own reason, and still only
      // for candidates the sweep actually reached — pre-filtering the whole
      // list would report sources it never got to.
      final wave = <String>[];
      for (final sourceId in candidates) {
        // Asked already this episode, and its links would not play. Handing
        // them back a second time is how "every source failed (tried 1)"
        // happened with twenty more sources sitting untouched.
        if (dead.contains(sourceId)) {
          debugPrint(
            '[playback] _resolve · skip $sourceId (its links did not play)',
          );
          note(sourceId, SweepReason.streamsDead);
          continue;
        }
        if (CfSolveNeeded.sourceFlagged(sourceId)) {
          debugPrint('[playback] _resolve · skip $sourceId (CF blocked)');
          note(sourceId, SweepReason.cloudflare);
          continue;
        }
        if (_health.isSkippable(sourceId)) {
          debugPrint('[playback] _resolve · skip $sourceId (unhealthy)');
          note(sourceId, SweepReason.unhealthy);
          continue;
        }
        if (_recentlyOverBudget(sourceId)) {
          debugPrint(
            '[playback] _resolve · skip $sourceId (over budget recently)',
          );
          note(sourceId, SweepReason.cooldown);
          continue;
        }
        wave.add(sourceId);
      }
      if (wave.isEmpty) continue;

      // `ask` never throws — every failure inside it is caught and returns
      // null — so one bad source in a wave cannot take the others down.
      final answers = await Future.wait([for (final id in wave) ask(id)]);

      // Again on the way out, not only on the way in. Every candidate in the
      // wave races the abort signal and comes back null the moment it fires,
      // so the wave itself ends promptly — but if this was the LAST wave the
      // loop would then fall through to the bottom and report "nothing has
      // this episode", which is not what happened. The viewer left.
      if (accept == null && gen != _sweepGen) {
        debugPrint(
          '[playback] _resolve · abandoned mid source wave — '
          'the viewer left',
        );
        throw const PlaybackAborted();
      }

      for (var i = 0; i < wave.length; i++) {
        final sourceId = wave[i];
        final attempt = answers[i];
        if (attempt == null) {
          // A source the viewer PICKED by hand is not a candidate among others.
          // Walking past it to whatever answers next meant pinning AnimePahe and
          // silently getting Netflix 25 seconds later — the substitution was
          // never mentioned, so it read as the pin being ignored. Stop here and
          // let the failure say what happened to the source they chose.
          //
          // Playback only (accept == null): a download sweep is looking for a
          // file any source can provide, not honouring a viewing choice. And
          // only when it FAILED — a pin that answers still hands off to the
          // player's own dead-link failover, which is a different question.
          // gen check first: the viewer LEAVING is not the pin failing, and the
          // top of the loop still has to throw PlaybackAborted for it.
          if (accept == null && sourceId == pinned && gen == _sweepGen) {
            debugPrint(
              '[playback] _resolve · $sourceId was pinned by hand and did not '
              'answer — not substituting another source',
            );
            // The whole sweep, not just this wave: the point is that no OTHER
            // source gets substituted, and the rest of the wave is other
            // sources. Their answers are discarded with the loop.
            break outer;
          }
          continue;
        }

        // The caller can require more than "has streams". Downloading does: a
        // source can play perfectly and still hand back only DASH manifests,
        // which never become a file. Asking here keeps it to ONE sweep that
        // walks every candidate — the alternative was re-running the whole
        // sweep per rejected source, which is quadratic and froze the app.
        if (accept != null && !accept(attempt.streams)) {
          debugPrint(
            '[playback] _resolve · ${attempt.match.sourceId} answered but the '
            'caller rejected its streams — next candidate',
          );
          continue;
        }

        // A filtered sweep answers a narrower question, so it must not become
        // the remembered winner: playback would inherit a source picked for
        // being downloadable rather than for playing well.
        if (accept != null) {
          return ResolvedPlayback(
            match: attempt.match,
            episodeUrl: attempt.episodeUrl,
            streams: attempt.streams,
            show: p.show,
            episode: p.episode,
          );
        }

        // Written here rather than inside _tryCandidate so an abandoned
        // (timed-out) candidate that finishes later can never overwrite the
        // winner of the source we actually settled on.
        _winners[_winKey(zmEpisodeUrl, category)] = (
          episodeUrl: attempt.episodeUrl,
          sourceId: attempt.match.sourceId,
          match: attempt.match,
        );
        // Same disk memory as the progressive path: the next run's Play gets
        // this source without repeating the sweep.
        await _anchors?.save(
          zmEpisodeUrl,
          category,
          EpisodeAnchor(
            sourceId: attempt.match.sourceId,
            episodeUrl: attempt.episodeUrl,
            match: attempt.match,
            streams: attempt.streams,
            at: DateTime.now(),
          ),
        );
        // Per-title only — remembered for THIS show's own re-ranking (see
        // `_orderedCandidates`). This must never write the kind-wide
        // `ZSourcePrefs` default: that's an explicit, rare user choice (the
        // "source went quiet" recovery picker), and a single successful
        // Auto Resolve play silently promoting itself to play EVERY title of
        // the kind is exactly the bug this design fixes.
        if (!attempt.match.pinned) {
          await _store.rememberLastPlayed(p.show, attempt.match.sourceId);
          await _scores?.bump(attempt.match.sourceId);
        }
        debugPrint(
          '[playback] $zmEpisodeUrl -> ${attempt.match.sourceId} '
          '(${attempt.streams.length} streams)',
        );
        return ResolvedPlayback(
          match: attempt.match,
          episodeUrl: attempt.episodeUrl,
          streams: attempt.streams,
          show: p.show,
          episode: p.episode,
        );
      }
    }

    final blocked = _matcher.cfBlockedUrl(p.show.kind);
    if (blocked != null && !hadTitleMatch) {
      debugPrint(
        '[playback] _resolve · CF blocked for kind=${p.show.kind} '
        'url=$blocked',
      );
      // Let CloudflareRequiredException propagate from SourceRepository if thrown;
      // cfBlockedUrl covers suppressed searches.
    }

    if (accept == null) {
      _noSource[_winKey(zmEpisodeUrl, category)] = (
        at: DateTime.now(),
        hadTitleMatch: hadTitleMatch,
      );
    }
    if (hadTitleMatch) {
      debugPrint(
        '[playback] _resolve → EpisodeNotAvailable '
        '(hadTitleMatch=true, episode=${p.episode})',
      );
      throw EpisodeNotAvailable(
        p.show,
        p.episode,
        hadTitleMatch: true,
        outcomes: outcomes,
      );
    }
    debugPrint(
      '[playback] _resolve → NoSourceMatch · '
      '${sweepFailureDetail(outcomes) ?? "every source answered"}',
    );
    throw NoSourceMatch(p.show, outcomes: outcomes);
  }

  /// Returns streams for [zmEpisodeUrl], sweeping sources when needed.
  ///
  /// When a winner is already cached, it is reused regardless of [fast] —
  /// this avoids re-running the full source sweep (title match → episode list
  /// → stream resolve) for the same episode just because the native player's
  /// Server picker calls back for its mirror list. [fast] is still forwarded
  /// to [SourceRepository.sources] so stream URLs are resolved with the fast
  /// path (first usable link) and served from the TTL cache when fresh.
  Future<List<VideoSource>> sources(
    String zmEpisodeUrl, {
    bool fast = false,
    String category = 'sub',
  }) async {
    if (fast) return _fastSources(zmEpisodeUrl, category);
    final hit = _winners[_winKey(zmEpisodeUrl, category)];
    if (hit != null) {
      // ClearCut: the remembered source's links are fetched FRESH here, and
      // were never checked — some sources hand out new or short-lived links
      // every time, so the links auto-find verified were not the ones the
      // player got. Check these too; if none play, skip this source for the
      // episode and let the sweep find the next one.
      final fresh = await _sources.sources(
        hit.episodeUrl,
        sourceId: hit.sourceId,
        fast: fast,
      );
      final live = await _probe.liveStreams(
        fresh,
        firstHitGrace: fast ? fastFirstHitGrace : null,
      );
      if (live.isNotEmpty) return enrichStreams(live);
      debugPrint(
        '[playback] sources · remembered ${hit.sourceId} now returns no '
        'playable link for $zmEpisodeUrl — trying the next source',
      );
      markSourceUnplayable(zmEpisodeUrl, hit.sourceId, category: category);
    }
    // Disk memory of the source that played this episode in an earlier run.
    // The in-memory winner above dies with the process; this does not. Same
    // rule as the progressive path: the viewer's explicit pick wins over it,
    // and a source already known unplayable for this episode is not replayed.
    final anchor = _anchors?.get(zmEpisodeUrl, category);
    final parsed = anchor == null ? null : ZmodeIds.parseEpisode(zmEpisodeUrl);
    final selected = parsed == null
        ? null
        : _matcher.sourceForTitle(parsed.show);
    final dead =
        _unplayable[_winKey(zmEpisodeUrl, category)] ?? const <String>{};
    if (anchor != null &&
        parsed != null &&
        !dead.contains(anchor.sourceId) &&
        (selected == null || selected == anchor.sourceId)) {
      final live = await _replayAnchor(anchor);
      if (live.isNotEmpty) {
        _winners[_winKey(zmEpisodeUrl, category)] = (
          episodeUrl: anchor.episodeUrl,
          sourceId: anchor.sourceId,
          match: anchor.match,
        );
        await _anchors?.save(
          zmEpisodeUrl,
          category,
          EpisodeAnchor(
            sourceId: anchor.sourceId,
            episodeUrl: anchor.episodeUrl,
            match: anchor.match,
            streams: live,
            at: DateTime.now(),
          ),
        );
        return live;
      }
      debugPrint(
        '[playback] sources · anchor for $zmEpisodeUrl no longer plays — '
        'sweeping',
      );
      await _anchors?.remove(zmEpisodeUrl, category);
    }
    return (await resolveForPlayback(
      zmEpisodeUrl,
      fast: fast,
      category: category,
    )).streams;
  }

  Future<({List<VideoSource> sources, bool done})> polledSources(
    String zmEpisodeUrl, {
    String category = 'sub',
  }) async {
    final key = _winKey(zmEpisodeUrl, category);
    var winner = _winners[key];
    if (winner == null) {
      await resolveForPlayback(zmEpisodeUrl, category: category);
      winner = _winners[key];
    }
    if (winner == null) {
      return (sources: const <VideoSource>[], done: true);
    }
    return _sources.polledSources(winner.episodeUrl, sourceId: winner.sourceId);
  }

  /// The source that last resolved [zmEpisodeUrl], if any this session.
  String? resolvedSourceId(String zmEpisodeUrl, {String category = 'sub'}) =>
      _winners[_winKey(zmEpisodeUrl, category)]?.sourceId;

  /// Background playback options. Checking them leaves the active winner,
  /// the saved source preference, and the current stream unchanged.
  Stream<List<VideoSource>> alternativeStreams(
    String episodeUrl, {
    String? currentSourceId,
    String category = 'sub',
    bool Function()? abandoned,
  }) async* {
    final episode = ZmodeIds.parseEpisode(episodeUrl);
    if (episode == null) return;
    final current =
        currentSourceId ?? resolvedSourceId(episodeUrl, category: category);
    final title = await _titleLookup(episode.show);
    final candidates = _orderedCandidates(
      episode.show,
      allEligible: true,
    ).where((id) => id != current && !CfSolveNeeded.sourceFlagged(id)).toList();
    final preferred = _chosenSources(episode.show);
    for (final wave in _candidateWaves(candidates, waveSize: 4)) {
      if (abandoned?.call() == true) return;
      final hits = await Future.wait(
        wave.map((sourceId) async {
          try {
            return await ProviderManager.inBackground(
              () => _passively(
                () => _tryCandidate(
                  episode,
                  sourceId,
                  title,
                  fast: true,
                  category: category,
                  onTitleMatch: () {},
                  onMiss: (_) {},
                ),
              ),
            ).timeout(_budgetFor(sourceId, preferred));
          } catch (_) {
            return null;
          }
        }),
      );
      if (abandoned?.call() == true) return;
      final streams = [
        for (final hit in hits.whereType<_Attempt>())
          for (final stream in hit.streams)
            stream.withLabel(
              [
                _sources.displayName(hit.match.sourceId),
                if (stream.label?.isNotEmpty == true) stream.label!,
              ].join(' · '),
            ),
      ];
      if (streams.isNotEmpty) yield streams;
    }
  }

  /// Drop the cached winner for [zmEpisodeUrl] so the next
  /// [resolveForPlayback] re-sweeps sources instead of reusing the failed one.
  ///
  /// Also clears over-budget cooldowns: an episode tap / Retry is the viewer
  /// asking to try again, so a source that timed out on the previous attempt
  /// must be eligible. Background sweeps keep the cooldown until this runs.
  void invalidateWinner(String zmEpisodeUrl) {
    // Also drops a remembered "nothing has this episode": Retry and the
    // player's own source-switch both come through here, and they must get a
    // real sweep rather than the cached no.
    //
    // EVERY category: the keys carry one now, and a caller retrying an episode
    // means "forget what you know about it", not "forget the sub cut".
    bool mine(String k) => k == zmEpisodeUrl || k.startsWith('$zmEpisodeUrl|');
    // BOTH maps, independently. A sweep that found nothing leaves a _noSource
    // entry and no winner at all, so walking _winners alone would clear
    // nothing and Retry would keep answering from the remembered no.
    final winners = _winners.keys.where(mine).toList();
    final misses = _noSource.keys.where(mine).toList();
    for (final k in winners) {
      _winners.remove(k);
    }
    for (final k in misses) {
      _noSource.remove(k);
    }
    for (final k in _unplayable.keys.where(mine).toList()) {
      _unplayable.remove(k);
    }
    final clearedBudget = _overBudget.isNotEmpty;
    if (clearedBudget) _overBudget.clear();
    if (winners.isNotEmpty || misses.isNotEmpty || clearedBudget) {
      debugPrint(
        '[playback] invalidateWinner · $zmEpisodeUrl '
        '(${winners.length} winner(s), ${misses.length} miss(es)'
        '${clearedBudget ? ', over-budget cleared' : ''})',
      );
    }
  }

  /// Drop every cached winner for [c] — the whole show, not one episode.
  ///
  /// Changing a title's source has to come through here. [_winners] is keyed
  /// per EPISODE and [sources] short-circuits on it without consulting the
  /// pin, so switching source left every episode still resolving through the
  /// source that played last: press play and you got the old source's stream.
  /// It cleared itself on restart, which is the only reason it looked
  /// intermittent rather than broken.
  void invalidateShow(ZCanonical c) {
    final prefix = '${ZmodeIds.showUrl(c)}/ep/';
    // Each map walked on its own. A show whose sweep found nothing has a
    // _noSource entry and no winner, so keying the loop off _winners would
    // leave the remembered "no source" in place and the new source would
    // never get asked.
    final winners = _winners.keys.where((k) => k.startsWith(prefix)).toList();
    final misses = _noSource.keys.where((k) => k.startsWith(prefix)).toList();
    // An in-flight resolve was started for the OLD source; letting it settle
    // would write that source straight back into _winners.
    final flights = _inFlight.keys.where((k) => k.startsWith(prefix)).toList();
    for (final k in winners) {
      _winners.remove(k);
    }
    for (final k in misses) {
      _noSource.remove(k);
    }
    for (final k in flights) {
      _inFlight.remove(k);
    }
    // The disk memory names sources for this show too; a source switch that
    // left it in place would replay the old source on the next restart.
    unawaited(_anchors?.removePrefix(prefix) ?? Future<void>.value());
    // Source switch / CF solve — same "try again" intent as an episode tap.
    final clearedBudget = _overBudget.isNotEmpty;
    if (clearedBudget) _overBudget.clear();
    if (winners.isNotEmpty ||
        misses.isNotEmpty ||
        flights.isNotEmpty ||
        clearedBudget) {
      debugPrint(
        '[playback] invalidateShow · $prefix '
        '(${winners.length} winner(s), ${misses.length} miss(es)'
        '${clearedBudget ? ', over-budget cleared' : ''})',
      );
    }
  }

  Future<Episode?> _selectEpisode(
    List<Episode> eps,
    ({ZCanonical show, int episode}) requested,
  ) async {
    final n = requested.episode;
    if (requested.show.kind == ZKind.tv) {
      final lookup = _tvEpisodeLookup;
      final target = lookup == null ? null : await lookup(requested.show, n);
      final labelled = [
        for (final ep in eps)
          if (tvEpisodeCoordinates(ep) case final coordinates?)
            (episode: ep, coordinates: coordinates),
      ];
      if (target != null && labelled.isNotEmpty) {
        return labelled
            .where((entry) => entry.coordinates == target)
            .firstOrNull
            ?.episode;
      }
    }
    if (requested.show.kind == ZKind.tv) {
      final exact = eps.where((episode) => episode.number == n).toList();
      if (exact.length == 1) return exact.single;
      if (eps.any((episode) => episode.number != null)) return null;
    }
    final i = n - 1;
    if (i < 0 || i >= eps.length) return null;
    return eps[i];
  }

  /// Answered over a method channel by native code, rather than by the JS
  /// runtime on this isolate — which decides whether a probe can run alongside
  /// its neighbours or has to wait its turn.
  static bool _isNativeSource(String id) =>
      id.startsWith('cs:') ||
      id.startsWith('ani:') ||
      id.startsWith('mihon:') ||
      id.startsWith('lnr:');

  /// Every source [probeEach] is going to ask, in the order it will ask them.
  ///
  /// Exposed so a list can show the whole queue up front — a row appearing out
  /// of nowhere reads as a stall, whereas a pending row turning into an answer
  /// reads as progress, and the count tells you how much is left.
  List<({String id, String name})> candidatesForEpisode(String zmEpisodeUrl) {
    final p = ZmodeIds.parseEpisode(zmEpisodeUrl);
    if (p == null) return const [];
    return [
      for (final id in _orderedCandidates(p.show))
        (id: id, name: _sources.displayName(id)),
    ];
  }

  /// One candidate's verdict, as [probeEach] reports it.
  ///
  /// [streams] non-empty means this source can play the episode right now.
  /// [checking] is true for the row emitted BEFORE the work starts, so a list
  /// can show which source is being asked rather than a bare spinner.
  /// Bounded by TIME, not by a count of sources.
  ///
  /// Counting was the wrong dial. Measured on device, most candidates answer
  /// in 0-1ms — they have a remembered miss for this title and cost nothing to
  /// ask. Capping at twelve *sources* therefore spent the whole allowance on
  /// free questions and stopped before the interesting ones, so the viewer had
  /// to keep pressing "Keep checking" to get through a list that would have
  /// finished on its own in seconds.
  ///
  /// [wallClock] bounds the pass instead, which is what actually protects
  /// someone with a hundred sources: cheap ones stay free, and only genuinely
  /// slow ones eat the budget. [skip] lets a caller resume past a stop.
  ///
  /// Each candidate is a real scrape, and JS providers run on this isolate —
  /// so the yield between them is not politeness, it is the only chance the UI
  /// gets to draw the answer that just landed.
  Stream<SourceProbe> probeEach(
    String zmEpisodeUrl, {
    Duration wallClock = const Duration(seconds: 20),
    Set<String> skip = const {},
    String category = 'sub',
  }) {
    final out = StreamController<SourceProbe>();
    final clock = Stopwatch()..start();
    var stopped = false;
    bool full() => stopped || out.isClosed || clock.elapsed > wallClock;

    Future<void> run() async {
      final p = ZmodeIds.parseEpisode(zmEpisodeUrl);
      if (p == null) return;
      final t = await _titleLookup(p.show);
      final all = _orderedCandidates(
        p.show,
      ).where((id) => !skip.contains(id)).toList();
      debugPrint(
        '[probe] ── pass start · ${all.length} to ask · '
        'up to ${wallClock.inSeconds}s',
      );

      /// True when this one blew its budget — the JS lane uses that to stop.
      Future<bool> probeOne(String sourceId) async {
        if (full()) return false;
        final name = _sources.displayName(sourceId);
        if (CfSolveNeeded.sourceFlagged(sourceId) ||
            _health.isSkippable(sourceId) ||
            _recentlyOverBudget(sourceId)) {
          if (!out.isClosed) {
            out.add(SourceProbe(sourceId: sourceId, name: name, skipped: true));
          }
          return false;
        }
        // Re-checked here, not just on entry: several probes are in flight at
        // once, and a hit landing while this one was queued means it is no
        // longer wanted.
        if (full()) return false;
        if (!out.isClosed) {
          out.add(SourceProbe(sourceId: sourceId, name: name, checking: true));
        }
        Episode? srcEp;
        SourceMatch? match;
        // Timed and logged per source: without this the probe was invisible in
        // a device log — a ten-second stall showed up as a gap between two
        // unrelated lines, with nothing saying who was being waited on.
        final sw = Stopwatch()..start();
        var how = 'no';
        try {
          // Passive: a survey must never pop the blocking Cloudflare WebView.
          // One challenged source did exactly that and stalled the app for
          // twelve seconds — after its own probe had already been abandoned.
          // Challenged sources are recorded via CfSolveNeeded instead, so the
          // solve can still be offered when the viewer actually picks one.
          (match, srcEp) = await _passively(
            () => _hasEpisode(p, sourceId, t, category: category),
          ).timeout(probeBudget);
          how = srcEp != null ? 'HAS' : 'no';
        } on TimeoutException {
          _overBudget[sourceId] = DateTime.now();
          how = 'timeout';
        } catch (e) {
          how = 'error: $e';
        }
        final timedOut = how == 'timeout';

        // ClearCut: Auto Find used to stop at the episode list and report a
        // source as found even when every stream link was dead. Play then
        // failed while another source would have worked. Verify the links here
        // too, with a short budget so the survey stays responsive; the sheet
        // shows "lists it, no link plays" separately from a real hit.
        var playable = false;
        if (srcEp != null && match != null && !timedOut && !full()) {
          try {
            // Bounded too: this runs on the serialized JS lane, so an
            // unbounded source lookup here would stall every JS source behind
            // this one — the exact thing that made sources look unreachable.
            final streams = await _sources
                .sources(srcEp.url, sourceId: match.sourceId, fast: true)
                .timeout(probeBudget);
            if (streams.isNotEmpty) {
              final live = await _probe
                  .liveStreams(
                    streams,
                    budget: anchorProbeBudget,
                    firstHitGrace: fastFirstHitGrace,
                  )
                  .timeout(
                    anchorProbeBudget + const Duration(milliseconds: 750),
                  );
              playable = live.isNotEmpty;
            }
          } on TimeoutException {
            // A link that never answers is not a playable source.
          } catch (_) {
            // Same: a failed probe is reported as "lists it", never as a hit.
          }
        }
        if (how == 'HAS') {
          how = playable ? 'HAS + playable link' : 'lists it, no live link';
        }
        debugPrint('[probe] $sourceId → $how (${sw.elapsedMilliseconds}ms)');
        if (!out.isClosed) {
          out.add(
            SourceProbe(
              sourceId: sourceId,
              name: name,
              episodeUrl: srcEp?.url,
              match: match,
              playable: playable,
            ),
          );
        }
        return timedOut;
      }

      // TWO LANES, because the sources are not alike.
      //
      // CloudStream, Aniyomi and Mihon answer over a method channel — the work
      // happens on a native thread pool, so several at once cost this isolate
      // nothing but the replies. Those go in parallel, a few at a time.
      //
      // JS providers run in flutter_js ON this isolate, and calls to it are
      // deliberately serialized (running them concurrently is what used to
      // SIGABRT the runtime). Those stay one at a time — "parallel" there
      // would not be faster, it would be a crash.
      //
      // The two lanes run together, so a slow JS provider no longer holds up
      // twenty native ones behind it.
      final native = <String>[];
      var js = <String>[];
      for (final id in all) {
        (_isNativeSource(id) ? native : js).add(id);
      }
      // The JS lane is serialized, so whoever is at the front of it decides how
      // much of the pass ever happens. Bundled sources answer in a few hundred
      // milliseconds, so they go first: a stalled third-party provider can then
      // no longer starve FrameXTV (and everything else) out of the survey.
      // This changes only the ORDER OF ASKING, never which source wins —
      // playback still follows the viewer's Source Priority.
      final bundled = bundledSourceIds();
      js = [
        ...js.where((id) => bundled.contains(id)),
        ...js.where((id) => !bundled.contains(id)),
      ];

      // Workers pulling from a shared queue, NOT batches of five: a batch is
      // only as fast as its slowest member, so one source sitting on its whole
      // budget stalled four others that had already answered. A worker that
      // finishes takes the next id immediately.
      var next = 0;
      Future<void> nativeWorker() async {
        while (!full()) {
          if (next >= native.length) return;
          final id = native[next++];
          await probeOne(id);
          await Future<void>.delayed(Duration.zero);
        }
      }

      Future<void> nativeLane() =>
          Future.wait([for (var i = 0; i < 5; i++) nativeWorker()]);

      Future<void> jsLane() async {
        var consecutiveTimeouts = 0;
        for (final id in js) {
          if (full()) return;
          final timedOut = await probeOne(id);
          // `.timeout()` abandons the WAIT, not the work: a JS call that blew
          // its budget is still running on the shared runtime, so the next JS
          // probe queues behind it and burns its own budget waiting for a
          // runtime that is still busy. Measured on device: animekai timed out
          // at 5.001s and hianime timed out at 5.001s immediately after.
          //
          // ONE timeout used to end the whole lane. With 140+ installed sources
          // that meant a single bad provider left every JS source behind it
          // permanently unasked — the reported "the app doesn't reach FrameXTV
          // and the other sources". Keep going, briefly pause so the runtime can
          // drain, and only give up after three stalls in a row.
          if (timedOut) {
            consecutiveTimeouts++;
            if (consecutiveTimeouts >= 3) {
              debugPrint(
                '[probe] JS lane paused — $consecutiveTimeouts sources in a '
                'row left the runtime busy',
              );
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 250));
            continue;
          }
          consecutiveTimeouts = 0;
          await Future<void>.delayed(Duration.zero);
        }
      }

      await Future.wait([nativeLane(), jsLane()]);
    }

    out.onCancel = () => stopped = true;
    unawaited(
      run().whenComplete(() {
        if (!out.isClosed) out.close();
      }),
    );
    return out.stream;
  }

  /// Streams for [zmEpisodeUrl] from EXACTLY [sourceId] — no sweep, no
  /// remembered winner.
  ///
  /// For callers that already know which source they mean. Downloading is the
  /// one that matters: the record stores the source the user was looking at,
  /// asked for it by name, and got whichever source last PLAYED the episode
  /// instead, because the name was dropped on the way through. Returns an
  /// empty list when that source doesn't have it, rather than quietly
  /// substituting another — a download from a source you didn't choose is the
  /// bug, not the fallback.
  Future<List<VideoSource>> sourcesFrom(
    String zmEpisodeUrl,
    String sourceId, {
    bool fast = false,
    String category = 'sub',
  }) async {
    final p = ZmodeIds.parseEpisode(zmEpisodeUrl);
    if (p == null) return const [];
    final t = await _titleLookup(p.show);
    final (match, ep) = await _hasEpisode(p, sourceId, t, category: category);
    if (match == null || ep == null) {
      debugPrint('[playback] sourcesFrom · $sourceId has no ep ${p.episode}');
      return const [];
    }
    return _sources.sources(ep.url, sourceId: match.sourceId, fast: fast);
  }

  /// Warms Continue Watching from the source already remembered for this
  /// title, without starting an Auto Resolve sweep.
  ///
  /// A background prewarm is speculative work: if the remembered source no
  /// longer has the episode, leave playback to handle that after a real tap.
  /// Contacting fallback sources here makes merely opening Home run provider
  /// searches the viewer never requested.
  Future<List<VideoSource>> prewarmRememberedSource(
    String zmEpisodeUrl, {
    String category = 'sub',
  }) async {
    final parsed = ZmodeIds.parseEpisode(zmEpisodeUrl);
    if (parsed == null) return const [];
    final remembered = _store.bestFor(parsed.show);
    if (remembered == null || isAutoResolveBlocked(remembered.sourceId)) {
      return const [];
    }
    final title = await _titleLookup(parsed.show);
    await _hasEpisode(parsed, remembered.sourceId, title, category: category);
    return const [];
  }

  /// [body] with the blocking Cloudflare solver disabled, when the JS provider
  /// manager is available to disable it. A no-op otherwise (tests, TV boot)
  /// rather than a hard dependency — suppression is an optimisation, never a
  /// correctness gate.
  Future<T> _passively<T>(Future<T> Function() body) =>
      sl.isRegistered<ProviderManager>()
      ? sl<ProviderManager>().asPassiveSweep(body)
      : body();

  /// Does [sourceId] LIST this episode? Deliberately stops there.
  ///
  /// The expensive half of resolving a source is the streams: server
  /// enumeration, the extractor round-trips, the host that answers in its own
  /// time. Measured on device, that turned a single probe into three to
  /// thirteen seconds — for a list whose only question is "who has it".
  ///
  /// So this asks the title and the episode list and stops. The answer is
  /// slightly optimistic — a source can list an episode and still have no
  /// working server — but that is the failure the player already handles with
  /// failover and an honest message, and it is worth trading for a list that
  /// answers in well under a second per source.
  Future<(SourceMatch?, Episode?)> _hasEpisode(
    ({ZCanonical show, int episode}) p,
    String sourceId,
    ({String title, String? alt, int? malId}) t, {
    String category = 'sub',
  }) async {
    final match = await _matcher.matchOn(
      p.show,
      sourceId,
      title: t.title,
      altTitle: t.alt,
      malId: t.malId,
      metadataAliases: await _aliasesFor(p.show),
    );
    if (match == null) return (null, null);
    final eps = await _sources.episodes(
      match.showUrl,
      sourceId: match.sourceId,
      category: category,
    );
    return (match, await _selectEpisode(eps, p));
  }

  /// Make [sourceId]'s already-probed result the one playback uses, so opening
  /// the player after a pick doesn't re-resolve anything.
  /// The winner cache holds only (episode url, source id), so a probe that
  /// stopped short of the streams is enough — the player resolves them for the
  /// one source that was picked, which is the work that had to happen anyway.
  Future<void> useProbed(
    String zmEpisodeUrl,
    SourceProbe probe, {
    String category = 'sub',
  }) async {
    final url = probe.episodeUrl;
    final m = probe.match;
    if (url == null || m == null) return;
    final key = _winKey(zmEpisodeUrl, category);
    _noSource.remove(key);
    _unplayable[key]?.remove(m.sourceId);
    _winners[key] = (episodeUrl: url, sourceId: m.sourceId, match: m);
    final p = ZmodeIds.parseEpisode(zmEpisodeUrl);
    if (p != null && !m.pinned) {
      await _store.rememberLastPlayed(p.show, m.sourceId);
      await _scores?.bump(m.sourceId);
    }
  }

  /// One candidate's whole attempt — title match, episode list, streams — as a
  /// single future, so [perSourceBudget] can cap all three together. Null when
  /// this source simply doesn't have the title or the episode; it throws only
  /// when the source itself failed.
  Future<_Attempt?> _tryCandidate(
    ({ZCanonical show, int episode}) p,
    String sourceId,
    ({String title, String? alt, int? malId}) t, {
    required bool fast,
    required void Function() onTitleMatch,
    required void Function(SweepReason) onMiss,
    String category = 'sub',
  }) async {
    final match = await _matcher.matchOn(
      p.show,
      sourceId,
      title: t.title,
      altTitle: t.alt,
      malId: t.malId,
      metadataAliases: await _aliasesFor(p.show),
    );
    if (match == null) {
      debugPrint('[playback] _resolve · $sourceId → no title match');
      onMiss(SweepReason.noTitleMatch);
      return null;
    }
    onTitleMatch();

    final srcEp = await _selectEpisode(
      await _sources.episodes(
        match.showUrl,
        sourceId: match.sourceId,
        category: category,
      ),
      p,
    );
    if (srcEp == null) {
      debugPrint(
        '[playback] _resolve · $sourceId → episode ${p.episode} not found',
      );
      onMiss(SweepReason.episodeMissing);
      return null;
    }

    final streams = await _sources.sources(
      srcEp.url,
      sourceId: match.sourceId,
      fast: fast,
    );
    if (streams.isEmpty) {
      debugPrint(
        '[playback] _resolve · $sourceId → 0 streams for ep ${p.episode}',
      );
      onMiss(SweepReason.noStreams);
      return null;
    }
    // ClearCut: only accept a source whose links actually answer like video,
    // so auto-find moves on to the next source instead of handing the player
    // dead links.
    final live = await _probe.liveStreams(
      streams,
      // Playback starts on the first confirmed link; late mirrors still
      // arrive through progressive events and polling. A download passes
      // fast:false and keeps the full window so no mirror is missed.
      firstHitGrace: fast ? fastFirstHitGrace : null,
    );
    if (live.isEmpty) {
      debugPrint(
        '[playback] _resolve · $sourceId → ${streams.length} streams for '
        'ep ${p.episode}, none playable — trying the next source',
      );
      onMiss(SweepReason.noStreams);
      return null;
    }
    return _Attempt(
      match: match,
      episodeUrl: srcEp.url,
      streams: enrichStreams(live),
    );
  }

  String? _rememberedPlaybackSource(ZCanonical c, List<String> ordered) {
    if (ordered.isEmpty ||
        (c.kind == ZKind.manga || c.kind == ZKind.novel) ||
        _matcher.sourceForTitle(c) != null) {
      return null;
    }
    final last = _store.lastPlayed(c);
    if (last == null || ordered.first != last) return null;
    final match = _store.get(c, last);
    return match != null && match.showUrl.isNotEmpty ? last : null;
  }

  /// Try the remembered source without starting unrelated provider requests.
  Iterable<List<String>> _candidateWaves(
    List<String> ordered, {
    bool firstAlone = false,
    int? waveSize,
  }) sync* {
    final size = waveSize ?? sweepWaveSize;
    var start = 0;
    if (firstAlone && ordered.isNotEmpty) {
      yield [ordered.first];
      start = 1;
    }
    for (; start < ordered.length; start += size) {
      yield ordered.skip(start).take(size).toList();
    }
  }

  List<String> _orderedCandidates(ZCanonical c, {bool allEligible = false}) {
    final all = _candidates(c.kind);
    if (all.isEmpty) return const [];

    final explicit = _matcher.sourceForTitle(c);
    final ids = all
        .map((s) => s.id)
        .where((id) => id == explicit || !isAutoResolveBlocked(id))
        .toSet()
        .toList();
    final pinned = _matcher.pinnedSource(c);
    final last = _store.lastPlayed(c);
    final preferred = _prefs.get(c.kind);

    int rank(String id) {
      if (id == pinned) return 0;
      if (id == last) return 1;
      if (id == preferred) return 2;
      return 3 + _healthRank(id);
    }

    // Position in the incoming list IS the user's Source Priority order (see
    // `orderedCandidates` in zmode_module). Dart's List.sort is only stable
    // below 32 elements — past that it switches to quicksort — and a real
    // library has more candidates than that, so ranking without an explicit
    // positional tiebreak silently scrambled the priority the user set.
    final position = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    final sorted = ids.toList()
      ..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        return byRank != 0 ? byRank : position[a]!.compareTo(position[b]!);
      });
    // Bounded by the SAME number the Source Priority screen shows. It used to
    // cap only the title-match sweep, so "Try the top 3 sources" still asked
    // all 32 here — the setting meant one thing on that screen and another in
    // the player, which makes it not a setting.
    //
    // A pinned source and the last one that played rank 0 and 1 above, so the
    // sources most likely to work are inside any cap, however small.
    //
    // The cost, deliberately taken: set it low and if those few serve dead
    // links the episode does not play, even though a source further down
    // would have. The failure sheet says only the top sources were checked,
    // and the slider is the fix. A hidden floor here would put the lie back.
    final cap = _sweepCap(c.kind);
    // `all` is a sentinel, not a count: `take(-1)` would hand back an empty
    // list and make "scan everything" the one setting that plays nothing.
    final capped = allEligible || cap == SourceOrderPrefs.allSourcesCap
        ? sorted
        : sorted.take(cap).toList();
    // FrameXTV ships in the APK but is not necessarily in the user's Source
    // Priority list. Append it as a last resort AFTER the cap: it can rescue a
    // sweep where every chosen source failed, without ever jumping the queue.
    return withAutomaticFallbacks([
      for (final id in capped) (id: id, name: _sources.displayName(id)),
    ], c.kind).map((s) => s.id).toList();
  }

  /// How many sources a sweep may walk, from the user's Source Priority
  /// setting. Falls back to the whole list where that store is not registered
  /// — several tests build this resolver without DI, and bounding them to a
  /// number they never set would change what they are testing.
  int _sweepCap(ZKind kind) => sl.isRegistered<SourceOrderPrefs>()
      ? sl<SourceOrderPrefs>().cap(kind)
      : 1 << 30;

  int _healthRank(String id) => switch (_health.statusOf(id)) {
    SourceHealth.ok => 0,
    SourceHealth.slow => 1,
    SourceHealth.dead => 2,
  };
}

/// One candidate's successful attempt, before it is promoted to the sweep's
/// answer. Separate from [ResolvedPlayback] because it carries only what the
/// candidate itself produced — the show/episode are the sweep's to add.
class _Attempt {
  const _Attempt({
    required this.match,
    required this.episodeUrl,
    required this.streams,
  });
  final SourceMatch match;
  final String episodeUrl;
  final List<VideoSource> streams;
}

/// One source's answer while [PlaybackResolver.probeEach] walks the list.
class SourceProbe {
  const SourceProbe({
    required this.sourceId,
    required this.name,
    this.pending = false,
    this.checking = false,
    this.skipped = false,
    this.episodeUrl,
    this.match,
    this.playable = false,
  });

  final String sourceId;
  final String name;

  /// Queued but not reached yet. Never emitted by [PlaybackResolver.probeEach]
  /// — the sheet seeds its list with these from [candidatesForEpisode] so the
  /// whole queue is visible from the first frame.
  final bool pending;

  /// Emitted before the work starts, so the row can show what's happening.
  final bool checking;

  /// Never asked: Cloudflare-blocked, marked unhealthy, or over budget too
  /// recently. Reported rather than hidden — "not asked" is not "hasn't got it".
  final bool skipped;

  final String? episodeUrl;
  final SourceMatch? match;

  /// At least one of this source's stream links answered like video when Auto
  /// Find checked it. A source can [hasEpisode] while this is false — it lists
  /// the title but hands out dead/expired links, which is exactly why Play used
  /// to fail right after a "found" result.
  final bool playable;

  /// This source lists the episode. See [playable] for whether its links work.
  bool get hasEpisode => episodeUrl != null;
}
