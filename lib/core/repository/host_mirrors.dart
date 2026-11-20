import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

/// A per-source pool of interchangeable base domains, with automatic rotation.
///
/// Extensions die by domain, not by code: a plugin that resolved its host six
/// months ago keeps pointing at a site that now 403s or redirects to a parking
/// page. The user usually knows the mirror (`.to`, `.gg`, `www2.`…), but typing
/// a new one on every outage is a chore, and a single override can't survive
/// the next move.
///
/// This store keeps an ORDERED pool per source. The head is the active mirror;
/// the app uses it wherever it already honours a manual override ("open in
/// browser" and the Cloudflare solve). After two consecutive hard failures the
/// head rotates to the back, so the next attempt tries a different domain
/// without any user action.
///
/// Deliberately narrow, exactly like [SourceDomainOverrides]: this changes the
/// domain the APP targets, never where the extension itself fetches from.
class HostMirrors {
  HostMirrors._(this._box);

  static const String boxName = 'host_mirrors';

  /// How many consecutive hard failures a source gets before rotating. Two,
  /// not one: a single 5xx is usually the site itself, not the mirror.
  static const int failuresBeforeRotate = 2;

  /// A pool longer than this is not a mirror list, it's a mistake.
  static const int maxMirrors = 6;

  static Future<HostMirrors> open() async =>
      HostMirrors._(await openBoxSafely<String>(boxName));

  final Box<String> _box;

  /// Consecutive failures per source. In-memory only: an app restart is a
  /// legitimate "try the best mirror again" reset.
  final Map<String, int> _failures = <String, int>{};

  /// The stored pool for [sourceId], active mirror first.
  List<String> mirrors(String sourceId) {
    final raw = _box.get(sourceId);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [
        for (final v in list)
          if (v is String && v.trim().isNotEmpty) v,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// The mirror to use right now, or null when the user has set none.
  String? active(String sourceId) {
    final list = mirrors(sourceId);
    return list.isEmpty ? null : list.first;
  }

  bool hasPool(String sourceId) => mirrors(sourceId).length > 1;

  /// Replaces the pool with [urls]. Blank entries are dropped, duplicates
  /// collapsed, order preserved (first = active), length capped.
  Future<void> setMirrors(String sourceId, Iterable<String> urls) async {
    final seen = <String>{};
    final cleaned = <String>[];
    for (final raw in urls) {
      final norm = normalize(raw);
      if (norm == null || !seen.add(norm)) continue;
      cleaned.add(norm);
      if (cleaned.length >= maxMirrors) break;
    }
    _failures.remove(sourceId);
    if (cleaned.isEmpty) {
      await _box.delete(sourceId);
    } else {
      await _box.put(sourceId, jsonEncode(cleaned));
    }
  }

  Future<void> clear(String sourceId) async {
    _failures.remove(sourceId);
    await _box.delete(sourceId);
  }

  /// Moves the active mirror to the back and returns the new head.
  ///
  /// Returns null when the pool has fewer than two entries — there is nothing
  /// to rotate to, and pretending otherwise would just churn the same url.
  Future<String?> advance(String sourceId) async {
    final list = mirrors(sourceId);
    if (list.length < 2) return null;
    final rotated = [...list.skip(1), list.first];
    _failures[sourceId] = 0;
    await _box.put(sourceId, jsonEncode(rotated));
    return rotated.first;
  }

  /// Records one hard failure for [sourceId] (timeout, error, blocked).
  ///
  /// Rotates once [failuresBeforeRotate] is reached, then starts counting
  /// again. Returns the new active mirror when it rotated, else null.
  Future<String?> noteFailure(String sourceId) async {
    if (mirrors(sourceId).length < 2) return null;
    final next = (_failures[sourceId] ?? 0) + 1;
    if (next < failuresBeforeRotate) {
      _failures[sourceId] = next;
      return null;
    }
    return advance(sourceId);
  }

  /// A response — even an empty one — means the domain is alive. Reset the
  /// counter so the next two failures are what trigger a rotation.
  void noteSuccess(String sourceId) {
    _failures.remove(sourceId);
  }

  /// Same rules as [SourceDomainOverrides.normalize]: adds a missing scheme,
  /// drops a trailing slash, rejects anything that isn't a host.
  static String? normalize(String raw) {
    var v = raw.trim();
    if (v.isEmpty) return null;
    if (!v.startsWith('http://') && !v.startsWith('https://')) {
      v = 'https://$v';
    }
    final uri = Uri.tryParse(v);
    if (uri == null || uri.host.isEmpty) return null;
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }
}
