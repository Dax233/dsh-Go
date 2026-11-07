import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/update_state.dart';

/// Mounted once in the home shell; draws nothing.
///
/// Fork: it no longer runs the automatic daily check, so no update sheet pops
/// up over whatever the person is doing (设置 → 关于 → 检查更新 stays manual).
/// It keeps telling the controller when the app comes back to the front, which
/// continues an install waiting on the "install unknown apps" permission.
class UpdateLaunchCheck extends ConsumerStatefulWidget {
  const UpdateLaunchCheck({super.key});

  @override
  ConsumerState<UpdateLaunchCheck> createState() => _UpdateLaunchCheckState();
}

class _UpdateLaunchCheckState extends ConsumerState<UpdateLaunchCheck> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(ref.read(appUpdateProvider.notifier).onAppResumed()));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
