import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/route_names.dart';
import '../../../shared/widgets/startup_brand_intro.dart';
import 'auth_providers.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_bootstrap);
  }

  Future<void> _bootstrap() async {
    final session = await ref.read(authControllerProvider.future);
    if (!mounted) {
      return;
    }
    context.go(session == null ? RoutePaths.provisioning : RoutePaths.dialer);
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: StartupBrandIntro());
  }
}
