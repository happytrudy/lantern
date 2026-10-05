import 'package:auto_route/annotations.dart';
import 'package:flutter/material.dart';
import 'package:lantern/features/private_server/manually_server_setup.dart';

/// Pure self-hosted build: cloud-provider provisioning is removed.
@RoutePage(name: 'PrivateServerSetup')
class PrivateServerSetup extends StatelessWidget {
  const PrivateServerSetup({super.key});

  @override
  Widget build(BuildContext context) => const ManuallyServerSetup();
}
