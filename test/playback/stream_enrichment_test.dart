import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/stream_enrichment.dart';

void main() {
  test('language and quality are recovered from provider labels', () {
    final raw = VideoSource(
      url: 'https://x/stream',
      label: 'English Dub · 1080p',
      subtitles: const [
        Subtitle(url: 'https://x/en.vtt', lang: '', label: 'English'),
      ],
    );

    final out = enrichStreams([raw]).single;
    expect(out.audioLang, 'en');
    expect(out.quality, '1080p');
    expect(out.subtitles.single.lang, 'en');
  });

  test('explicit provider values are never overwritten', () async {
    final raw = VideoSource(
      url: 'https://x/stream',
      label: 'Japanese 480p',
      quality: '720p',
      audioLang: 'ja',
    );
    final out = enrichStreams([raw]).single;
    expect(out.audioLang, 'ja');
    expect(out.quality, '720p');
  });
}
