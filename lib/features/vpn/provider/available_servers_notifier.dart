import 'dart:convert';
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
  Map<String, int> _latencies = {};
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
        final accessToken =
            (item['access_token'] ?? item['accessToken'] ?? item['token'] ?? '')
                .toString();
        final isJoined = item['is_joined'] == true;
        var protocol = (item['protocol'] ?? item['type'] ?? '')
            .toString()
            .trim();
        if (protocol.isEmpty) {
          protocol =
              await _resolvePrivateServerProtocol(
                ip: ip,
                port: port,
                accessToken: accessToken,
              ) ??
              '';
          if (protocol.isNotEmpty) {
            await sl<LocalStorageService>().savePrivateServer(
              tag: tag,
              protocol: protocol,
            );
          }
        }
        final delay = _latencies[tag];
        return Server(
          tag: tag,
          type: protocol,
          isLantern: false,
          managerHost: ip,
          location: GeoLocation(
            country: '',
            countryCode: '',
            city: name,
            latitude: 0,
            longitude: 0,
          ),
          credentials: ServerCredential(
            accessToken: accessToken,
            isJoined: isJoined,
            port: port.toString(),
          ),
          selectionHistory: SelectionHistory(
            lastSuccessDelayMs: delay ?? 0,
            consecutiveFailures: 0,
          ),
        );
      }),
    );
    return right(AvailableServers(servers));
  }

  Future<String?> _resolvePrivateServerProtocol({
    required String ip,
    required int port,
    required String accessToken,
  }) async {
    if (ip.isEmpty || accessToken.isEmpty || port <= 0 || port > 65535) {
      return null;
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3)
      ..badCertificateCallback = (_, _, _) => true;
    try {
      final uri = Uri(
        scheme: 'https',
        host: ip,
        port: port,
        path: '/api/v1/connect-config',
        queryParameters: {'token': accessToken},
      );
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 3));
      final response = await request.close().timeout(
        const Duration(seconds: 3),
      );
      if (response.statusCode != HttpStatus.ok) return null;
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final outbounds = decoded['outbounds'];
      if (outbounds is List && outbounds.isNotEmpty && outbounds.first is Map) {
        final type = (outbounds.first['type'] ?? '').toString().trim();
        if (type.isNotEmpty) return type;
      }
      final endpoints = decoded['endpoints'];
      if (endpoints is List && endpoints.isNotEmpty && endpoints.first is Map) {
        final type = (endpoints.first['type'] ?? '').toString().trim();
        if (type.isNotEmpty) return type;
      }
    } catch (error) {
      appLogger.debug('Unable to resolve private server protocol: $error');
    } finally {
      client.close(force: true);
    }
    return null;
  }

  Future<Either<Failure, AvailableServers>> probePrivateServers() async {
    _latencies = {};
    final service = ref.read(lanternServiceProvider);
    final local = sl<LocalStorageService>().getPrivateServers();
    final registrations = await Future.wait(
      local.map((item) async {
        return service.addServerManually(
          ip: (item['ip'] ?? '').toString(),
          port: (item['port'] ?? '443').toString(),
          accessToken:
              (item['access_token'] ??
                      item['accessToken'] ??
                      item['token'] ??
                      '')
                  .toString(),
          serverName: item['tag'].toString(),
        );
      }),
    );
    final registeredTags = <String>{};
    for (var i = 0; i < registrations.length; i++) {
      if (registrations[i].isRight()) {
        registeredTags.add(local[i]['tag'].toString());
      }
    }
    if (local.isEmpty) return right(AvailableServers([]));
    if (registeredTags.isEmpty) {
      return registrations.first.map((_) => AvailableServers([]));
    }
    final tested = await service.runURLTests();
    if (tested.isLeft()) {
      return tested.map((_) => AvailableServers([]));
    }
    _latencies = Map.of(
      tested.getOrElse((_) => {}),
    )..removeWhere((tag, delay) => !registeredTags.contains(tag) || delay <= 0);
    final result = await fetchAvailableServers();
    if (ref.mounted) {
      result.fold(
        (_) {},
        (servers) => state = AsyncValue.data(_privateServersOnly(servers)),
      );
    }
    return result;
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
