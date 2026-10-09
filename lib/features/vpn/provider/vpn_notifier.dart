import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:fpdart/fpdart.dart';
import 'package:lantern/core/common/common.dart';
import 'package:lantern/core/models/lantern_status.dart';
import 'package:lantern/core/models/notification_event.dart';
import 'package:lantern/core/services/injection_container.dart';
import 'package:lantern/core/services/local_storage_service.dart';
import 'package:lantern/core/services/notification_service.dart';
import 'package:lantern/core/services/rating_prompt_service.dart';
import 'package:lantern/features/home/provider/app_setting_notifier.dart';
import 'package:lantern/features/vpn/provider/available_servers_notifier.dart';
import 'package:lantern/features/vpn/provider/server_location_notifier.dart';
import 'package:lantern/features/vpn/provider/vpn_status_notifier.dart';
import 'package:lantern/lantern/lantern_service_notifier.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'vpn_notifier.g.dart';

@Riverpod(keepAlive: true)
class VpnNotifier extends _$VpnNotifier {
  bool _hasStatusStreamEmission = false;
  Future<Either<Failure, String>>? _stopRequest;
  bool _userDisconnectRequested = false;

  RatingPromptService? get _ratingPrompt =>
      sl.isRegistered<RatingPromptService>() ? sl<RatingPromptService>() : null;

  @override
  VPNStatus build() {
    unawaited(_hydrateInitialStatus());
    ref.listen(vPNStatusProvider, (previous, next) {
      if (next.hasError) {
        _hasStatusStreamEmission = true;
        _userDisconnectRequested = false;
        appLogger.error(
          'VPN status provider failed',
          next.error,
          next.stackTrace,
        );
        state = VPNStatus.error;
        return;
      }
      if (!next.hasValue) return;
      final lanternStatus = next.value;
      if (lanternStatus == null) return;
      _hasStatusStreamEmission = true;
      final previousStatus = previous?.hasValue == true
          ? previous!.value?.status
          : null;
      final nextStatus = lanternStatus.status;
      final nextOrigin = lanternStatus.origin;
      // [vpn-state-trace] hop=dart_applied — moment Riverpod fires the listener
      // after the FFI ReceivePort delivers a status. Pairs with ffi_to_port
      // (lantern-core) and ssehandler_flushed / sse_parsed / daemon_setstatus
      // (radiance) to localize the Windows lag in Freshdesk #174072.
      // Use nextStatus.name (e.g. "disconnecting") rather than the default
      // toString() ("VPNStatus.disconnecting") so the value matches the wire
      // format emitted by radiance — makes cross-hop grep/correlation work.
      appLogger.info(
        '[vpn-state-trace] hop=dart_applied status=${nextStatus.name} '
        'ts_ms=${DateTime.now().millisecondsSinceEpoch}',
      );
      final suppressConnectionNotifications =
          nextOrigin == VPNStatusOrigin.settingsMutation &&
          (nextStatus == VPNStatus.connected ||
              nextStatus == VPNStatus.disconnected);

      final isFirstEvent = previous == null || previous.value == null;
      final statusChanged = !isFirstEvent && previousStatus != nextStatus;

      if (nextStatus == VPNStatus.error ||
          nextStatus == VPNStatus.connecting ||
          (nextStatus == VPNStatus.connected &&
              previousStatus == VPNStatus.disconnecting)) {
        _userDisconnectRequested = false;
      }

      if (nextStatus == VPNStatus.disconnected &&
          (statusChanged || isFirstEvent)) {
        // A successful stop request can return before the tunnel is down.
        // Count the session once, when the native status confirms it.
        final byUser = _userDisconnectRequested;
        _userDisconnectRequested = false;
        unawaited(
          byUser
              ? _ratingPrompt?.onUserDisconnected()
              : _ratingPrompt?.onDisconnected(),
        );
      }

      if (statusChanged) {
        if (previousStatus != VPNStatus.connecting &&
            nextStatus == VPNStatus.disconnected) {
          if (!suppressConnectionNotifications) {
            sl<NotificationService>().showNotification(
              id: NotificationEvent.vpnDisconnected.id,
              title: 'app_name'.i18n,
              body: 'vpn_disconnected'.i18n,
            );
          } else {
            appLogger.debug(
              'Suppressed vpn_disconnected notification (origin=$nextOrigin)',
            );
          }
        }
      }

      if (nextStatus == VPNStatus.connected &&
          (statusChanged || isFirstEvent)) {
        if (statusChanged && PlatformUtils.isMobile) {
          HapticFeedback.mediumImpact();
        }

        /// Mark successful connection in app settings
        ref.read(appSettingProvider.notifier).setSuccessfulConnection(true);
        unawaited(_ratingPrompt?.onConnected());

        if (statusChanged && !suppressConnectionNotifications) {
          sl<NotificationService>().showNotification(
            id: NotificationEvent.vpnConnected.id,
            title: 'app_name'.i18n,
            body: 'vpn_connected'.i18n,
          );
        }
      }

      state = nextStatus;
    });
    return VPNStatus.disconnected;
  }

  Future<void> _hydrateInitialStatus() async {
    late final Either<Failure, bool> result;
    try {
      result = await ref.read(lanternServiceProvider).isVPNConnected();
    } catch (e, stackTrace) {
      appLogger.error('Failed to hydrate VPN status', e, stackTrace);
      if (ref.mounted &&
          !_hasStatusStreamEmission &&
          state == VPNStatus.disconnected) {
        state = VPNStatus.error;
      }
      return;
    }
    if (!ref.mounted || _hasStatusStreamEmission) return;
    result.fold(
      (failure) {
        appLogger.error(
          'Failed to hydrate VPN status: ${failure.error}',
          failure.error,
        );
        if (state == VPNStatus.disconnected) {
          state = VPNStatus.error;
        }
      },
      (connected) {
        if (state == VPNStatus.disconnected) {
          state = connected ? VPNStatus.connected : VPNStatus.disconnected;
        }
        // Hydration bypasses the status listener, so reconcile the persisted
        // rating session here.
        unawaited(
          connected
              ? _ratingPrompt?.onConnected()
              : _ratingPrompt?.onDisconnected(),
        );
      },
    );
  }

  Future<Either<Failure, String>> onVPNStateChange() async {
    if (_stopRequest != null ||
        _userDisconnectRequested ||
        state == VPNStatus.connecting ||
        state == VPNStatus.disconnecting) {
      return Right("");
    }
    appLogger.info("VPN State Change requested. Current state: $state");
    if (state == VPNStatus.connected) {
      return stopVPN(userInitiated: true);
    }
    return startVPN();
  }

  /// Starts the VPN connection.
  /// force parameter, if true it will always connect to auto tag
  /// If the server location is set to auto, it will connect to the best available server.
  /// If a specific server location is set, it will connect to that server
  /// valid server location types are: auto,lanternLocation,privateServer

  Future<Either<Failure, String>> startVPN({
    bool force = false,
    bool skipConflictCheck = false,
  }) async {
    if (!skipConflictCheck) {
      final conflict = await _checkVpnConflict();
      if (conflict != null) return conflict;
    }

    // Smart Routing may spend several seconds probing every self-hosted
    // server before the native tunnel starts. Reflect that work immediately
    // so the connect control cannot look unresponsive during probing.
    state = VPNStatus.connecting;

    final serverLocation = ref.read(serverLocationProvider);

    final type = serverLocation.serverType.toServerLocationType;
    if (type == ServerLocationType.auto || force) {
      // Smart Routing is the auto mode in the pure build. Re-probe every
      // configured self-hosted server for each connection request, then use
      // the lowest successful latency without requiring a preselected tag.
      final probe = await ref
          .read(availableServersProvider.notifier)
          .probePrivateServers();
      if (probe.isLeft()) {
        state = VPNStatus.disconnected;
        return probe.map((_) => 'ok');
      }
      final available = probe.getOrElse(
        (_) => throw StateError('Expected probe results'),
      );
      if (!available.hasUserServers) {
        state = VPNStatus.disconnected;
        return Left(
          Failure(
            error: 'self_hosted_server_required',
            localizedErrorMessage: 'no_private_server_setup_yet'.i18n,
          ),
        );
      }
      final fastest = available.fastestPrivateServer;
      if (fastest == null) {
        state = VPNStatus.disconnected;
        return Left(
          Failure(
            error: 'self_hosted_server_unreachable',
            localizedErrorMessage: 'private_servers_unreachable'.i18n,
          ),
        );
      }

      final result = await connectToServer(
        ServerLocationType.privateServer,
        fastest.tag,
        // The VPN conflict check already ran at the start of startVPN.
        skipConflictCheck: true,
      );
      return result;
    }

    final tag = serverLocation.serverName;
    if (tag.isEmpty) {
      state = VPNStatus.disconnected;
      appLogger.info(
        'Connection aborted: selected self-hosted server tag is empty.',
      );
      return Left(
        Failure(
          error: 'self_hosted_server_unavailable',
          localizedErrorMessage: '自建服务器不可用，请重新添加'.i18n,
        ),
      );
    }
    return connectToServer(type, tag, skipConflictCheck: skipConflictCheck);
  }

  /// Connects to a specific server location.
  /// it supports lantern locations and private servers.
  Future<Either<Failure, String>> connectToServer(
    ServerLocationType location,
    String tag, {
    bool skipConflictCheck = false,
  }) async {
    // Check for a conflicting VPN before initiating a new connection.
    // The native side guards against false positives by returning false when
    // Lantern's own VPN is already active (e.g. server switching while connected).
    if (!skipConflictCheck) {
      final conflict = await _checkVpnConflict();
      if (conflict != null) return conflict;
    }

    state = VPNStatus.connecting;
    if (location == ServerLocationType.privateServer) {
      final restoreResult = await _restorePrivateServerRegistration(tag);
      if (restoreResult != null) {
        state = VPNStatus.disconnected;
        return restoreResult;
      }
    }
    appLogger.debug("Connecting to server: $location with tag: $tag");
    final result = await ref
        .read(lanternServiceProvider)
        .connectToServer(location.name, tag);
    if (result.isLeft() && ref.mounted && state == VPNStatus.connecting) {
      state = VPNStatus.disconnected;
    }
    return result;
  }

  Future<Either<Failure, String>?> _restorePrivateServerRegistration(
    String tag,
  ) async {
    Map<String, dynamic>? savedServer;
    for (final server in sl<LocalStorageService>().getPrivateServers()) {
      if (server['tag']?.toString() == tag) {
        savedServer = server;
        break;
      }
    }
    if (savedServer == null) return null;

    final ip = (savedServer['ip'] ?? '').toString().trim();
    final port = (savedServer['port'] ?? '').toString().trim();
    final accessToken =
        (savedServer['access_token'] ?? savedServer['accessToken'] ?? '')
            .toString()
            .trim();
    if (ip.isEmpty || port.isEmpty || accessToken.isEmpty) return null;

    appLogger.info('Ensuring saved private server is registered: tag=$tag');
    final result = await ref
        .read(lanternServiceProvider)
        .addServerManually(
          ip: ip,
          port: port,
          accessToken: accessToken,
          serverName: tag,
        );
    return result.fold((failure) => Left(failure), (_) => null);
  }

  Future<Left<Failure, String>?> _checkVpnConflict() async {
    if (!Platform.isAndroid && !Platform.isMacOS) return null;
    final hasConflict = await ref
        .read(lanternServiceProvider)
        .checkVpnConflict();
    return hasConflict ? Left(VpnConflictFailure()) : null;
  }

  Future<Either<Failure, String>> stopVPN({bool userInitiated = false}) {
    if (_stopRequest != null) return _stopRequest!;
    if (_userDisconnectRequested) return Future.value(Right(""));
    // Only explicit disconnects qualify; setup and shutdown also stop the VPN.
    _userDisconnectRequested = userInitiated && state == VPNStatus.connected;
    return _stopRequest = _requestStop().whenComplete(() {
      _stopRequest = null;
    });
  }

  Future<Either<Failure, String>> _requestStop() async {
    try {
      final result = await ref.read(lanternServiceProvider).stopVPN();
      if (result.isLeft()) _userDisconnectRequested = false;
      return result;
    } catch (_) {
      _userDisconnectRequested = false;
      rethrow;
    }
  }
}
