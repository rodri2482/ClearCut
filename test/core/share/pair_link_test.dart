import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/environment.dart';
import 'package:watch_app/core/share/pair_link.dart';
import 'package:watch_app/core/supabase/auth_route.dart';

void main() {
  const code = 'ABCD2345';
  const nonce = 'n_s3creTN0nceValue_________pad';
  final site = Environment.sitePairUri;

  test('qrData uses the configured website or the ClearCut app', () {
    final data = PairLink.qrData(code: code, nonce: nonce);
    final uri = Uri.parse(data);

    expect(uri.scheme, site?.scheme ?? 'clearcut');
    expect(uri.host, site?.host ?? 'pair');
    expect(uri.path, site?.path ?? '');
    expect(uri.queryParameters['code'], code);
    expect(uri.queryParameters['nonce'], nonce);
    expect(uri.queryParameters.containsKey('trackers'), isFalse);
  });

  test('qrData omits nonce when absent and flags the trackers-only flow', () {
    final data = PairLink.qrData(code: code, trackers: true);
    final uri = Uri.parse(data);

    expect(uri.scheme, site?.scheme ?? 'clearcut');
    expect(uri.queryParameters['code'], code);
    expect(uri.queryParameters.containsKey('nonce'), isFalse);
    expect(uri.queryParameters['trackers'], '1');
  });

  test('parse round-trips the QR URL and the ClearCut deep link', () {
    final web = Uri.parse(PairLink.qrData(code: code, nonce: nonce));
    final fromWeb = PairLink.parse(web);
    expect(fromWeb, isNotNull);
    expect(fromWeb!.code, code);
    expect(fromWeb.nonce, nonce);
    expect(fromWeb.trackers, isFalse);

    final deep = Uri.parse(
      PairLink.deepLink(code: code, nonce: nonce, trackers: true),
    );
    expect(deep.scheme, 'clearcut');
    expect(deep.host, 'pair');
    final fromDeep = PairLink.parse(deep);
    expect(fromDeep, isNotNull);
    expect(fromDeep!.code, code);
    expect(fromDeep.nonce, nonce);
    expect(fromDeep.trackers, isTrue);
  });

  test('parse ignores unrelated links', () {
    expect(PairLink.parse(Uri.parse('zangetsu://open?s=x&u=y')), isNull);
    expect(
      PairLink.parse(Uri.parse('https://zangetsu.online/open/?s=x&u=y')),
      isNull,
    );
    expect(
      PairLink.parse(Uri.parse('https://example.com/pair/?code=$code')),
      isNull,
    );
  });
  test('VPS account and tracker links carry the selected authority', () {
    for (final value in [
      PairLink.qrData(code: code, authority: 'vps'),
      PairLink.deepLink(code: code, authority: 'vps'),
      PairLink.trackerWebLink(
        code: code,
        nonce: nonce,
        tracker: 'anilist',
        authority: 'vps',
      ),
    ]) {
      expect(Uri.parse(value).queryParameters['auth'], 'vps');
    }
    expect(
      Uri.parse(
        PairLink.qrData(code: code),
      ).queryParameters.containsKey('auth'),
      isFalse,
    );
  });

  test('pair links retain authority and reject an unknown selector', () {
    expect(
      PairLink.parse(
        Uri.parse('zangetsu://pair?code=$code&auth=vps'),
      )!.authority,
      'vps',
    );
    expect(
      PairLink.parse(Uri.parse('zangetsu://pair?code=$code'))!.authority,
      'cloud',
    );
    expect(
      PairLink.parse(
        Uri.parse('zangetsu://pair?code=$code&auth=vps&auth=cloud'),
      ),
      isNull,
    );
    expect(
      PairLink.parse(Uri.parse('zangetsu://pair?code=$code&auth=unknown')),
      isNull,
    );
  });

  test('links use the launch authority without another settings request', () {
    AuthRoute.active = const AuthRoute(
      authority: 'vps',
      generation: 2,
      anonKey: 'public',
    );
    try {
      expect(
        Uri.parse(PairLink.deepLink(code: code)).queryParameters['auth'],
        'vps',
      );
      expect(
        Uri.parse(
          PairLink.trackerWebLink(code: code, nonce: nonce, tracker: 'mal'),
        ).queryParameters['auth'],
        'vps',
      );
    } finally {
      AuthRoute.active = AuthRoute.cloud;
    }
  });
}
