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
List<({String id, String name})> withAutomaticFallbacks(
  List<({String id, String name})> ordered,
  ZKind kind,
) {
  final result = List<({String id, String name})>.from(ordered);
  if (kind == ZKind.manga || kind == ZKind.novel) return result;
  if (result.any((s) => s.id == frameXtvSourceId)) return result;

  final getIt = GetIt.instance;
  if (!getIt.isRegistered<SourceRepository>() ||
      !getIt.isRegistered<SourceOrderPrefs>()) {
    return result;
  }
  if (isAutoResolveBlocked(frameXtvSourceId)) return result;
  if (getIt<SourceOrderPrefs>().excluded(kind).contains(frameXtvSourceId)) {
    return result;
  }
  // Installed but disabled/unavailable sources must not be forced back in.
  if (!getIt<SourceRepository>().pickableSources.any(
    (s) => s.id == frameXtvSourceId,
  )) {
    return result;
  }

  result.add((id: frameXtvSourceId, name: 'FrameXTV'));
  return result;
}
