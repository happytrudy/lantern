import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lantern/core/widgets/setting_tile.dart';
import 'package:lantern/features/vpn/provider/server_location_notifier.dart';
import 'package:lantern/features/vpn/provider/available_servers_notifier.dart';

import '../../core/common/common.dart';

class LocationSetting extends HookConsumerWidget {
  const LocationSetting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverLocation = ref.watch(serverLocationProvider);
    final serverType = serverLocation.serverType.toServerLocationType;
    final availableServers = ref.watch(availableServersProvider).value;

    String title = '';
    String value = '';
    String flag = '';
    String protocol = '';

    switch (serverType) {
      case ServerLocationType.auto:
        title = 'smart_routing'.i18n;
        final fastest = availableServers?.fastestPrivateServer;
        final fallback = availableServers?.userServers.isNotEmpty == true
            ? availableServers!.userServers.first
            : null;
        final selected = fastest ?? fallback;
        final autoLoc = serverLocation.autoLocation;
        value = selected?.tag ??
            (autoLoc != null && autoLoc.displayName.isNotEmpty
                ? autoLoc.displayName
                : 'fastest_server'.i18n);
        flag = selected?.location.countryCode ?? autoLoc?.countryCode ?? '';
        protocol = selected?.protocol ?? autoLoc?.protocol ?? '';
        break;

      case ServerLocationType.lanternLocation:
        title = 'selected_location'.i18n;
        value = serverLocation.displayName;
        flag = serverLocation.countryCode;
        protocol = serverLocation.protocol;
        break;

      case ServerLocationType.privateServer:
        title = serverLocation.serverName;
        value = serverLocation.displayName;
        flag = serverLocation.countryCode;
        protocol = serverLocation.protocol;
        break;
    }

    return SettingTile(
      tileKey: const Key('home.location_setting'),
      label: title,
      value: value.i18n,
      subtitle: protocol,
      icon: flag.isEmpty ? AppImagePaths.location : Flag(countryCode: flag),
      // Small screens drop the > chevron; the row stays tappable via onTap.
      actions: [
        if (serverType == ServerLocationType.auto)
          AppImage(path: AppImagePaths.blot, useThemeColor: false),
        if (!isSmallScreen(context)) ...[
          const SizedBox(width: 8),
          const AppImage(path: AppImagePaths.arrowForward),
        ],
      ],
      onTap: () => appRouter.push(const ServerSelection()),
    );
  }
}
