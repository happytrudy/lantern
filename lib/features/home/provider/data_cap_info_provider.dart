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
