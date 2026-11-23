import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/environment.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/share/share_link.dart';

void main() {
  group('ShareLink.watchUrl', () {
    test('shares a ClearCut link and round-trips the title', () {
      const item = MediaItem(
        id: '123',
        url: 'https://example.org/one-piece',
        title: 'One Piece',
        type: ProviderType.anime,
        sourceId: 'cs:example',
      );
      final uri = Uri.parse(ShareLink.forItem(item));
      expect(uri.scheme, Environment.siteOpenUri?.scheme ?? 'clearcut');
      expect(uri.host, Environment.siteOpenUri?.host ?? 'open');
      expect(ShareLink.parse(uri)?.title, item.title);
      expect(ShareLink.parse(uri)?.sourceId, item.sourceId);
      // No CLEARCUT_SITE_URL is needed: the app's own clearcut://open link is
      // a valid share URL and keeps the Discord "Open in ClearCut" button live.
      expect(
        ShareLink.watchUrl(
          sourceId: item.sourceId,
          url: item.url,
          title: item.title,
          type: item.type,
        ),
        uri.toString(),
      );
    });

    test('null when the title identity is incomplete', () {
      expect(
        ShareLink.watchUrl(
          sourceId: '',
          url: 'https://hianime.to/watch/x',
          title: 'X',
          type: ProviderType.anime,
        ),
        isNull,
      );
      expect(
        ShareLink.watchUrl(
          sourceId: 'cs:hiAnime',
          url: null,
          title: 'X',
          type: ProviderType.anime,
        ),
        isNull,
      );
      expect(
        ShareLink.watchUrl(
          sourceId: 'cs:hiAnime',
          url: '',
          title: 'X',
          type: ProviderType.anime,
        ),
        isNull,
      );
    });
  });
}
