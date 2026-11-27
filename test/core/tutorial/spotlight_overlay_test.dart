import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/tutorial/spotlight_overlay.dart';
import 'package:lmstory/core/tutorial/spotlight_registry.dart';
import 'package:lmstory/core/tutorial/spotlight_target.dart';
import 'package:lmstory/core/tutorial/tutorial_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';

Widget hostApp({
  required TutorialController controller,
  required SpotlightRegistry registry,
  required Widget page,
  ValueNotifier<int>? presence,
}) {
  return ProviderScope(
    overrides: [
      spotlightRegistryProvider.overrideWithValue(registry),
      tutorialControllerProvider.overrideWithValue(controller),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        builder: (context, child) => SpotlightOverlayHost(
          modalPresence: presence,
          child: child ?? const SizedBox(),
        ),
        home: page,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    LocaleSettings.setLocaleRaw('zh');
  });

  TutorialStep step(
    String id, {
    String? targetId,
    bool skippable = false,
    String? confirmLabel,
  }) =>
      TutorialStep(
        id: id,
        title: '步骤-$id',
        message: '这是步骤 $id 的说明文字。',
        targetId: targetId,
        skippable: skippable,
        confirmLabel: confirmLabel,
      );

  testWidgets('无教程活动时不渲染遮罩；目标步骤渲染挖孔与气泡', (tester) async {
    final controller = TutorialController();
    final registry = SpotlightRegistry();

    await tester.pumpWidget(
      hostApp(
        controller: controller,
        registry: registry,
        page: Scaffold(
          body: Center(
            child: SpotlightTarget(
              id: 'btn',
              child: ElevatedButton(
                onPressed: () {},
                child: const Text('真实按钮'),
              ),
            ),
          ),
        ),
      ),
    );
    // 未 begin：无遮罩
    expect(find.text('步骤-x'), findsNothing);

    controller.begin([step('x', targetId: 'btn')]);
    await tester.pumpAndSettle();

    expect(find.text('步骤-x'), findsOneWidget);
    expect(find.text('退出体验'), findsOneWidget);
  });

  testWidgets('挖孔区命中穿透（用户真实点击目标）；遮罩区吸收误触', (tester) async {
    var taps = 0;
    final controller = TutorialController();
    final registry = SpotlightRegistry();

    await tester.pumpWidget(
      hostApp(
        controller: controller,
        registry: registry,
        page: Scaffold(
          body: Column(
            children: [
              const SizedBox(height: 40),
              SpotlightTarget(
                id: 'btn',
                child: ElevatedButton(
                  onPressed: () => taps++,
                  child: const Text('目标按钮'),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
    controller.begin([step('x', targetId: 'btn')]);
    await tester.pumpAndSettle();

    // 挖孔内点击：穿透到真实按钮
    await tester.tap(find.text('目标按钮'), warnIfMissed: false);
    await tester.pump();
    expect(taps, 1, reason: '挖孔区必须放行真实操作');

    // 遮罩区点击：吸收（不打到按钮）
    await tester.tapAt(const Offset(20, 600));
    await tester.pump();
    expect(taps, 1, reason: '遮罩区必须吸收误触');
  });

  testWidgets('wrapped guidance keeps the bottom target tappable',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final controller = TutorialController();
    final registry = SpotlightRegistry();
    var taps = 0;

    await tester.pumpWidget(
      hostApp(
        controller: controller,
        registry: registry,
        page: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: SpotlightTarget(
                id: 'finish',
                child: ElevatedButton(
                  onPressed: () => taps++,
                  child: const Text('Done'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    controller.begin([
      const TutorialStep(
        id: 'rules',
        title: 'Use the built-in world rules',
        message: 'Choose the Isekai narrator system prompt and review '
            'the project rules in the preview. Tap Use this to confirm. '
            'Then tap Done to open the story and read the first scene.',
        targetId: 'finish',
      ),
    ]);
    await tester.pumpAndSettle();

    final done = find.widgetWithText(ElevatedButton, 'Done');
    await tester.tap(done, warnIfMissed: false);
    await tester.pump();
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('介绍步（allowUntargetedTaps）全屏自由操作', (tester) async {
    var taps = 0;
    final controller = TutorialController();
    final registry = SpotlightRegistry();

    await tester.pumpWidget(
      hostApp(
        controller: controller,
        registry: registry,
        page: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: ElevatedButton(
                onPressed: () => taps++,
                child: const Text('任意按钮'),
              ),
            ),
          ),
        ),
      ),
    );
    controller.begin([
      const TutorialStep(
        id: 'intro',
        title: '介绍',
        message: '自由操作',
        allowUntargetedTaps: true,
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('任意按钮'), warnIfMissed: false);
    await tester.pump();
    expect(taps, 1, reason: '介绍步遮罩外允许操作');
  });

  testWidgets('目标缺失 → 等待卡（不静默跳步）；退出入口只请求退出', (tester) async {
    var aborted = 0;
    var exitRequested = 0;
    final controller = TutorialController(
      onAborted: () => aborted++,
      onExitRequested: () => exitRequested++,
    );
    final registry = SpotlightRegistry();

    await tester.pumpWidget(
      hostApp(
        controller: controller,
        registry: registry,
        page: const Scaffold(body: SizedBox()),
      ),
    );
    controller.begin([step('x', targetId: 'missing-target')]);
    await tester.pumpAndSettle();

    expect(find.text('正在等待目标出现…'), findsOneWidget);
    expect(controller.active, isTrue, reason: '必需步骤不得静默跳过');

    await tester.tap(find.text('退出体验'));
    await tester.pumpAndSettle();
    // r3 契约：退出入口只发出请求（宿主弹确认框），不终止教程
    expect(exitRequested, 1, reason: '退出入口应置退出请求态');
    expect(controller.active, isTrue, reason: '教程不得提前终止');
    expect(aborted, 0, reason: '确认前不得直接结束');
  });

  testWidgets('无目标说明步：确认按钮推进下一步', (tester) async {
    final controller = TutorialController();
    final registry = SpotlightRegistry();

    await tester.pumpWidget(
      hostApp(
        controller: controller,
        registry: registry,
        page: const Scaffold(body: SizedBox()),
      ),
    );
    controller.begin([step('a', confirmLabel: '知道了'), step('b')]);
    await tester.pumpAndSettle();
    expect(find.text('步骤-a'), findsOneWidget);

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('步骤-b'), findsOneWidget);
  });

  testWidgets('skippable 步骤显示跳过并推进', (tester) async {
    final controller = TutorialController();
    final registry = SpotlightRegistry();

    await tester.pumpWidget(
      hostApp(
        controller: controller,
        registry: registry,
        page: const Scaffold(body: SizedBox()),
      ),
    );
    controller.begin([
      step('a', skippable: true, confirmLabel: 'ok'),
      step('b'),
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('跳过此步'));
    await tester.pumpAndSettle();
    expect(find.text('步骤-b'), findsOneWidget);
  });

  testWidgets('Semantics：气泡标题/正文可被辅助技术读取', (tester) async {
    final controller = TutorialController();
    final registry = SpotlightRegistry();

    await tester.pumpWidget(
      hostApp(
        controller: controller,
        registry: registry,
        page: const Scaffold(body: SizedBox()),
      ),
    );
    controller.begin([step('a')]);
    await tester.pumpAndSettle();

    final handle = tester.ensureSemantics();
    final node = find.text('步骤-a');
    expect(node, findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('这是步骤 a 的说明文字')),
      findsOneWidget,
      reason: '气泡正文须带合并语义标签（标题+正文）',
    );
    handle.dispose();
  });

  testWidgets('候选目标/动态解析器优先指向首个已挂载目标（不触发等待卡）', (tester) async {
    final controller = TutorialController();
    final registry = SpotlightRegistry();

    await tester.pumpWidget(
      hostApp(
        controller: controller,
        registry: registry,
        page: Scaffold(
          body: Center(
            child: SpotlightTarget(
              id: 'btn2',
              child: ElevatedButton(
                onPressed: () {},
                child: const Text('按钮2'),
              ),
            ),
          ),
        ),
      ),
    );

    // btn1 未挂载，btn2 已挂载 → 动态解析到 btn2，不报等待卡
    controller.begin([
      const TutorialStep(
        id: 'multi',
        title: '多目标',
        message: '流转说明',
        targetId: 'btn1',
        candidateTargetIds: ['btn1', 'btn2'],
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('正在等待目标出现…'), findsNothing);
    expect(find.text('多目标'), findsOneWidget);
  });

  testWidgets('局部交互放行区（passThroughTargetId）放行点击，区外按钮吸收阻断', (tester) async {
    final controller = TutorialController();
    final registry = SpotlightRegistry();
    var outsideTapped = false;
    var insideTapped = false;

    await tester.pumpWidget(
      hostApp(
        controller: controller,
        registry: registry,
        page: Scaffold(
          body: Column(
            children: [
              // 区外按钮（如 AppBar 或底部栏）
              ElevatedButton(
                onPressed: () => outsideTapped = true,
                child: const Text('区外按钮'),
              ),
              // 放行区（如会话消息体）
              Expanded(
                child: SpotlightTarget(
                  id: 'chatBody',
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ElevatedButton(
                      onPressed: () => insideTapped = true,
                      child: const Text('会话区折叠按钮'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    controller.begin([
      const TutorialStep(
        id: 'running',
        title: '工作中',
        message: '说明',
        passThroughTargetId: 'chatBody',
      ),
    ]);
    await tester.pumpAndSettle();

    // 点击区外按钮：被吸收，不触发
    await tester.tap(find.text('区外按钮'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(outsideTapped, isFalse, reason: '遮罩吸收区外误触');

    // 点击放行区内按钮（避开居中气泡）：穿透放行，正常触发
    await tester.tap(find.text('会话区折叠按钮'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(insideTapped, isTrue, reason: '放行区内点击事件正常下发');
  });

  testWidgets('PopScope 拦截系统返回手势并触发 requestExit', (tester) async {
    final controller = TutorialController();
    final registry = SpotlightRegistry();
    var exitRequested = false;
    controller.onExitRequested = () => exitRequested = true;

    await tester.pumpWidget(
      hostApp(
        controller: controller,
        registry: registry,
        page: const Scaffold(body: Text('页面内容')),
      ),
    );

    controller.begin([
      const TutorialStep(
        id: 'step1',
        title: '测试',
        message: '正文',
      ),
    ]);
    await tester.pumpAndSettle();

    // 触发系统返回手势
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(exitRequested, isTrue, reason: '返回手势应触发 requestExit 进行二次确认');
    expect(controller.exitRequestOpen, isTrue);
  });

  testWidgets('模态浮层在栈且当前目标在顶层路由时，遮罩正常渲染并高亮目标', (tester) async {
    final controller = TutorialController();
    final registry = SpotlightRegistry();
    final presence = ValueNotifier<int>(1);

    await tester.pumpWidget(
      hostApp(
        controller: controller,
        registry: registry,
        presence: presence,
        page: const Scaffold(
          body: Center(
            child: SpotlightTarget(
              id: 'modalTarget',
              child: Text('浮层内按钮'),
            ),
          ),
        ),
      ),
    );

    controller.begin([
      step('step1', targetId: 'modalTarget'),
    ]);
    await tester.pumpAndSettle();

    // 目标在当前顶层路由且已注册，即使 presence=1 遮罩也正常渲染并展示气泡
    expect(find.text('步骤-step1'), findsOneWidget);
    expect(find.text('这是步骤 step1 的说明文字。'), findsOneWidget);
  });

  testWidgets('模态浮层在栈但当前目标在底层背景路由时，遮罩抬起放行浮层自由交互', (tester) async {
    final controller = TutorialController();
    final registry = SpotlightRegistry();
    final presence = ValueNotifier<int>(1);

    await tester.pumpWidget(
      hostApp(
        controller: controller,
        registry: registry,
        presence: presence,
        page: const Scaffold(
          body: Text('底层页面'),
        ),
      ),
    );

    // 模拟目标在底层路由（isCurrentRoute: false）
    registry.register(
      'backgroundTarget',
      const Rect.fromLTWH(50, 50, 100, 100),
      isCurrentRoute: false,
    );

    controller.begin([
      step('step1', targetId: 'backgroundTarget'),
    ]);
    await tester.pumpAndSettle();

    // 目标不在当前活动路由，遮罩抬起，气泡不渲染
    expect(find.text('步骤-step1'), findsNothing);
  });

  testWidgets('额外并列高亮目标列表（extraHighlightTargetIds）与主目标一同渲染挖孔并放行点击',
      (tester) async {
    final controller = TutorialController();
    final registry = SpotlightRegistry();
    var extraTapped = false;

    await tester.pumpWidget(
      hostApp(
        controller: controller,
        registry: registry,
        page: Scaffold(
          body: Column(
            children: [
              const SpotlightTarget(
                id: 'mainTarget',
                child: Text('主目标'),
              ),
              SpotlightTarget(
                id: 'extraTarget',
                child: GestureDetector(
                  onTap: () => extraTapped = true,
                  child: const Text('额外高亮目标'),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    controller.begin([
      const TutorialStep(
        id: 'multiHighlightStep',
        title: '多目标高亮',
        message: '说明',
        targetId: 'mainTarget',
        extraHighlightTargetIds: ['extraTarget'],
      ),
    ]);
    await tester.pumpAndSettle();

    // 点击额外高亮目标：挖孔穿透正常命中
    await tester.tap(find.text('额外高亮目标'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(extraTapped, isTrue, reason: '额外高亮目标挖孔区应穿透放行点击');
  });
}
