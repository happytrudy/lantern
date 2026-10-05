import 'dart:async';

import 'package:lantern/core/common/common.dart';
import 'package:lantern/core/models/datacap_info.dart';
import 'package:lantern/lantern/lantern_service_notifier.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'data_cap_info_provider.g.dart';

/// Traffic usage is display-only. No allotment, threshold, reset, or
/// notification logic exists in the pure self-hosted build.
@Riverpod(keepAlive: true)
class DataCapInfoNotifier extends _$DataCapInfoNotifier {
  @override
  Future<DataCapUsageResponse> build() async {
    final initial = await _fetch();
    final timer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!ref.mounted) return;
      try {
        final next = await _fetch();
        if (ref.mounted) state = AsyncValue.data(next);
      } catch (error, stackTrace) {
        // A transient daemon restart must not hide the last displayed value.
        appLogger.debug('Traffic usage refresh failed: $error');
        if (state.hasValue && ref.mounted) {
          state = AsyncValue.data(state.requireValue);
        } else if (ref.mounted) {
          state = AsyncValue.error(error, stackTrace);
        }
      }
    });
    ref.onDispose(timer.cancel);
    return initial;
  }

  Future<DataCapUsageResponse> _fetch() async {
    final result = await ref.read(lanternServiceProvider).getDataCapInfo();
    return result.fold(
      (failure) => throw Exception('Failed to fetch traffic usage: $failure'),
      (usage) => usage,
    );
  }

  void updateDataCapInfo(DataCapUsageResponse newInfo) {
    state = AsyncValue.data(newInfo);
  }
}
