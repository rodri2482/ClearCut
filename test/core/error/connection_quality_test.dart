import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/error/network_failure.dart';

Future<List<InternetAddress>> _neutral() async => const [];

void main() {
  tearDown(() {
    lookupForQuality = _neutral;
  });

  test('a fast neutral lookup is a good connection', () async {
    lookupForQuality = () async => [InternetAddress('1.1.1.1')];
    expect(await checkConnectionQuality(), ConnectionQuality.good);
  });

  test('a slow neutral lookup is reported as slow', () async {
    lookupForQuality = () async {
      await Future<void>.delayed(const Duration(milliseconds: 1900));
      return [InternetAddress('1.1.1.1')];
    };
    expect(await checkConnectionQuality(), ConnectionQuality.slow);
  });

  test('a failed neutral lookup is reported as offline', () async {
    lookupForQuality = () => throw 'DNS failed';
    expect(await checkConnectionQuality(), ConnectionQuality.offline);
  });
}
