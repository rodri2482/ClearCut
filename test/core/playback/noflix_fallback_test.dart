import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/noflix_fallback.dart';

void main() {
  test('uses exact TV episode and maps direct streams and subtitles', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          expect(request.queryParameters, {
            'id': '42',
            'type': 'tv',
            'season': '2',
            'episode': '1',
          });
          handler.resolve(
            Response(
              requestOptions: request,
              data: {
                'success': true,
                'sources': [
                  {'url': 'https://video.example/manifest', 'type': 'hls'},
                  {'url': 'https://video.example/manifest', 'type': 'hls'},
                  {'url': 'https://video.example/embed/42', 'type': 'iframe'},
                  {'url': 'file:///data/video.mp4', 'type': 'mp4'},
                ],
                'subtitles': [
                  {
                    'url': 'https://subs.example/track',
                    'lang': 'en',
                    'format': 'vtt',
                  },
                ],
              },
            ),
          );
        },
      ),
    );
    final result = await NoFlixFallback(dio).resolve(
      tmdbId: 42,
      isTv: true,
      episode: const Episode(
        id: '11',
        title: 'S2 · E1',
        url: '',
        number: 11,
        season: 2,
      ),
    );
    expect(result, hasLength(1));
    expect(result.single.container, SourceContainer.hls);
    expect(result.single.subtitles.single.lang, 'en');
  });

  test('does not guess TV numbering from an absolute episode number', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (_, _) {
          fail('Must not request a guessed episode');
        },
      ),
    );
    expect(
      await NoFlixFallback(dio).resolve(
        tmdbId: 42,
        isTv: true,
        episode: const Episode(
          id: '11',
          title: 'Episode 11',
          url: '',
          number: 11,
        ),
      ),
      isEmpty,
    );
  });
}
