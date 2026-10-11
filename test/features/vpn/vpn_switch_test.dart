import 'package:animated_toggle_switch/animated_toggle_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:i18n_extension/i18n_extension.dart';
import 'package:lantern/core/common/common.dart';
import 'package:lantern/core/models/lantern_status.dart';
import 'package:lantern/features/vpn/provider/vpn_notifier.dart';
import 'package:lantern/features/vpn/vpn_switch.dart';
import 'package:lantern/lantern/lantern_service.dart';
import 'package:lantern/lantern/lantern_service_notifier.dart';

class _Service implements LanternService {
  @override
  Stream<LanternStatus> watchVPNStatus() => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Vpn extends VpnNotifier {
  int requests = 0;

  @override
  VPNStatus build() => VPNStatus.disconnected;

  @override
  Future<Either<Failure, String>> onVPNStateChange() async {
    requests++;
    state = state == VPNStatus.connected
        ? VPNStatus.disconnecting
        : VPNStatus.connecting;
    return right('ok');
  }

  void emit(VPNStatus status) => state = status;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final previousTranslations = Localization.translations;
    final previousLocale = Localization.defaultLocale;
    Localization.translations =
        Translations.byLocale('en') +
        {
          'en': {
            'Connecting…': 'Connecting…',
            'Disconnecting…': 'Disconnecting…',
          },
          'zh-Hans': {'Connecting…': '正在连接…', 'Disconnecting…': '正在断开…'},
        };
    Localization.defaultLocale = 'zh-Hans';
    addTearDown(() {
      Localization.translations = previousTranslations;
      Localization.defaultLocale = previousLocale;
    });
  });

  Future<ProviderContainer> mount(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        lanternServiceProvider.overrideWithValue(_Service()),
        vpnProvider.overrideWith(_Vpn.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ScreenUtilInit(
          designSize: const Size(390, 844),
          child: MaterialApp(
            theme: AppTheme.appTheme(),
            home: const Scaffold(body: Center(child: VPNSwitch())),
          ),
        ),
      ),
    );
    return container;
  }

  testWidgets(
    'blocks taps and dragging throughout connection and disconnection',
    (tester) async {
      final container = await mount(tester);
      final vpn = container.read(vpnProvider.notifier) as _Vpn;
      await tester.tap(find.byKey(const Key('vpn.toggle')));
      await tester.pump();
      expect(find.text('正在连接…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<AbsorbPointer>(
              find.byKey(const Key('vpn.switch.interaction')),
            )
            .absorbing,
        isTrue,
      );
      expect(
        tester
            .widget<CustomAnimatedToggleSwitch<bool>>(
              find.byType(CustomAnimatedToggleSwitch<bool>),
            )
            .active,
        isFalse,
      );
      final switchFinder = find.byKey(const Key('vpn.switch.connecting'));
      for (var i = 0; i < 5; i++) {
        await tester.tapAt(tester.getCenter(switchFinder));
      }
      await tester.drag(switchFinder, const Offset(80, 0), warnIfMissed: false);
      await tester.pump();
      expect(vpn.requests, 1);
      expect(container.read(vpnProvider), VPNStatus.connecting);

      vpn.emit(VPNStatus.connected);
      await tester.pump();
      expect(find.byKey(const Key('vpn.switch.progress')), findsNothing);
      expect(
        tester
            .widget<AbsorbPointer>(
              find.byKey(const Key('vpn.switch.interaction')),
            )
            .absorbing,
        isFalse,
      );
      await tester.tap(find.byKey(const Key('vpn.toggle')));
      await tester.pump();
      expect(find.text('正在断开…'), findsOneWidget);
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('vpn.switch.disconnecting'))),
      );
      await tester.pump();
      expect(vpn.requests, 2);

      vpn.emit(VPNStatus.disconnected);
      await tester.pump();
      expect(find.byKey(const Key('vpn.switch.progress')), findsNothing);
      await tester.tap(find.byKey(const Key('vpn.toggle')));
      await tester.pump();
      expect(vpn.requests, 3);
    },
  );

  testWidgets('a failed connection enables the switch for retry', (
    tester,
  ) async {
    final container = await mount(tester);
    final vpn = container.read(vpnProvider.notifier) as _Vpn;
    await tester.tap(find.byKey(const Key('vpn.toggle')));
    await tester.pump();
    vpn.emit(VPNStatus.error);
    await tester.pump();
    expect(find.byKey(const Key('vpn.switch.progress')), findsNothing);
    expect(
      tester
          .widget<AbsorbPointer>(
            find.byKey(const Key('vpn.switch.interaction')),
          )
          .absorbing,
      isFalse,
    );
    await tester.tap(find.byKey(const Key('vpn.toggle')));
    await tester.pump();
    expect(vpn.requests, 2);
    expect(find.text('正在连接…'), findsOneWidget);
  });
}
