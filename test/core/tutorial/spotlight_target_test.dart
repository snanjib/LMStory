import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/tutorial/spotlight_registry.dart';
import 'package:lmstory/core/tutorial/spotlight_target.dart';

void main() {
  testWidgets('挂载注册全局 Rect；卸载注销', (tester) async {
    final registry = SpotlightRegistry();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [spotlightRegistryProvider.overrideWithValue(registry)],
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SpotlightTarget(
                id: 'btn',
                child: SizedBox(width: 80, height: 40),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(registry.rectOf('btn'), const Rect.fromLTWH(0, 0, 80, 40));

    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pump();
    expect(registry.rectOf('btn'), isNull);
  });

  testWidgets('布局变化重新上报', (tester) async {
    final registry = SpotlightRegistry();
    final wide = ValueNotifier<bool>(true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [spotlightRegistryProvider.overrideWithValue(registry)],
        child: MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: wide,
              builder: (context, isWide, _) => Align(
                alignment: Alignment.topLeft,
                child: SpotlightTarget(
                  id: 't',
                  child: Container(
                    color: Colors.red,
                    width: isWide ? 100.0 : 40.0,
                    height: 20,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(registry.rectOf('t')!.width, 100);

    wide.value = false;
    await tester.pump();
    await tester.pump();
    expect(registry.rectOf('t')!.width, 40);
  });

  testWidgets('滚动容器内：外部位移经上报器逐帧刷新跟随', (tester) async {
    final registry = SpotlightRegistry();
    final controller = ScrollController();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [spotlightRegistryProvider.overrideWithValue(registry)],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: ListView(
                controller: controller,
                children: const [
                  SizedBox(height: 50),
                  SpotlightTarget(
                    id: 'in-list',
                    child: SizedBox(height: 40, child: Text('target')),
                  ),
                  SizedBox(height: 800),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final before = registry.rectOf('in-list')!;
    expect(before.top, 50);

    // 滚动 120px：目标自身未重建，几何变化经 refreshReporters 兜底
    controller.jumpTo(120);
    await tester.pump();
    registry.refreshReporters();
    await tester.pump();
    final after = registry.rectOf('in-list')!;
    expect(after.top, closeTo(before.top - 120, 0.5), reason: '滚动位移必须被逐帧刷新捕获');
  });
}
