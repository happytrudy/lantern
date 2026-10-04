import 'dart:async';
import 'package:lantern/core/common/common.dart';
import 'package:lantern/core/models/server_location.dart';
import 'package:lantern/core/services/injection_container.dart' show sl;
import 'package:lantern/core/services/local_storage_service.dart';
import 'package:lantern/lantern/lantern_service_notifier.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'server_location_notifier.g.dart';

@Riverpod(keepAlive: true)
class ServerLocationNotifier extends _$ServerLocationNotifier {
  LocalStorageService get _storage => sl<LocalStorageService>();

  @override
  ServerLocation build() {
    // Every change to the selected/resolved location is mirrored into the
    // native widget so it can show where the tunnel exits.
    listenSelf((_, next) => _publishToWidget(next));
    final cached = _storage.getServerLocation();
    final initial = cached ?? _defaultLocation();
    appLogger.debug(
      'ServerLocationNotifier.build() cached=${cached != null} '
      'type=${initial.serverType} city=${initial.city}',
    );
    return initial;
  }

  /// Compatibility hook for callers that used to refresh the official
  /// location. Self-hosted locations are entirely local in the pure build.
  Future<void> fetchServerLocation() async {}

  void updateServerLocation(ServerLocation entity) {
    final current = state;
    final ServerLocation updated;
    if (entity.serverType != ServerLocationType.auto.name) {
      //Preserve auto location metadata when switching to a non-auto server,
      // so we can show user smart location
      updated = entity.copyWith(autoLocation: current.autoLocation);
    } else {
      updated = entity;
    }
    appLogger.debug(
      'updateServerLocation: type=${updated.serverType} '
      'name=${updated.serverName} city=${updated.city}',
    );
    state = updated;
    _storage.saveServerLocation(updated);
  }

  Future<void> refreshAutoLocationIfNeeded() async {
    // Automatic official location resolution was removed. Smart routing now
    // resolves only from the locally managed self-hosted server set.
  }

  /// Flips the active selection to auto and clears any stale custom-server
  /// identity fields so downstream UI does not keep highlighting a previous
  /// manual selection. The existing [autoLocation] metadata is preserved so
  /// the Smart Location label remains available until the next push event.
  Future<void> switchToAuto() async {
    if (state.serverType == ServerLocationType.auto.name) return;
    final updated = state.copyWith(serverType: ServerLocationType.auto.name);
    state = updated;
    await _storage.saveServerLocation(updated);
  }

  void _publishToWidget(ServerLocation location) {
    final isAuto =
        location.serverType.toServerLocationType == ServerLocationType.auto;
    final auto = location.autoLocation;
    unawaited(
      ref
          .read(lanternServiceProvider)
          .updateWidgetLocation(
            city: location.city,
            country: isAuto ? (auto?.country ?? '') : location.country,
            countryCode: isAuto
                ? (auto?.countryCode ?? '')
                : location.countryCode,
            displayName: isAuto
                ? (auto?.displayName ?? '')
                : location.displayName,
          ),
    );
  }

  static ServerLocation _defaultLocation() => ServerLocation(
    serverType: ServerLocationType.auto.name,
    serverName: '',
    displayName: '',
    protocol: '',
    city: '',
  );
}
