import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/memory_detail_dialog.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// MemoryDetailDialog widget test（v0.2 Phase C 方案二，2026-07-19 新增）
///
/// 验证：
/// 1. EventSummary 详情：5W1E 字段展示、空字段不展示、关闭按钮
/// 2. ExperientialMemory micro 详情：5W1E 字段展示、重要性星级、底栏元数据
/// 3. ExperientialMemory macro 详情：聚合微摘要数 + 触发原因
/// 4. 空事件占位：所有 5W1E 字段为空时展示'(空事件)'
/// 5. 点击小窗外区域关闭（barrierDismissible）
/// 6. 点击关闭按钮关闭
void main() {
  Widget wrap() {
    return TranslationProvider(
      child: MaterialApp(
        theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
  }

  Future<void> showEventSummaryDialog(
    WidgetTester tester, {
    required EventSummary summary,
  }) async {
    await tester.pumpWidget(wrap());
    final ctx = tester.element(find.byType(SizedBox));
    // ignore: use_build_context_synchronously
    unawaited(MemoryDetailDialog.showEventSummary(ctx, summary: summary));
    await tester.pumpAndSettle();
  }

  Future<void> showExperientialMemoryDialog(
    WidgetTester tester, {
    required ExperientialMemory memory,
  }) async {
    await tester.pumpWidget(wrap());
    final ctx = tester.element(find.byType(SizedBox));
    // ignore: use_build_context_synchronously
    unawaited(MemoryDetailDialog.showExperientialMemory(ctx, memory: memory));
    await tester.pumpAndSettle();
  }

  group('MemoryDetailDialog - EventSummary 详情', () {
    testWidgets('1. 展示 5W1E 字段 + 重要性 + 标签', (tester) async {
      const summary = EventSummary(
        importance: 4,
        tags: ['战斗', '转折'],
        turnNumber: 7,
        summary: '一句话摘要',
        when: '次日清晨',
        where: '北境长城',
        who: '守夜人',
        what: '与异鬼交战',
        significance: '首次正面胜利',
        extra: '使用了龙晶',
      );

      await showEventSummaryDialog(tester, summary: summary);

      // 标题
      expect(find.text('事件详情'), findsOneWidget);
      // 5W1E 字段（label + value）
      expect(find.text('何事'), findsOneWidget);
      expect(find.text('与异鬼交战'), findsOneWidget);
      expect(find.text('何时'), findsOneWidget);
      expect(find.text('次日清晨'), findsOneWidget);
      expect(find.text('何地'), findsOneWidget);
      expect(find.text('北境长城'), findsOneWidget);
      expect(find.text('何人'), findsOneWidget);
      expect(find.text('守夜人'), findsOneWidget);
      expect(find.text('为何重要'), findsOneWidget);
      expect(find.text('首次正面胜利'), findsOneWidget);
      expect(find.text('额外'), findsOneWidget);
      expect(find.text('使用了龙晶'), findsOneWidget);
      // 标签
      expect(find.text('战斗'), findsOneWidget);
      expect(find.text('转折'), findsOneWidget);
      // 重要性文案
      expect(find.textContaining('重要性'), findsOneWidget);
    });

    testWidgets('2. summary 与 what 相同时不重复展示原始摘要', (tester) async {
      const summary = EventSummary(
        importance: 3,
        tags: <String>[],
        turnNumber: 1,
        summary: '相同内容',
        what: '相同内容',
      );

      await showEventSummaryDialog(tester, summary: summary);

      // "原始摘要" label 不应出现（与 what 相同）
      expect(find.text('原始摘要'), findsNothing);
      // 但 "相同内容" 应通过 what 字段展示
      expect(find.text('相同内容'), findsOneWidget);
    });

    testWidgets('3. summary 与 what 不同时展示原始摘要', (tester) async {
      const summary = EventSummary(
        importance: 3,
        tags: <String>[],
        turnNumber: 1,
        summary: '简短摘要',
        what: '详细事件描述',
      );

      await showEventSummaryDialog(tester, summary: summary);

      expect(find.text('原始摘要'), findsOneWidget);
      expect(find.text('简短摘要'), findsOneWidget);
    });

    testWidgets('4. 空字段不展示', (tester) async {
      const summary = EventSummary(
        importance: 2,
        tags: <String>[],
        turnNumber: 3,
        what: '只有 what 字段',
        // when/where/who/significance/extra 均为 null
      );

      await showEventSummaryDialog(tester, summary: summary);

      // only what 字段展示
      expect(find.text('何事'), findsOneWidget);
      expect(find.text('只有 what 字段'), findsOneWidget);
      // 其他字段 label 不应出现
      expect(find.text('何时'), findsNothing);
      expect(find.text('何地'), findsNothing);
      expect(find.text('何人'), findsNothing);
      expect(find.text('为何重要'), findsNothing);
      expect(find.text('额外'), findsNothing);
      expect(find.text('原始摘要'), findsNothing);
    });

    testWidgets('5. 全部字段为空时展示空事件占位', (tester) async {
      const summary = EventSummary(
        importance: 1,
        tags: <String>[],
        turnNumber: 0,
      );

      await showEventSummaryDialog(tester, summary: summary);

      expect(find.text('（空事件）'), findsOneWidget);
      // 5W1E label 都不应出现
      expect(find.text('何事'), findsNothing);
      expect(find.text('何时'), findsNothing);
    });

    testWidgets('6. 关闭按钮可关闭小窗', (tester) async {
      const summary = EventSummary(
        importance: 3,
        tags: <String>[],
        turnNumber: 1,
        what: '某事件',
      );

      await showEventSummaryDialog(tester, summary: summary);
      expect(find.text('事件详情'), findsOneWidget);

      // 点击关闭按钮
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();

      // 小窗消失
      expect(find.text('事件详情'), findsNothing);
    });
  });

  group('MemoryDetailDialog - ExperientialMemory 详情', () {
    testWidgets('7. micro 记忆：展示 5W1E + 底栏轮次与层级', (tester) async {
      final memory = ExperientialMemory(
        memoryId: 'mem-1',
        sessionId: 'session-1',
        importance: 3,
        tags: const ['冒险'],
        turnNumber: 5,
        summary: '一句话',
        when: '黄昏',
        where: '森林',
        who: '主角',
        what: '与巨龙对话',
        significance: '获得关键信息',
        extra: '巨龙名为萨尔',
        createdAt: DateTime(2026, 7, 19, 14, 30),
      );

      await showExperientialMemoryDialog(tester, memory: memory);

      // 标题
      expect(find.text('记忆详情'), findsOneWidget);
      // 5W1E 字段
      expect(find.text('与巨龙对话'), findsOneWidget);
      expect(find.text('黄昏'), findsOneWidget);
      expect(find.text('森林'), findsOneWidget);
      expect(find.text('主角'), findsOneWidget);
      expect(find.text('获得关键信息'), findsOneWidget);
      expect(find.text('巨龙名为萨尔'), findsOneWidget);
      // 底栏包含"轮次 5"和"微观记忆"
      expect(find.textContaining('轮次 5'), findsOneWidget);
      expect(find.textContaining('微观记忆'), findsOneWidget);
      // 底栏包含生成时间
      expect(find.textContaining('生成时间'), findsOneWidget);
      expect(find.textContaining('2026-07-19 14:30'), findsOneWidget);
    });

    testWidgets('8. macro 记忆：展示聚合微摘要数 + 触发原因', (tester) async {
      final memory = ExperientialMemory(
        memoryId: 'mem-macro-1',
        sessionId: 'session-1',
        importance: 5,
        tags: const ['章节转折'],
        turnNumber: 10,
        summary: '宏摘要一句话',
        memoryLevel: MemoryLevel.macro,
        parentEventIds: const ['mem-1', 'mem-2', 'mem-3'],
        macroTriggerReason: MacroTriggerReason.eventEnd,
        createdAt: DateTime(2026, 7, 19, 16),
      );

      await showExperientialMemoryDialog(tester, memory: memory);

      // 底栏包含"宏观记忆"
      expect(find.textContaining('宏观记忆'), findsOneWidget);
      // 底栏包含"聚合 3 条微摘要"
      expect(find.textContaining('聚合 3 条微摘要'), findsOneWidget);
      // 底栏包含触发原因"事件结束触发"
      expect(find.textContaining('触发原因：事件结束触发'), findsOneWidget);
    });

    testWidgets('9. macro 记忆 roundLimit 触发原因', (tester) async {
      final memory = ExperientialMemory(
        memoryId: 'mem-macro-2',
        sessionId: 'session-1',
        importance: 4,
        tags: const <String>[],
        turnNumber: 15,
        summary: '宏摘要一句话',
        memoryLevel: MemoryLevel.macro,
        parentEventIds: const ['mem-1', 'mem-2'],
        macroTriggerReason: MacroTriggerReason.roundLimit,
        createdAt: DateTime(2026, 7, 19),
      );

      await showExperientialMemoryDialog(tester, memory: memory);

      // 底栏包含"触发原因：固定轮次兜底"
      expect(find.textContaining('触发原因：固定轮次兜底'), findsOneWidget);
    });

    testWidgets('10. 重要性星级渲染（importance=5 → 5 颗实心星）', (tester) async {
      final memory = ExperientialMemory(
        memoryId: 'mem-1',
        sessionId: 'session-1',
        importance: 5,
        tags: const <String>[],
        turnNumber: 1,
        what: '高重要性事件',
        createdAt: DateTime(2026),
      );

      await showExperientialMemoryDialog(tester, memory: memory);

      // 5 颗实心星
      expect(find.byIcon(Icons.star), findsNWidgets(5));
      expect(find.byIcon(Icons.star_border), findsNothing);
    });

    testWidgets('11. 重要性=1 → 1 颗实心星 + 4 颗空心星', (tester) async {
      final memory = ExperientialMemory(
        memoryId: 'mem-1',
        sessionId: 'session-1',
        importance: 1,
        tags: const <String>[],
        turnNumber: 1,
        what: '低重要性事件',
        createdAt: DateTime(2026),
      );

      await showExperientialMemoryDialog(tester, memory: memory);

      expect(find.byIcon(Icons.star), findsOneWidget);
      expect(find.byIcon(Icons.star_border), findsNWidgets(4));
    });

    testWidgets('12. 点击小窗外区域可关闭', (tester) async {
      final memory = ExperientialMemory(
        memoryId: 'mem-1',
        sessionId: 'session-1',
        importance: 3,
        tags: const <String>[],
        turnNumber: 1,
        what: '某事件',
        createdAt: DateTime(2026),
      );

      await showExperientialMemoryDialog(tester, memory: memory);
      expect(find.text('记忆详情'), findsOneWidget);

      // 点击屏幕左上角（小窗外的 barrier 区域）
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // 小窗消失
      expect(find.text('记忆详情'), findsNothing);
    });

    testWidgets('13. 空事件占位（ExperientialMemory 全空）', (tester) async {
      final memory = ExperientialMemory(
        memoryId: 'mem-empty',
        sessionId: 'session-1',
        importance: 1,
        tags: const <String>[],
        turnNumber: 0,
        createdAt: DateTime(2026),
      );

      await showExperientialMemoryDialog(tester, memory: memory);

      expect(find.text('（空事件）'), findsOneWidget);
      expect(find.text('何事'), findsNothing);
    });
  });
}
