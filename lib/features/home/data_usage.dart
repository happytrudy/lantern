import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lantern/features/home/provider/data_cap_info_provider.dart';

import '../../core/common/common.dart';

class DataUsage extends ConsumerWidget {
  const DataUsage({super.key, this.insideCard = false});

  /// Renders as a row (with trailing divider) inside the VPN settings card
  /// instead of a standalone card — small-screen spec, engineering#3046.
  final bool insideCard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final dataCapAsync = ref.watch(dataCapInfoProvider);
    return dataCapAsync.when(
      data: (dataCapResponse) {
        /// If data cap is not enabled, don't show the widget
        if (!dataCapResponse.enabled || dataCapResponse.usage == null) {
          return const SizedBox.shrink();
        }
        final dataCap = dataCapResponse.usage!;

        final int usedBytes = dataCap.bytesUsed.clamp(0, 1 << 62);
        appLogger.debug(
          "Data Usage - Bytes: $usedBytes bytes",
        );
        final usedData = usedBytes / (1024 * 1024);
        appLogger.debug(
          "Data Usage - Used: $usedData MB",
        );

        final content = Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppImage(path: AppImagePaths.dataUsage),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'daily_data_usage'.i18n,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelLarge!.copyWith(
                      color: context.textTertiary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${usedData.toStringAsFixed(2)}${'mb'.i18n}',
                  style: textTheme.titleSmall!.copyWith(
                    color: context.textPrimary,
                  ),
                ),
              ],
            ),
          ],
        );

        if (insideCard) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: isSmallScreen(context) ? 8 : 10,
                ),
                child: content,
              ),
              const DividerSpace(),
            ],
          );
        }

        return Container(
          decoration: BoxDecoration(
            boxShadow: [
              BoxShadow(
                color: Color(0x19006162),
                blurRadius: 32,
                offset: Offset(0, 4),
                spreadRadius: 0,
              ),
            ],
          ),
          child: Card(
            margin: EdgeInsets.zero,
            child: Padding(padding: const EdgeInsets.all(16.0), child: content),
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (error, stack) => const SizedBox.shrink(),
    );
  }
}
