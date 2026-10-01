import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/intermediate/components/factual_memory_tab.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../helpers/fake_factual_repository.dart';

/// 事实 Tab 归档筛选默认态（2026-09-03 用户反馈）
///
/// 归并/ARCHIVE_ENTITY 后归档实体混在列表里显得乱：
/// - 默认只显示活跃实体（_archiveFilter 初始 1），统计栏如实显示"显示 2 / 3"
/// - 筛选栏三态可切：已归档（只看归档）、全部（含归档）、活跃（默认）
void main() {
  FakeFactualRepository seedRepo() {
    final repo = FakeFactualRepository();
    FactualEntity entity(
      String id,
      String name,
      FactualEntityType type, {
      bool archived = false,
    }) =>
        FactualEntity(
          entityId: id,
          sessionId: 's1',
          type: type,
          primaryName: name,
          aliases: const [],
          importance: 3,
          createdTurn: 1,
          createdAt: DateTime(2026),
          isArchived: archived,
        );
    repo.entitiesById = {
      'e1': entity('e1', '林动', FactualEntityType.character),
      'e2': entity('e2', '玄天尺', FactualEntityType.item),
      'e3': entity('e3', '旧林动', FactualEntityType.character, archived: true),
    };
    return repo;
  }

  Future<void> pumpTab(WidgetTester tester, FakeFactualRepository repo) async {
    // 加宽测试面：筛选 chips 行完整放下，避免水平滚动视口的中间态
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
    // _loadData 在 initState 异步发起；用定时 pump 而非 pumpAndSettle
    // （防测试环境无限动画挂死，见 test-infra 约定）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> openFilterBarAndTap(WidgetTester tester, String label) async {
    // 折叠态图标是 filter_list_outlined，展开后变 filter_list
    final collapsed =
        find.widgetWithIcon(IconButton, Icons.filter_list_outlined);
    if (collapsed.evaluate().isNotEmpty) {
      await tester.tap(collapsed.first);
      // 关键：tap 的 setState 在下一帧才重建，AnimatedSize 该帧才起播——
      // 只 pump(300ms) 一次会让点击落在动画进行中的折叠态（列表盖住 chips）
      await tester.pump(); // 重建帧：chips 出现、动画起播
      await tester.pump(const Duration(milliseconds: 250)); // 播完 200ms 动画
    }
    final chip = find.text(label);
    expect(chip, findsWidgets, reason: '筛选栏应已展开并含 $label chip');
    await tester.tap(chip.first);
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('默认只显示活跃实体，统计栏显示 显示 2 / 3', (tester) async {
    await pumpTab(tester, seedRepo());

    expect(find.text('林动'), findsOneWidget);
    expect(find.text('玄天尺'), findsOneWidget);
    // 归档实体默认不出现（含"已归档"徽标也不出现）
    expect(find.text('旧林动'), findsNothing);
    expect(find.text('已归档'), findsNothing);
    expect(find.textContaining('显示 2 / 3'), findsOneWidget);
  });

  testWidgets('筛选切到已归档：只看归档实体；切回全部：含归档', (tester) async {
    await pumpTab(tester, seedRepo());

    await openFilterBarAndTap(tester, '已归档');
    expect(find.text('旧林动'), findsOneWidget);
    expect(find.text('林动'), findsNothing);
    expect(find.text('玄天尺'), findsNothing);

    // "全部" chip 有三组（类型/重要性/归档状态），取归档组（最后一组）
    final allChips = find.text('全部');
    expect(allChips, findsNWidgets(3));
    await tester.tap(allChips.last);
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('林动'), findsOneWidget);
    expect(find.text('玄天尺'), findsOneWidget);
    expect(find.text('旧林动'), findsOneWidget);
    // 归档实体的"已归档"徽标与筛选 chip 同名，共 2 处
    expect(find.text('已归档'), findsNWidgets(2));
  });

  testWidgets('筛选切回活跃：恢复默认视图', (tester) async {
    await pumpTab(tester, seedRepo());

    await openFilterBarAndTap(tester, '已归档');
    await openFilterBarAndTap(tester, '活跃');

    expect(find.text('林动'), findsOneWidget);
    expect(find.text('玄天尺'), findsOneWidget);
    expect(find.text('旧林动'), findsNothing);
    expect(find.textContaining('显示 2 / 3'), findsOneWidget);
  });
}
