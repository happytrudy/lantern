import 'package:auto_route/annotations.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lantern/core/common/common.dart';
import 'package:lantern/core/widgets/split_tunneling_tile.dart';
import 'package:lantern/core/widgets/switch_button.dart';
import 'package:lantern/features/home/provider/radiance_settings_providers.dart';
import 'package:lantern/features/home/provider/app_setting_notifier.dart';

@RoutePage(name: 'VPNSetting')
class VPNSetting extends HookConsumerWidget {
  const VPNSetting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return BaseScreen(
      title: 'vpn_settings'.i18n,
      body: _buildBody(context, ref),
    );
  }

  Widget _buildBody(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final isUserPro = ref.watch(isUserProProvider);
    final isPrivateServerFound = ref.watch(isPrivateServerFoundProvider);
    final splitTunnelingEnabled = ref.watch(
      radianceSettingsProvider.select((s) => s.splitTunneling),
    );
    final routingMode = ref.watch(
      radianceSettingsProvider.select((s) => s.routingMode),
    );
    final autoConnectOnStartup = ref.watch(
      appSettingProvider.select((s) => s.autoConnectOnStartup),
    );
    return ListView(
      key: const Key('vpn_setting.list'),
      padding: const EdgeInsets.all(0),
      shrinkWrap: true,
      children: <Widget>[
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppTile(
                label: 'server_locations'.i18n,
                icon: AppImagePaths.location,
                trailing: AppImage(
                  path: AppImagePaths.arrowForward,
                  height: 20,
                ),
                onPressed: () {
                  appRouter.push(const ServerSelection());
                },
              ),
              DividerSpace(),
              AppTile(
                label: '启动自动连接',
                subtitle: Text(
                  '连接上次使用的自建服务器；智能路由选择最低延迟节点',
                  style: textTheme.labelMedium!.copyWith(
                    color: context.textTertiary,
                  ),
                ),
                icon: AppImagePaths.vpnDisconnected,
                trailing: SwitchButton(
                  value: autoConnectOnStartup,
                  onChanged: (value) => ref
                      .read(appSettingProvider.notifier)
                      .setAutoConnectOnStartup(value ?? false),
                ),
              ),
              if (!PlatformUtils.isIOS) ...[
                DividerSpace(),
                SplitTunnelingTile(
                  label: 'routing_mode'.i18n,
                  icon: AppImagePaths.route,
                  actionText: routingMode.label(),
                  onPressed: () => appRouter.push(const SmartRouting()),
                ),
              ],
              DividerSpace(),
              if (PlatformUtils.isAndroid ||
                  PlatformUtils.isMacOS ||
                  PlatformUtils.isWindows) ...[
                SplitTunnelingTile(
                  label: 'split_tunneling'.i18n,
                  icon: AppImagePaths.callSpilt,
                  actionText:
                      splitTunnelingEnabled ? 'enabled'.i18n : 'disabled'.i18n,
                  onPressed: () => appRouter.push(const SplitTunneling()),
                ),
                DividerSpace(),
              ],
            ],
          ),
        ),
        // The "Share My Connection" entry that used to push a SmC
        // screen from here moved to a top-level Unbounded tab in the
        // Home shell — see lib/features/home/home.dart. Toggling peer
        // share now happens inside that tab.
        SizedBox(height: 16),
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppTile(
                label: 'join_private_server'.i18n,
                icon: AppImagePaths.joinServer,
                trailing: AppImage(
                  path: AppImagePaths.arrowForward,
                  height: 20,
                ),
                onPressed: () => appRouter.push(JoinPrivateServer()),
              ),
              DividerSpace(),
              if (isPrivateServerFound)
                AppTile(
                  label: 'manage_private_servers'.i18n,
                  icon: AppImagePaths.settingServer,
                  trailing: AppImage(
                    path: AppImagePaths.arrowForward,
                    height: 20,
                  ),
                  onPressed: () => appRouter.push(const ManagePrivateServer()),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
