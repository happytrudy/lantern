import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'feature_flag_notifier.g.dart';

@Riverpod(keepAlive: true)
class FeatureFlagNotifier extends _$FeatureFlagNotifier {
  @override
  Map<String, dynamic> build() {
    return {};
  }

  Future<void> fetchFeatureFlags() async {
    // Disabled in the pure self-hosted build.
  }
}
