import 'dart:io';

import 'package:hive/hive.dart';

import '../aniyomi/aniyomi_repo.dart';
import '../di/injector.dart';
import '../hive/safe_box.dart';
import '../stremio/stremio_manager.dart';
import 'cloudstream_provider.dart';
import 'provider_repo_registry.dart';
import 'repo_inspector.dart';

/// Hive boxes of tracked repo URLs, as the Aniyomi / Mihon / LNReader screens
/// store them (Box<String>, list-style). Same names as those screens'
/// constants; kept here so core code doesn't import feature code.
const String _aniyomiBox = 'aniyomi_repos';
const String _mihonBox = 'mihon_repos';
const String _lnreaderBox = 'lnreader_repos';

/// The result of adding a repo, for the snackbar.
class RepoAddResult {
  const RepoAddResult(this.inspection, {this.alreadyAdded = false});
  final RepoInspection inspection;
  final bool alreadyAdded;

  String get message {
    final i = inspection;
    final where = i.format == RepoFormat.clearcut
        ? ''
        : ' Open Extensions → ${i.format.label} to install them.';
    if (alreadyAdded) {
      return '${i.name} is already added (${i.format.label}, '
          '${i.format.count(i.sourceCount)}).';
    }
    return 'Added ${i.name} — ${i.format.label} repository with '
        '${i.format.count(i.sourceCount)}.$where';
  }
}

/// Validates a pasted link with [RepoInspector], then stores it with the
/// adapter that matches its format: ClearCut repos in the provider registry,
/// CloudStream repos in the native plugin host, Aniyomi / Mihon / LNReader
/// repos in their own lists, Stremio add-ons in the Stremio manager.
///
/// [expected] is the screen the user is on. When the link is another format,
/// it is still added to the right place (the message says where), because
/// what the user wants is a working repo, not a lesson in formats.
///
/// Throws [RepoInspectException] with a specific problem; never stores a
/// repository that offers no compatible sources.
class RepoRouter {
  RepoRouter({RepoInspector? inspector})
    : _inspector = inspector ?? RepoInspector();

  final RepoInspector _inspector;

  Future<RepoAddResult> add(String rawUrl) async {
    final i = await _inspector.inspect(rawUrl);
    switch (i.format) {
      case RepoFormat.clearcut:
        final registry = sl<ProviderReposRegistry>();
        final existed = registry.has(i.url);
        await registry.fetchAndCache(i.url);
        return RepoAddResult(i, alreadyAdded: existed);
      case RepoFormat.cloudstream:
        if (!Platform.isAndroid) {
          throw RepoInspectException(
            RepoProblem.unsupportedFormat,
            'CloudStream plugins only run on Android.',
          );
        }
        final cs = sl<CloudStreamManager>();
        final existed = cs.repoUrls.contains(i.url);
        await cs.addRepo(i.url);
        return RepoAddResult(i, alreadyAdded: existed);
      case RepoFormat.aniyomi:
        return RepoAddResult(
          i,
          alreadyAdded: !await _addTo(_aniyomiBox, i.url),
        );
      case RepoFormat.mihon:
        return RepoAddResult(i, alreadyAdded: !await _addTo(_mihonBox, i.url));
      case RepoFormat.lnreader:
        return RepoAddResult(
          i,
          alreadyAdded: !await _addTo(_lnreaderBox, i.url),
        );
      case RepoFormat.stremio:
        try {
          await sl<StremioManager>().install(i.url);
          return RepoAddResult(i);
        } on StremioInstallException catch (e) {
          if (e.message.contains('already installed')) {
            return RepoAddResult(i, alreadyAdded: true);
          }
          rethrow;
        }
    }
  }

  /// Adds [url] to a repo list unless an equivalent URL is already there.
  /// Returns false when it was a duplicate.
  static Future<bool> _addTo(String boxName, String url) async {
    final box = Hive.isBoxOpen(boxName)
        ? Hive.box<String>(boxName)
        : await openBoxSafely<String>(boxName);
    final key = _dedupeKey(url);
    if (box.values.any((v) => _dedupeKey(v) == key)) return false;
    await box.add(url);
    return true;
  }

  /// Folder links and links to the index file inside them are the same repo.
  static String _dedupeKey(String url) =>
      AniyomiRepo.normalizeBase(normalizeRepoUrl(url)).toLowerCase();
}
