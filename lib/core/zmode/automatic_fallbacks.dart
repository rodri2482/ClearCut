import 'package:get_it/get_it.dart';

import '../provider/bundled_sources.dart';
import '../repository/source_repository.dart';
import 'nsfw_guard.dart';
import 'source_order_prefs.dart';
import 'zmode_ids.dart';

/// Adds FrameXTV as an automatic last resort for video titles.
///
/// FrameXTV ships inside the APK, so it is always available even when the
/// viewer never added it to Source Priority. It used to be *inserted at index
/// 1*, which silently overrode the viewer's own order. That is not acceptable:
/// a source the viewer put first must be tried first.
///
/// Appending it instead means every configured source is still tried ahead of
/// it, but a source that is installed and enabled is never left out of the
/// automatic sweep merely because it was never dragged into the priority list.
///
/// Honours an explicit exclusion and the NSFW guard, and is a no-op for reading
/// titles (FrameXTV only serves video).
/// The sources [withAutomaticFallbacks] would append for [kind], in the order
/// it appends them.
///
/// This is public because the sweep needs the same answer for a second reason:
/// a fallback sits *last* in the ask order by design, and asking it late is not
/// the same as asking it at all. `SourceMatcher` uses this to start those
/// searches early while still accepting them only after the viewer's own order
/// has come up empty. Keeping both readers on one function is what stops
/// "what is a fallback" and "what gets the early ask" from drifting apart.
///
/// Returns nothing for reading kinds (FrameXTV only serves video), for a source
/// the viewer switched off, for a blocked or uninstalled source, and when the
/// cloud surfaces are not wired up.
List<({String id, String name})> automaticFallbacks(ZKind kind) {
  if (kind == ZKind.manga || kind == ZKind.novel) return const [];

  final getIt = GetIt.instance;
  if (!getIt.isRegistered<SourceRepository>() ||
      !getIt.isRegistered<SourceOrderPrefs>()) {
    return const [];
  }
  if (isAutoResolveBlocked(frameXtvSourceId)) return const [];
  if (getIt<SourceOrderPrefs>().excluded(kind).contains(frameXtvSourceId)) {
    return const [];
  }
  // Installed but disabled/unavailable sources must not be forced back in.
  if (!getIt<SourceRepository>().pickableSources.any(
    (s) => s.id == frameXtvSourceId,
  )) {
    return const [];
  }
  return [(id: frameXtvSourceId, name: 'FrameXTV')];
}

List<({String id, String name})> withAutomaticFallbacks(
  List<({String id, String name})> ordered,
  ZKind kind,
) {
  final result = List<({String id, String name})>.from(ordered);
  for (final fallback in automaticFallbacks(kind)) {
    if (result.any((s) => s.id == fallback.id)) continue;
    result.add(fallback);
  }
  return result;
}
