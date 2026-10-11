import 'package:flutter_test/flutter_test.dart';
import 'package:lantern/core/utils/private_server_access_key.dart';

void main() {
  final now = DateTime.utc(2026, 10, 11);
  final expiration =
      now.add(const Duration(hours: 24)).millisecondsSinceEpoch ~/ 1000;
  final shared = PrivateServerAccessKey(
    host: 'manager.example',
    port: '8443',
    token: 'guest-token',
    alias: '访客 A',
  ).toUri('lantern.io', expiresAt: expiration);

  test('sharing and pasting the whole message preserves guest credentials', () {
    final key = PrivateServerAccessKey.parse('加入我的私有服务器 $shared', now: now)!;
    expect(shared.queryParameters['token'], 'guest-token');
    expect(key.host, 'manager.example');
    expect(key.port, '8443');
    expect(key.token, 'guest-token');
    expect(key.alias, '访客 A');
  });

  test('accepts app links and the older deep-link access key format', () {
    for (final prefix in [
      'lantern://private-server',
      'lantern//private-server',
    ]) {
      final key = PrivateServerAccessKey.parse(
        '$prefix?${shared.query}',
        now: now,
      )!;
      expect(key.token, 'guest-token');
      expect(key.host, 'manager.example');
    }
  });

  test('proxy URLs still use the native URL importer', () {
    expect(
      PrivateServerAccessKey.parse('vless://user@example.com:443'),
      isNull,
    );
    expect(
      PrivateServerAccessKey.parse('https://example.com/subscription'),
      isNull,
    );
  });

  test('invalid and expired invitations fail before registration', () {
    expect(
      () => PrivateServerAccessKey.parse(
        'https://lantern.io/private-server?ip=example.com&port=0&token=guest',
      ),
      throwsFormatException,
    );
    expect(
      () => PrivateServerAccessKey.parse(
        'https://lantern.io/private-server?ip=example.com&port=443',
      ),
      throwsFormatException,
    );
    expect(
      () => PrivateServerAccessKey.parse(
        shared.toString(),
        now: now.add(const Duration(days: 2)),
      ),
      throwsFormatException,
    );
  });
}
