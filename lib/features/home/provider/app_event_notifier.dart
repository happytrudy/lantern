import 'dart:async';

import 'package:lantern/core/services/logger_service.dart';
import 'package:lantern/features/home/provider/country_code_notifier.dart';
import 'package:lantern/features/home/provider/home_notifier.dart';
import 'package:lantern/lantern/lantern_service_notifier.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'app_event_notifier.g.dart';

/// Listens for application-wide events and triggers corresponding actions.
/// This can be used for all listening to events that go sends and handling them
/// in one place.
@Riverpod(keepAlive: true)
class AppEventNotifier extends _$AppEventNotifier {
  StreamSubscription? _appEventSub;

  @override
  Future<void> build() async {
    watchAppEvents();
    ref.onDispose(() {
      appLogger.debug(
        'Disposing AppEventNotifier and cancelling subscriptions.',
      );
      _appEventSub?.cancel();
    });
  }

  /// Event types that arrive continuously rather than occasionally: one per
  /// peer connection, and a data-cap poll every few seconds. Logging a line
  /// each made them 75% of a 297 MB flutter.log, which is what pushed issue
  /// reports past their attachment budget so users could not send logs at all.
  /// Per-event diagnostics are available at the opt-in trace level.
  static const _highVolumeEvents = {'peer-connection'};

  /// Watches for application events and triggers appropriate actions.
  /// Currently, it listens for 'config' and server-location events.
  void watchAppEvents() {
    appLogger.debug('Setting up app event listener...');
    _appEventSub = ref.read(lanternServiceProvider).watchAppEvents().listen((
      event,
    ) {
      final eventType = event.eventType;
      if (_highVolumeEvents.contains(eventType)) {
        appLogger.trace(() => 'Received app event of type: $eventType');
      } else {
        appLogger.debug('Received app event of type: $eventType');
      }
      switch (eventType) {
        case 'config':
        case 'server-location':
          // Official configuration and location events are intentionally
          // ignored. Self-hosted servers are managed locally by the app.
          break;
        case 'country-code':
          ref.read(countryCodeProvider.notifier).update(event.message);
          break;
        case 'user-data':
          // Go refreshed user data from the server; re-read the cache.
          unawaited(ref.read(homeProvider.notifier).reloadUserData());
          break;
        default:
          break;
      }
    });
  }
}
