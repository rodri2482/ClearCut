import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../aniyomi/aniyomi_extension_service.dart';
import '../aniyomi/aniyomi_repo.dart';
import '../di/injector.dart';
import '../hive/safe_box.dart';
import '../lnreader/lnreader_manager.dart';
import '../mangayomi/mangayomi_manager.dart';
import '../mihon/mihon_extension_service.dart';
import '../mihon/mihon_manager.dart';
import '../mihon/mihon_repo.dart';
import '../provider/provider_manager.dart' show AniyomiManager;
import 'cloudstream_provider.dart';
import 'provider_registry.dart';
import 'provider_repo_registry.dart';

/// What a plugin serves, for the library's filters.
enum LibraryKind { moviesSeries, anime, manga, novel }

extension LibraryKindX on LibraryKind {
  String get label => switch (this) {
    LibraryKind.moviesSeries => 'Movies & series',
    LibraryKind.anime => 'Anime',
    LibraryKind.manga => 'Manga',
    LibraryKind.novel => 'Novels',
  };
}

/// Which extension system a plugin belongs to. Each keeps its own installer.
enum LibraryFormat {
  clearcut,
  cloudstream,
  aniyomi,
  mihon,
  mangayomi,
  lnreader,
}

extension LibraryFormatX on LibraryFormat {
  String get label => switch (this) {
    LibraryFormat.clearcut => 'ClearCut',
    LibraryFormat.cloudstream => 'CloudStream',
    LibraryFormat.aniyomi => 'Aniyomi',
    LibraryFormat.mihon => 'Mihon',
    LibraryFormat.mangayomi => 'Mangayomi',
    LibraryFormat.lnreader => 'LNReader',
  };
}

/// One installable plugin from one of the user's repositories.
class LibraryEntry {
  LibraryEntry({
    required this.format,
    required this.kind,
    required this.id,
    required this.name,
    required this.repoUrl,
    required this.installed,
    required Future<bool> Function() install,
    this.lang = '',
    this.version = '',
    this.iconUrl,
    this.nsfw = false,
  }) : _install = install;

  final LibraryFormat format;
  final LibraryKind kind;
  final String id;
  final String name;
  final String repoUrl;
  final String lang;
  final String version;
  final String? iconUrl;
  final bool nsfw;
  bool installed;
  final Future<bool> Function() _install;

  /// Installs with this plugin's own system. Never throws; true on success.
  Future<bool> install() async {
    try {
      final ok = await _install();
      if (ok) installed = true;
      return ok;
    } catch (e, st) {
      debugPrint('[library] install ${format.label}/$id failed: $e\n$st');
      return false;
    }
  }
}

/// ClearCut: one catalogue of every plugin in every repository the user has
/// added — ClearCut, CloudStream, Aniyomi, Mihon, Mangayomi and LNReader — so
/// they can be browsed, searched and installed (one by one or all at once)
/// from a single screen.
///
/// It only reads repositories the user added on the Extensions screens; it
/// never adds a repository itself. Each plugin is installed by its own
/// system's installer (APKs by the APK loaders, .cs3 by the CloudStream host,
/// JS by the JS runtimes) exactly as its own screen would.
class ExtensionLibrary {
  /// Repo-list boxes as the Aniyomi / Mihon / LNReader screens store them.
  static const _aniyomiRepos = 'aniyomi_repos';
  static const _mihonRepos = 'mihon_repos';
  static const _lnreaderRepos = 'lnreader_repos';

  /// Loads every catalogue. Repositories that fail are reported in [errors]
  /// (one line each) and the rest still load.
  Future<({List<LibraryEntry> entries, List<String> errors})> load() async {
    final entries = <LibraryEntry>[];
    final errors = <String>[];
    Future<void> guard(String what, Future<void> Function() body) async {
      try {
        await body();
      } catch (e) {
        errors.add('$what: $e');
        debugPrint('[library] $what failed: $e');
      }
    }

    await Future.wait([
      guard('ClearCut repos', () async => entries.addAll(_clearcut())),
      guard(
        'CloudStream repos',
        () async => entries.addAll(await _cloudstream()),
      ),
      ..._repoUrls(_aniyomiRepos).map(
        (url) => guard(
          'Aniyomi $url',
          () async => entries.addAll(await _aniyomi(url)),
        ),
      ),
      ..._repoUrls(_mihonRepos).map(
        (url) =>
            guard('Mihon $url', () async => entries.addAll(await _mihon(url))),
      ),
      guard('Mangayomi repos', () async => entries.addAll(await _mangayomi())),
      ..._repoUrls(_lnreaderRepos).map(
        (url) => guard(
          'LNReader $url',
          () async => entries.addAll(await _lnreader(url)),
        ),
      ),
    ]);
    entries.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return (entries: entries, errors: errors);
  }

  static List<String> _repoUrls(String box) {
    if (!Hive.isBoxOpen(box)) return const [];
    return Hive.box<String>(box).values.toSet().toList();
  }

  static LibraryKind _kindOfType(String type) => switch (type.toLowerCase()) {
    'movie' || 'tv' || 'series' => LibraryKind.moviesSeries,
    'manga' => LibraryKind.manga,
    'novel' => LibraryKind.novel,
    _ => LibraryKind.anime,
  };

  // ── ClearCut JS repos ────────────────────────────────────────────────────

  List<LibraryEntry> _clearcut() {
    final repos = sl<ProviderReposRegistry>();
    final registry = sl<ProviderRegistry>();
    return [
      for (final repo in repos.getAll())
        for (final s in repo.sources)
          LibraryEntry(
            format: LibraryFormat.clearcut,
            kind: _kindOfType(s.type),
            id: s.id,
            name: s.name,
            lang: s.lang,
            version: s.version,
            iconUrl: ProviderReposRegistry.resolveLogoUrl(repo, s),
            nsfw: s.nsfw,
            repoUrl: repo.url,
            installed: registry.entryFor(s.id) != null,
            install: () async {
              await registry.install(
                sourceId: s.id,
                fileUrl: repos.resolveFileUrl(repo, s),
                repoUrl: repo.url,
                displayName: s.name,
                version: s.version,
                logoUrl: ProviderReposRegistry.resolveLogoUrl(repo, s) ?? '',
              );
              return true;
            },
          ),
    ];
  }

  // ── CloudStream (.cs3 plugins, Android only) ─────────────────────────────

  static const _animeTypes = {'anime', 'animemovie', 'ova'};

  Future<List<LibraryEntry>> _cloudstream() async {
    if (!Platform.isAndroid || !sl.isRegistered<CloudStreamManager>()) {
      return const [];
    }
    final cs = sl<CloudStreamManager>();
    for (final url in cs.repoUrls) {
      if (url.isNotEmpty) await cs.ensureCatalog(url);
    }
    return [
      for (final group in cs.repoGroups)
        if (group.url.isNotEmpty)
          for (final p in group.catalog)
            LibraryEntry(
              format: LibraryFormat.cloudstream,
              kind: p.tvTypes.any((t) => _animeTypes.contains(t.toLowerCase()))
                  ? LibraryKind.anime
                  : LibraryKind.moviesSeries,
              id: p.internalName,
              name: p.name,
              lang: p.language ?? '',
              version: '${p.version}',
              iconUrl: p.iconUrl,
              nsfw: p.tvTypes.any((t) => t.toLowerCase() == 'nsfw'),
              repoUrl: group.url,
              installed: cs.isPluginInstalled(
                p.internalName,
                repoUrl: group.url,
              ),
              install: () async {
                await cs.installPlugin(p, repoUrl: group.url);
                return cs.isPluginInstalled(p.internalName, repoUrl: group.url);
              },
            ),
    ];
  }

  // ── Aniyomi / Mihon (APK extensions) ─────────────────────────────────────

  static Future<bool> _installedPkg(String box, String pkg) async {
    final b = Hive.isBoxOpen(box)
        ? Hive.box<dynamic>(box)
        : await openBoxSafely<dynamic>(box);
    return b.containsKey(pkg);
  }

  Future<List<LibraryEntry>> _aniyomi(String url) async {
    final entries = await AniyomiRepo.fetchIndex(url);
    return [
      for (final e in entries)
        LibraryEntry(
          format: LibraryFormat.aniyomi,
          kind: LibraryKind.anime,
          id: e.pkg,
          name: e.name.replaceFirst(RegExp(r'^Aniyomi:\s*'), ''),
          lang: e.lang,
          version: e.version,
          iconUrl: e.iconUrl,
          nsfw: e.nsfw,
          repoUrl: url,
          installed: await _installedPkg(
            AniyomiExtensionService.installedBoxName,
            e.pkg,
          ),
          install: () async {
            final providers = await AniyomiExtensionService().installFromRepo(
              e,
              manager: sl<AniyomiManager>(),
            );
            return providers.isNotEmpty;
          },
        ),
    ];
  }

  Future<List<LibraryEntry>> _mihon(String url) async {
    final entries = await MihonRepo.fetchIndex(url);
    return [
      for (final e in entries)
        LibraryEntry(
          format: LibraryFormat.mihon,
          kind: LibraryKind.manga,
          id: e.pkg,
          name: e.name.replaceFirst(RegExp(r'^Tachiyomi:\s*'), ''),
          lang: e.lang,
          version: e.version,
          iconUrl: e.iconUrl,
          nsfw: e.nsfw,
          repoUrl: url,
          installed: await _installedPkg(
            MihonExtensionService.installedBoxName,
            e.pkg,
          ),
          install: () async {
            final providers = await MihonExtensionService().installFromRepo(
              e,
              manager: sl<MihonManager>(),
            );
            return providers.isNotEmpty;
          },
        ),
    ];
  }

  // ── Mangayomi (JS / Dart sources via the bridge) ─────────────────────────

  Future<List<LibraryEntry>> _mangayomi() async {
    if (!sl.isRegistered<MangayomiManager>()) return const [];
    final m = sl<MangayomiManager>();
    final out = <LibraryEntry>[];
    for (final repo in m.repositories) {
      final catalogue = await m.refreshRepository(repo);
      for (final s in catalogue) {
        final type = s.contentType.name.toLowerCase();
        out.add(
          LibraryEntry(
            format: LibraryFormat.mangayomi,
            kind: type == 'manga'
                ? LibraryKind.manga
                : type == 'novel'
                ? LibraryKind.novel
                : LibraryKind.anime,
            id: s.key,
            name: s.name,
            lang: s.language,
            version: s.version,
            iconUrl: s.iconUrl?.toString(),
            nsfw: s.isNsfw,
            repoUrl: repo.toString(),
            installed: m.installed.any((i) => i.source.key == s.key),
            install: () async {
              await m.install(s);
              return m.installed.any((i) => i.source.key == s.key);
            },
          ),
        );
      }
    }
    return out;
  }

  // ── LNReader (JS novel plugins) ──────────────────────────────────────────

  Future<List<LibraryEntry>> _lnreader(String url) async {
    if (!sl.isRegistered<LnReaderManager>()) return const [];
    final service = sl<LnReaderManager>().service;
    final metas = await service.fetchIndex(url);
    final installedIds = {for (final m in service.installed()) m.id};
    return [
      for (final meta in metas)
        LibraryEntry(
          format: LibraryFormat.lnreader,
          kind: LibraryKind.novel,
          id: meta.id,
          name: meta.name,
          lang: meta.lang,
          version: meta.version,
          iconUrl: meta.iconUrl.isEmpty ? null : meta.iconUrl,
          repoUrl: url,
          installed: installedIds.contains(meta.id),
          install: () async {
            await service.install(meta);
            return true;
          },
        ),
    ];
  }
}
