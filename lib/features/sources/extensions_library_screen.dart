import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/provider/extension_library.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';

/// ClearCut: every plugin from every repository the user has added, in one
/// place — searchable, filterable by what it serves, installable one by one or
/// all at once with "Download all".
///
/// Only the user's own repositories are read (added on the Extensions
/// screens). 18+ plugins are hidden unless adult sources are turned on, and
/// "Download all" never installs them.
class ExtensionsLibraryScreen extends StatefulWidget {
  const ExtensionsLibraryScreen({super.key});

  @override
  State<ExtensionsLibraryScreen> createState() =>
      _ExtensionsLibraryScreenState();
}

class _ExtensionsLibraryScreenState extends State<ExtensionsLibraryScreen> {
  final _library = ExtensionLibrary();
  final _search = TextEditingController();

  bool _loading = true;
  List<LibraryEntry> _all = const [];
  List<String> _errors = const [];
  LibraryKind? _kind; // null = all
  final Set<LibraryEntry> _installing = {};

  // "Download all" progress.
  bool _bulkRunning = false;
  bool _bulkCancel = false;
  int _bulkDone = 0;
  int _bulkTotal = 0;
  int _bulkFailed = 0;
  String _bulkCurrent = '';

  bool get _adultAllowed =>
      sl.isRegistered<PlaybackPrefs>() && sl<PlaybackPrefs>().nsfwSources;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _bulkCancel = true;
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final result = await _library.load();
    if (!mounted) return;
    setState(() {
      _all = result.entries;
      _errors = result.errors;
      _loading = false;
    });
  }

  List<LibraryEntry> get _visible {
    final q = _search.text.trim().toLowerCase();
    return [
      for (final e in _all)
        if ((_adultAllowed || !e.nsfw) &&
            (_kind == null || e.kind == _kind) &&
            (q.isEmpty ||
                e.name.toLowerCase().contains(q) ||
                e.lang.toLowerCase() == q ||
                e.format.label.toLowerCase().contains(q)))
          e,
    ];
  }

  /// What "Download all" would install for the current filter and search.
  List<LibraryEntry> get _bulkTargets => [
    for (final e in _visible)
      if (!e.installed && !e.nsfw) e,
  ];

  Future<void> _installOne(LibraryEntry e) async {
    setState(() => _installing.add(e));
    final ok = await e.install();
    if (!mounted) return;
    setState(() => _installing.remove(e));
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            ok ? 'Installed ${e.name}' : "Couldn't install ${e.name}",
          ),
        ),
      );
  }

  Future<void> _downloadAll() async {
    final targets = _bulkTargets;
    if (targets.isEmpty) return;
    final scope = _kind?.label ?? 'all types';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Download all?', style: AppText.headline),
        content: Text(
          'Install ${targets.length} plugins ($scope) from your repositories.'
          '\n\nAlready-installed and 18+ plugins are skipped. Large repos can '
          'take a while and use mobile data; you can cancel at any time.',
          style: AppText.body.copyWith(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Install ${targets.length}'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _bulkRunning = true;
      _bulkCancel = false;
      _bulkDone = 0;
      _bulkFailed = 0;
      _bulkTotal = targets.length;
    });
    // One at a time: APK installs and plugin loads are heavy, and parallel
    // installs into the same extension host race each other.
    for (final e in targets) {
      if (_bulkCancel || !mounted) break;
      setState(() {
        _bulkCurrent = e.name;
        _installing.add(e);
      });
      final success = await e.install();
      if (!mounted) return;
      setState(() {
        _installing.remove(e);
        _bulkDone++;
        if (!success) _bulkFailed++;
      });
    }
    if (!mounted) return;
    final cancelled = _bulkCancel;
    setState(() => _bulkRunning = false);
    final installed = _bulkDone - _bulkFailed;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '${cancelled ? 'Stopped. ' : ''}Installed $installed'
            '${_bulkFailed > 0 ? ', $_bulkFailed failed' : ''}.',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final installedCount = visible.where((e) => e.installed).length;
    final bulk = _bulkTargets;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(
        'Extensions library',
        actions: [
          IconButton(
            tooltip: 'Refresh repositories',
            onPressed: _loading || _bulkRunning ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _all.isEmpty
          ? _empty()
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: TextField(
                    controller: _search,
                    style: AppText.body,
                    decoration: InputDecoration(
                      hintText: 'Search plugins, languages or formats',
                      prefixIcon: const Icon(Icons.search_rounded),
                      filled: true,
                      fillColor: AppColors.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 52,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    children: [
                      _chip('All', null),
                      for (final k in LibraryKind.values) _chip(k.label, k),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: _bulkRunning ? _progress() : _downloadAllBar(bulk),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Row(
                    children: [
                      Text(
                        '${visible.length} plugins · $installedCount installed',
                        style: AppText.caption,
                      ),
                      const Spacer(),
                      if (_errors.isNotEmpty)
                        TextButton(
                          onPressed: _showErrors,
                          child: Text(
                            '${_errors.length} repo'
                            '${_errors.length == 1 ? '' : 's'} failed',
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: visible.length,
                    itemBuilder: (_, i) => _row(visible[i]),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _chip(String label, LibraryKind? kind) {
    final selected = _kind == kind;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: _bulkRunning ? null : (_) => setState(() => _kind = kind),
        selectedColor: AppColors.accent,
        labelStyle: AppText.caption.copyWith(
          color: selected ? Colors.white : AppColors.textSecondary,
        ),
      ),
    );
  }

  Widget _downloadAllBar(List<LibraryEntry> bulk) {
    return SizedBox(
      width: double.infinity,
      height: 46,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          disabledBackgroundColor: AppColors.surface2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        onPressed: bulk.isEmpty ? null : _downloadAll,
        icon: const Icon(Icons.download_rounded),
        label: Text(
          bulk.isEmpty
              ? 'Everything here is installed'
              : 'Download all (${bulk.length})',
        ),
      ),
    );
  }

  Widget _progress() {
    final fraction = _bulkTotal == 0 ? 0.0 : _bulkDone / _bulkTotal;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Installing ${_bulkDone + 1 > _bulkTotal ? _bulkTotal : _bulkDone + 1}'
                  ' of $_bulkTotal · $_bulkCurrent',
                  style: AppText.caption.copyWith(color: AppColors.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: _bulkCancel
                    ? null
                    : () => setState(() => _bulkCancel = true),
                child: Text(_bulkCancel ? 'Stopping…' : 'Cancel'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: fraction,
            color: AppColors.accent,
            backgroundColor: AppColors.surface2,
          ),
          if (_bulkFailed > 0) ...[
            const SizedBox(height: 6),
            Text('$_bulkFailed failed so far', style: AppText.caption),
          ],
        ],
      ),
    );
  }

  Widget _row(LibraryEntry e) {
    final busy = _installing.contains(e);
    final details = [
      e.format.label,
      e.kind.label,
      if (e.lang.isNotEmpty) e.lang.toUpperCase(),
      if (e.version.isNotEmpty) 'v${e.version}',
    ].join(' · ');
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 40,
          height: 40,
          child: e.iconUrl == null || e.iconUrl!.isEmpty
              ? ColoredBox(
                  color: AppColors.surface2,
                  child: const Icon(Icons.extension_rounded, size: 20),
                )
              : CachedNetworkImage(
                  imageUrl: e.iconUrl!,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => ColoredBox(
                    color: AppColors.surface2,
                    child: const Icon(Icons.extension_rounded, size: 20),
                  ),
                ),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              e.name,
              style: AppText.body,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (e.nsfw) ...[
            const SizedBox(width: 6),
            Text(
              '18+',
              style: AppText.caption.copyWith(color: AppColors.accent),
            ),
          ],
        ],
      ),
      subtitle: Text(details, style: AppText.caption, maxLines: 1),
      trailing: e.installed
          ? const Icon(Icons.check_circle_rounded, color: Colors.greenAccent)
          : busy
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              onPressed: _bulkRunning ? null : () => _installOne(e),
              child: const Text('Install'),
            ),
    );
  }

  Widget _empty() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.extension_off_rounded,
            size: 48,
            color: AppColors.textTertiary,
          ),
          const SizedBox(height: 12),
          Text(
            'No repositories yet',
            style: AppText.headline,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'Add a repository on any Extensions screen (ClearCut, CloudStream, '
            'Aniyomi, Mihon, Mangayomi or LNReader). Everything it offers '
            'appears here.',
            style: AppText.caption,
            textAlign: TextAlign.center,
          ),
          if (_errors.isNotEmpty) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: _showErrors,
              child: Text('${_errors.length} repositories failed to load'),
            ),
          ],
        ],
      ),
    ),
  );

  void _showErrors() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text("Repositories that didn't load", style: AppText.headline),
        content: SingleChildScrollView(
          child: Text(
            _errors.join('\n\n'),
            style: AppText.caption.copyWith(color: AppColors.textSecondary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
