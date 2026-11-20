import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/video_source.dart';

/// ClearCut: checks that a source's stream links actually answer like video
/// before auto-find accepts that source.
///
/// Without this, auto-find took the first source that returned *any* links.
/// Many sources hand back dead links, HTML error/embed pages or blocked
/// streams, so the player failed ("couldn't load this episode") while a
/// source further down the list would have played.
class StreamProbe {
  StreamProbe({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 6),
              followRedirects: true,
              maxRedirects: 5,
              responseType: ResponseType.bytes,
              validateStatus: (_) => true,
            ),
          );

  final Dio _dio;

  /// How many links are probed per source. The rest are kept unprobed (they
  /// are usually other qualities of the same mirror).
  static const int maxProbed = 6;

  /// The streams worth handing to the player, best first: the probed links
  /// that answered, followed by any links that were not probed. Empty when
  /// every probed link is dead, which means: try the next source.
  Future<List<VideoSource>> liveStreams(List<VideoSource> streams) async {
    if (streams.isEmpty) return streams;
    final probed = streams.take(maxProbed).toList();
    final results = await Future.wait(probed.map(isAlive));
    final alive = [
      for (var i = 0; i < probed.length; i++)
        if (results[i]) probed[i],
    ];
    if (alive.isEmpty) return const [];
    return [...alive, ...streams.skip(maxProbed)];
  }

  /// True when [s] looks playable. Links that can't be checked over plain
  /// HTTP (torrents, DRM, non-http schemes) are trusted as before.
  Future<bool> isAlive(VideoSource s) async {
    if (s.container == SourceContainer.torrent || s.isDrm) return true;
    if (!s.url.startsWith('http')) return true;
    if (await _probe(s.url, s.headers)) return true;
    // Aniyomi sources carry a local-proxy fallback for Cloudflare-blocked
    // streams; the player switches to it on its own, so it counts.
    final proxy = s.proxyUrl;
    return proxy != null && proxy.isNotEmpty && await _probe(proxy, s.headers);
  }

  Future<bool> _probe(String url, Map<String, String>? headers) async {
    try {
      final r = await _dio.get<List<int>>(
        url,
        options: Options(headers: {...?headers, 'Range': 'bytes=0-2047'}),
      );
      final code = r.statusCode ?? 0;
      if (code < 200 || code >= 400) {
        debugPrint('[probe] HTTP $code · $url');
        return false;
      }
      final bytes = r.data ?? const <int>[];
      final head = utf8
          .decode(bytes.take(512).toList(), allowMalformed: true)
          .trimLeft();
      if (head.startsWith('#EXTM3U')) return true; // HLS playlist
      final type = (r.headers.value('content-type') ?? '').toLowerCase();
      // A web page instead of video: an embed page, captcha or error page.
      if (type.contains('text/html') ||
          head.startsWith('<!DOCTYPE') ||
          head.startsWith('<html')) {
        debugPrint('[probe] got a web page, not video · $url');
        return false;
      }
      return bytes.isNotEmpty;
    } catch (e) {
      debugPrint('[probe] failed · $url · $e');
      return false;
    }
  }
}

/// A probe that trusts every link — the pre-ClearCut behaviour. Used by tests
/// whose fake sources return placeholder URLs.
class TrustingStreamProbe extends StreamProbe {
  TrustingStreamProbe() : super(dio: Dio());

  @override
  Future<List<VideoSource>> liveStreams(List<VideoSource> streams) async =>
      streams;
}
