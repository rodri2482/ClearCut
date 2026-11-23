import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/zmode/zmode_ids.dart';
import '../../core/zmode/episode_number.dart';
import '../../core/zmode/source_matcher.dart';
import '../../core/zmode/playback_resolver.dart';
import '../../core/di/injector.dart';
import '../../core/stremio/stremio_manager.dart';
import '../../core/stremio/stremio_ref.dart';
import '../../core/stremio/stremio_subtitles.dart';
import '../../core/privacy/incognito_mode.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_record.dart';
import '../downloads/episode_download_source_sheet.dart'
    show matchDownloadEpisode, resolveEpisodeDownloadShowId;
import '../../core/repository/catalogue_repository.dart';
import '../../core/provider/bundled_sources.dart';
import '../../core/discord/discord_rpc.dart';
import '../../core/discord/discord_presence.dart';
import '../../core/share/share_link.dart';
import '../../core/share/last_playback.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/network_quality.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/source_selection.dart';
import '../../core/playback/subtitle_download_service.dart';
import '../../core/playback/subtitle_language.dart';
import '../../core/playback/subtitle_encode_skew.dart';
import '../../core/playback/subtitle_font_stage.dart';
import '../../core/playback/tv_track_helpers.dart';
import '../../core/playback/watch_history.dart';
import '../../core/theme/app_colors.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../core/tracker/simkl_playback_session.dart';
import 'subtitle_font_service.dart';
import 'player_controls_config.dart';
import 'player_engine_fallback.dart';
import 'subtitle_style.dart';
import 'watch_page_info.dart';
import '../detail/cubit/detail_cubit.dart' show seasonOf;

String phoneEpisodeLabel(
  Episode episode, {
  required String showTitle,
  required bool isMovie,
  required int episodeCount,
}) {
  final title = episode.title.trim();
  if (isMovie) {
    if (episodeCount == 1 && showTitle.trim().isNotEmpty) {
      return showTitle.trim();
    }
    return title.isNotEmpty ? title : showTitle;
  }
  final number = episode.number;
  final base = number == null
      ? ''
      : 'Episode ${number % 1 == 0 ? number.toInt() : number}';
  // Many sources title their rows "Episode 1: Asteroid Blues". Keeping that
  // prefix while adding our own number shows "Episode 1 · Episode 1: …".
  final withoutPrefix =
      title
          .replaceFirst(
            RegExp(r'^episode\s*\d+(?:\.\d+)?\s*[:\-–—.]?\s*',
                caseSensitive: false),
            '',
          )
          .trim();
  final displayTitle = withoutPrefix.isEmpty ? title : withoutPrefix;
  final lower = displayTitle.toLowerCase();
  if (displayTitle.isEmpty ||
      lower == base.toLowerCase() ||
      lower == showTitle.trim().toLowerCase()) {
    return base;
  }
  return base.isEmpty ? displayTitle : '$base · $displayTitle';
}

/// Rejects stale sessions and malformed writes before touching saved controls.
PlayerControlsConfig? phoneControlLayoutForSave(
  Map<String, dynamic>? args, {
  required int sessionId,
  required bool playerOpen,
}) {
  if (!playerOpen || args?['sessionId'] != sessionId) return null;
  List<String>? read(String key) {
    final value = args?[key];
    if (value is! List || value.any((item) => item is! String)) return null;
    return value.cast<String>();
  }

  final top = read('top');
  final left = read('left');
  final right = read('right');
  if (top == null || left == null || right == null) return null;
  return PlayerControlsConfig(top: top, left: left, right: right).sanitised();
}

/// Display-only rows retain the original index used by native episode taps.
Map<String, dynamic> phoneWatchPageData({
  required List<Episode> episodes,
  String? showTitle,
  String? showDescription,
  String? cover,
  bool Function(Episode)? isWatched,
  bool isMovie = false,
}) {
  final rows = watchPageEpisodes(
    episodes: episodes,
    currentIndex: -1,
    isMovie: isMovie,
    showTitle: showTitle,
    coverFallback: cover,
    isWatched: isWatched,
  );
  return {
    'isMovie': isMovie,
    'episodes': rows.map((row) {
      final ep = episodes[row.index];
      final header = resolveWatchPageHeader(
        episode: ep,
        showTitle: showTitle,
        showDescription: showDescription,
        isMovie: isMovie,
      );
      return <String, dynamic>{
        'index': row.index,
        'watched': row.watched,
        'heading': row.heading,
        'label': row.label,
        'thumb': row.thumb,
        'meta': row.meta,
        'synopsis': row.synopsis,
        'number': row.number,
        'season': seasonOf(ep),
        'unavailable': row.unavailableReason,
        'title': header.title,
        'subtitle': header.subtitle,
      };
    }).toList(),
  };
}

int? phoneWatchActionIndex(
  Map<String, dynamic>? args, {
  required int sessionId,
  required int episodeCount,
  required bool playerOpen,
}) {
  final index = args?['index'];
  if (!playerOpen ||
      args?['sessionId'] != sessionId ||
      index is! int ||
      index < 0 ||
      index >= episodeCount) {
    return null;
  }
  return index;
}

/// Container → MIME hint. A tokenised url carries no extension, so without an
/// explicit MIME ExoPlayer builds the wrong MediaSource and never starts.
String? phoneMimeFor(VideoSource source) {
  final u = source.url.toLowerCase();
  if (source.container == SourceContainer.hls || u.contains('.m3u8')) {
    return 'application/x-mpegURL';
  }
  if (u.contains('.mpd')) return 'application/dash+xml';
  if (u.contains('.mp4')) return 'video/mp4';
  return null;
}

String phoneSubtitleMime(String? format, String url) {
  final f = (format ?? '').toLowerCase();
  final u = url.toLowerCase();
  if (f == 'vtt' || f == 'webvtt') return 'text/vtt';
  if (f == 'ass' || f == 'ssa') return 'text/x-ssa';
  if (f == 'ttml' || f == 'dfxp') return 'application/ttml+xml';
  if (f == 'srt' || f == 'subrip') return 'application/x-subrip';
  if (u.contains('.vtt')) return 'text/vtt';
  if (u.contains('.ass') || u.contains('.ssa')) return 'text/x-ssa';
  if (u.contains('.ttml') || u.contains('.dfxp')) {
    return 'application/ttml+xml';
  }
  if (u.contains('.srt')) return 'application/x-subrip';
  return 'text/vtt';
}

/// The provider's own name, else the quality, else a number — never blank.
String phoneMirrorLabel(VideoSource src, int i) {
  final l = src.label?.trim();
  if (l != null && l.isNotEmpty) return l;
  final q = src.quality?.trim();
  if (q != null && q.isNotEmpty) return q;
  return 'Server ${i + 1}';
}

const _onlineSubtitleProvider = 'OpenSubtitles';

Map<String, dynamic> _phoneSubtitlePayload(VideoSource source) {
  final online = [
    for (final subtitle in source.subtitles)
      if (subtitle.providerName == _onlineSubtitleProvider) subtitle.url,
  ];
  return <String, dynamic>{
    'subUrls': [for (final s in source.subtitles) s.url],
    'subLangs': [for (final s in source.subtitles) s.lang],
    'subLabels': [for (final s in source.subtitles) s.displayLabel],
    'subFormats': [for (final s in source.subtitles) s.format ?? ''],
    'subDefaults': [for (final s in source.subtitles) s.isDefault],
    if (online.isNotEmpty) 'onlineSubtitleUrls': online,
  };
}

/// Auto-downloaded subtitle for a native-player source that carries none.
///
/// Mirrors the built-in player's keyless fallback and the TV player's
/// download-and-attach: the same [SubtitleDownloadService], remote-URL
/// handoff, no temp files. [fetch] is the service call pre-bound by the
/// caller so tests can substitute canned results.
Future<Subtitle?> autoDownloadedPhoneSubtitle({
  required List<Subtitle> existing,
  required bool autoDownload,
  required bool hasIdentifiers,
  required String iso2,
  String? label,
  required Future<List<({String lang, String url})>> Function() fetch,
}) async {
  final language = kSubtitleLanguages
      .where((entry) => entry.iso2 == iso2)
      .firstOrNull;
  if (!autoDownload ||
      !hasIdentifiers ||
      existing.any(
        (track) => language == null
            ? track.lang == iso2
            : matchesSourceLang(track.lang, language) ||
                  matchesSourceLang(track.label ?? '', language),
      )) {
    return null;
  }
  late final List<({String lang, String url})> found;
  try {
    found = await fetch();
  } catch (_) {
    return null;
  }
  if (found.isEmpty) return null;
  final url = found.first.url.trim();
  if (url.isEmpty) return null;
  final lang = found.first.lang.trim();
  final u = url.toLowerCase();
  final format = u.contains('.vtt')
      ? 'vtt'
      : u.contains('.ass') || u.contains('.ssa')
      ? 'ass'
      : 'srt';
  return Subtitle(
    url: url,
    lang: lang.isNotEmpty ? lang : iso2,
    label: label ?? (lang.isNotEmpty ? lang : iso2),
    providerName: _onlineSubtitleProvider,
    format: format,
    isDefault: true,
  );
}

Map<String, dynamic> phoneSourceMap(VideoSource source, int index) {
  return <String, dynamic>{
    'label': phoneMirrorLabel(source, index),
    'url': source.url,
    'headers': source.headers ?? const <String, String>{},
    'mimeType': ?phoneMimeFor(source),
    'quality': source.quality ?? '',
    'kind': source.kind.name,
    'audioLang': source.audioLang ?? '',
    ..._phoneSubtitlePayload(source),
  };
}

/// Everything [PhonePlayerActivity] needs for one launch, as a flat map.
///
/// Flat on purpose: the Kotlin side reads each value straight off the method
/// call, and [bufferParams] is spread in rather than nested so BufferPresets
/// can read it without knowing this function exists.
Map<String, dynamic> phonePlayerArgs({
  VideoSource? source,
  int positionMs = 0,
  required String title,
  required String episodeLabel,
  required List<String> episodeLabels,
  required int startIndex,
  required int accentColor,
  required bool softwareDecoding,
  String? decoderMode,
  bool nativeCacheEnabled = false,
  int nativeCacheMb = 128,
  bool diskCacheEnabled = false,
  int diskCacheGb = 2,
  bool autoPip = false,
  required double defaultSpeed,
  required Map<String, dynamic> bufferParams,
  required double subtitleScale,
  required int subtitleFgColor,
  required int subtitleBgColor,
  required int subtitleEdgeType,
  required int subtitleEdgeColor,
  required String subtitlePreference,
  int subtitlePosition = 95,
  required bool autoResume,
  required bool keepScreenOn,
  required bool autoplayNext,
  required int seekSeconds,
  bool isMovie = false,
  bool stremioSubtitles = false,
  bool autoPlayerFallback = false,
  bool ambientPlayer = true,
  bool megaSkip = true,
  int megaSkipSeconds = 85,
  String? subtitleFontPath,
  String? cover,
  Map<String, String>? coverHeaders,
  String playerOrientation = 'landscape',
  Map<String, List<String>>? controlLayout,
  Map<String, dynamic>? watchData,
  String? showDescription,
  List<String>? availableCategories,
  String category = 'sub',
  int sessionId = 0,
}) {
  final mime = source == null ? null : phoneMimeFor(source);
  return <String, dynamic>{
    if (stremioSubtitles) 'stremioSubtitles': true,
    if (autoPlayerFallback) 'autoPlayerFallback': true,
    'ambientPlayer': ambientPlayer,
    // No url: the Activity opens on its loading screen and asks Dart for the
    // episode over the channel, so the user never waits on a blank route.
    if (source != null) ...{
      'url': source.url,
      'headers': source.headers ?? const <String, String>{},
      'mimeType': ?mime,
      'positionMs': positionMs,
      ..._phoneSubtitlePayload(source),
    },
    'title': title,
    'episodeLabel': episodeLabel,
    'episodeLabels': episodeLabels,
    'episodeCount': episodeLabels.length,
    'isMovie': isMovie,
    'startIndex': startIndex,
    'accentColor': accentColor,
    'softwareDecoding': softwareDecoding,
    'decoderMode': decoderMode ?? (softwareDecoding ? 'sw' : 'auto'),
    'nativeCacheEnabled': nativeCacheEnabled,
    'nativeCacheMb': nativeCacheMb.clamp(32, 512),
    'diskCacheEnabled': diskCacheEnabled,
    'diskCacheGb': diskCacheGb.clamp(1, 20),
    'defaultSpeed': defaultSpeed,
    ...bufferParams,
    'autoResume': autoResume,
    'keepScreenOn': keepScreenOn,
    'autoPip': autoPip,
    'autoplayNext': autoplayNext,
    'seekSeconds': seekSeconds,
    'megaSkip': megaSkip,
    'megaSkipSeconds': megaSkipSeconds.clamp(
      PlaybackPrefs.megaSkipMin,
      PlaybackPrefs.megaSkipMax,
    ),
    'subtitleScale': subtitleScale,
    'subtitleFgColor': subtitleFgColor,
    'subtitleBgColor': subtitleBgColor,
    'subtitleEdgeType': subtitleEdgeType,
    'subtitleEdgeColor': subtitleEdgeColor,
    'subtitlePreference': subtitlePreference,
    'subtitlePosition': subtitlePosition.clamp(0, 100),
    'subtitleFontPath': ?subtitleFontPath,
    'cover': ?cover,
    'coverHeaders': coverHeaders ?? const <String, String>{},
    'playerOrientation': playerOrientation,
    'controlLayout': ?controlLayout,
    'watchData': ?watchData,
    'showDescription': ?showDescription,
    'availableCategories': availableCategories ?? const <String>[],
    'category': category,
    'sessionId': sessionId,
  };
}

Future<void> phoneScrobbleOnLaunch({
  required Episode episode,
  required List<Episode> episodes,
  int? malId,
  String? scrobbleTitle,
  int? tmdbId,
  bool tmdbIsTv = false,
  String? imdbId,
  bool peek = false,
  bool auto = true,
  bool simklLive = false,
}) async {
  if (peek) return;
  final number = episode.number;
  if (number == null ||
      !number.isFinite ||
      number <= 0 ||
      number != number.truncateToDouble()) {
    return;
  }
  if (!sl.isRegistered<TrackerHub>()) return;
  unawaited(
    sl<TrackerHub>().scrobble(
      malId: malId,
      title: scrobbleTitle,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
      episode: number.toInt(),
      season: episode.season,
      seasonEpisode: seasonEpisodeOf(episodes, episode),
      auto: auto,
      simklLive: simklLive,
    ),
  );
}

bool phoneShouldScrobbleOnFirstFrame({
  required bool playerOpen,
  required bool alreadyScrobbled,
  required bool peek,
  required int episodeIndex,
  required int startIndex,
}) => playerOpen && !alreadyScrobbled && !peek && episodeIndex == startIndex;

typedef PhoneSourcesPoll =
    Future<({List<VideoSource> sources, bool done})> Function(
      String episodeUrl,
    );

typedef PhonePlaybackFailure = ({
  List<Episode> episodes,
  int index,
  VideoSource source,
  Duration position,
  String category,
});

/// Opens the native phone player for [episodes] starting at [startIndex].
///
/// Same argument list as the TV launcher so the call site barely changes, but
/// a separate function with its own behaviour: it is laid out for touch, it
/// rotates, and it says so on screen when it has to change source.
Future<bool> launchPhonePlayback({
  required BuildContext context,
  required String sourceId,
  required List<Episode> episodes,
  required int startIndex,
  required ResumeStore resume,
  required Future<List<VideoSource>> Function(String episodeUrl) resolveSources,
  PhoneSourcesPoll? pollSources,
  int resumePosition = 0,
  bool peek = false,
  String? showUrl,
  String? downloadShowId,
  bool allowDownloads = true,
  String? showTitle,
  String? cover,
  Map<String, String>? coverHeaders,
  String category = 'sub',
  List<String> availableCategories = const [],
  String? showDescription,
  WatchHistory? history,
  VideoSource? initialSource,
  int? malId,
  String? scrobbleTitle,
  int? tmdbId,
  bool tmdbIsTv = false,
  String? imdbId,
  bool isMovie = false,
  PlayerEngineFallback? engineFallback,
  void Function(PhonePlaybackFailure)? onEngineFallback,
  bool forceInitialResume = false,
}) async {
  // ClearCut: fresh connection estimate for Auto quality (never throws).
  unawaited(NetworkQuality.instance.refresh());
  return PhoneNativePlayer.play(
    sourceId: sourceId,
    episodes: episodes,
    startIndex: startIndex,
    resume: resume,
    resolveSources: resolveSources,
    pollSources: pollSources,
    resumePosition: resumePosition,
    peek: peek,
    showUrl: showUrl,
    downloadShowId: downloadShowId,
    allowDownloads: allowDownloads,
    showTitle: showTitle,
    cover: cover,
    coverHeaders: coverHeaders,
    category: category,
    availableCategories: availableCategories,
    showDescription: showDescription,
    history: history,
    initialSource: initialSource,
    malId: malId,
    scrobbleTitle: scrobbleTitle,
    tmdbId: tmdbId,
    tmdbIsTv: tmdbIsTv,
    imdbId: imdbId,
    isMovie: isMovie,
    engineFallback: engineFallback,
    onEngineFallback: onEngineFallback,
    forceInitialResume: forceInitialResume,
  );
}

/// Drives [PhonePlayerActivity] over `zangetsu/phone_player`.
///
/// Resolution and persistence stay in Dart; the Activity is only a player.
/// Only one player is on screen at a time, so plain statics hold the session.
class PhoneNativePlayer {
  static const _ch = MethodChannel('zangetsu/phone_player');
  static bool _handlerBound = false;

  /// Completes when the Activity reports it closed, carrying the final
  /// position, duration and episode index.
  static Completer<Map<String, dynamic>?>? _closed;

  static Future<List<VideoSource>> Function(String episodeUrl)? _resolve;
  static PhoneSourcesPoll? _pollSources;
  static List<Episode> _episodes = const [];
  static String _sourceId = '';
  static String _showId = '';
  static String? _downloadShowId;
  static bool _allowDownloads = true;
  static int _downloadToken = 0;
  static ({
    int token,
    int index,
    String category,
    Episode episode,
    List<VideoSource> sources,
  })?
  _downloadChoice;
  static String? _showUrl;
  static String _showTitle = '';
  static String? _cover;
  static Map<String, String>? _coverHeaders;
  static int? _malId;
  static String? _scrobbleTitle;
  static int? _tmdbId;
  static bool _tmdbIsTv = false;
  static String? _imdbId;
  static String _category = 'sub';
  static List<String> _availableCategories = const [];
  static int _sessionId = 0;
  static String? _showDescription;
  static ResumeStore? _resume;
  static WatchHistory? _history;
  static bool _autoResume = true;
  static bool _peek = false;
  static VideoSource? _seedSource;
  static int _startIndex = 0;
  static int _resumeOverride = 0;
  static bool _seedUsed = false;
  static bool _scrobbled = false;
  static SimklPlaybackSession? _simklPlayback;
  static int _simklIndex = -1;
  static bool _isMovie = false;
  static PlayerEngineFallback? _engineFallback;
  static void Function(PhonePlaybackFailure)? _onEngineFallback;
  static PhonePlaybackFailure? _pendingEngineFailure;
  static bool _forceInitialResume = false;
  static final _engineSources = <int, List<VideoSource>>{};
  static final _otherSources = <(int, String), List<VideoSource>>{};
  static final _otherSourceChecks = <(int, String), DateTime>{};
  static final _firstOtherSource = <(int, String), Completer<void>>{};
  static int? _playingIndex;

  /// ClearCut: how many times this session moved on to another source after
  /// one failed in the player. Each hop is a real scrape, so it is capped.

  static List<VideoSource> _rememberEngineSources(
    int index,
    List<VideoSource> sources, {
    required int session,
    required String category,
  }) {
    if (_engineFallback == null ||
        session != _sessionId ||
        category != _category ||
        _closed?.isCompleted != false) {
      return sources;
    }
    _engineSources[index] = sources;
    return _blockedFiltered(index, sources);
  }

  static List<VideoSource> _blockedFiltered(
    int index,
    List<VideoSource> sources,
  ) {
    final blocked = sl<PlaybackPrefs>().autoPlayerFallback
        ? _engineFallback?.blockedUrls(_episodes[index].url, _category) ??
              const <String>{}
        : const <String>{};
    return blocked.isEmpty
        ? sources
        : sources.where((source) => !blocked.contains(source.url)).toList();
  }

  /// What's already resolved for [index], if the episode's own open/switch
  /// already fetched it — null only before anything has resolved at all.
  static List<VideoSource>? _cachedSourcesFor(int index) {
    final raw = _engineSources[index];
    if (raw == null || raw.isEmpty) return null;
    return _blockedFiltered(index, raw);
  }

  static List<VideoSource> _mergeMirrors(
    List<VideoSource> current,
    List<VideoSource> extra,
  ) {
    final seen = <String>{};
    return [
      for (final source in [...current, ...extra])
        if (seen.add(source.url)) source,
    ];
  }

  static Future<String?> _canonicalEpisode(Episode episode) async {
    if (ZmodeIds.parseEpisode(episode.url) != null) return episode.url;
    final tmdbId = _tmdbId;
    if (tmdbId == null) return null;
    final show = ZCanonical(_tmdbIsTv ? ZKind.tv : ZKind.movie, 'tmdb:$tmdbId');
    if (!_tmdbIsTv) {
      return _isMovie ? ZmodeIds.episodeUrl(show, 1) : null;
    }
    final season = seasonOf(episode);
    final number = episode.number?.toInt();
    if (season == null || number == null || number < 1) return null;
    final episodes = await sl<CatalogueRepository>().episodes(
      ZmodeIds.showUrl(show),
      sourceId: ZmodeIds.sourceId,
    );
    final inSeason = episodes.where((entry) => seasonOf(entry) == season).toList();
    // A positional skip is wrong as soon as the source has a recap, special or
    // a gap in its numbering: choosing "2" would silently canonicalise to the
    // fourth row and play a different episode. Match by the actual number and
    // refuse a positional fallback that lands on a different number.
    final index = resolveEpisodeIndex(inSeason, number);
    if (index < 0 || index >= inSeason.length) return null;
    final chosenNumber = sourceEpisodeNumber(inSeason[index]);
    if (chosenNumber != null && (chosenNumber - number).abs() > 0.5) {
      return null;
    }
    return inSeason[index].url;
  }

  static Future<void>? _checkOtherSources(int index, {String? searchCategory}) {
    if (_peek || !_allowDownloads || !sl.isRegistered<PlaybackResolver>()) {
      return null;
    }
    final episode = _episodes[index];
    final session = _sessionId;
    final activeCategory = _category;
    final category = searchCategory ?? activeCategory;
    final key = (index, category);
    final checked = _otherSourceChecks[key];
    if (checked != null &&
        DateTime.now().difference(checked) < const Duration(minutes: 3)) {
      return _firstOtherSource[key]?.future;
    }
    _otherSourceChecks[key] = DateTime.now();
    _otherSources.remove(key);
    final first = Completer<void>();
    _firstOtherSource[key] = first;
    bool abandoned() =>
        session != _sessionId ||
        activeCategory != _category ||
        _closed?.isCompleted != false ||
        (_playingIndex != null && _playingIndex != index);
    unawaited(() async {
      try {
        final canonical = await _canonicalEpisode(episode);
        if (canonical == null || abandoned()) return;
        final resolver = sl<PlaybackResolver>();
        await for (final choices in resolver.alternativeStreams(
          canonical,
          currentSourceId: _sourceId == ZmodeIds.sourceId ? null : _sourceId,
          category: category,
          abandoned: abandoned,
        )) {
          if (abandoned()) break;
          final prepared = await _prepareSources(choices);
          if (abandoned()) break;
          _otherSources[key] = _mergeMirrors(
            _otherSources[key] ?? const [],
            prepared,
          );
          if (!first.isCompleted) first.complete();
        }
      } catch (error) {
        debugPrint('[phone] alternative sources · $error');
      } finally {
        if (!first.isCompleted) first.complete();
        if (identical(_firstOtherSource[key], first)) {
          _firstOtherSource.remove(key);
          if (abandoned()) _otherSourceChecks.remove(key);
        }
      }
    }());
    return first.future;
  }

  static Future<List<({String lang, String url})>> _findSubtitles(
    Episode episode,
    Language language,
  ) {
    final season = seasonOf(episode) ?? 1;
    final number = ZmodeIds.parseEpisode(episode.url)?.show.kind == ZKind.tv
        ? seasonEpisodeOf(_episodes, episode) ?? episode.number?.toInt()
        : episode.number?.toInt();
    return SubtitleDownloadService().find(
      imdbId: _imdbId,
      tmdbId: _tmdbId,
      isTv: _tmdbIsTv,
      season: _tmdbIsTv ? season : null,
      episode: _tmdbIsTv ? number : null,
      title: _showTitle.isNotEmpty ? _showTitle : null,
      iso2: language.iso2,
      iso1: language.iso1,
    );
  }

  /// Returns false when the Activity cannot be started; stream errors are
  /// shown inside the native player so the user can retry or leave.
  static Future<bool> play({
    required String sourceId,
    required List<Episode> episodes,
    required int startIndex,
    required ResumeStore resume,
    required Future<List<VideoSource>> Function(String episodeUrl)
    resolveSources,
    PhoneSourcesPoll? pollSources,
    int resumePosition = 0,
    bool peek = false,
    String? showUrl,
    String? downloadShowId,
    bool allowDownloads = true,
    String? showTitle,
    String? cover,
    Map<String, String>? coverHeaders,
    String category = 'sub',
    List<String> availableCategories = const [],
    String? showDescription,
    WatchHistory? history,
    VideoSource? initialSource,
    int? malId,
    String? scrobbleTitle,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    bool isMovie = false,
    PlayerEngineFallback? engineFallback,
    void Function(PhonePlaybackFailure)? onEngineFallback,
    bool forceInitialResume = false,
  }) async {
    if (startIndex < 0 || startIndex >= episodes.length) return false;
    _engineFallback = engineFallback;
    _onEngineFallback = onEngineFallback;
    _forceInitialResume = forceInitialResume;
    _pendingEngineFailure = null;
    _engineSources.clear();
    _otherSources.clear();
    _otherSourceChecks.clear();
    _firstOtherSource.clear();
    _playingIndex = null;
    _resolve = resolveSources;
    _pollSources = pollSources;
    _peek = peek;
    _episodes = episodes;
    _sourceId = sourceId;
    _showUrl = showUrl;
    _showId = showUrl ?? sourceId;
    _downloadShowId = downloadShowId;
    _allowDownloads = allowDownloads;
    _downloadChoice = null;
    _downloadToken++;
    _showTitle = showTitle ?? '';
    _cover = cover;
    _coverHeaders = coverHeaders;
    _malId = malId;
    _scrobbleTitle = scrobbleTitle;
    _tmdbId = tmdbId;
    _tmdbIsTv = tmdbIsTv;
    _imdbId = imdbId;
    _category = category;
    _availableCategories = availableCategories;
    _showDescription = showDescription;
    _sessionId++;
    _prefetchedEpisodes.clear();
    _isMovie = isMovie;
    // Remember where we were: if the player Activity or the process is killed,
    // the next cold start reopens this title instead of dropping the viewer at
    // Home. Cleared when the player closes normally.
    unawaited(
      LastPlayback.remember(
        ShareLink.forItem(
          MediaItem(
            id: showUrl ?? sourceId,
            title: _showTitle.isNotEmpty
                ? _showTitle
                : (_scrobbleTitle ?? ''),
            url: showUrl ?? sourceId,
            type: isMovie ? ProviderType.movie : ProviderType.anime,
            sourceId: sourceId,
            cover: cover,
          ),
        ),
      ),
    );
    _resume = resume;
    _history = history;
    if (!_handlerBound) {
      _ch.setMethodCallHandler(_onNativeCall);
      _handlerBound = true;
    }

    final ep = _episodes[startIndex];
    final prefs = sl<PlaybackPrefs>();
    _autoResume = prefs.autoResume;
    _seedSource = initialSource;
    _stremioSources.clear();
    _startIndex = startIndex;
    _resumeOverride = resumePosition;
    _seedUsed = false;
    _scrobbled = false;
    _simklPlayback?.stop();
    _simklPlayback = null;
    _simklIndex = -1;
    final subFontPath = await _stageSubtitleFont(prefs.subtitleFont);
    final args = phonePlayerArgs(
      title: _showTitle,
      episodeLabel: _episodeLabel(ep),
      episodeLabels: [for (final e in _episodes) _episodeLabel(e)],
      isMovie: _isMovie,
      stremioSubtitles: _sourceId == stremioSourceId,
      autoPlayerFallback:
          engineFallback != null &&
          onEngineFallback != null &&
          prefs.autoPlayerFallback,
      ambientPlayer: prefs.ambientPlayer,
      startIndex: startIndex,
      accentColor: AppColors.accent.toARGB32(),
      softwareDecoding: prefs.videoDecoder == 'sw',
      decoderMode: prefs.videoDecoder,
      nativeCacheEnabled: prefs.phoneNativeCacheEnabled,
      nativeCacheMb: prefs.phoneNativeCacheMb,
      diskCacheEnabled: prefs.phoneDiskCacheEnabled,
      diskCacheGb: prefs.phoneDiskCacheGb,
      autoPip: prefs.autoPip,
      defaultSpeed: prefs.defaultSpeed,
      bufferParams: prefs.exoBufferParams,
      subtitleScale: prefs.subtitleScale,
      subtitleFgColor: parseSubtitleHex(
        prefs.subtitleColorHex,
        opacity: prefs.subtitleTextOpacity,
      ).toARGB32(),
      subtitleBgColor: parseSubtitleHex(
        '#000000',
        opacity: prefs.subtitleBgOpacity,
      ).toARGB32(),
      subtitleEdgeType: tvEdgeTypeFromOutlinePref(prefs.subtitleOutlineType),
      subtitleEdgeColor: parseSubtitleHex(
        prefs.subtitleOutlineColorHex,
      ).toARGB32(),
      subtitlePreference: _resolvedSubtitlePreference(),
      subtitlePosition: prefs.subtitlePosition,
      autoResume: prefs.autoResume,
      keepScreenOn: prefs.keepScreenOn,
      autoplayNext: prefs.autoplayNext,
      seekSeconds: prefs.seekSeconds,
      megaSkip: prefs.megaSkip,
      megaSkipSeconds: prefs.megaSkipSeconds,
      subtitleFontPath: subFontPath,
      cover: _cover,
      coverHeaders: _coverHeaders,
      playerOrientation: prefs.playerOrientation,
      controlLayout: {
        'top': prefs.playerBarTop ?? PlayerControlsConfig.defaultTop,
        'left': prefs.playerBarLeft ?? PlayerControlsConfig.defaultLeft,
        'right': prefs.playerBarRight ?? PlayerControlsConfig.defaultRight,
      },
      watchData: {
        ...phoneWatchPageData(
          episodes: _episodes,
          showTitle: _showTitle,
          showDescription: _showDescription,
          cover: _cover,
          isWatched: (ep) =>
              _resume?.get(_sourceId, _showId, ep.id)?.finished ?? false,
          isMovie: _isMovie,
        ),
        'coverHeaders': _coverHeaders ?? const <String, String>{},
        'canDownload':
            _allowDownloads &&
            (_showUrl?.isNotEmpty ?? false) &&
            !_peek &&
            sl.isRegistered<DownloadManager>() &&
            !ep.url.startsWith('file:') &&
            !ep.url.startsWith('content:'),
        'surface': AppColors.surface2.toARGB32(),
        'downloadSurface': AppColors.surface.toARGB32(),
        'secondary': AppColors.textSecondary.toARGB32(),
      },
      showDescription: _showDescription,
      availableCategories: _availableCategories,
      category: _category,
      sessionId: _sessionId,
    );

    _closed = Completer<Map<String, dynamic>?>();
    final launched = await _ch.invokeMethod<bool>('launch', args) ?? false;
    if (!launched) {
      _closed = null;
      return false;
    }
    // Entries without a snapshot (anything but Details) enrich once, lazily:
    // the show page is already up, and a changed show or a local file skips.
    unawaited(_pushShowDescription(_sessionId));
    await _closed!.future;
    return true;
  }

  /// One lazy synopsis fetch per session, pushed to the live player only if
  /// it is still the session that asked. Local files never trigger resolution.
  static Future<void> _pushShowDescription(int session) async {
    if ((_showDescription?.trim().isNotEmpty ?? false)) return;
    final url = _showUrl;
    if (url == null || url.isEmpty) return;
    final seed = _seedSource?.url ?? '';
    if (seed.startsWith('file://') || seed.startsWith('content://')) return;
    try {
      final desc =
          (await sl<CatalogueRepository>().detail(
            url,
            sourceId: _sourceId,
          )).description?.trim() ??
          '';
      if (desc.isEmpty || session != _sessionId) return;
      _showDescription = desc;
      await _ch.invokeMethod('updateMetadata', {
        'sessionId': session,
        'showDescription': desc,
      });
    } catch (_) {
      // No synopsis is a hidden section, never a failed launch.
    }
  }

  static final _stremioSources = <int, List<VideoSource>>{};

  static Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'englishSubtitles':
        final args = _callArgs(call);
        final index = phoneWatchActionIndex(
          args,
          sessionId: _sessionId,
          episodeCount: _episodes.length,
          playerOpen: _closed?.isCompleted == false && !_peek,
        );
        if (index == null) return null;
        final session = _sessionId;
        final tracks = await _findSubtitles(
          _episodes[index],
          languageByPref('en')!,
        );
        if (session != _sessionId || _closed?.isCompleted != false) return null;
        final subtitles = [
          for (final (i, track) in tracks.take(8).indexed)
            Subtitle(url: track.url, lang: 'en', label: 'English · ${i + 1}'),
        ];
        return _phoneSubtitlePayload(
          VideoSource(url: '', subtitles: subtitles),
        );
      case 'rememberStremioLink':
      case 'addonSubtitles':
        final args = _callArgs(call);
        final index = (args?['index'] as num?)?.toInt() ?? -1;
        if (_sourceId != stremioSourceId ||
            _closed?.isCompleted != false ||
            args?['sessionId'] != _sessionId ||
            index < 0 ||
            index >= _episodes.length) {
          return null;
        }
        final url = args?['url'] as String?;
        VideoSource? selected;
        for (final source in _stremioSources[index] ?? const <VideoSource>[]) {
          if (source.url == url) {
            selected = source;
            break;
          }
        }
        if (selected == null) return null;
        if (call.method == 'rememberStremioLink') {
          if (!_peek &&
              !IncognitoMode.on &&
              sl.isRegistered<TitlePrefsStore>()) {
            final store = sl<TitlePrefsStore>();
            await store.rememberStremioLink(_episodes[index].url, selected);
            final show = _showUrl;
            if (show != null && show.isNotEmpty) {
              await store.rememberStremioBingeGroup(show, selected.bingeGroup);
            }
          }
          return null;
        }
        if (!sl.isRegistered<StremioManager>() ||
            !StremioRef.isRef(_episodes[index].url)) {
          return null;
        }
        final session = _sessionId;
        final enriched = await stremioSourceWithSubtitles(
          sl<StremioManager>(),
          StremioRef.parse(_episodes[index].url),
          selected,
        );
        if (session != _sessionId || _closed?.isCompleted != false) return null;
        return _phoneSubtitlePayload(enriched);
      case 'rememberSubtitle':
        final args = _callArgs(call);
        if (_closed?.isCompleted != false ||
            args?['sessionId'] != _sessionId ||
            _peek ||
            IncognitoMode.on) {
          return null;
        }
        final choice = args?['choice'] as String?;
        final show = _showUrl;
        if (choice == null ||
            choice.isEmpty ||
            show == null ||
            show.isEmpty ||
            !sl.isRegistered<TitlePrefsStore>()) {
          return null;
        }
        await sl<TitlePrefsStore>().setSubtitleChoice(_sourceId, show, choice);
        return null;
      case 'resolveEpisode':
        final rArgs = _callArgs(call);
        final playerSession = rArgs?['sessionId'];
        if (playerSession != null && playerSession != _sessionId) return null;
        final index = (rArgs?['index'] as num?)?.toInt() ?? -1;
        if (index < 0 || index >= _episodes.length) return null;
        return _resolveEpisode(index);
      case 'playbackStarted':
        final args = _callArgs(call);
        if (!_matchesSession(args)) return null;
        final index = (args?['index'] as num?)?.toInt() ?? -1;
        if (!_peek &&
            _closed?.isCompleted == false &&
            index >= 0 &&
            index < _episodes.length) {
          _playingIndex = index;
          _checkOtherSources(index);
        }
        if (!phoneShouldScrobbleOnFirstFrame(
          playerOpen: _closed?.isCompleted == false,
          alreadyScrobbled: _scrobbled,
          peek: _peek,
          episodeIndex: index,
          startIndex: _startIndex,
        )) {
          return null;
        }
        _scrobbled = true;
        unawaited(
          phoneScrobbleOnLaunch(
            episode: _episodes[index],
            episodes: _episodes,
            malId: _malId,
            scrobbleTitle: _scrobbleTitle,
            tmdbId: _tmdbId,
            tmdbIsTv: _tmdbIsTv,
            imdbId: _imdbId,
            simklLive: true,
          ),
        );
        return null;
      case 'watchDownloadOptions':
      case 'watchDownloadChoose':
      case 'watchDownloadAction':
        final args = _callArgs(call);
        final index = phoneWatchActionIndex(
          args,
          sessionId: _sessionId,
          episodeCount: _episodes.length,
          playerOpen: _closed?.isCompleted == false && !_peek,
        );
        if (index == null ||
            !_allowDownloads ||
            (_showUrl?.isEmpty ?? true) ||
            !sl.isRegistered<DownloadManager>()) {
          return null;
        }
        final original = _episodes[index];
        if (original.url.startsWith('file:') ||
            original.url.startsWith('content:') ||
            (original.unavailable?.isNotEmpty ?? false)) {
          return null;
        }
        final manager = sl<DownloadManager>();
        final downloadSession = _sessionId;
        final requestToken = call.method == 'watchDownloadOptions'
            ? ++_downloadToken
            : null;
        if (requestToken != null) _downloadChoice = null;
        final downloadShowId = await resolveEpisodeDownloadShowId(
          sourceId: _sourceId,
          showUrl: _showUrl!,
          knownId: _downloadShowId,
          downloads: manager.all,
          loadShowId: () async => (await sl<CatalogueRepository>().detail(
            _showUrl!,
            sourceId: _sourceId,
          )).id,
        );
        if (downloadSession != _sessionId ||
            _closed?.isCompleted != false ||
            (requestToken != null && requestToken != _downloadToken)) {
          return null;
        }
        _downloadShowId = downloadShowId;
        final record = manager.recordFor(
          _sourceId,
          downloadShowId,
          original.id,
        );
        final active =
            record != null &&
            {
              DownloadStatus.downloading,
              DownloadStatus.paused,
              DownloadStatus.queued,
              DownloadStatus.resolving,
            }.contains(record.status);
        if (call.method == 'watchDownloadAction') {
          if (!active) return false;
          switch (args?['action']) {
            case 'pause':
              await manager.pause(record);
              return true;
            case 'resume':
              await manager.resume(record);
              return true;
            case 'cancel':
              await manager.cancel(record);
              return true;
            default:
              return false;
          }
        }
        if (call.method == 'watchDownloadChoose') {
          final choice = _downloadChoice;
          final source = args?['source'];
          if (active ||
              choice == null ||
              choice.index != index ||
              args?['token'] != choice.token ||
              source is! int ||
              source < 0 ||
              source >= choice.sources.length) {
            return false;
          }
          _downloadChoice = null;
          final selected = choice.sources[source];
          await manager.enqueueSource(
            sourceId: _sourceId,
            showId: downloadShowId,
            showTitle: _showTitle,
            cover: _cover,
            coverHeaders: _coverHeaders,
            showUrl: _showUrl ?? _showId,
            category: choice.category,
            episode: choice.episode,
            source: selected,
            qualityLabel: selected.quality ?? 'auto',
            fallbacks: choice.sources,
            nowMs: DateTime.now().millisecondsSinceEpoch,
            malId: _malId,
          );
          return true;
        }
        if (active) return {'status': record.status.name};
        final requestedCategory = args?['category'];
        if (requestedCategory != null && requestedCategory is! String) {
          return null;
        }
        final category = requestedCategory as String? ?? _category;
        if (category != _category && !_availableCategories.contains(category)) {
          return null;
        }
        final session = _sessionId;
        final token = requestToken!;
        _downloadChoice = null;
        Episode? episode = original;
        final repo = sl<CatalogueRepository>();
        if (category != _category) {
          episode = matchDownloadEpisode(
            original,
            await repo.episodes(
              _showUrl ?? _showId,
              sourceId: _sourceId,
              category: category,
            ),
          );
        }
        final sources = episode == null
            ? <VideoSource>[]
            : DownloadManager.sourcesForDownloadCategory(
                await repo.sources(
                  episode.url,
                  sourceId: _sourceId,
                  fast: false,
                ),
                category,
              );
        if (session != _sessionId ||
            token != _downloadToken ||
            _closed?.isCompleted != false) {
          return null;
        }
        if (episode != null) {
          _downloadChoice = (
            token: token,
            index: index,
            category: category,
            episode: episode,
            sources: sources,
          );
        }
        return {
          'token': token,
          'category': category,
          'categories': _availableCategories,
          'sources': [
            for (var i = 0; i < sources.length; i++)
              phoneSourceMap(sources[i], i),
          ],
        };
      case 'watchEpisodeState':
      case 'setWatchEpisodeWatched':
      case 'watchEpisodeMirrors':
        final args = _callArgs(call);
        final index = phoneWatchActionIndex(
          args,
          sessionId: _sessionId,
          episodeCount: _episodes.length,
          playerOpen: _closed?.isCompleted == false && !_peek,
        );
        if (index == null) return null;
        final session = _sessionId;
        final requestCategory = _category;
        final ep = _episodes[index];
        if (call.method == 'watchEpisodeState') {
          return {
            'watched':
                _resume?.get(_sourceId, _showId, ep.id)?.finished ?? false,
          };
        }
        if (call.method == 'setWatchEpisodeWatched') {
          final watched = args?['watched'];
          if (watched is! bool || _resume == null) return false;
          await _resume!.setWatched(
            _sourceId,
            _showId,
            ep.id,
            watched: watched,
          );
          if (session != _sessionId || _closed?.isCompleted != false) {
            return false;
          }
          if (watched) {
            unawaited(
              phoneScrobbleOnLaunch(
                episode: ep,
                episodes: _episodes,
                malId: _malId,
                scrobbleTitle: _scrobbleTitle ?? _showTitle,
                tmdbId: _tmdbId,
                tmdbIsTv: _tmdbIsTv,
                imdbId: _imdbId,
                auto: false,
              ),
            );
          }
          return true;
        }
        final sources = sl.isRegistered<CatalogueRepository>()
            ? await sl<CatalogueRepository>().sources(
                tvEpisodeUrl(ep.url, _category),
                sourceId: _sourceId,
                fast: false,
              )
            : await _resolveSources(ep);
        final prepared = _rememberEngineSources(
          index,
          await _prepareSources(sources),
          session: session,
          category: requestCategory,
        );
        if (session != _sessionId || _closed?.isCompleted != false) return null;
        if (_sourceId == stremioSourceId) _stremioSources[index] = prepared;
        return [
          for (var i = 0; i < prepared.length; i++)
            {
              ...phoneSourceMap(prepared[i], i),
              'positionMs': _autoResume ? _resumePosition(ep) : 0,
              'episodeLabel': _episodeLabel(ep),
            },
        ];
      case 'tryOtherPlayer':
        final args = _callArgs(call);
        final index = phoneWatchActionIndex(
          args,
          sessionId: _sessionId,
          episodeCount: _episodes.length,
          playerOpen: _closed?.isCompleted == false,
        );
        if (index == null ||
            _onEngineFallback == null ||
            _engineFallback == null) {
          return false;
        }
        final url = args?['url'];
        VideoSource? source;
        for (final candidate
            in _engineSources[index] ?? const <VideoSource>[]) {
          if (candidate.url == url) {
            source = candidate;
            break;
          }
        }
        if (source == null) return false;
        // A torrent can never play natively — yield to mpv even when the
        // auto-switch toggle is off. Anything else needs the toggle, unless
        // the user tapped Switch Player themselves.
        final manual = args?['manual'] == true;
        if (!manual &&
            !isNativeBlockedTorrent(source) &&
            !sl<PlaybackPrefs>().autoPlayerFallback) {
          return false;
        }
        // A manual switch isn't a failure — recording it in the shared
        // fallback tracker would make the SECOND manual switch for the same
        // episode permanently a no-op (next() is one-shot per engine/source).
        if (!manual &&
            _engineFallback!.next(
                  enabled: true,
                  failedEngine: PlaybackEngine.nativePlayer,
                  episodeUrl: _episodes[index].url,
                  category: _category,
                  source: source,
                ) !=
                PlaybackEngine.mpv) {
          return false;
        }
        final position = (args?['positionMs'] as num?)?.toInt() ?? 0;
        _pendingEngineFailure = (
          episodes: List.of(_episodes),
          index: index,
          source: source,
          position: Duration(milliseconds: position < 0 ? 0 : position),
          category: _category,
        );
        return true;
      case 'sourcesFor':
        final args = _callArgs(call);
        if (!_matchesSession(args)) return const <Map>[];
        final index = (args?['index'] as num?)?.toInt() ?? -1;
        if (index < 0 || index >= _episodes.length) return const <Map>[];
        // Reuse what the episode's own open/switch already resolved instead
        // of re-scraping: a fresh scrape queues behind that still-running
        // call on the JS engine's one-at-a-time lane, so the Server sheet
        // (and native's own mirror failover, which hits this same case)
        // would sit there not opening until the original load cleared.
        final cached = _cachedSourcesFor(index);
        final episode = _episodes[index];
        final resolver =
            _sourceId == ZmodeIds.sourceId &&
                sl.isRegistered<PlaybackResolver>()
            ? sl<PlaybackResolver>()
            : null;
        final frameXtv =
            _sourceId == frameXtvSourceId ||
            resolver?.resolvedSourceId(episode.url, category: _category) ==
                frameXtvSourceId;
        _checkOtherSources(index);
        final session = _sessionId;
        final requestCategory = _category;
        final findDub =
            args?['preferEnglish'] == true &&
            requestCategory != 'dub' &&
            ZmodeIds.parseEpisode(episode.url)?.show.kind == ZKind.anime;
        final dubCheck = findDub
            ? _checkOtherSources(index, searchCategory: 'dub')
            : null;
        if (dubCheck != null && !frameXtv) {
          await dubCheck.timeout(const Duration(seconds: 4), onTimeout: () {});
          if (session != _sessionId ||
              requestCategory != _category ||
              _closed?.isCompleted != false) {
            return const <Map>[];
          }
        }
        List<VideoSource> alternatives() => [
          ...?_otherSources[(index, requestCategory)],
          if (findDub) ...?_otherSources[(index, 'dub')],
        ];
        if (cached != null && !frameXtv) {
          final choices = _mergeMirrors(cached, alternatives());
          return [
            for (var i = 0; i < choices.length; i++)
              phoneSourceMap(choices[i], i),
          ];
        }
        final sources = await _resolveSources(episode, preferPolled: true);
        final merged = _mergeMirrors(cached ?? const [], sources);
        final prepared = _rememberEngineSources(
          index,
          await _prepareSources(merged),
          session: session,
          category: requestCategory,
        );
        if (session != _sessionId ||
            requestCategory != _category ||
            _closed?.isCompleted != false) {
          return const <Map>[];
        }
        if (_sourceId == stremioSourceId) _stremioSources[index] = prepared;
        final choices = _mergeMirrors(prepared, alternatives());
        return [
          for (var i = 0; i < choices.length; i++)
            phoneSourceMap(choices[i], i),
        ];
      case 'nextSource':
        // ClearCut: every link of the current source failed in the player.
        // In auto mode, mark that source unplayable for this episode and let
        // auto-find hand over the next one, instead of ending on an error
        // while other sources were available. Bounded, and never replaces a
        // source the viewer pinned by hand.
        {
          final args = _callArgs(call);
          if (!_matchesSession(args)) return const <Map>[];
          final index = (args?['index'] as num?)?.toInt() ?? -1;
          if (index < 0 || index >= _episodes.length) return const <Map>[];
          final epUrl = _episodes[index].url;
          final canonical = ZmodeIds.parseShow(epUrl);
          if (ZmodeIds.parseEpisode(epUrl) == null ||
              canonical == null ||
              !sl.isRegistered<PlaybackResolver>()) {
            return const <Map>[];
          }
          if (sl.isRegistered<SourceMatcher>() &&
              sl<SourceMatcher>().sourceForTitle(canonical) != null) {
            return const <Map>[];
          }
          final resolver = sl<PlaybackResolver>();
          final winner = resolver.resolvedSourceId(epUrl, category: _category);
          if (winner == null) return const <Map>[];
          resolver.markSourceUnplayable(epUrl, winner, category: _category);
          _engineSources.remove(index);
          final session = _sessionId;
          final requestCategory = _category;
          try {
            final sources = await _resolveSources(_episodes[index]);
            final prepared = _rememberEngineSources(
              index,
              await _prepareSources(sources),
              session: session,
              category: requestCategory,
            );
            if (session != _sessionId ||
                requestCategory != _category ||
                _closed?.isCompleted != false) {
              return const <Map>[];
            }
            return [
              for (var i = 0; i < prepared.length; i++)
                phoneSourceMap(prepared[i], i),
            ];
          } catch (e) {
            // The sweep found nothing else: a real dead end, not a crash.
            debugPrint('[phone] nextSource · no other source: $e');
            return const <Map>[];
          }
        }
      case 'switchCategory':
        {
          // Native Audio menu's Sub/Dub row. Same episode, same list, Dart's
          // normal resolution path — a failed resolve returns null and the
          // player keeps playing instead of jumping anywhere.
          final args = _callArgs(call);
          if (!_matchesSession(args)) return null;
          final cat = args?['category'] as String?;
          final index = (args?['index'] as num?)?.toInt() ?? -1;
          if (cat == null ||
              !_availableCategories.contains(cat) ||
              index < 0 ||
              index >= _episodes.length) {
            return null;
          }
          final previous = _category;
          _category = cat;
          final payload = await _resolveEpisode(index);
          if (payload == null) {
            _category = previous;
            return null;
          }
          payload['positionMs'] =
              (args?['positionMs'] as num?)?.toInt() ?? payload['positionMs'];
          return payload;
        }
      case 'setAutoplayNext':
        {
          final value = _callArgs(call)?['value'] as bool?;
          if (value == null) return null;
          await sl<PlaybackPrefs>().setAutoplayNext(value);
          return null;
        }
      case 'setAmbientPlayer':
        {
          final value = _callArgs(call)?['value'] as bool?;
          if (value == null) return null;
          await sl<PlaybackPrefs>().setAmbientPlayer(value);
          return null;
        }
      case 'saveControlLayout':
        {
          final layout = phoneControlLayoutForSave(
            _callArgs(call),
            sessionId: _sessionId,
            playerOpen: _closed?.isCompleted == false,
          );
          if (layout == null) return false;
          await sl<PlaybackPrefs>().setPlayerBar(
            layout.top,
            layout.left,
            layout.right,
          );
          return true;
        }
      case 'discordPresence':
        final args = _callArgs(call);
        _syncSimkl(args);
        _pushDiscordPresence(args);
        return null;
      case 'saveProgress':
        final args = _callArgs(call);
        await _saveProgress(args, flush: true);
        _preheatNearEnd(args);
        return null;
      case 'playerClosed':
        final closingArgs = _callArgs(call);
        if (closingArgs?['sessionId'] == _sessionId) {
          unawaited(LastPlayback.clear());
          _syncSimkl({
            ...?closingArgs,
            'index': closingArgs?['episodeIndex'],
            'actualPlaying': false,
            'completed': true,
          });
          _simklPlayback?.stop();
        }
        if (!_peek &&
            _closed?.isCompleted == false &&
            sl.isRegistered<DiscordRpc>()) {
          sl<DiscordRpc>().clear(delay: DiscordRpc.playerExitClearDelay);
        }
        final args = _callArgs(call);
        await _saveProgress(args, flush: true);
        final failure = _pendingEngineFailure;
        if (args?['sessionId'] == _sessionId &&
            args?['engineFallback'] == true &&
            failure != null &&
            args?['episodeIndex'] == failure.index &&
            args?['url'] == failure.source.url) {
          _onEngineFallback?.call(failure);
        }
        _pendingEngineFailure = null;
        _engineSources.clear();
        _onEngineFallback = null;
        _engineFallback = null;
        if (_closed?.isCompleted == false) _closed!.complete(args);
        _closed = null;
        _prefetchedEpisodes.clear();
        _downloadChoice = null;
        _downloadToken++;
        return null;
    }
    return null;
  }

  static void _syncSimkl(Map<String, dynamic>? args) {
    if (_peek ||
        _closed?.isCompleted != false ||
        args?['sessionId'] != _sessionId ||
        !sl.isRegistered<TrackerHub>()) {
      return;
    }
    final index = (args?['index'] as num?)?.toInt() ?? -1;
    if (index < 0 || index >= _episodes.length) return;
    if (index != _simklIndex) {
      _simklPlayback?.stop();
      _simklPlayback = null;
      _simklIndex = index;
    }
    final ep = _episodes[index];
    final n = ep.number;
    _simklPlayback ??= sl<TrackerHub>().simklPlayback(
      malId: _malId,
      tmdbId: _tmdbId,
      tmdbIsTv: _tmdbIsTv,
      imdbId: _imdbId,
      episode: n != null && n.isFinite && n > 0 && n == n.truncateToDouble()
          ? n.toInt()
          : null,
      season: ep.season,
      seasonEpisode: seasonEpisodeOf(_episodes, ep),
    );
    _simklPlayback?.update(
      positionMs: (args?['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (args?['durationMs'] as num?)?.toInt() ?? 0,
      playing: args?['actualPlaying'] == true,
      completed: args?['completed'] == true,
    );
  }

  static void _pushDiscordPresence(Map<String, dynamic>? args) {
    if (_closed?.isCompleted != false ||
        _peek ||
        args == null ||
        !sl.isRegistered<DiscordRpc>()) {
      return;
    }
    final index = (args['index'] as num?)?.toInt() ?? -1;
    final duration = (args['durationMs'] as num?)?.toInt() ?? 0;
    final title = _showTitle.isNotEmpty ? _showTitle : _scrobbleTitle ?? '';
    if (index < 0 ||
        index >= _episodes.length ||
        duration <= 0 ||
        title.isEmpty) {
      return;
    }
    unawaited(
      sl<DiscordRpc>().setWatching(
        title: title,
        episodeLabel: discordEpisodeLabel(
          _episodes[index],
          fallbackNumber: index + 1,
        ),
        posterUrl: _cover,
        position: Duration(
          milliseconds: ((args['positionMs'] as num?)?.toInt() ?? 0).clamp(
            0,
            1 << 62,
          ),
        ),
        duration: Duration(milliseconds: duration),
        playing: args['playing'] == true,
        openUrl: ShareLink.watchUrl(
          sourceId: _sourceId,
          url: _showUrl,
          title: title,
          type: (_scrobbleTitle != null || _malId != null)
              ? ProviderType.anime
              : ProviderType.movie,
          cover: _cover,
        ),
      ),
    );
  }

  static Map<String, dynamic>? _callArgs(MethodCall call) {
    final raw = call.arguments;
    return raw is Map ? raw.cast<String, dynamic>() : null;
  }

  static bool _matchesSession(Map<String, dynamic>? args) =>
      args?['sessionId'] == null || args?['sessionId'] == _sessionId;

  static Future<Map<String, dynamic>?> _resolveEpisode(int index) async {
    final session = _sessionId;
    final category = _category;
    final ep = _episodes[index];
    final seed = !_seedUsed && _seedSource != null && index == _startIndex
        ? _seedSource
        : null;
    if (seed != null) _seedUsed = true;
    final sources = seed == null
        ? await _resolveSources(ep)
        : <VideoSource>[seed];
    final prepared = _rememberEngineSources(
      index,
      await _prepareSources(sources),
      session: session,
      category: category,
    );
    if (session != _sessionId || category != _category || prepared.isEmpty) {
      return null;
    }
    if (_sourceId == stremioSourceId) _stremioSources[index] = prepared;
    final src0 = seed == null ? _pickSource(prepared, ep) : prepared.first;
    if (src0 == null) return null;
    var src = src0;
    if (sl<PlaybackPrefs>().autoDownloadSubtitles) {
      final prefLang = languageByPref(
        sl<PlaybackPrefs>().preferredSubtitleLanguage,
      );
      if (prefLang != null) {
        final dl = await autoDownloadedPhoneSubtitle(
          existing: src.subtitles,
          autoDownload: true,
          hasIdentifiers:
              (_imdbId?.isNotEmpty ?? false) ||
              _tmdbId != null ||
              _showTitle.isNotEmpty,
          iso2: prefLang.iso2,
          label: prefLang.name,
          fetch: () => _findSubtitles(ep, prefLang),
        );
        if (session != _sessionId || category != _category) return null;
        if (dl != null) src = src.withSubtitles([...src.subtitles, dl]);
      }
    }
    final position = index == _startIndex && _forceInitialResume
        ? _resumeOverride
        : index == _startIndex
        ? (_autoResume
              ? (_resumeOverride > 0 ? _resumeOverride : _resumePosition(ep))
              : 0)
        : _resumePosition(ep);
    if (index == _startIndex) _forceInitialResume = false;
    return {
      ...phoneSourceMap(src, seed == null ? _indexOfSource(prepared, src) : 0),
      'positionMs': position,
      'episodeLabel': _episodeLabel(ep),
    };
  }

  static VideoSource? _pickSource(List<VideoSource> sources, Episode episode) {
    if (_sourceId == stremioSourceId && sl.isRegistered<TitlePrefsStore>()) {
      final saved = sl<TitlePrefsStore>().preferredStremioLink(
        episode.url,
        sources,
        showUrl: _showUrl,
      );
      if (saved != null) return saved;
    }
    return pickDefault(
      sources,
      prefer: _category == 'dub' ? AudioKind.dub : AudioKind.sub,
      preferQuality: _preferredQuality(),
    );
  }

  static String _preferredQuality() {
    final url = _showUrl;
    return (url != null && url.isNotEmpty && sl.isRegistered<TitlePrefsStore>()
            ? sl<TitlePrefsStore>().quality(_sourceId, url)
            : null) ??
        sl<PlaybackPrefs>().defaultQuality;
  }

  static String _resolvedSubtitlePreference() {
    final show = _showUrl;
    if (show != null && show.isNotEmpty && sl.isRegistered<TitlePrefsStore>()) {
      final remembered = sl<TitlePrefsStore>().subtitleChoice(_sourceId, show);
      if (remembered != null) return remembered;
    }
    return sl<PlaybackPrefs>().subtitlePreference;
  }

  static final _prefetchedEpisodes = <(int, String)>{};

  static void _preheatNearEnd(Map<String, dynamic>? args) {
    if (_peek || _closed?.isCompleted != false || args == null) return;
    final index = (args['index'] as num?)?.toInt() ?? -1;
    final position = (args['positionMs'] as num?)?.toInt() ?? 0;
    final duration = (args['durationMs'] as num?)?.toInt() ?? 0;
    if (index < 0 ||
        index + 1 >= _episodes.length ||
        duration <= 0 ||
        position < duration * 0.85) {
      return;
    }
    if (!_prefetchedEpisodes.add((index, _category))) return;
    unawaited(
      _resolveSources(
        _episodes[index + 1],
      ).catchError((_) => const <VideoSource>[]),
    );
  }

  static int _indexOfSource(List<VideoSource> sources, VideoSource target) {
    final index = sources.indexWhere((source) => source.url == target.url);
    return index < 0 ? 0 : index;
  }

  static Future<List<VideoSource>> _resolveSources(
    Episode ep, {
    bool preferPolled = false,
  }) async {
    final url = tvEpisodeUrl(ep.url, _category);
    if (_allowDownloads &&
        _sourceId == ZmodeIds.sourceId &&
        ZmodeIds.parseEpisode(url) != null &&
        sl.isRegistered<PlaybackResolver>()) {
      final resolver = sl<PlaybackResolver>();
      if (preferPolled &&
          resolver.resolvedSourceId(url, category: _category) != null) {
        final polled = await resolver.polledSources(url, category: _category);
        if (polled.sources.isNotEmpty) return polled.sources;
      }
      return resolver.sources(url, fast: true, category: _category);
    }
    if (preferPolled &&
        _sourceId == frameXtvSourceId &&
        sl.isRegistered<CatalogueRepository>()) {
      final mirrors = await sl<CatalogueRepository>().polledSources(
        url,
        sourceId: _sourceId,
      );
      if (mirrors.sources.isNotEmpty) return mirrors.sources;
    }
    if (preferPolled && _pollSources != null) {
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        var latest = const <VideoSource>[];
        while (true) {
          final polled = await _pollSources!(url);
          latest = polled.sources;
          if (polled.done || DateTime.now().isAfter(deadline)) {
            if (latest.isNotEmpty) return latest;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      } catch (e) {
        debugPrint('[PhoneNativePlayer] poll failed · $e');
      }
    }
    try {
      return await _resolve!(url);
    } catch (e) {
      debugPrint('[PhoneNativePlayer] resolve failed · $e');
      return const [];
    }
  }

  static Future<List<VideoSource>> _prepareSources(
    List<VideoSource> sources,
  ) async {
    final prepared = <VideoSource>[];
    for (final source in sources) {
      if ((source.subtitleSkewSeconds ?? 0).abs() < 0.05) {
        prepared.add(source);
      } else {
        prepared.add(await materializeSkewedSubtitles(source));
      }
    }
    return prepared;
  }

  static Future<String?> _stageSubtitleFont(String family) async {
    if (family.isEmpty) return null;
    if (!await SubtitleFontService.instance.ensure(family)) return null;
    return stageSubtitleFont(family);
  }

  static int _resumePosition(Episode ep) {
    if (!_autoResume) return 0;
    return _resume?.get(_sourceId, _showId, ep.id)?.position.inMilliseconds ??
        0;
  }

  static Future<void> _saveProgress(
    Map<String, dynamic>? args, {
    required bool flush,
  }) async {
    if (args == null || _peek) return;
    final index = (args['index'] ?? args['episodeIndex']) as num?;
    final position = args['positionMs'] as num?;
    final duration = args['durationMs'] as num?;
    if (index == null || position == null) return;
    final i = index.toInt();
    if (i < 0 || i >= _episodes.length) return;
    final positionMs = position.toInt().clamp(0, 1 << 62);
    final durationMs = duration?.toInt().clamp(0, 1 << 62) ?? 0;
    if (durationMs <= 0 && positionMs <= 0) return;
    final ep = _episodes[i];
    await _resume?.save(
      _sourceId,
      _showId,
      ep.id,
      Duration(milliseconds: positionMs),
      Duration(milliseconds: durationMs),
    );
    final history = _history;
    if (history != null && _showTitle.isNotEmpty) {
      unawaited(
        history.save(
          HistoryEntry(
            sourceId: _sourceId,
            showId: _showId,
            showTitle: _showTitle,
            cover: _cover,
            coverHeaders: _coverHeaders,
            thumbnail: ep.thumbnail,
            showUrl: _showUrl ?? '',
            category: _category,
            episodeId: ep.id,
            episodeNumber: ep.number,
            episodeUrl: ep.url,
            position: Duration(milliseconds: positionMs),
            duration: Duration(milliseconds: durationMs),
            updatedAt: DateTime.now().millisecondsSinceEpoch,
            malId: _malId,
          ),
          flush: flush,
        ),
      );
    }
  }

  static String _episodeLabel(Episode ep) => phoneEpisodeLabel(
    ep,
    showTitle: _showTitle,
    isMovie: _isMovie,
    episodeCount: _episodes.length,
  );
}
