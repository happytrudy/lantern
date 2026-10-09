import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lantern/core/common/common.dart';
import 'package:lantern/core/services/injection_container.dart';
import 'package:lantern/core/services/local_storage_service.dart';
import 'package:lantern/features/vpn/provider/available_servers_notifier.dart';
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
  Map<String, int> delays = {};
  final registered = <String>[];
  final failedRegistrations = <String>{};
  int testCalls = 0;

  @override
  Future<Either<Failure, Unit>> addServerManually({
    required String ip,
    required String port,
    required String accessToken,
    required String serverName,
  }) async {
    registered.add(serverName);
    return failedRegistrations.contains(serverName)
        ? left(
            Failure(
              error: 'registration failed',
              localizedErrorMessage: 'registration failed',
            ),
          )
        : right(unit);
  }

  @override
  Future<Either<Failure, Map<String, int>>> runURLTests() async {
    testCalls++;
    return right(delays);
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
    await sl.reset();
  });

  Future<void> save(String tag) => storage.savePrivateServer(
    tag: tag,
    protocol: 'vless',
    ip: '127.0.0.1',
    port: '443',
    accessToken: 'test',
  );

  test(
    'selects lowest native URL-test delay and drops stale successes',
    () async {
      await save('slow');
      await save('fast');
      await save('failed');
      service.delays = {'slow': 240, 'fast': 60, 'unconfigured': 1};
      await container.read(availableServersProvider.future);
      final notifier = container.read(availableServersProvider.notifier);
      final first = await notifier.probePrivateServers();
      expect(first.isRight(), isTrue);
      final servers = first.getOrElse((_) => throw StateError('probe failed'));
      expect(servers.fastestPrivateServer?.tag, 'fast');
      expect(servers.serverByTag('failed')?.hasSuccessfulProbe, isFalse);
      expect(service.registered, ['slow', 'fast', 'failed']);
      expect(service.testCalls, 1);

      service.delays = {'slow': 280};
      final second = await notifier.probePrivateServers();
      expect(
        second
            .getOrElse((_) => throw StateError('probe failed'))
            .fastestPrivateServer
            ?.tag,
        'slow',
      );
      expect(
        container
            .read(availableServersProvider)
            .requireValue
            .serverByTag('fast')
            ?.hasSuccessfulProbe,
        isFalse,
      );
    },
  );

  test('single failed node is never presented as a successful probe', () async {
    await save('only');
    await container.read(availableServersProvider.future);
    final result = await container
        .read(availableServersProvider.notifier)
        .probePrivateServers();
    expect(
      result
          .getOrElse((_) => throw StateError('probe failed'))
          .fastestPrivateServer,
      isNull,
    );
  });

  test('unrestored node cannot displace a working restored node', () async {
    await save('missing');
    await save('working');
    service.failedRegistrations.add('missing');
    service.delays = {'missing': 1, 'working': 80};
    await container.read(availableServersProvider.future);
    final result = await container
        .read(availableServersProvider.notifier)
        .probePrivateServers();
    expect(
      result
          .getOrElse((_) => throw StateError('probe failed'))
          .fastestPrivateServer
          ?.tag,
      'working',
    );
  });
}
