/// Public compile-time application settings.
class Environment {
  // Supabase is the backend for accounts, cloud sync and media. Compile a
  // project in with
  //   --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
  // Without one the app still runs fully offline, just without an account.
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://offline.invalid',
  );
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'disabled',
  );

  // Saved sessions live under the key Supabase itself would use for the
  // compiled project (`sb-<ref>-auth-token`). It used to be pinned to another
  // project's ref, so a stale token from that project could be restored and
  // then rejected by this one — sign-in looked broken with no error.
  static String get supabaseSessionStorageKey {
    final host = Uri.tryParse(supabaseUrl)?.host ?? '';
    const suffix = '.supabase.co';
    if (host.endsWith(suffix)) {
      final ref = host.substring(0, host.length - suffix.length);
      if (ref.isNotEmpty && ref != 'offline.invalid') {
        return 'sb-$ref-auth-token';
      }
    }
    // Offline build: keep the historical key so a later configured build can
    // still see a session saved before the project URL was supplied.
    return 'sb-eogwzrlfoercfwcfwlmv-auth-token';
  }

  // Supabase is the backend of record: accounts, app data and media. The
  // VPS_SYNC_URL define remains as an override for a standalone PostgREST
  // deployment, but when it is absent the Supabase project is used instead of
  // silently pointing every store at offline.invalid.
  static const String vpsSyncUrl = String.fromEnvironment(
    'VPS_SYNC_URL',
    defaultValue: 'https://offline.invalid',
  );

  /// Base URL of the PostgREST endpoint that holds app cloud data.
  static String get cloudSyncUrl {
    final vps = Uri.tryParse(vpsSyncUrl);
    if (vps != null && vps.host.isNotEmpty && vps.host != 'offline.invalid') {
      return vpsSyncUrl;
    }
    return supabaseUrl;
  }

  /// True when a real cloud backend (Supabase or an explicit VPS override) was
  /// compiled into this build.
  static bool get cloudSyncConfigured {
    final uri = Uri.tryParse(cloudSyncUrl);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.host != 'offline.invalid';
  }

  static bool get usingSupabaseForData {
    final uri = Uri.tryParse(cloudSyncUrl);
    return uri != null && uri.host.endsWith('.supabase.co');
  }

  /// PostgREST root for [cloudSyncUrl]. Supabase serves it under `/rest/v1`;
  /// a standalone VPS override is already a PostgREST root.
  static String get cloudRestUrl {
    final uri = Uri.tryParse(cloudSyncUrl);
    if (uri == null || !usingSupabaseForData) return cloudSyncUrl;
    return uri
        .replace(
          pathSegments: [
            ...uri.pathSegments.where((segment) => segment.isNotEmpty),
            'rest',
            'v1',
          ],
        )
        .toString();
  }

  /// Kept for callers that only need to know whether the legacy VPS override
  /// is set. Prefer [cloudSyncConfigured].
  static bool get vpsSyncConfigured =>
      Uri.tryParse(vpsSyncUrl)?.host != 'offline.invalid';

  /// Password-reset landing page.
  /// Password-reset landing. Supabase now drives reset (via the auth `site_url`,
  /// which points at this same page); kept for reference. Not used by the
  /// Supabase AuthCubit, which calls `resetPasswordForEmail`.
  static String get passwordResetUrl =>
      siteBaseUri?.toString() ?? 'https://clearcut.app/';

  static const _siteUrl = String.fromEnvironment('CLEARCUT_SITE_URL');
  static Uri? get siteBaseUri {
    final uri = Uri.tryParse(_siteUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    return uri.replace(path: '${uri.path.replaceFirst(RegExp(r'/+$'), '')}/');
  }

  static Uri? get siteOpenUri => siteBaseUri?.resolve('open/');
  static Uri? get sitePairUri => siteBaseUri?.resolve('pair/');
  static const String openLinkScheme = 'clearcut';
  static const String openLinkHost = 'open';

  /// `clearcut://open` — the app's own return address for auth and share
  /// links. Using this instead of a hardcoded `zangetsu://open` matters when
  /// both apps are installed: Android would otherwise hand the login back to
  /// Zangetsu.
  static String get openLinkUrl => '$openLinkScheme://$openLinkHost';
  static const String pairLinkHost = 'pair';

  // Provisioned backend ids (see docs / setup).
  static const String databaseId = 'main';
  static const String mylistCollectionId = 'mylist';
  static const String historyCollectionId = 'history';
  static const String watchRoomsCollectionId = 'watch_rooms';
  static const String roomParticipantsCollectionId = 'room_participants';
  static const String roomMessagesCollectionId = 'room_messages';
  static const String avatarsBucketId = 'avatars';
  static const String backupsCollectionId = 'backups';

  // ── Tracker OAuth ──────────────────────────────────────────────────────────
  // All redirects share the zangetsu:// scheme; each has its own host with a
  // matching Android intent-filter. Client secrets are embedded where the
  // provider's token exchange requires it (MAL = PKCE, no secret; Simkl needs
  // one) — standard for these APIs and low-risk.
  static const String trackerRedirectScheme = 'zangetsu';

  // AniList — implicit grant (token in URL fragment, 1-year, no secret).
  static const String anilistClientId = '43052';
  static const String anilistRedirectHost = 'anilist-auth';
  static String get anilistRedirectUri =>
      '$trackerRedirectScheme://$anilistRedirectHost';

  // MyAnimeList — OAuth2 PKCE (plain), no client secret.
  static const String malClientId = 'ac006943589381143c4c4e54eac93a89';
  static const String malRedirectHost = 'mal-auth';
  static String get malRedirectUri =>
      '$trackerRedirectScheme://$malRedirectHost';

  // Simkl wants these on EVERY request (url params + a real User-Agent), or
  // the call is invisible in their debug log and they can't help when
  // something breaks. See https://api.simkl.org/conventions/headers.
  static const String simklAppName = 'zangetsu';
  static const String simklApiHost = 'api.simkl.com';
  static const String simklDataHost = 'data.simkl.in';

  // Simkl — OAuth2 authorization-code (needs the secret to exchange the code).
  static const String simklClientId =
      '8b847b09206ccdb0b3de4cc1293d6dd7d355821f5c179c57315da8ba9030eb53';
  static const String simklClientSecret =
      '34ba8e5ac7c8a5c27926dfdf78205e5b913de9928361cb5a243558239298c96d';
  static const String simklRedirectHost = 'simkl-auth';
  static String get simklRedirectUri =>
      '$trackerRedirectScheme://$simklRedirectHost';

  // Back-compat alias (older AniList code referenced this name).
  // ── MangaBaka ────────────────────────────────────────────────────────────
  //
  // Manga/manhwa/manhua only — no anime list, which is why `supportsReading`
  // is the one thing it answers true to.
  //
  // A PUBLIC OAuth client: no secret, PKCE (S256) instead, which is the right
  // shape for an installed app — anything shipped in the APK can be extracted.
  // Endpoints come from https://mangabaka.org/.well-known/openid-configuration
  // (the `.org` host; `api.mangabaka.org/.well-known/*` is 404). MangaBaka's
  // own API docs mention neither OAuth nor tokens, so prefer the discovery
  // document over the docs if they ever disagree.
  static const String mangabakaClientId = 'EkBIEASsBsfRvPKGevUZIcRLSdubVHPK';
  static const String mangabakaRedirectHost = 'mangabaka-auth';
  static String get mangabakaRedirectUri =>
      '$trackerRedirectScheme://$mangabakaRedirectHost';
  static const String mangabakaAuthorizeUrl =
      'https://mangabaka.org/auth/oauth2/authorize';
  static const String mangabakaTokenUrl =
      'https://mangabaka.org/auth/oauth2/token';
  static const String mangabakaRevokeUrl =
      'https://mangabaka.org/auth/oauth2/revoke';
  static const String mangabakaApi = 'https://api.mangabaka.org';

  /// `library.write` is an official scope — third-party writes are supported,
  /// not a workaround. `offline_access` is what returns a refresh token.
  /// `openid` is required by `/v1/my/profile`: with the other four granted it
  /// still answered `BAD_REQUEST: Missing required scope`, which is the OIDC
  /// identity scope missing rather than any library permission.
  static const String mangabakaScopes =
      'openid profile library.read library.write offline_access';

  static const String anilistRedirectScheme = trackerRedirectScheme;
}
