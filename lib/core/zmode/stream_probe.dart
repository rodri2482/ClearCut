import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/video_source.dart';

/// ClearCut: checks that a source's stream links actually answer like video
/// before they are accepted or handed to the player.
///
/// Without this, auto-find took the first source that returned *any* links.
/// Many sources hand back dead links, HTML error/embed pages or blocked
/// streams, so the player failed ("couldn't load this episode") while a
/// source further down the list would have played.
///
/// HLS is followed down to a real video segment: a master playlist often loads
/// while its variant playlists or segments are blocked (wrong Referer, expired
/// token, geo-block), and only the segment answers that honestly.
class StreamProbe {
  StreamProbe({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 4),
              receiveTimeout: const Duration(seconds: 5),
              followRedirects: true,
              maxRedirects: 5,
              responseType: ResponseType.bytes,
              validateStatus: (_) => true,
            ),
          );

  final Dio _dio;

  /// Links checked per source, all in parallel. Links beyond this are dropped
  /// rather than passed on unchecked: an unchecked link is exactly what the
  /// player used to land on and fail.
  static const int maxProbed = 16;

  /// The streams worth handing to the player — only links that answered like
  /// video, in their original order. Empty means: try the next source.
  ///
  /// [budget] caps the whole pass. It exists for replaying a remembered
  /// episode: the links were checked when they were saved, and waiting the
  /// full timeout on a slow host would spend the head start the memory bought.
  /// Links still unanswered at the cap are dropped unless
  /// [trustUnchecked] is set, which treats them as playable rather than
  /// proven dead — the right call for a saved link that already worked once.
  Future<List<VideoSource>> liveStreams(
    List<VideoSource> streams, {
    Duration? budget,
    bool trustUnchecked = false,
  }) async {
    if (streams.isEmpty) return streams;
    final probed = streams.take(maxProbed).toList();
    final alive = List<bool?>.filled(probed.length, null);
    final done = Completer<void>();
    var finished = 0;
    Timer? grace;
    Timer? cap;

    void finish() {
      grace?.cancel();
      cap?.cancel();
      if (!done.isCompleted) done.complete();
    }

    if (budget != null) cap = Timer(budget, finish);

    for (var i = 0; i < probed.length; i++) {
      isAlive(probed[i]).then((ok) {
        alive[i] = ok;
        finished++;
        if (finished == probed.length) {
          finish();
        } else if (ok) {
          // ClearCut: once one link is confirmed, wait only briefly for the
          // rest instead of for the slowest dead link's full timeout.
          grace ??= Timer(firstHitGrace, finish);
        }
      });
    }
    await done.future;
    final live = [
      for (var i = 0; i < probed.length; i++)
        if (alive[i] == true) probed[i],
    ];
    if (live.isNotEmpty || !trustUnchecked) return live;
    // Nothing confirmed within the cap. Saved links that have not answered
    // "no" are handed over; one that answered an error or a web page is not.
    return [
      for (var i = 0; i < probed.length; i++)
        if (alive[i] != false) probed[i],
    ];
  }

  /// How long to keep waiting for other links after the first one passes.
  static const Duration firstHitGrace = Duration(milliseconds: 1200);

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

  /// [depth] counts HLS hops: master → variant playlist → segment.
  Future<bool> _probe(
    String url,
    Map<String, String>? headers, {
    int depth = 0,
  }) async {
    try {
      final playlist = depth > 0 || _looksLikePlaylist(url);
      final r = await _dio.get<List<int>>(
        url,
        options: Options(
          // Playlists are small text files and must be read whole; media only
          // needs its first bytes.
          headers: playlist
              ? {...?headers}
              : {...?headers, 'Range': 'bytes=0-4095'},
        ),
      );
      final code = r.statusCode ?? 0;
      if (code < 200 || code >= 400) {
        debugPrint('[probe] HTTP $code · $url');
        return false;
      }
      final bytes = r.data ?? const <int>[];
      final text = utf8
          .decode(
            bytes.length > 65536 ? bytes.sublist(0, 65536) : bytes,
            allowMalformed: true,
          )
          .trimLeft();
      if (text.startsWith('#EXTM3U')) {
        return depth >= 2 ? true : _probeHls(url, text, headers, depth);
      }
      final type = (r.headers.value('content-type') ?? '').toLowerCase();
      // A web page instead of video: an embed page, captcha or error page.
      if (type.contains('text/html') ||
          text.startsWith('<!DOCTYPE') ||
          text.startsWith('<html')) {
        debugPrint('[probe] got a web page, not video · $url');
        return false;
      }
      return bytes.isNotEmpty;
    } catch (e) {
      debugPrint('[probe] failed · $url · $e');
      return false;
    }
  }

  /// Follows an HLS playlist one level down: a master playlist to its first
  /// variant, a media playlist to its first segment.
  Future<bool> _probeHls(
    String url,
    String body,
    Map<String, String>? headers,
    int depth,
  ) async {
    final lines = const LineSplitter().convert(body);
    String? next;
    var afterTag = false;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-STREAM-INF') || line.startsWith('#EXTINF')) {
        afterTag = true;
        continue;
      }
      if (line.startsWith('#')) continue;
      if (afterTag) {
        next = line;
        break;
      }
    }
    // A playlist with nothing playable in it is not a stream.
    if (next == null) {
      debugPrint('[probe] HLS playlist lists nothing · $url');
      return false;
    }
    final target = Uri.parse(url).resolve(next).toString();
    return _probe(target, headers, depth: depth + 1);
  }

  static bool _looksLikePlaylist(String url) =>
      (Uri.tryParse(url)?.path ?? url).toLowerCase().endsWith('.m3u8');
}

/// A probe that trusts every link — the pre-ClearCut behaviour. Used by tests
/// whose fake sources return placeholder URLs.
class TrustingStreamProbe extends StreamProbe {
  TrustingStreamProbe() : super(dio: Dio());

  @override
  Future<List<VideoSource>> liveStreams(
    List<VideoSource> streams, {
    Duration? budget,
    bool trustUnchecked = false,
  }) async => streams;
}
