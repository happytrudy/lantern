import 'dart:io';

import 'package:fpdart/fpdart.dart';
import 'package:lantern/core/common/common.dart';
import 'package:lantern/core/models/available_servers.dart';
import 'package:lantern/core/services/injection_container.dart' show sl;
import 'package:lantern/core/services/local_storage_service.dart';
import 'package:lantern/lantern/lantern_service_notifier.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'available_servers_notifier.g.dart';

const _availableServersSettleReloadThrottle = Duration(seconds: 30);
const _availableServersSettleReloadDelay = Duration(seconds: 4);

@Riverpod(keepAlive: true)
class AvailableServersNotifier extends _$AvailableServersNotifier {
  DateTime? _lastSettleReloadAt;
  Future<void>? _settleReload;

  @override
  Future<AvailableServers> build() async {
    final result = await fetchAvailableServers();
    return result.fold(
      (failure) {
        appLogger.error('Error getting available servers: ${failure.error}');
        throw Exception('Failed to load available servers');
      },
      (servers) {
        return _privateServersOnly(servers);
      },
    );
  }

  /// Fetches the available servers from the Lantern.
  Future<Either<Failure, AvailableServers>> fetchAvailableServers() async {
    final local = sl<LocalStorageService>().getPrivateServers();
    final servers = await Future.wait(
      local.map((item) async {
        final tag = item['tag'].toString();
        final name = (item['name'] ?? tag).toString();
        final ip = (item['ip'] ?? '').toString();
        final port = int.tryParse((item['port'] ?? '').toString()) ?? 443;
        final delay = await _probePrivateServer(ip, port);
        return Server(
          tag: tag,
          type: (item['protocol'] ?? '').toString(),
          isLantern: false,
          location: GeoLocation(
            country: '',
            countryCode: '',
            city: name,
            latitude: 0,
            longitude: 0,
          ),
          credentials: null,
          selectionHistory: SelectionHistory(
            lastSuccessDelayMs: delay ?? 0,
            consecutiveFailures: delay == null ? 1 : 0,
          ),
        );
      }),
    );
    return right(AvailableServers(servers));
  }

  Future<int?> _probePrivateServer(String ip, int port) async {
    if (ip.isEmpty || port <= 0 || port > 65535) return null;
    final stopwatch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(seconds: 3),
      );
      stopwatch.stop();
      await socket.close();
      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      stopwatch.stop();
      return null;
    }
  }

  /// Forces a fetch of the available servers and updates the state.
  /// Updates UI accordingly.
  Future<void> forceFetchAvailableServers() async {
    if (!ref.mounted) {
      return;
    }
    final result = await fetchAvailableServers();
    // The fetch is async and this notifier can be disposed while it is in
    // flight (e.g. the app tears down during an integration test). Writing
    // state on a disposed Ref throws, so bail out if we are no longer mounted.
    if (!ref.mounted) {
      return;
    }
    result.fold(
      (failure) {
        appLogger.error('Error getting available servers: ${failure.error}');
      },
      (servers) {
        state = AsyncValue.data(_privateServersOnly(servers));
      },
    );
  }

  AvailableServers _privateServersOnly(AvailableServers servers) {
    return AvailableServers(servers.userServers);
  }

  /// Reloads available servers from the latest persisted Smart Location probe data.
  Future<void> refreshAvailableServersAfterProbeSettle() async {
    final now = DateTime.now();
    final lastReload = _lastSettleReloadAt;
    await forceFetchAvailableServers();
    if (!ref.mounted) {
      return;
    }

    if (_settleReload != null) {
      await _settleReload;
      return;
    }
    if (lastReload != null &&
        now.difference(lastReload) < _availableServersSettleReloadThrottle) {
      return;
    }
    _lastSettleReloadAt = now;

    final settleReload = Future<void>(() async {
      await Future.delayed(_availableServersSettleReloadDelay);
      if (!ref.mounted) {
        return;
      }
      await forceFetchAvailableServers();
    });
    _settleReload = settleReload;
    try {
      await settleReload;
    } finally {
      if (_settleReload == settleReload) {
        _settleReload = null;
      }
    }
  }
}
