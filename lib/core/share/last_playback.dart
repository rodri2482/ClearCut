import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The title that was last playing, so a cold start after the player Activity
/// (or the whole process) was killed can put the viewer back on that series
/// instead of dropping them at Home.
///
/// Stored as a normal share link: the existing open-link handler already knows
/// how to turn one into a Detail route, so there is one navigation path to
/// maintain. A short TTL keeps an old session from hijacking a fresh launch.
class LastPlayback {
  const LastPlayback._();

  static const String key = 'clearcut_last_playback';
  static const Duration ttl = Duration(minutes: 20);

  static Future<void> remember(String link) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        key,
        jsonEncode({'link': link, 'at': DateTime.now().millisecondsSinceEpoch}),
      );
    } catch (_) {
      // Best effort: a full/readonly preferences store must not stop playback.
    }
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (_) {}
  }

  static Future<String?> takeFresh() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) return null;
      await prefs.remove(key); // single use: never resurrect an old session
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final link = decoded['link'];
      final at = decoded['at'];
      if (link is! String || link.isEmpty || at is! int) return null;
      if (DateTime.now().millisecondsSinceEpoch - at > ttl.inMilliseconds) {
        return null;
      }
      return link;
    } catch (_) {
      return null;
    }
  }
}
