import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lantern/core/common/common.dart';
import 'package:lantern/core/models/private_server_status.dart';
import 'package:lantern/core/services/injection_container.dart';
import 'package:lantern/core/services/local_storage_service.dart';
import 'package:lantern/features/private_server/provider/private_server_notifier.dart';
import 'package:lantern/lantern/lantern_service.dart';
import 'package:lantern/lantern/lantern_service_notifier.dart';

class _Storage extends LocalStorageService {
  final values = <String, String>{};
  @override
  String? getString(String key) => values[key];
  @override
  Future<void> setString(String key, String value) async => values[key] = value;
}

class _Service implements LanternService {
  final events = StreamController<PrivateServerStatus>.broadcast();
  final registered = <Map<String, String>>[];
  final imported = <String>[];
  bool fail = false;

  @override
  Stream<PrivateServerStatus> watchPrivateServerStatus() => events.stream;

  @override
  Future<Either<Failure, Unit>> addServerManually({
    required String ip,
    required String port,
    required String accessToken,
    required String serverName,
  }) async {
    registered.add({
      'ip': ip,
      'port': port,
      'token': accessToken,
      'name': serverName,
    });
    return fail
        ? left(Failure(error: 'rejected', localizedErrorMessage: 'rejected'))
        : right(unit);
  }

  @override
  Future<Either<Failure, List<String>>> addServerBasedOnURLs({
    required String urls,
    required bool skipCertVerification,
  }) async {
    imported.add(urls);
    return right(['imported']);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Storage storage;
  late _Service service;
  late ProviderContainer container;
  setUp(() async {
    await sl.reset();
    storage = _Storage();
    sl.registerSingleton<LocalStorageService>(storage);
    service = _Service();
    container = ProviderContainer(
      overrides: [lanternServiceProvider.overrideWithValue(service)],
    );
  });
  tearDown(() async {
    container.dispose();
    await service.events.close();
    await sl.reset();
  });

  const key =
      'https://lantern.io/private-server?ip=manager.example&port=8443&token=guest&alias=friend';
  test(
    'shared keys register the manager with the guest token and nickname',
    () async {
      final result = await container
          .read(privateServerProvider.notifier)
          .joinServer('加入我的服务器 $key', ' My server ');
      expect(result.isRight(), isTrue);
      expect(service.imported, isEmpty);
      expect(service.registered.single, {
        'ip': 'manager.example',
        'port': '8443',
        'token': 'guest',
        'name': 'My server',
      });
      final saved = storage.getPrivateServers().single;
      expect(saved['is_joined'], isTrue);
      expect(saved['access_token'], 'guest');
      expect(saved['tag'], 'My server');
    },
  );

  test('a later native registration event preserves joined ownership', () async {
    await container
        .read(privateServerProvider.notifier)
        .joinServer(key, 'Joined');
    service.events.add(
      PrivateServerStatus(
        status: 'EventTypeProvisioningCompleted',
        data:
            '{"tag":"Joined","external_ip":"manager.example","port":8443,"access_token":"guest","protocol":"vless"}',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(storage.getPrivateServers().single['is_joined'], isTrue);
    expect(storage.getPrivateServers().single['protocol'], 'vless');
    await Future<void>.delayed(const Duration(seconds: 1));
  });

  test('rejected invitations never persist a server', () async {
    service.fail = true;
    final result = await container
        .read(privateServerProvider.notifier)
        .joinServer(key, 'Rejected');
    expect(result.isLeft(), isTrue);
    expect(storage.getPrivateServers(), isEmpty);
  });

  test('proxy URI imports remain supported', () async {
    final result = await container
        .read(privateServerProvider.notifier)
        .joinServer('vless://uuid@example.com:443', 'Imported');
    expect(result.isRight(), isTrue);
    expect(service.registered, isEmpty);
    expect(service.imported, ['vless://uuid@example.com:443']);
    expect(storage.getPrivateServers().single['is_joined'], isTrue);
  });
}
