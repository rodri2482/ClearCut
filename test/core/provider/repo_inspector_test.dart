import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';
import 'package:watch_app/core/provider/repo_inspector.dart';

// Regression tests for the repository bugs fixed in ClearCut:
//  * a CloudStream repo.json saved as a ClearCut repo with 0 sources;
//  * Aniyomi/Mihon indexes, LNReader indexes and Stremio manifests not told
//    apart from each other;
//  * GitHub page links, pasted wrappers and repo.json links turning into 404s.
void main() {
  group('detectRepoFormat', () {
    test('ClearCut manifest', () {
      expect(
        detectRepoFormat({
          'name': 'r',
          'sources': [
            {'id': 'a', 'name': 'A', 'file': 'a.js'},
          ],
        }),
        RepoFormat.clearcut,
      );
    });

    test('CloudStream repo.json is not a ClearCut repo', () {
      expect(
        detectRepoFormat({
          'name': 'csext',
          'manifestVersion': 1,
          'pluginLists': ['https://x/plugins.json'],
        }),
        RepoFormat.cloudstream,
      );
    });

    test('CloudStream plugins.json', () {
      expect(
        detectRepoFormat([
          {'internalName': 'P', 'url': 'https://x/P.cs3', 'version': 1},
        ]),
        RepoFormat.cloudstream,
      );
    });

    test('Aniyomi index (anime extension packages)', () {
      expect(
        detectRepoFormat([
          {
            'name': 'Aniyomi: X',
            'pkg': 'eu.kanade.tachiyomi.animeextension.en.x',
            'apk': 'x.apk',
          },
        ]),
        RepoFormat.aniyomi,
      );
    });

    test('Mihon index (manga extension packages)', () {
      expect(
        detectRepoFormat([
          {
            'name': 'Tachiyomi: Y',
            'pkg': 'eu.kanade.tachiyomi.extension.en.y',
            'apk': 'y.apk',
          },
        ]),
        RepoFormat.mihon,
      );
    });

    test('Mihon index.json with extensionList', () {
      expect(
        detectRepoFormat({
          'extensionList': {
            'extensions': [
              {'pkg': 'eu.kanade.tachiyomi.extension.en.y', 'apk': 'y.apk'},
            ],
          },
        }),
        RepoFormat.mihon,
      );
    });

    test('Mihon repo.json descriptor', () {
      expect(
        detectRepoFormat({
          'meta': {
            'name': 'Repo',
            'shortName': 'R',
            'signingKeyFingerprint': 'f',
          },
        }),
        RepoFormat.mihon,
      );
    });

    test('LNReader plugin index', () {
      expect(
        detectRepoFormat([
          {
            'id': 'n',
            'name': 'N',
            'site': 'https://n',
            'url': 'https://x/n.js',
            'version': '1',
          },
        ]),
        RepoFormat.lnreader,
      );
    });

    test('Stremio manifest', () {
      expect(
        detectRepoFormat({
          'id': 'org.x',
          'name': 'X',
          'resources': ['stream'],
          'types': ['movie'],
        }),
        RepoFormat.stremio,
      );
    });

    test('unrelated JSON is unsupported', () {
      expect(detectRepoFormat({'id': 1342, 'title': 'Pride'}), isNull);
      expect(detectRepoFormat(<Object>[]), isNull);
      expect(detectRepoFormat('text'), isNull);
    });
  });

  group('normalizeRepoUrl', () {
    test('GitHub blob/raw/tree page links become raw links', () {
      expect(
        normalizeRepoUrl('https://github.com/o/r/blob/main/repo.json'),
        'https://raw.githubusercontent.com/o/r/main/repo.json',
      );
      expect(
        normalizeRepoUrl('https://github.com/o/r/raw/builds/plugins.json'),
        'https://raw.githubusercontent.com/o/r/builds/plugins.json',
      );
      expect(
        normalizeRepoUrl('https://github.com/o/r/tree/repo'),
        'https://raw.githubusercontent.com/o/r/repo',
      );
    });

    test('wrapped and punctuated pastes are cleaned', () {
      expect(
        normalizeRepoUrl('<raw.githubusercontent.com/o/r/b/repo.json>.'),
        'https://raw.githubusercontent.com/o/r/b/repo.json',
      );
      expect(
        normalizeRepoUrl('  "https://x.com/index.min.json"  '),
        'https://x.com/index.min.json',
      );
    });
  });

  group('AniyomiRepo.normalizeBase', () {
    test('repo.json and index links resolve to the folder', () {
      for (final link in [
        'https://raw.githubusercontent.com/o/r/repo/repo.json',
        'https://raw.githubusercontent.com/o/r/repo/index.min.json',
        'https://raw.githubusercontent.com/o/r/repo/index.json',
        'https://raw.githubusercontent.com/o/r/repo/',
        'https://github.com/o/r/blob/repo/index.min.json',
      ]) {
        expect(
          AniyomiRepo.normalizeBase(link),
          'https://raw.githubusercontent.com/o/r/repo',
          reason: link,
        );
      }
    });
  });

  test('singular and plural counts', () {
    expect(RepoFormat.cloudstream.count(1), '1 plugin');
    expect(RepoFormat.cloudstream.count(3), '3 plugins');
    expect(RepoFormat.aniyomi.count(0), '0 extensions');
  });
}
