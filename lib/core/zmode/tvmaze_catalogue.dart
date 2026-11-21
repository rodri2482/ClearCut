import 'package:dio/dio.dart';

import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import 'metadata_filters.dart';
import 'video_catalogue.dart';
import 'zmode_ids.dart';

/// A GET that returns decoded TVmaze JSON (a Map or a List). Injected so tests
/// don't need the network; [dioGet] is the production transport.
typedef TvmazeGet = Future<dynamic> Function(String path);

/// Free, key-free TV metadata from TVMaze.
///
/// It intentionally implements [VideoCatalogue] and stays search/detail-only:
/// no home rows (those stay with the user's chosen provider), and episodes are
/// built inside [detail] because the video path paints them from metadata
/// before the matched playback source overlays its own list. All ids are
/// `tvmaze:<n>` under [ZKind.tv], so playback still resolves through the normal
/// source sweep.
class TvmazeCatalogue implements VideoCatalogue {
  TvmazeCatalogue(this._get);
  final TvmazeGet _get;

  static const String base = 'https://api.tvmaze.com';

  static TvmazeGet dioGet(Dio dio) => (path) async {
    try {
      final r = await dio.get<dynamic>('$base$path');
      return r.data;
    } catch (_) {
      return null;
    }
  };

  @override
  Future<List<HomeSection>> home() async => const [];

  @override
  Future<List<MediaItem>> browseRow(String rowId, int page) async => const [];

  @override
  bool get supportsFilters => false;

  static String _strip(String? html) => (html ?? '')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static int? _tmdbId(Map m) {
    final ext = m['externals'];
    if (ext is! Map) return null;
    return int.tryParse('${ext['themoviedb'] ?? ''}');
  }

  static String? _imdbId(Map m) {
    final ext = m['externals'];
    if (ext is! Map) return null;
    final v = ext['imdb'];
    return v is String && v.isNotEmpty ? v : null;
  }

  static MediaItem _item(Map m) {
    var id = m['id'];
    if (id is! int) {
      // /search/shows wraps the show; /singlesearch/shows does not.
      final wrapped = m['show'];
      if (wrapped is Map) return _item(wrapped);
      id = null;
    }
    if (id == null) {
      // Return a sentinel; callers filter it out.
      return MediaItem(
        id: '',
        title: '',
        url: '',
        type: ProviderType.movie,
        sourceId: ZmodeIds.sourceId,
      );
    }
    final c = ZCanonical(ZKind.tv, 'tvmaze:$id');
    final image = m['image'];
    return MediaItem(
      id: c.id,
      title: (m['name'] as String?) ?? '',
      cover: image is Map ? image['original'] as String? : null,
      url: ZmodeIds.showUrl(c),
      type: ProviderType.movie,
      sourceId: ZmodeIds.sourceId,
      tmdbId: _tmdbId(m),
      imdbId: _imdbId(m),
      tmdbIsTv: true,
      genres: (m['genres'] as List? ?? const [])
          .whereType<String>()
          .toList()
          .take(6)
          .toList(),
    );
  }

  @override
  Future<List<MediaItem>> search(String q) => searchFiltered(q);

  @override
  Future<List<MediaItem>> searchFiltered(
    String q, {
    MetaFilters? filters,
    int page = 1,
  }) async {
    if (q.trim().isEmpty) return const [];
    final encoded = Uri.encodeComponent(q.trim());
    final single = await _get('/singlesearch/shows?q=$encoded');
    if (single is Map && single['id'] is int) {
      return [_item(single)];
    }
    final data = await _get('/search/shows?q=$encoded');
    if (data is! List) return const [];
    return [
      for (final r in data)
        if (r is Map) _item(r),
    ].where((m) => m.id.isNotEmpty).toList();
  }

  /// Resolve the catalogue id for any canonical we may be handed. TMDB ids
  /// cannot be translated by TVmaze (only IMDb is supported by its lookup), so
  /// those fail here and the repository reports the original provider's error.
  Future<int> _showId(ZCanonical c) async {
    if (c.id.startsWith('tvmaze:')) {
      return int.parse(c.id.substring('tvmaze:'.length));
    }
    if (c.id.startsWith('imdb:')) {
      final data = await _get('/lookup/shows?imdb=${c.id.substring(5)}');
      if (data is Map && data['id'] is int) return data['id'] as int;
    }
    throw StateError('TVmaze has no id for $c');
  }

  @override
  Future<MediaDetail> detail(ZCanonical c) async {
    final id = await _showId(c);
    final show = await _get('/shows/$id');
    if (show is! Map) throw StateError('TVmaze returned nothing for $c');
    final eps = await _get('/shows/$id/episodes');
    final canonical = ZCanonical(ZKind.tv, 'tvmaze:$id');

    final episodes = <Episode>[];
    if (eps is List) {
      var n = 1;
      for (final e in eps) {
        if (e is! Map) continue;
        final number = n++;
        episodes.add(
          Episode(
            id: '${e['id'] ?? number}',
            title: (e['name'] as String?) ?? 'Episode $number',
            number: number.toDouble(),
            url: ZmodeIds.episodeUrl(canonical, number),
          ),
        );
      }
    }

    final image = show['image'];
    final year = (show['premiered'] as String?);
    return MediaDetail(
      id: canonical.id,
      title: (show['name'] as String?) ?? '',
      cover: image is Map ? image['original'] as String? : null,
      url: ZmodeIds.showUrl(canonical),
      description: _strip(show['summary'] as String?),
      status: switch (show['status']) {
        'Running' => MediaStatus.ongoing,
        'Ended' => MediaStatus.completed,
        'Canceled' => MediaStatus.cancelled,
        'To Be Determined' || 'In Development' => MediaStatus.unknown,
        _ => MediaStatus.unknown,
      },
      genres: (show['genres'] as List? ?? const [])
          .whereType<String>()
          .toList(),
      studios: [
        if (show['network'] is Map)
          (show['network'] as Map)['name'] as String? ?? '',
      ].where((s) => s.isNotEmpty).toList(),
      episodes: episodes,
      year: year != null && year.length >= 4 ? year.substring(0, 4) : null,
      type: ProviderType.movie,
      sourceId: ZmodeIds.sourceId,
      tmdbId: _tmdbId(show),
      imdbId: _imdbId(show),
      tmdbIsTv: true,
      // TVmaze rates out of 10; the model stores out of 100.
      score: (show['rating'] is Map)
          ? ((((show['rating'] as Map)['average']) as num?) ?? 0).round() * 10
          : null,
    );
  }
}
