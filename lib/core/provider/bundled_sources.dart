import 'package:flutter/services.dart';

import 'provider_registry.dart';

/// A source script shipped inside the APK instead of fetched from a repo.
///
/// Only sources that are wanted on every install belong here. The legal
/// public-domain catalogue sources that used to live here were removed at the
/// owner's request; FrameXTV is kept, bundled exactly as supplied.
class BundledSource {
  const BundledSource(this.id, this.file, this.name, {this.optional = false});

  final String id;
  final String file;
  final String name;
  final bool optional;

  bool isInstalled(ProviderRegistry registry) => registry.getAll().any(
    (entry) => entry.name == id && entry.originRepoUrl == kBundledRepoUrl,
  );

  Future<void> install(ProviderRegistry registry) async {
    await registry.installFromBundled(
      name: id,
      jsSource: await rootBundle.loadString('assets/builtin_sources/$file'),
      displayName: name,
    );
  }
}

const frameXtvSourceId = 'clearcut_framextv';

const bundledSources = [
  BundledSource(frameXtvSourceId, 'framextv.js', 'FrameXTV'),
];

/// Ids of every source shipped inside the APK. Used by the resolver to make
/// sure these are asked early in the serialized JS lane: they are always
/// installed and always quick, so they should never be starved by a slow
/// third-party provider sitting in front of them.
Set<String> bundledSourceIds() => {for (final s in bundledSources) s.id};
