import 'package:dio/dio.dart';

import '../models/provider_info.dart';

/// Short, displayable age rating for a title.
///
/// Anime ratings come from Jikan's free public API (the MyAnimeList data set) —
/// no key, and only fetched on the detail screen. Movies/TV fall back to the
/// "adult" flag already present in TMDB metadata. Everything fails soft: a
/// missing rating simply means no badge, never a broken detail page.
class AgeRatingService {
  AgeRatingService(this._dio);
  final Dio _dio;

  static const String _jikan = 'https://api.jikan.moe/v4/anime';
  final Map<String, String?> _cache = {};

  Future<String?> label({
    required String title,
    String? englishTitle,
    required ProviderType type,
    required bool isAdult,
    int? malId,
  }) async {
    if (type == ProviderType.anime) {
      final fromJikan = await _jikanRating(
        title: title,
        englishTitle: englishTitle,
        malId: malId,
      );
      if (fromJikan != null) return fromJikan;
    }
    return isAdult ? '18+' : null;
  }

  Future<String?> _jikanRating({
    required String title,
    String? englishTitle,
    int? malId,
  }) async {
    final key = malId != null ? 'id:$malId' : (englishTitle ?? title);
    if (_cache.containsKey(key)) return _cache[key];

    String? rating;
    try {
      final query = malId != null
          ? '$_jikan/$malId'
          : '$_jikan?q=${Uri.encodeComponent(englishTitle ?? title)}&limit=1';
      final res = await _dio.get<dynamic>(
        query,
        options: Options(receiveTimeout: const Duration(seconds: 6)),
      );
      final data = res.data;
      final item = data is Map
          ? (data['data'] is List && (data['data'] as List).isNotEmpty
                ? (data['data'] as List).first
                : data['data'])
          : null;
      if (item is Map) rating = normalize(item['rating'] as String?);
    } catch (_) {
      rating = null;
    }
    _cache[key] = rating;
    return rating;
  }

  /// "R - 17+ (violence & profanity)" → "R", "PG-13 - Teens 13 or older" →
  /// "PG-13". Unknown values are dropped rather than shown as noise.
  static String? normalize(String? raw) {
    if (raw == null) return null;
    final value = raw.trim();
    if (value.isEmpty) return null;
    final upper = value.toUpperCase();
    for (final prefix in const ['PG-13', 'R+', 'PG', 'G', 'R']) {
      if (upper.startsWith(prefix)) return prefix;
    }
    return null;
  }
}
