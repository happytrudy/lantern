import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lantern/core/common/common.dart';
import 'package:lantern/core/models/lantern_status.dart';
import 'package:lantern/core/services/injection_container.dart';
import 'package:lantern/core/services/local_storage_service.dart';
import 'package:lantern/core/services/notification_service.dart';
import 'package:lantern/features/vpn/provider/server_location_notifier.dart';
import 'package:lantern/features/vpn/provider/vpn_notifier.dart';
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
  final events = StreamController<LanternStatus>.broadcast();
  Completer<Either<Failure, Map<String, int>>> probe = Completer();
  int probeCalls = 0;
  final connections = <String>[];

  @override
  Future<Either<Failure, bool>> isVPNConnected() async => right(false);
  @override
  Stream<LanternStatus> watchVPNStatus() => events.stream;
  @override
  Future<bool> checkVpnConflict() async => false;
  @override
  Future<Either<Failure, Unit>> addServerManually({
    required String ip,
    required String port,
    required String accessToken,
    required String serverName,
  }) async => right(unit);
  @override
  Future<Either<Failure, Map<String, int>>> runURLTests() async {
    probeCalls++;
    return probe.future;
  }

  @override
  Future<Either<Failure, String>> connectToServer(
    String location,
    String tag,
  ) async {
    connections.add(tag);
    return right('ok');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> pump() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Service service;
  late ProviderContainer container;
  setUp(() async {
    await sl.reset();
    final storage = _Storage();
    sl.registerSingleton<LocalStorageService>(storage);
    sl.registerSingleton<NotificationService>(NotificationService());
    await storage.savePrivateServer(
      tag: 'new',
      ip: 'manager.example',
      port: '443',
      accessToken: 'guest',
      protocol: 'vless',
    );
    service = _Service();
    container = ProviderContainer(
      overrides: [
        lanternServiceProvider.overrideWithValue(service),
        serverLocationProvider.overrideWithValue(initialServerLocation()),
      ],
    );
    container.listen(vpnProvider, (_, _) {});
    await pump();
  });
  tearDown(() async {
    container.dispose();
    await service.events.close();
    await sl.reset();
  });

  test(
    'rapid starts share one probe even before conflict checking completes',
    () async {
      final notifier = container.read(vpnProvider.notifier);
      final first = notifier.startVPN();
      expect(container.read(vpnProvider), VPNStatus.connecting);
      final second = notifier.startVPN(force: true);
      final manual = notifier.connectToServer(
        ServerLocationType.privateServer,
        'new',
      );
      expect(identical(first, second), isTrue);
      expect(identical(first, manual), isTrue);
      await pump();
      expect(service.probeCalls, 1);
      service.events.add(LanternStatus(status: VPNStatus.disconnected));
      await pump();
      expect(container.read(vpnProvider), VPNStatus.connecting);
      expect((await notifier.onVPNStateChange()).isRight(), isTrue);
      expect(service.probeCalls, 1);
      service.probe.complete(right({'new': 18}));
      for (final result in await Future.wait([first, second, manual])) {
        expect(result.isRight(), isTrue);
      }
      expect(service.connections, ['new']);
      await notifier.startVPN(force: true);
      expect(service.probeCalls, 1);
    },
  );

  test('an exceptional probe releases the guard for a fresh attempt', () async {
    final notifier = container.read(vpnProvider.notifier);
    final first = notifier.startVPN();
    final failed = expectLater(first, throwsStateError);
    await pump();
    service.probe.completeError(StateError('native canceled'));
    await failed;
    expect(container.read(vpnProvider), VPNStatus.disconnected);
    service.probe = Completer()..complete(right({'new': 19}));
    expect((await notifier.startVPN()).isRight(), isTrue);
    expect(service.probeCalls, 2);
    expect(service.connections, ['new']);
  });

  test(
    'all fresh probes failing still produces an error without fallback',
    () async {
      service.probe.complete(right({}));
      final result = await container.read(vpnProvider.notifier).startVPN();
      expect(
        result.getLeft().toNullable()?.error,
        'self_hosted_server_unreachable',
      );
      expect(service.connections, isEmpty);
      expect(container.read(vpnProvider), VPNStatus.disconnected);
    },
  );
}
