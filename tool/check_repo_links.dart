// Live check of the repository inspector against real addresses.
// Run: dart run tool/check_repo_links.dart
import 'package:watch_app/core/provider/repo_inspector.dart';

Future<void> main() async {
  final cases = <String, String>{
    'CloudStream repo.json (raw)':
        'https://raw.githubusercontent.com/Adiversion/csext/builds/repo.json',
    'Same repo, GitHub page link':
        'https://github.com/Adiversion/csext/blob/builds/repo.json',
    'Same repo, pasted in <> with a full stop':
        '<raw.githubusercontent.com/Adiversion/csext/builds/repo.json>.',
    'CloudStream plugins.json pasted directly':
        'https://raw.githubusercontent.com/Adiversion/csext/builds/plugins.json',
    'Stremio add-on (Cinemeta)': 'https://v3-cinemeta.strem.io/manifest.json',
    'Missing file (404)':
        'https://raw.githubusercontent.com/Adiversion/csext/builds/nope.json',
    'GitHub repo web page': 'https://github.com/Adiversion/csext',
    'Not JSON':
        'https://raw.githubusercontent.com/flutter/flutter/master/LICENSE',
    'JSON but not a repo': 'https://gutendex.com/books/1342/',
    'Not a link': 'hello world',
  };
  final inspector = RepoInspector();
  for (final e in cases.entries) {
    try {
      final r = await inspector.inspect(e.value);
      print(
        'OK    ${e.key}\n      → ${r.format.label}, "${r.name}", '
        '${r.format.count(r.sourceCount)}, stored as ${r.url}',
      );
    } on RepoInspectException catch (x) {
      print('ERROR ${e.key}\n      → ${x.problem.name}: ${x.message}');
    }
  }
}
