import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';

class _Service extends SupabaseService {
  _Service(this.connection);
  final SupabaseClient connection;
  @override
  SupabaseClient get client => connection;
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('signup-fresh');
    Hive.init(dir.path);
    await Hive.openBox(AuthCubit.cacheBoxName);
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test(
    'sign-up succeeds even when the fresh project has no profiles table',
    () async {
      const user = {
        'id': 'new-user',
        'aud': 'authenticated',
        'role': 'authenticated',
        'email': 'new@example.com',
        'app_metadata': {
          'provider': 'email',
          'providers': ['email'],
        },
        'user_metadata': {'name': 'New User'},
        'created_at': '2026-01-01T00:00:00Z',
      };
      final requests = <Uri>[];
      final client = SupabaseClient(
        'https://auth.test',
        'test-only-key',
        authOptions: const AuthClientOptions(
          authFlowType: AuthFlowType.implicit,
        ),
        httpClient: MockClient((request) async {
          requests.add(request.url);
          if (request.url.path.contains('/signup')) {
            // Autoconfirm is on: Supabase returns a session with the user.
            return http.Response(
              jsonEncode({
                'access_token': 'access-token',
                'token_type': 'bearer',
                'expires_in': 3600,
                'refresh_token': 'refresh-token',
                'user': user,
              }),
              200,
            );
          }
          // A brand-new project: no profiles table, no insert policy.
          return http.Response(
            '{"message":"relation \\"public.profiles\\" does not exist"}',
            404,
          );
        }),
      );
      final cubit = AuthCubit(_Service(client));

      final ok = await cubit.signUp(
        'New User',
        'new@example.com',
        'password123',
      );

      expect(
        ok,
        isTrue,
        reason: 'the account was created; the cosmetic row is optional',
      );
      expect(cubit.state.isLoggedIn, isTrue);
      expect(cubit.state.error, isNull);
      expect(requests.any((u) => u.path.contains('/signup')), isTrue);
      expect(requests.any((u) => u.path.contains('profiles')), isTrue);

      await cubit.close();
      await client.dispose();
    },
  );
}
