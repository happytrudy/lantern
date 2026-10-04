import 'package:fpdart/fpdart.dart';
import 'package:lantern/core/utils/failure.dart';
import 'package:lantern/core/services/injection_container.dart' show sl;
import 'package:lantern/core/services/local_storage_service.dart';
import 'package:lantern/features/vpn/provider/available_servers_notifier.dart';
import 'package:lantern/lantern/lantern_service_notifier.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/services/logger_service.dart';

part 'manage_server_notifier.g.dart';

@Riverpod(keepAlive: true)
class ManageServerNotifier extends _$ManageServerNotifier {
  @override
  void build() {}

  Future<void> refresh() async {
    appLogger.debug(
      'Force fetching available servers from Go after server management operation...',
    );
    await ref
        .read(availableServersProvider.notifier)
        .forceFetchAvailableServers();
  }

  Future<Either<Failure, Unit>> deleteServer(String serverName) async {
    final res = await ref
        .read(lanternServiceProvider)
        .deletePrivateServerByName(serverName);
    if (res.isRight()) {
      await sl<LocalStorageService>().removePrivateServer(serverName);
      await refresh();
    }
    return res;
  }

  Future<Either<Failure, Unit>> renameServer(
    String oldName,
    String newName,
  ) async {
    final res = await ref
        .read(lanternServiceProvider)
        .updatePrivateServerName(oldName, newName);
    if (res.isRight()) {
      await sl<LocalStorageService>().renamePrivateServer(oldName, newName);
      await refresh();
    }
    return res;
  }
}
