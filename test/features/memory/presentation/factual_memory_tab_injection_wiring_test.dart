import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/factual_memory_tab.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/entities/force_inject_target.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../helpers/fake_factual_repository.dart';

/// 批 J-b 注入停用 UI 接线（7cf837af）回归测试
///
/// factual_memory_tab 的「停用注入/恢复注入」菜单与三徽标（来源/常驻/
/// 停用）交付时零测试。覆盖：
/// - 未归档实体菜单含停用注入项；点击后 batchUpdateInjectionDisabled
///   落库（fake 记录状态翻转）、成功后刷新出停用徽标 + floating snackbar
/// - 再点恢复注入：状态翻回、恢复 snackbar（双向）
/// - 归档实体菜单无停用/恢复注入项（有「恢复」置顶直达项）
/// - 徽标条件渲染：来源（角色卡/世界书）、常驻（世界/指令）、停用
///
/// 搭法沿用 factual_memory_tab_archive_filter_test 的 pump 范式
/// （定时 pump，勿用 pumpAndSettle——无限动画会挂死）。
void main() {
  FactualEntity entity(
    String id,
    String name, {
    bool archived = false,
    FactualSource source = FactualSource.auto,
    ForceInjectTarget forceInject = ForceInjectTarget.none,
    bool injectionDisabled = false,
  }) =>
      FactualEntity(
        entityId: id,
        sessionId: 's1',
        type: FactualEntityType.character,
        primaryName: name,
        aliases: const [],
        importance: 3,
        createdTurn: 1,
        createdAt: DateTime(2026),
        isArchived: archived,
        source: source,
        forceInject: forceInject,
        injectionDisabled: injectionDisabled,
      );

  Future<void> pumpTab(WidgetTester tester, FakeFactualRepository repo) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: ProviderScope(
          overrides: [factualRepositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
            home: const Scaffold(
              body: FactualMemoryTab(sessionId: 's1'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// 打开实体卡右上角菜单并点选 [label] 菜单项
  Future<void> openMenuAndTap(WidgetTester tester, String label) async {
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pump();
    // 菜单入场动画播完再点——动画中命中区域与布局位置不重合会 tap 落空
    await tester.pump(const Duration(milliseconds: 300));
    final item = find.text(label);
    expect(item, findsOneWidget, reason: '菜单应含「$label」项');
    await tester.tap(item);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200)); // 菜单退场
    await tester.pump(const Duration(milliseconds: 100)); // 异步落库 + 刷新
  }

  testWidgets('未归档实体：菜单含停用注入项，点击后落库+刷新徽标+snackbar', (tester) async {
    final repo = FakeFactualRepository()
      ..entitiesById = {'e1': entity('e1', '林动')};
    await pumpTab(tester, repo);

    expect(find.text('已停用注入'), findsNothing, reason: '初始未停用，无停用徽标');

    await openMenuAndTap(tester, '停用注入（暂不参与每轮上下文）');

    // fake 仓储记录了 batchUpdateInjectionDisabled([e1], true) 的状态翻转
    expect(repo.entitiesById['e1']!.injectionDisabled, isTrue);
    // 成功 snackbar（floating）反馈
    expect(find.text('已停用注入，该词条暂不进入每轮上下文'), findsOneWidget);
    // _loadData 刷新后列表内出现停用徽标
    expect(find.text('已停用注入'), findsOneWidget);
  });

  testWidgets('停用后再点恢复注入：状态翻回、恢复 snackbar（双向接线）', (tester) async {
    final repo = FakeFactualRepository()
      ..entitiesById = {
        'e1': entity('e1', '林动', injectionDisabled: true),
      };
    await pumpTab(tester, repo);

    expect(find.text('已停用注入'), findsOneWidget, reason: '停用态先渲染徽标');

    await openMenuAndTap(tester, '恢复注入');

    expect(repo.entitiesById['e1']!.injectionDisabled, isFalse);
    expect(find.text('已恢复注入'), findsOneWidget);
    expect(find.text('已停用注入'), findsNothing, reason: '刷新后停用徽标消失');
  });

  testWidgets('归档实体：菜单无停用/恢复注入项，有「恢复」直达项', (tester) async {
    final repo = FakeFactualRepository()
      ..entitiesById = {'e1': entity('e1', '旧林动', archived: true)};
    await pumpTab(tester, repo);

    // 默认归档筛选=活跃，先切到「已归档」让归档实体出现
    final collapsed =
        find.widgetWithIcon(IconButton, Icons.filter_list_outlined);
    await tester.tap(collapsed.first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250)); // 播完展开动画
    await tester.tap(find.text('已归档').first);
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pump();

    expect(
      find.text('停用注入（暂不参与每轮上下文）'),
      findsNothing,
      reason: '归档实体无停用注入操作（onToggleInjection 传 null）',
    );
    expect(find.text('恢复注入'), findsNothing);
    expect(find.text('恢复'), findsOneWidget, reason: '归档实体置顶恢复直达项');
  });

  testWidgets('卡头徽标条件渲染：来源/常驻/停用（批 J-b）', (tester) async {
    final repo = FakeFactualRepository()
      ..entitiesById = {
        'e1': entity('e1', '角色卡种子', source: FactualSource.card),
        'e2': entity(
          'e2',
          '世界书常驻',
          source: FactualSource.worldbook,
          forceInject: ForceInjectTarget.world,
        ),
        'e3': entity('e3', '停用词条', injectionDisabled: true),
        'e4': entity('e4', '自动生长'),
      };
    await pumpTab(tester, repo);

    // 来源徽标：card → 角色卡；worldbook → 世界书；auto → 无
    expect(find.text('角色卡'), findsOneWidget);
    expect(find.text('世界书'), findsOneWidget);
    // 常驻徽标：world → 常驻·世界；未设置/指令未用不出
    expect(find.text('常驻·世界'), findsOneWidget);
    expect(find.text('常驻·指令'), findsNothing);
    // 停用徽标
    expect(find.text('已停用注入'), findsOneWidget);
    // e4（auto/none/未停用）三种徽标都不出：总数即上文各一
    expect(find.text('角色卡'), findsOneWidget);
    expect(find.byIcon(Icons.person_outline), findsOneWidget);
    expect(find.byIcon(Icons.auto_stories_outlined), findsOneWidget);
  });
}
