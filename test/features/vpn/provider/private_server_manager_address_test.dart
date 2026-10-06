import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lantern/core/services/injection_container.dart' show sl;
import 'package:lantern/core/services/local_storage_service.dart';
import 'package:lantern/features/vpn/provider/available_servers_notifier.dart';

class _MemoryStorage extends LocalStorageService {
  final values = <String, String>{};

  @override
  String? getString(String key) => values[key];

  @override
  Future<void> setString(String key, String value) async => values[key] = value;
}

void main() {
  test('rebuilt private servers retain the address used for sharing', () async {
    final storage = _MemoryStorage();
    await storage.savePrivateServer(
      tag: 'my-server',
      ip: '127.0.0.1',
      port: '1',
      accessToken: 'owner-token',
      protocol: 'hysteria2',
    );
    sl.registerSingleton<LocalStorageService>(storage);
    addTearDown(() => sl.unregister<LocalStorageService>());
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final servers = await container.read(availableServersProvider.future);
    final server = servers.userServers.single;
    expect(server.managerHost, '127.0.0.1');
    expect(server.serverIP, '127.0.0.1');
    expect(server.credentials!.port, '1');
    expect(server.credentials!.accessToken, 'owner-token');
  });
}
