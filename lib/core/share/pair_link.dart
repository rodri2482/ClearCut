import '../environment.dart';
import '../supabase/auth_route.dart';

/// Encodes and parses TV pairing links.
class PairLink {
  const PairLink({
    this.code,
    this.nonce,
    this.trackers = false,
    this.authority = 'cloud',
  });

  final String authority;

  final String? code;
  final String? nonce;

  /// When true this is the trackers-only QR (Flow B), not account sign-in.
  final bool trackers;

  /// Uses ClearCut's web handoff when configured.
  static String qrData({
    required String code,
    String? nonce,
    bool trackers = false,
    String? authority,
  }) {
    final site = Environment.sitePairUri;
    if (site == null) {
      return deepLink(
        code: code,
        nonce: nonce,
        trackers: trackers,
        authority: authority,
      );
    }
    return site
        .replace(
          queryParameters: _query(
            code: code,
            nonce: nonce,
            trackers: trackers,
            authority: authority,
          ),
        )
        .toString();
  }

  /// Custom-scheme deeplink for TV "have the app" QRs and Android intent-filters.
  /// Handled by [OpenLinkService].
  static String deepLink({
    required String code,
    String? nonce,
    bool trackers = false,
    String? authority,
  }) {
    return Uri(
      scheme: Environment.openLinkScheme,
      host: Environment.pairLinkHost,
      queryParameters: _query(
        code: code,
        nonce: nonce,
        trackers: trackers,
        authority: authority,
      ),
    ).toString();
  }

  static Map<String, String> _query({
    required String code,
    String? nonce,
    bool trackers = false,
    String? authority,
  }) => {
    'code': code,
    if ((authority ?? AuthRoute.active.authority) == 'vps') 'auth': 'vps',
    if (nonce != null && nonce.isNotEmpty) 'nonce': nonce,
    if (trackers) 'trackers': '1',
  };

  static String trackerWebLink({
    required String code,
    required String nonce,
    required String tracker,
    String? authority,
  }) =>
      (Environment.siteBaseUri?.resolve('tv-connect/') ??
              Uri(
                scheme: Environment.openLinkScheme,
                host: Environment.pairLinkHost,
              ))
          .replace(
            queryParameters: {
              ..._query(
                code: code,
                nonce: nonce,
                trackers: Environment.siteBaseUri == null,
                authority: authority,
              ),
              'tracker': tracker,
            },
          )
          .toString();

  /// Accepts current and legacy pairing links.
  static PairLink? parse(Uri uri) {
    if (!_isPairUri(uri)) return null;
    if ((uri.queryParametersAll['auth']?.length ?? 0) > 1) return null;
    final q = uri.queryParameters;
    final authority = q['auth'] ?? 'cloud';
    if (authority != 'cloud' && authority != 'vps') return null;
    return PairLink(
      code: q['code'],
      nonce: q['nonce'],
      trackers: q['trackers'] == '1',
      authority: authority,
    );
  }

  static bool _isPairUri(Uri uri) {
    if ((uri.scheme == Environment.openLinkScheme ||
            uri.scheme == Environment.trackerRedirectScheme) &&
        uri.host == Environment.pairLinkHost) {
      return true;
    }
    if (uri.scheme != 'https') return false;
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    final site = Environment.sitePairUri;
    return (site != null &&
            uri.origin == site.origin &&
            path == site.path.replaceFirst(RegExp(r'/+$'), '')) ||
        (uri.origin == 'https://zangetsu.online' && path == '/pair');
  }
}
