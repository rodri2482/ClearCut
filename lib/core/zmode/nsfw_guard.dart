import '../di/injector.dart';
import '../provider/provider_registry.dart';

/// Whether [sourceId] must be kept out of AUTOMATIC matching.
///
/// Adult sources are deliberately allowed to exist for explicit per-title
/// selection, but they must never be picked by Auto Resolve: a sweep has no
/// way to know that "Ben 10" from an adult source is not the children's show,
/// and the result is a family title opening unrelated explicit content.
///
/// The checked-in built-ins never advertise NSFW, so this only affects
/// third-party plugin sources the viewer installed themselves.
bool isAutoResolveBlocked(String sourceId) {
  final lower = sourceId.toLowerCase();
  // Defence in depth: a source whose very id says NSFW is always excluded,
  // even if its repo manifest forgot to flag it.
  if (lower.contains('nsfw')) return true;
  try {
    if (!sl.isRegistered<ProviderRegistry>()) return false;
    final ids = sl<ProviderRegistry>().nsfwSourceIds();
    if (ids.isEmpty) return false;
    final bare = sourceId.contains(':') ? sourceId.split(':').last : sourceId;
    return ids.contains(sourceId) || ids.contains(bare);
  } catch (_) {
    return false;
  }
}
