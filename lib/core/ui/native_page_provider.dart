import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../aniyomi/aniyomi_image_provider.dart';
import '../mihon/mihon_image_provider.dart';

/// The native image path for a CHAPTER PAGE, or null when the page is an
/// ordinary one that Flutter should fetch itself.
///
/// The markers are the same as for covers (`x-mihon-src` / `x-ani-src`).
///
/// ClearCut: the Mihon bridge now marks EVERY page of an HTTP source, so pages
/// load through the source's own OkHttp client like they do in Mihon. Flutter's
/// image downloader skips that client's interceptors, session and Cloudflare
/// handling, which left many sources' pages blank in the reader while "open in
/// browser" showed them. The page's own headers ride along and are merged
/// natively over the source's headers.
///
/// Returns null for an unmarked page (JS / Mangayomi sources, local files),
/// so the caller keeps its existing behaviour.
ImageProvider? nativePageProvider(String url, Map<String, String>? headers) {
  final ani = headers?['x-ani-src'];
  if (ani != null) {
    final id = int.tryParse(ani);
    if (id != null) return AniyomiImage(id, url);
  }
  final mihon = headers?['x-mihon-src'];
  if (mihon != null) {
    final id = int.tryParse(mihon);
    if (id != null) return MihonImage(id, url, headers: realHeaders(headers));
  }
  return null;
}

/// [headers] without ClearCut's internal routing markers, which must never be
/// sent over the network.
Map<String, String>? realHeaders(Map<String, String>? headers) {
  if (headers == null) return null;
  final out = {
    for (final e in headers.entries)
      if (!e.key.startsWith('x-mihon') && !e.key.startsWith('x-ani'))
        e.key: e.value,
  };
  return out.isEmpty ? null : out;
}

/// Fetches a natively-routed page's bytes (for chapter downloads), or returns
/// null when the page is not natively routed and should be fetched normally.
Future<Uint8List?> fetchNativePageBytes(
  String url,
  Map<String, String>? headers,
) async {
  final mihon = headers?['x-mihon-src'];
  final ani = headers?['x-ani-src'];
  final marker = mihon ?? ani;
  final id = marker == null ? null : int.tryParse(marker);
  if (id == null) return null;
  final channel = MethodChannel(
    mihon != null ? 'zangetsu/mihon' : 'zangetsu/aniyomi',
  );
  final bytes = await channel.invokeMethod<Uint8List>('getImage', {
    'sourceId': id,
    'url': url,
    if (realHeaders(headers) != null) 'headers': realHeaders(headers),
  });
  if (bytes == null || bytes.isEmpty) {
    throw Exception('empty image from the source for $url');
  }
  return bytes;
}
