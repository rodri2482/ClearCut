import '../models/video_source.dart';
import 'source_selection.dart';
import 'subtitle_language.dart';

/// Fills in the language and quality fields that providers frequently leave
/// empty, using the tags they DO send (label, quality, subtitle labels).
///
/// This is what makes a source's English and other-language variants, plus
/// its 480p/720p/1080p renditions, show up as separate selectable rows when
/// the provider itself only sent a file name. Nothing is overwritten: an
/// explicit value from the provider always wins.
List<VideoSource> enrichStreams(List<VideoSource> sources) => [
  for (final s in sources) _enrich(s),
];

VideoSource _enrich(VideoSource s) {
  final text = [s.quality ?? '', s.label ?? '', s.audioLang ?? ''].join(' ');

  var audioLang = s.audioLang;
  if (audioLang == null || audioLang.trim().isEmpty) {
    for (final lang in kSubtitleLanguages) {
      if (matchesSourceLang(text, lang)) {
        audioLang = lang.iso1;
        break;
      }
    }
  }

  var quality = s.quality;
  if (quality == null ||
      quality.trim().isEmpty ||
      resolutionPx(quality) == null) {
    final m = RegExp(
      r'(2160|1080|720|480|360|240)\s*p?',
      caseSensitive: false,
    ).firstMatch(text);
    if (m != null) {
      quality = '${m.group(1)}p';
    } else if (RegExp(r'\b4k\b', caseSensitive: false).hasMatch(text)) {
      quality = '4K';
    }
  }

  final subtitles = <Subtitle>[];
  for (final sub in s.subtitles) {
    var lang = sub.lang;
    if (lang.trim().isEmpty) {
      for (final candidate in kSubtitleLanguages) {
        if (matchesSourceLang(sub.label ?? '', candidate)) {
          lang = candidate.iso1;
          break;
        }
      }
    }
    subtitles.add(
      Subtitle(
        url: sub.url,
        lang: lang,
        label: sub.label ?? lang,
        format: sub.format,
        providerName: sub.providerName,
        isDefault: sub.isDefault,
      ),
    );
  }

  return VideoSource(
    url: s.url,
    quality: quality,
    label: s.label,
    container: s.container,
    headers: s.headers,
    kind: s.kind,
    audioLang: audioLang,
    subtitles: subtitles.isEmpty ? s.subtitles : subtitles,
    subtitleSkewSeconds: s.subtitleSkewSeconds,
    subtitleSkewAfterSeconds: s.subtitleSkewAfterSeconds,
    proxyUrl: s.proxyUrl,
    torrentFileIndex: s.torrentFileIndex,
    bingeGroup: s.bingeGroup,
    drmKid: s.drmKid,
    drmKey: s.drmKey,
  );
}
