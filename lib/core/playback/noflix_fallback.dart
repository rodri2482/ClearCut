import 'dart:async';

import 'package:dio/dio.dart';

import '../models/episode.dart';
import '../models/video_source.dart';
import '../zmode/zmode_ids.dart';

/// NoFlix uses FrameXTV embeds. Fetch their direct media rather than loading
/// the embed and its page scripts in ClearCut.
class NoFlixFallback {
  NoFlixFallback(this._dio);

  static final instance = NoFlixFallback(
    Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 8),
      ),
    ),
  );

  static final _episodeTitle = RegExp(r'^S(\d+)\s*·\s*E(\d+)$');
  final Dio _dio;

  Future<List<VideoSource>> resolveTitle({
    required ZCanonical? canonical,
    required int? tmdbId,
    required bool isTv,
    required Episode episode,
  }) {
    if (canonical != null &&
        canonical.kind != ZKind.movie &&
        canonical.kind != ZKind.tv) {
      return Future.value(const []);
    }
    final id = canonical?.id;
    final canonicalId = id != null && id.startsWith('tmdb:')
        ? int.tryParse(id.substring('tmdb:'.length))
        : null;
    return resolve(
      tmdbId: canonicalId ?? tmdbId ?? 0,
      isTv: canonical == null ? isTv : canonical.kind == ZKind.tv,
      episode: episode,
    );
  }

  Future<List<VideoSource>> resolve({
    required int tmdbId,
    required bool isTv,
    required Episode episode,
  }) async {
    if (tmdbId <= 0) return const [];
    final query = {'id': '$tmdbId', 'type': isTv ? 'tv' : 'movie'};
    if (isTv) {
      final coordinates = _episodeTitle.firstMatch(episode.title.trim());
      final season = int.tryParse(coordinates?.group(1) ?? '');
      final number = int.tryParse(coordinates?.group(2) ?? '');
      if (season == null ||
          number == null ||
          number <= 0 ||
          (episode.season != null && episode.season != season)) {
        return const [];
      }
      query.addAll({'season': '$season', 'episode': '$number'});
    }

    try {
      final response = await _dio
          .get<Object?>(
            'https://api.framextv.tech/api/stream',
            queryParameters: query,
          )
          .timeout(const Duration(seconds: 12));
      final body = response.data;
      if (body is! Map || body['success'] != true) return const [];

      final subtitles = <Subtitle>[];
      for (final track in _entries(body['subtitles'])) {
        final url = _mediaUrl(track['url']);
        final lang = _string(track['lang']) ?? _string(track['language']);
        if (url == null || lang == null) continue;
        subtitles.add(
          Subtitle(
            url: url,
            lang: lang,
            label: _string(track['label']),
            format: _string(track['format']),
            isDefault: track['isDefault'] == true,
          ),
        );
      }

      final seen = <String>{};
      final streams = <VideoSource>[];
      for (final source in _entries(body['sources'])) {
        final container = switch (_string(source['type'])?.toLowerCase()) {
          'hls' => SourceContainer.hls,
          'mp4' => SourceContainer.mp4,
          _ => null,
        };
        final url = _mediaUrl(source['url']);
        if (container == null || url == null || !seen.add(url)) continue;
        final server = _string(source['server']);
        streams.add(
          VideoSource(
            url: url,
            container: container,
            label: server == null ? 'NoFlix' : 'NoFlix · $server',
            quality: _string(source['quality']),
            subtitles: subtitles,
          ),
        );
      }
      return streams;
    } on DioException {
      return const [];
    } on TimeoutException {
      return const [];
    }
  }

  static Iterable<Map> _entries(Object? value) =>
      value is List ? value.whereType<Map>() : const [];

  static String? _string(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static String? _mediaUrl(Object? value) {
    final url = _string(value);
    final uri = url == null ? null : Uri.tryParse(url);
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? url
        : null;
  }
}
