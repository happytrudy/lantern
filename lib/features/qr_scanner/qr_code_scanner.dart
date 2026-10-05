import 'dart:async';

import 'package:auto_route/annotations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lantern/core/common/common.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

@RoutePage(name: 'QrCodeScanner')
class QrCodeScanner extends HookConsumerWidget {
  const QrCodeScanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = useMemoized(
      () => MobileScannerController(facing: CameraFacing.back),
      const [],
    );

    final isHandling = useRef(false);

    useEffect(() {
      return controller.dispose;
    }, [controller]);

    // Lifecycle: stop camera in background, restart on resume
    useOnAppLifecycleStateChange((previous, current) {
      final state = current;
      final isCurrentRoute = (ModalRoute.of(context)?.isCurrent ?? true);

      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.inactive) {
        controller.stop();
        return;
      }

      if (state == AppLifecycleState.resumed && isCurrentRoute) {
        if (!isHandling.value) controller.start();
      }
    });

    Future<void> handleCode(String code) async {
      try {
        appLogger.info('Barcode found'); // QR payload intentionally not logged
        await controller.stop();
        if (!context.mounted) return;
        appRouter.pop(code);
      } finally {
        isHandling.value = false;
      }
    }

    return BaseScreen(
      title: 'scan_qr_code'.i18n,
      padded: false,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final scanWindow = Rect.fromCenter(
            center: Offset(constraints.maxWidth / 2, constraints.maxHeight / 2),
            width: constraints.maxWidth.clamp(240.0, 340.0).toDouble(),
            height: constraints.maxHeight.clamp(180.0, 280.0).toDouble(),
          );
          return Stack(
            children: [
              Positioned.fill(
                child: MobileScanner(
                  controller: controller,
                  // Do not restrict decoding to the overlay rectangle. A
                  // device preview can be cropped differently from Flutter's
                  // layout, which made valid codes appear to do nothing.
                  fit: BoxFit.cover,
                  onDetect: (capture) {
                    if (isHandling.value) return;

                    for (final barcode in capture.barcodes) {
                      final code = barcode.rawValue;
                      if (code == null || code.isEmpty) continue;

                      isHandling.value = true;
                      unawaited(handleCode(code));
                      break;
                    }
                  },
                  errorBuilder: (context, error) {
                    appLogger.error('Error scanning QR code: $error');
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          error.toString(),
                          style: const TextStyle(color: Colors.red),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  },
                ),
              ),
              ScanWindowOverlay(
                scanWindow: scanWindow,
                color: AppColors.whiteBlur.withOpacity(.75),
                borderRadius: BorderRadius.circular(16),
                borderColor: AppColors.gray0,
                borderWidth: 4,
                controller: controller,
              ),
            ],
          );
        },
      ),
    );
  }
}
