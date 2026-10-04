import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lantern/core/common/common.dart';
import 'package:lantern/core/localization/localization_constants.dart';
import 'package:lantern/core/updater/updater.dart';
import 'package:lantern/core/utils/pro_utils.dart';
import 'package:lantern/core/widgets/subscription_tags.dart';
import 'package:lantern/core/models/feature_flags.dart';
import 'package:lantern/features/home/provider/app_setting_notifier.dart';
import 'package:lantern/features/home/provider/country_code_notifier.dart';
import 'package:lantern/features/home/provider/feature_flag_notifier.dart';
import 'package:lantern/features/home/provider/home_notifier.dart';
import 'package:lantern/features/plans/restore_purchase_mixin.dart';
import 'package:lantern/features/setting/appearance.dart'
    show appearanceModeLabel, showAppearanceBottomSheet;

import '../../core/services/injection_container.dart';

enum _SettingType {
  account,
  signIn,
  vpnSetting,
  actionModeSetting,
  language,
  appearance,
  support,
  getPro,
  checkForUpdates,
  browserUnbounded,
  restorePurchase,
}

@RoutePage(name: 'Setting')
class Setting extends StatefulHookConsumerWidget {
  const Setting({super.key});

  @override
  ConsumerState<Setting> createState() => _SettingState();
}

class _SettingState extends ConsumerState<Setting>
    with RestorePurchaseMixin<Setting> {
  late final Future<bool> _canCheckForUpdates = _canCheckForUpdatesSafely();

  Future<bool> _canCheckForUpdatesSafely() async {
    if (!sl.isRegistered<Updater>()) {
      appLogger.warning('Updater not registered, hiding update check setting');
      return false;
    }
    try {
      return await sl<Updater>().canCheckForUpdates();
    } catch (e, st) {
      appLogger.error('Failed to determine update check availability', e, st);
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keep store actions in sync with country-based billing availability.
    ref.watch(countryCodeProvider);
    final appSetting = ref.watch(appSettingProvider);
    // Server-side gate. Censored regions get Features[unbounded]=false,
    // which hides the Unbounded settings sub-page link below.
    final unboundedAvailable = ref
        .watch(featureFlagProvider)
        .getBool(FeatureFlag.unbounded);

    final locale = appSetting.locale;
    final themeMode = appSetting.themeMode;
    final textTheme = Theme.of(context).textTheme;

    return BaseScreen(
      title: 'settings'.i18n,
      padded: false,
      body: ListView(
        padding: EdgeInsets.symmetric(horizontal: defaultSize),
        children: <Widget>[
          const SizedBox(height: defaultSize),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                AppTile(
                  tileKey: const Key('setting.vpn_setting_tile'),
                  label: 'vpn_settings'.i18n,
                  icon: AppImagePaths.glob,
                  onPressed: () => settingMenuTap(_SettingType.vpnSetting),
                ),
                if (unboundedAvailable) ...[
                  DividerSpace(),
                  AppTile(
                    label: 'unbounded_settings_title'.i18n,
                    icon: AppImagePaths.handshake,
                    onPressed: () =>
                        settingMenuTap(_SettingType.actionModeSetting),
                  ),
                ],
                DividerSpace(),
                AppTile(
                  tileKey: const Key('setting.language_tile'),
                  label: 'language'.i18n,
                  icon: AppImagePaths.translate,
                  trailing: Text(
                    displayLanguage(locale),
                    style: textTheme.titleMedium!.copyWith(
                      color: context.textLink,
                    ),
                  ),
                  onPressed: () => settingMenuTap(_SettingType.language),
                ),
                DividerSpace(),
                AppTile(
                  tileKey: const Key('setting.appearance_tile'),
                  label: 'appearance'.i18n,
                  icon: AppImagePaths.theme,
                  trailing: Text(
                    appearanceModeLabel(themeMode),
                    style: textTheme.titleMedium!.copyWith(
                      color: context.textLink,
                    ),
                  ),
                  onPressed: () => settingMenuTap(_SettingType.appearance),
                ),
              ],
            ),
          ),
          const SizedBox(height: defaultSize),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
              ],
            ),
          ),
          if (AppBuildInfo.isDevModeEnabled) ...{
            SizedBox(height: defaultSize),
            AppCard(
              padding: EdgeInsets.zero,
              child: AppTile(
                label: 'developer_mode'.i18n,
                icon: Icon(Icons.developer_board),
                onPressed: () {
                  appRouter.push(const DeveloperMode());
                },
              ),
            ),
          },
        ],
      ),
    );
  }

  Future<void> settingMenuTap(_SettingType menu) async {
    switch (menu) {
      case _SettingType.signIn:
        appRouter.push(const SignInEmail());
        break;
      case _SettingType.language:
        appRouter.push(Language());
        return;
      case _SettingType.appearance:
        if (PlatformUtils.isDesktop) {
          appRouter.push(const Appearance());
          return;
        }
        showAppearanceBottomSheet(context: context);
        break;
      case _SettingType.support:
        appRouter.push(Support());
        break;

      case _SettingType.getPro:
        appRouter.push(InviteFriends());
        break;
      case _SettingType.checkForUpdates:
        await checkForUpdates();
        break;

      case _SettingType.account:
        final user = ref.read(homeProvider).value;
        final userSignedIn = ref.read(appSettingProvider).userLoggedIn;
        await openAccountOrProAccountSetup(
          context: context,
          user: user,
          userLoggedIn: userSignedIn,
        );
        break;
      case _SettingType.vpnSetting:
        appRouter.push(VPNSetting());
        break;
      case _SettingType.actionModeSetting:
        appRouter.push(ActionModeSetting());
        break;
      case _SettingType.browserUnbounded:
        // TODO: Handle this case.
        throw UnimplementedError();
      case _SettingType.restorePurchase:
        restorePurchaseFlow();
        break;
    }
  }

  Future<void> checkForUpdates() async {
    try {
      await sl<Updater>().checkNow();
    } catch (e, st) {
      appLogger.error('Error checking for updates: $e', st);
      if (!mounted) return;
      AppDialog.errorDialog(
        context: context,
        title: 'error'.i18n,
        content: e.localizedDescription,
      );
    }
  }
}
