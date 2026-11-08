import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/features/demo/presentation/demo_flow.dart';

/// Demo 作用域挂载点（根作用域使用）：独立无父容器包住 MaterialApp，
/// 并经 bootstrap widget 激活流程控制器。
class DemoScope extends StatelessWidget {
  const DemoScope({required this.container, required this.child, super.key});

  final ProviderContainer container;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return UncontrolledProviderScope(
      container: container,
      child: _DemoFlowBootstrap(child: child),
    );
  }
}

/// Demo 容器内首读 demoFlowProvider——启动步骤驱动器
class _DemoFlowBootstrap extends ConsumerWidget {
  const _DemoFlowBootstrap({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(demoFlowProvider);
    return child;
  }
}
