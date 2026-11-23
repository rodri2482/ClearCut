import 'dart:async';

import 'package:hive/hive.dart';

import '../hive/safe_box.dart';
import '../models/video_source.dart';
import 'match_store.dart';

/// The source and links that last played one episode, kept across restarts.
///
/// The resolver's in-memory winner cache already makes a replay instant, but it
/// dies with the process — so the first Play after opening the app paid the
/// whole sweep again for an episode the app had played an hour earlier. This
/// remembers that answer on disk: which source served it, the episode url on
/// that source, and the links that answered at the time.
///
/// The links are NOT trusted blindly on replay. CDNs hand out short-lived
/// tokens, so an old link can be dead. The resolver re-resolves the same source
/// first, then re-probes the saved links; only when both fail does it forget
/// the anchor and sweep from scratch.
class EpisodeAnchor {
  const EpisodeAnchor({
    required this.sourceId,
    required this.episodeUrl,
    required this.match,
    required this.streams,
    required this.at,
  });

  final String sourceId;

  /// The episode url on [sourceId], so a restart can ask that source directly
  /// instead of matching the title and walking its episode list again.
  final String episodeUrl;
  final SourceMatch match;
  final List<VideoSource> streams;
  final DateTime at;

  Map<String, dynamic> toMap() => {
    'sourceId': sourceId,
    'episodeUrl': episodeUrl,
    'match': match.toMap(),
    'streams': [for (final s in streams) s.toJson()],
    'at': at.millisecondsSinceEpoch,
  };

  static EpisodeAnchor? fromMap(dynamic m) {
    if (m is! Map) return null;
    final sourceId = m['sourceId'];
    final episodeUrl = m['episodeUrl'];
    final match = SourceMatch.fromMap(m['match']);
    if (sourceId is! String || episodeUrl is! String || match == null) {
      return null;
    }
    final at = m['at'];
    if (at is! int) return null;
    final streams = <VideoSource>[];
    final raw = m['streams'];
    if (raw is List) {
      for (final s in raw) {
        if (s is! Map) continue;
        try {
          streams.add(VideoSource.fromJson(Map<String, dynamic>.from(s)));
        } catch (_) {
          // One unreadable entry must not throw away the whole anchor.
        }
      }
    }
    if (streams.isEmpty) return null;
    return EpisodeAnchor(
      sourceId: sourceId,
      episodeUrl: episodeUrl,
      match: match,
      streams: streams,
      at: DateTime.fromMillisecondsSinceEpoch(at),
    );
  }
}

/// Per-episode last-known-good playback, keyed `'$zmEpisodeUrl|$category'`.
/// The category is part of the key for the same reason the resolver's winner
/// cache includes it: sub and dub are different episode lists for one episode.
class EpisodeAnchorStore {
  EpisodeAnchorStore._(this._box);
  final Box<Map> _box;

  static const String boxName = 'zmode_episode_anchors';

  static Future<EpisodeAnchorStore> open() async =>
      EpisodeAnchorStore._(await openBoxSafely<Map>(boxName));

  /// An anchor older than this is more likely to be a dead token than a head
  /// start. A day is long enough for "watch the rest tomorrow", short enough
  /// that stale links don't pile up.
  static const Duration maxAge = Duration(hours: 18);

  /// Bounded so the box cannot grow with every episode ever played. Oldest
  /// entries are dropped first.
  static const int maxEntries = 600;

  static String _key(String zmEpisodeUrl, String category) =>
      '$zmEpisodeUrl|$category${zmEpisodeUrl.startsWith('zm://tv/') || zmEpisodeUrl.startsWith('zm://movie/') || zmEpisodeUrl.startsWith('zm://anime/') ? '|2' : ''}';

  EpisodeAnchor? get(String zmEpisodeUrl, String category) {
    final key = _key(zmEpisodeUrl, category);
    final anchor = EpisodeAnchor.fromMap(_box.get(key));
    if (anchor == null) return null;
    if (DateTime.now().difference(anchor.at) > maxAge) {
      unawaited(_box.delete(key));
      return null;
    }
    return anchor;
  }

  Future<void> save(
    String zmEpisodeUrl,
    String category,
    EpisodeAnchor anchor,
  ) async {
    await _box.put(_key(zmEpisodeUrl, category), anchor.toMap());
    if (_box.length <= maxEntries) return;
    // Prune the oldest by their own timestamp rather than insertion order —
    // a refreshed anchor is written again, and an in-place update can land
    // anywhere in Hive's key order.
    final entries = _box.toMap().entries.toList()
      ..sort((a, b) => _atOf(a.value).compareTo(_atOf(b.value)));
    final drop = entries.length - maxEntries;
    if (drop > 0) {
      await _box.deleteAll(entries.take(drop).map((e) => e.key));
    }
  }

  Future<void> remove(String zmEpisodeUrl, String category) =>
      _box.delete(_key(zmEpisodeUrl, category));

  /// Drops every anchor whose key starts with [prefix] — used when the viewer
  /// switches a title's source, which invalidates that show's whole memory.
  Future<void> removePrefix(String prefix) async {
    final doomed = _box.keys
        .where((k) => k is String && k.startsWith(prefix))
        .toList();
    if (doomed.isNotEmpty) await _box.deleteAll(doomed);
  }

  Future<void> clear() => _box.clear();

  static int _atOf(dynamic value) {
    if (value is Map && value['at'] is int) return value['at'] as int;
    return 0;
  }
}
