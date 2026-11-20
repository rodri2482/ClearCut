import 'dart:convert';

import 'package:dio/dio.dart';
import 'dart:developer' as developer;

import 'cs_repo_url.dart';

/// ClearCut: one place that works out what a pasted repository link is,
/// before any screen saves it.
///
/// Why this exists (the bugs it fixes):
///  * ClearCut's own repo screen accepted ANY JSON. A CloudStream `repo.json`
///    has no `sources` list, so it was saved with 0 sources and the screen said
///    "Added …" — then "No sources in this repo".
///  * Aniyomi/Mihon/LNReader screens saved whatever was pasted without fetching
///    it, so typos, GitHub web-page links and wrong formats failed later as a
///    404 or an empty repo.
///  * GitHub `.../blob/...` page links return HTML (or 404 through the native
///    fetch), and Mihon `repo.json` links made the Tachiyomi adapter ask for
///    `.../repo.json/index.pb`.
///
/// The formats are recognised by the fields each one's manifest really uses;
/// they are NOT treated as interchangeable. Each format keeps its own adapter
/// (ClearCut JS providers, the native CloudStream plugin host, the Aniyomi /
/// Mihon APK loaders, the LNReader JS harness). This class only identifies a
/// repo and validates that it offers sources; it never executes anything.
enum RepoFormat {
  /// ClearCut/Zangetsu JS provider repo: `{name, sources:[{id,name,file}]}`.
  clearcut,

  /// CloudStream repo: `repo.json` with `pluginLists` → `.cs3` plugins.
  cloudstream,

  /// Aniyomi anime extension repo (Tachiyomi-style index of APKs).
  aniyomi,

  /// Mihon/Tachiyomi manga extension repo (index of APKs).
  mihon,

  /// LNReader novel plugin index (`plugins.min.json` of JS plugins).
  lnreader,

  /// Stremio add-on manifest (`manifest.json` with resources/types).
  stremio,
}

extension RepoFormatX on RepoFormat {
  String get label => switch (this) {
    RepoFormat.clearcut => 'ClearCut',
    RepoFormat.cloudstream => 'CloudStream',
    RepoFormat.aniyomi => 'Aniyomi',
    RepoFormat.mihon => 'Mihon / Tachiyomi',
    RepoFormat.lnreader => 'LNReader',
    RepoFormat.stremio => 'Stremio',
  };

  /// What one entry of this format is called, for messages.
  String get unitPlural => switch (this) {
    RepoFormat.clearcut => 'sources',
    RepoFormat.cloudstream => 'plugins',
    RepoFormat.aniyomi || RepoFormat.mihon => 'extensions',
    RepoFormat.lnreader => 'novel plugins',
    RepoFormat.stremio => 'add-ons',
  };

  /// "1 plugin" / "3 plugins".
  String count(int n) {
    final plural = unitPlural;
    if (n != 1) return '$n $plural';
    final singular = plural.endsWith('s')
        ? plural.substring(0, plural.length - 1)
        : plural;
    return '$n $singular';
  }
}

/// Why a link could not be used. Each maps to a message the user can act on.
enum RepoProblem {
  invalidUrl,
  notFound,
  networkError,
  webPage,
  invalidManifest,
  unsupportedFormat,
  noCompatibleSources,
}

class RepoInspectException implements Exception {
  RepoInspectException(this.problem, this.message);
  final RepoProblem problem;
  final String message;
  @override
  String toString() => message;
}

/// What a link turned out to be.
class RepoInspection {
  const RepoInspection({
    required this.format,
    required this.url,
    required this.name,
    required this.sourceCount,
  });

  final RepoFormat format;

  /// The URL in the form that format's adapter stores: the manifest URL for
  /// ClearCut / CloudStream / LNReader / Stremio, the index FOLDER for
  /// Aniyomi / Mihon (their fetchers add index.pb / index.json themselves).
  final String url;
  final String name;
  final int sourceCount;
}

/// Cleans a pasted link: the CloudStream tidy-up (quotes, <>, stray dots,
/// missing scheme, cloudstreamrepo://), then GitHub page links → raw files.
String normalizeRepoUrl(String raw) {
  // Repeat until stable: "<link>." needs the full stop removed before the
  // brackets can be, and one pass does those in the other order.
  var s = normalizeCsRepoUrl(raw);
  for (var i = 0; i < 3; i++) {
    final next = normalizeCsRepoUrl(s);
    if (next == s) break;
    s = next;
  }
  final uri = Uri.tryParse(s);
  if (uri == null) return s;
  final host = uri.host.toLowerCase();
  if (host == 'github.com' || host == 'www.github.com') {
    final segs = uri.pathSegments.where((p) => p.isNotEmpty).toList();
    // /owner/repo/(blob|raw|tree)/branch/path...
    if (segs.length >= 4 && const {'blob', 'raw', 'tree'}.contains(segs[2])) {
      final rest = [segs[0], segs[1], ...segs.skip(3)];
      return Uri(
        scheme: 'https',
        host: 'raw.githubusercontent.com',
        pathSegments: rest,
      ).toString();
    }
  }
  return s;
}

/// Pure format detection on an already-decoded manifest. Returns null when
/// the JSON matches no known repository format. Exposed for tests.
RepoFormat? detectRepoFormat(Object? json) {
  if (json is Map) {
    final sources = json['sources'];
    if (sources is List &&
        sources.whereType<Map>().any((m) => m['file'] is String)) {
      return RepoFormat.clearcut;
    }
    if (json['pluginLists'] is List) return RepoFormat.cloudstream;
    final extList = json['extensionList'];
    if (extList is Map && extList['extensions'] is List) {
      return _tachiyomiKind(extList['extensions'] as List);
    }
    final meta = json['meta'];
    if (meta is Map &&
        (meta.containsKey('signingKeyFingerprint') ||
            meta.containsKey('shortName'))) {
      // Mihon-style repo.json: names the repo; its index sits beside it.
      return RepoFormat.mihon;
    }
    if (json['resources'] is List &&
        json['types'] is List &&
        json['id'] is String) {
      return RepoFormat.stremio;
    }
    // A ClearCut manifest whose `sources` list is present but empty/invalid.
    if (sources is List) return RepoFormat.clearcut;
    return null;
  }
  if (json is List) {
    final maps = json.whereType<Map>().toList();
    if (maps.isEmpty) return null;
    if (maps.any((m) => m['pkg'] is String && m['apk'] is String)) {
      return _tachiyomiKind(maps);
    }
    if (maps.any(
      (m) => m['internalName'] is String && '${m['url']}'.endsWith('.cs3'),
    )) {
      // A CloudStream plugin list (plugins.json), not the repo itself.
      return RepoFormat.cloudstream;
    }
    if (maps.any(
      (m) => m['id'] is String && m['site'] is String && m['url'] is String,
    )) {
      return RepoFormat.lnreader;
    }
  }
  return null;
}

RepoFormat _tachiyomiKind(List entries) {
  final pkgs = entries.whereType<Map>().map((m) => '${m['pkg']}');
  // Aniyomi extensions live under eu.kanade.tachiyomi.animeextension.*;
  // Mihon/Tachiyomi manga ones under eu.kanade.tachiyomi.extension.*.
  return pkgs.any((p) => p.contains('.animeextension.'))
      ? RepoFormat.aniyomi
      : RepoFormat.mihon;
}

class RepoInspector {
  RepoInspector({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 20),
              followRedirects: true,
              maxRedirects: 8,
              responseType: ResponseType.plain,
              validateStatus: (_) => true,
            ),
          );

  final Dio _dio;

  /// Fetches [rawUrl], identifies its format and counts the sources it
  /// actually offers. Throws [RepoInspectException] with a specific
  /// [RepoProblem] otherwise — never returns a repo with zero sources.
  Future<RepoInspection> inspect(String rawUrl) async {
    final url = normalizeRepoUrl(rawUrl);
    final uri = Uri.tryParse(url);
    if (url.isEmpty || uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw RepoInspectException(
        RepoProblem.invalidUrl,
        "That doesn't look like a link. Paste the full repository URL.",
      );
    }

    // A link to a folder (no file name) is common for Tachiyomi-style repos.
    final last = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    final isFile = last.contains('.');
    final candidates = isFile
        ? [url]
        : [
            url,
            for (final f in const [
              'index.min.json',
              'index.json',
              'repo.json',
              'plugins.min.json',
              'manifest.json',
            ])
              _join(url, f),
          ];

    RepoInspectException? firstProblem;
    for (final candidate in candidates) {
      try {
        final body = await _get(candidate);
        return await _inspectBody(candidate, body);
      } on RepoInspectException catch (e) {
        // Keep the most useful error: the first one, unless a later file
        // was found but turned out wrong.
        if (firstProblem == null ||
            (firstProblem.problem == RepoProblem.notFound &&
                e.problem != RepoProblem.notFound)) {
          firstProblem = e;
        }
      }
    }
    throw firstProblem!;
  }

  Future<String> _get(String url) async {
    final Response<String> r;
    try {
      r = await _dio.get<String>(
        url,
        options: Options(headers: const {'Cache-Control': 'no-cache'}),
      );
    } on DioException catch (e) {
      throw RepoInspectException(
        RepoProblem.networkError,
        "Network error: couldn't reach ${Uri.tryParse(url)?.host ?? url} "
        '(${e.type.name}). Check your connection and try again.',
      );
    }
    final code = r.statusCode ?? 0;
    if (code == 404 || code == 410) {
      throw RepoInspectException(
        RepoProblem.notFound,
        'Nothing at this address (HTTP $code). Check the link — for GitHub, '
        'use the "Raw" link to the manifest file.',
      );
    }
    if (code < 200 || code >= 300) {
      throw RepoInspectException(
        RepoProblem.networkError,
        'The server answered HTTP $code. Try again later.',
      );
    }
    final body = r.data ?? '';
    if (body.trim().isEmpty) {
      throw RepoInspectException(
        RepoProblem.invalidManifest,
        'Invalid manifest: the file is empty.',
      );
    }
    return body;
  }

  Future<RepoInspection> _inspectBody(String url, String body) async {
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('<')) {
      throw RepoInspectException(
        RepoProblem.webPage,
        'This link opens a web page, not a repository file. On GitHub, open '
        'the manifest (e.g. repo.json or index.min.json) and copy its "Raw" '
        'link.',
      );
    }
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw RepoInspectException(
        RepoProblem.invalidManifest,
        'Invalid manifest: the file is not valid JSON.',
      );
    }
    final format = detectRepoFormat(json);
    if (format == null) {
      throw RepoInspectException(
        RepoProblem.unsupportedFormat,
        'Unsupported format: this JSON is not a ClearCut, CloudStream, '
        'Aniyomi, Mihon, LNReader or Stremio repository.',
      );
    }

    final (name, count, storeUrl) = await switch (format) {
      RepoFormat.clearcut => Future.value(_clearcut(url, json! as Map)),
      RepoFormat.cloudstream => _cloudstream(url, json!),
      RepoFormat.aniyomi || RepoFormat.mihon => _tachiyomi(url, json!),
      RepoFormat.lnreader => Future.value(_lnreader(url, json! as List)),
      RepoFormat.stremio => Future.value(_stremio(url, json! as Map)),
    };
    // A Mihon repo.json can point at an index of anime extensions.
    final resolvedFormat = format == RepoFormat.mihon && count.$2 != null
        ? count.$2!
        : format;
    if (count.$1 <= 0) {
      throw RepoInspectException(
        RepoProblem.noCompatibleSources,
        'No compatible sources: this ${resolvedFormat.label} repository lists '
        'no ${resolvedFormat.unitPlural}.',
      );
    }
    return RepoInspection(
      format: resolvedFormat,
      url: storeUrl,
      name: name,
      sourceCount: count.$1,
    );
  }

  (String, (int, RepoFormat?), String) _clearcut(String url, Map m) {
    final valid = ((m['sources'] as List?) ?? const [])
        .whereType<Map>()
        .where(
          (s) =>
              s['id'] is String &&
              s['name'] is String &&
              s['file'] is String &&
              (s['file'] as String).trim().isNotEmpty,
        )
        .length;
    return (_name(m['name'], url), (valid, null), url);
  }

  Future<(String, (int, RepoFormat?), String)> _cloudstream(
    String url,
    Object json,
  ) async {
    if (json is List) {
      // plugins.json pasted directly: CloudStream needs the repo.json that
      // lists it. Use the one beside it when it exists.
      final sibling = _join(_dir(url), 'repo.json');
      try {
        final body = await _get(sibling);
        final repo = jsonDecode(body);
        if (detectRepoFormat(repo) == RepoFormat.cloudstream && repo is Map) {
          return _cloudstream(sibling, repo);
        }
      } catch (_) {}
      throw RepoInspectException(
        RepoProblem.unsupportedFormat,
        'This is a CloudStream plugin list, not the repository itself. Add '
        "the repository's repo.json link instead.",
      );
    }
    final m = json as Map;
    var count = 0;
    for (final list in (m['pluginLists'] as List).whereType<String>()) {
      try {
        final plugins = jsonDecode(await _get(list));
        if (plugins is List) {
          count += plugins
              .whereType<Map>()
              .where((p) => '${p['url']}'.endsWith('.cs3'))
              .length;
        }
      } catch (e) {
        developer.log(
          'CloudStream plugin list failed · $list · $e',
          name: 'repo',
        );
      }
    }
    return (_name(m['name'], url), (count, null), url);
  }

  Future<(String, (int, RepoFormat?), String)> _tachiyomi(
    String url,
    Object json,
  ) async {
    final dir = _dir(url);
    List entries;
    if (json is List) {
      entries = json;
    } else if (json is Map && json['extensionList'] is Map) {
      entries = ((json['extensionList'] as Map)['extensions'] as List?) ?? [];
    } else {
      // Mihon repo.json: read the index that sits beside it.
      entries = const [];
      for (final f in const ['index.min.json', 'index.json']) {
        try {
          final idx = jsonDecode(await _get(_join(dir, f)));
          if (idx is List) {
            entries = idx;
            break;
          }
          if (idx is Map && idx['extensionList'] is Map) {
            entries =
                ((idx['extensionList'] as Map)['extensions'] as List?) ??
                const [];
            break;
          }
        } catch (_) {}
      }
    }
    final valid = entries
        .whereType<Map>()
        .where((e) => e['pkg'] is String && e['apk'] is String)
        .toList();
    final meta = json is Map ? json['meta'] : null;
    final name = meta is Map && meta['name'] is String
        ? meta['name'] as String
        : _repoNameFromUrl(dir);
    return (name, (valid.length, _tachiyomiKind(valid)), dir);
  }

  (String, (int, RepoFormat?), String) _lnreader(String url, List list) {
    final valid = list
        .whereType<Map>()
        .where((m) => m['id'] is String && m['url'] is String)
        .length;
    return (_repoNameFromUrl(url), (valid, null), url);
  }

  (String, (int, RepoFormat?), String) _stremio(String url, Map m) {
    final hasStreams = (m['resources'] as List).any(
      (r) => r == 'stream' || (r is Map && r['name'] == 'stream'),
    );
    final hasCatalogs =
        (m['catalogs'] is List) && (m['catalogs'] as List).isNotEmpty;
    return (
      _name(m['name'], url),
      ((hasStreams || hasCatalogs) ? 1 : 0, null),
      url,
    );
  }

  static String _name(Object? n, String url) =>
      n is String && n.trim().isNotEmpty ? n.trim() : _repoNameFromUrl(url);

  static String _repoNameFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (uri.host == 'raw.githubusercontent.com' && segs.length >= 2) {
      return '${segs[0]}/${segs[1]}';
    }
    return uri.host;
  }

  static String _dir(String url) {
    final uri = Uri.parse(url);
    final segs = uri.pathSegments.toList();
    if (segs.isNotEmpty && segs.last.contains('.')) segs.removeLast();
    while (segs.isNotEmpty && segs.last.isEmpty) {
      segs.removeLast();
    }
    return uri.replace(pathSegments: segs, query: null).toString();
  }

  static String _join(String base, String file) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return '$b/$file';
  }
}
