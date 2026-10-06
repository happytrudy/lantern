import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lantern/core/extensions/error.dart';
import 'package:lantern/core/localization/i18n.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(Localization.loadTranslations);

  tearDown(() => Localization.defaultLocale = 'en_US');

  for (final locale in ['en_US', 'zh-Hans', 'zh-Hant']) {
    test('Windows service errors have actionable translations in $locale', () {
      Localization.defaultLocale = locale;
      for (final key in [
        'windows_service_missing_binary',
        'windows_service_permission_required',
        'windows_service_start_failed',
        'windows_service_not_ready',
      ]) {
        final error = PlatformException(
          code: key,
          message: '$key: i/o timeout',
        );
        expect(key.i18n, isNot(key));
        expect(error.localizedDescription, key.i18n);
        expect(localizeRawError('$key: i/o timeout'), key.i18n);
      }
    });
  }

  test('service error codes are used when no native message is supplied', () {
    final error = PlatformException(
      code: 'windows_service_permission_required',
    );
    expect(
      error.localizedDescription,
      'windows_service_permission_required'.i18n,
    );
  });

  test('server network failures keep their existing classification', () {
    expect(localizeRawError('connection refused'), 'err_check_connection'.i18n);
  });
}
