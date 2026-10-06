import 'package:flutter_test/flutter_test.dart';
import 'package:lantern/core/services/local_storage_service.dart';

class _MemoryStorage extends LocalStorageService {
  final values = <String, String>{};

  @override
  String? getString(String key) => values[key];

  @override
  Future<void> setString(String key, String value) async => values[key] = value;
}

void main() {
  test(
    'learning protocol keeps the manager address, name and owner token',
    () async {
      final storage = _MemoryStorage();
      await storage.savePrivateServer(
        tag: 'server-a',
        name: 'My server',
        ip: 'manager.example',
        port: '8443',
        accessToken: 'owner-token',
      );
      await storage.savePrivateServer(tag: 'server-a', protocol: 'hysteria2');
      final saved = storage.getPrivateServers().single;
      expect(saved['ip'], 'manager.example');
      expect(saved['port'], '8443');
      expect(saved['name'], 'My server');
      expect(saved['access_token'], 'owner-token');
      expect(saved['protocol'], 'hysteria2');
    },
  );

  test('partial updates preserve joined ownership', () async {
    final storage = _MemoryStorage();
    await storage.savePrivateServer(tag: 'joined', isJoined: true);
    await storage.savePrivateServer(tag: 'joined', protocol: 'tuic');
    expect(storage.getPrivateServers().single['is_joined'], isTrue);
  });
}
