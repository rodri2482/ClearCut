import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import '../models/media_item.dart';
import 'incognito_mode.dart';
import 'source_health_store.dart' show SourceOutcome;

/// Disk-backed search results — ClearCut's version of FrameXTV's React-Query
/// cache.
///
/// FrameXTV feels instant because a repeat search never touches the network:
/// its client keeps results for 5–10 minutes and shows the previous page while
/// refetching. ClearCut had a 3-minute, in-memory-only cache, so every cold
/// start re-queried every source. This store keeps successful per-source
/// results on device so "Demon Slayer" comes back immediately.
///
/// Only successful outcomes ([SourceOutcome.ok] / [SourceOutcome.empty]) are
/// written — a timeout, block or error is never remembered, so a broken source
/// retries on the next search. Nothing is written in incognito mode.
class SearchResultCache {
  static const String boxName = 'search_result_cache';

  /// How long a result stays usable without a live revalidation.
  static const Duration freshFor = Duration(minutes: 5);

  /// Hard eviction age, regardless of freshness.
  static const Duration keepFor = Duration(hours: 6);

  /// Bounds the box: search is per-source, so 214 installed sources × queries
  /// would otherwise grow without limit.
  static const int maxEntries = 600;

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely<String>(boxName);
    }
  }

  Box<String> get _box => Hive.box<String>(boxName);

  /// Reads one cached entry. Returns null on a miss, an expired entry, or a
  /// decode failure (a bad row is dropped rather than crashing search).
  ({List<MediaItem> items, SourceOutcome outcome, DateTime at})? read(
    String key,
  ) {
    final raw = _box.get(key);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final at = DateTime.fromMillisecondsSinceEpoch(map['at'] as int);
      if (DateTime.now().difference(at) > keepFor) {
        // ignore: unawaited_futures
        _box.delete(key);
        return null;
      }
      final items = (map['items'] as List<dynamic>)
          .map((e) => MediaItem.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(growable: false);
      return (
        items: items,
        outcome: SourceOutcome.values.byName(map['outcome'] as String),
        at: at,
      );
    } catch (_) {
      // Corrupt/legacy row — drop it so it can't poison every future search.
      // ignore: unawaited_futures
      _box.delete(key);
      return null;
    }
  }

  bool isFresh(DateTime at) => DateTime.now().difference(at) <= freshFor;

  Future<void> write(
    String key,
    List<MediaItem> items,
    SourceOutcome outcome,
  ) async {
    if (IncognitoMode.on) return;
    if (outcome != SourceOutcome.ok && outcome != SourceOutcome.empty) return;
    final encoded = jsonEncode(<String, dynamic>{
      'at': DateTime.now().millisecondsSinceEpoch,
      'outcome': outcome.name,
      'items': items.map((item) => item.toJson()).toList(),
    });
    await _box.put(key, encoded);
    _prune();
  }

  /// Oldest-inserted first. Hive keeps insertion order on `put`, so updating a
  /// key doesn't move it; that's fine — the 6-hour [keepFor] handles staleness.
  void _prune() {
    final excess = _box.length - maxEntries;
    if (excess <= 0) return;
    for (final key in _box.keys.take(excess).toList()) {
      // ignore: unawaited_futures
      _box.delete(key);
    }
  }

  Future<void> clear() => _box.clear();
}
