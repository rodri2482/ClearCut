import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import '../models/media_item.dart';
import '../privacy/incognito_mode.dart';

/// An on-device index of every title ClearCut has already seen.
///
/// The cross-source fan-out is inherently slow: it asks 100+ real sources over
/// the network, and JS providers are serialised behind one call lane. No amount
/// of caching fixes a title you have never searched for. This index does the
/// other half of FrameXTV's trick — it answers from *local* data the moment a
/// key is pressed, for any title the app has seen before (a home row, a search,
/// a browse), even under a different query than the one that surfaced it.
///
/// Scope and safety:
///  * Only titles that came from a real, user-chosen source are indexed. This
///    is a record of what the app already fetched, never a crawler, and never a
///    replacement for the source's own search.
///  * Nothing is stored in incognito mode.
///  * The index is a FIRST-FRAME convenience: live results always replace it.
///  * Matching is a plain substring scan over normalised titles. At the
///    [maxEntries] cap that is a few milliseconds, which is cheaper in memory
///    and far simpler to reason about than an inverted index.
class LocalTitleIndex {
  LocalTitleIndex._(this._box);

  static const String boxName = 'local_title_index';

  /// Upper bound on indexed titles. A device that has browsed for years should
  /// not grow this without limit; the oldest insert is evicted first.
  static const int maxEntries = 5000;

  static Future<LocalTitleIndex> open() async =>
      LocalTitleIndex._(await openBoxSafely<String>(boxName));

  final Box<String> _box;

  /// In-memory mirror of the box, built once on first use. Key is
  /// `sourceId\u0000itemId` so two sources offering the same title both stay
  /// playable from their own source.
  final Map<String, MediaItem> _items = <String, MediaItem>{};

  /// Normalised title text per key, so matching never re-lowercases a title on
  /// every keystroke.
  final Map<String, String> _text = <String, String>{};

  bool _loaded = false;

  static String _key(MediaItem item) => '${item.sourceId}\u0000${item.id}';

  /// Lowercased, punctuation collapsed, single-spaced. Unicode-aware: anime
  /// titles carry macrons and accents that must not split a word.
  static String normalize(String raw) => raw
      .toLowerCase()
      .replaceAll(RegExp(r'[\W_]+', unicode: true), ' ')
      .trim();

  void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    for (final key in _box.keys) {
      final raw = _box.get(key);
      if (raw == null) continue;
      try {
        final item = MediaItem.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
        _items[key] = item;
        _text[key] = _searchTextFor(item);
      } catch (_) {
        // A row written by an older shape — drop it rather than fail the whole
        // index. Losing one cached title is cheap; losing search is not.
        // ignore: unawaited_futures
        _box.delete(key);
      }
    }
  }

  static String _searchTextFor(MediaItem item) {
    final t = StringBuffer(normalize(item.title));
    final alt = item.englishTitle;
    if (alt != null && alt.trim().isNotEmpty) {
      t
        ..write(' ')
        ..write(normalize(alt));
    }
    return t.toString().trim();
  }

  /// Adds [items] to the index. Safe to call with duplicates and with the
  /// hundreds of rows a home screen returns — already-indexed keys are skipped.
  ///
  /// Returns how many titles were newly added.
  int indexItems(Iterable<MediaItem> items) {
    if (IncognitoMode.on) return 0;
    _ensureLoaded();
    var added = 0;
    final writes = <String, String>{};
    for (final item in items) {
      if (item.id.isEmpty || item.title.trim().isEmpty) continue;
      final key = _key(item);
      if (_items.containsKey(key)) continue;
      if (_items.length + writes.length >= maxEntries) break;
      _items[key] = item;
      _text[key] = _searchTextFor(item);
      writes[key] = jsonEncode(item.toJson());
      added++;
    }
    if (writes.isEmpty) return 0;
    // Fire-and-forget: the index is a convenience, and a failed write must
    // never surface as a search error.
    for (final entry in writes.entries) {
      // ignore: unawaited_futures
      _box.put(entry.key, entry.value);
    }
    _prune();
    return added;
  }

  /// Oldest first: Hive preserves insertion order, and a re-put is skipped by
  /// [indexItems], so the head of the box is genuinely the stalest.
  void _prune() {
    final excess = _box.length - maxEntries;
    if (excess <= 0) return;
    for (final key in _box.keys.take(excess).toList()) {
      // ignore: unawaited_futures
      _box.delete(key);
      _items.remove(key);
      _text.remove(key);
    }
  }

  /// Instant matches for [query], best first.
  ///
  /// Ranked the way a person reads results: exact title, then titles that begin
  /// with the query, then titles that contain it. [sourceIds] restricts the
  /// answer to sources the current search is allowed to use, so a disabled
  /// source's leftovers never appear.
  List<MediaItem> search(
    String query, {
    Iterable<String>? sourceIds,
    int limit = 24,
  }) {
    final q = normalize(query);
    if (q.isEmpty) return const [];
    _ensureLoaded();
    final allowed = sourceIds == null ? null : sourceIds.toSet();
    final scored = <({MediaItem item, int score})>[];
    for (final entry in _items.entries) {
      final item = entry.value;
      if (allowed != null && !allowed.contains(item.sourceId)) continue;
      final text = _text[entry.key];
      if (text == null) continue;
      final at = text.indexOf(q);
      if (at < 0) continue;
      // Reward word-start matches over mid-word ones so "slayer" ranks
      // "Demon Slayer" above "Dragonslayer Returns".
      final atWordStart = at == 0 || text[at - 1] == ' ';
      final score = text == q
          ? (atWordStart ? 100 : 60)
          : at == 0
          ? 80
          : atWordStart
          ? 70
          : 40;
      scored.add((item: item, score: score));
    }
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.item.title.length.compareTo(b.item.title.length);
    });
    return [
      for (final s in scored.take(limit)) s.item,
    ];
  }

  int get length {
    _ensureLoaded();
    return _items.length;
  }

  Future<void> clear() async {
    _items.clear();
    _text.clear();
    await _box.clear();
  }
}
