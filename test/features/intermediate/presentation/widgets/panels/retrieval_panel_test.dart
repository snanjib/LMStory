import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/panels/retrieval_panel.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// RetrievalPanel 自动折叠时序 + stagger 淡入测试
///
/// 验证：
/// 1. retrieving 阶段：显示"正在检索记忆..."
/// 2. retrieving → 完成态：先展开展示命中结果列表
/// 3. 延时后自动折叠为单行摘要
/// 4. 用户点击展开/折叠：取消自动折叠定时器
/// 5. foldDelayMs=0：立即折叠
/// 6. 失败态：渲染错误图标 + 重试按钮
void main() {
  Widget wrap(Widget child) {
    return TranslationProvider(
      child: MaterialApp(
        theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
        home: Scaffold(body: child),
      ),
    );
  }

  List<ExperientialMemory> memories(int count) {
    return List.generate(count, (i) {
      return ExperientialMemory(
        memoryId: 'mem-$i',
        sessionId: 'session-1',
        summary: '经历摘要 $i',
        importance: i >= 4 ? 4 : 2,
        tags: const ['tag'],
        turnNumber: i,
        createdAt: DateTime(2026),
      );
    });
  }

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.enUs);
    LocaleSettings.setLocaleSync(AppLocale.zhCn);
  });

  testWidgets('fact summary and details follow the current locale',
      (tester) async {
    LocaleSettings.setLocaleSync(AppLocale.enUs);
    addTearDown(() => LocaleSettings.setLocaleSync(AppLocale.zhCn));
    final now = DateTime(2026);
    final facts = [
      RetrievedFact(
        entity: FactualEntity(
          entityId: 'character',
          sessionId: 'story',
          type: FactualEntityType.character,
          primaryName: '林晚',
          aliases: const ['守碑人', 'Lin'],
          importance: 4,
          createdTurn: 1,
          createdAt: now,
        ),
        attributes: [
          FactualAttribute(
            attributeId: 'detail',
            entityId: 'character',
            sessionId: 'story',
            attrKey: '随身物件',
            value: '银钥匙',
            importance: 3,
            createdAt: now,
          ),
        ],
        isKeyEntity: true,
        isKeywordMatched: true,
      ),
      RetrievedFact(
        entity: FactualEntity(
          entityId: 'location',
          sessionId: 'story',
          type: FactualEntityType.location,
          primaryName: '旧码头',
          aliases: const [],
          importance: 3,
          createdTurn: 1,
          createdAt: now,
        ),
        attributes: const [],
        isKeyEntity: false,
        isKeywordMatched: true,
      ),
    ];
    Widget panel(IntermediatePhase phase) => wrap(
          RetrievalPanel(
            phase: phase,
            retrievedMemories:
                phase == IntermediatePhase.retrieving ? null : memories(1),
            retrievedFacts: facts,
            failureContext: null,
            onRetry: () {},
          ),
        );
    await tester.pumpWidget(panel(IntermediatePhase.retrieving));
    await tester.pumpWidget(panel(IntermediatePhase.reviewing));
    await tester.pumpAndSettle();

    final enName = find.text('Character "林晚" (Aliases: 守碑人, Lin)');
    expect(enName, findsOneWidget);
    expect(find.text('Location "旧码头"'), findsOneWidget);
    expect(find.textContaining('经历摘要 0'), findsOneWidget);
    await tester.tap(enName);
    await tester.pumpAndSettle();
    expect(find.text('林晚'), findsOneWidget);
    expect(find.text('Type：Character'), findsOneWidget);
    expect(find.text('随身物件'), findsOneWidget);
    expect(find.text('银钥匙'), findsOneWidget);
    Navigator.of(tester.element(find.text('林晚'))).pop();
    await tester.pumpAndSettle();

    LocaleSettings.setLocaleSync(AppLocale.zhCn);
    await tester.pumpAndSettle();
    expect(enName, findsNothing);
    expect(find.text('角色"林晚"（别名：守碑人, Lin）'), findsOneWidget);
    final zhLocation = find.text('地点"旧码头"');
    expect(zhLocation, findsOneWidget);
    await tester.tap(zhLocation);
    await tester.pumpAndSettle();
    expect(find.text('旧码头'), findsOneWidget);
  });

  group('RetrievalPanel 自动折叠时序', () {
    testWidgets('1. retrieving 阶段：显示检索中提示', (tester) async {
      await tester.pumpWidget(
        wrap(
          RetrievalPanel(
            phase: IntermediatePhase.retrieving,
            retrievedMemories: null,
            failureContext: null,
            onRetry: () {},
          ),
        ),
      );

      // 用户可见文案采用故事语境中的“回忆”。
      expect(find.textContaining('正在回忆'), findsOneWidget);
    });

    testWidgets('2. retrieving → 完成态：展开展示命中结果', (tester) async {
      await tester.pumpWidget(
        wrap(
          RetrievalPanel(
            phase: IntermediatePhase.retrieving,
            retrievedMemories: null,
            failureContext: null,
            onRetry: () {},
          ),
        ),
      );

      // 切换到完成态
      await tester.pumpWidget(
        wrap(
          RetrievalPanel(
            phase: IntermediatePhase.idle,
            retrievedMemories: memories(3),
            failureContext: null,
            onRetry: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 展开状态：命中摘要可见
      expect(find.text('经历摘要 0'), findsOneWidget);
      expect(find.text('经历摘要 1'), findsOneWidget);
      expect(find.text('经历摘要 2'), findsOneWidget);
    });

    testWidgets('3. 延时后自动折叠为单行摘要', (tester) async {
      await tester.pumpWidget(
        wrap(
          RetrievalPanel(
            phase: IntermediatePhase.retrieving,
            retrievedMemories: null,
            failureContext: null,
            onRetry: () {},
          ),
        ),
      );

      await tester.pumpWidget(
        wrap(
          RetrievalPanel(
            phase: IntermediatePhase.idle,
            retrievedMemories: memories(2),
            failureContext: null,
            onRetry: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 展开状态：摘要可见
      expect(find.text('经历摘要 0'), findsOneWidget);

      // 2026-07-16 修复问题3：面板可见时延迟折叠（最多延迟2次）。
      // foldDelayMs=1000，最多延迟2次 → 需推进 1000×3=3000ms 才折叠。
      // Timer retries are scheduled from each callback, so advance each
      // interval separately and cross (rather than land exactly on) each
      // deadline.
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 1001));
      }
      await tester.pumpAndSettle();

      // 折叠后：摘要列表不再可见
      expect(find.text('经历摘要 0'), findsNothing);
      // 但"找到 N 条相关经历"摘要可见
      expect(find.textContaining('找到'), findsOneWidget);
    });

    testWidgets('4. 用户点击展开后取消自动折叠定时器', (tester) async {
      await tester.pumpWidget(
        wrap(
          RetrievalPanel(
            phase: IntermediatePhase.retrieving,
            retrievedMemories: null,
            failureContext: null,
            onRetry: () {},
          ),
        ),
      );

      await tester.pumpWidget(
        wrap(
          RetrievalPanel(
            phase: IntermediatePhase.reviewing,
            retrievedMemories: memories(2),
            failureContext: null,
            onRetry: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 展开状态：点击折叠行摘要文案（外层 InkWell 区域，非内层记忆条目）
      // 5W1E 详情查看功能新增了内层 InkWell 包裹每条记忆，
      // 因此不能用 find.byType(InkWell) 直接 tap（会命中多个）。
      await tester.tap(find.textContaining('找到'));
      await tester.pumpAndSettle();
      expect(find.text('经历摘要 0'), findsNothing);

      // 推进 1.5 秒后，应保持折叠（用户已交互，定时器被取消）
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(find.text('经历摘要 0'), findsNothing);

      // 再次点击展开
      await tester.tap(find.textContaining('找到'));
      await tester.pumpAndSettle();
      expect(find.text('经历摘要 0'), findsOneWidget);

      // 推进 3 秒后，应保持展开
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('经历摘要 0'), findsOneWidget);
    });

    testWidgets('5. foldDelayMs=0：立即折叠', (tester) async {
      await tester.pumpWidget(
        wrap(
          RetrievalPanel(
            phase: IntermediatePhase.retrieving,
            retrievedMemories: null,
            failureContext: null,
            onRetry: () {},
            foldDelayMs: 0,
          ),
        ),
      );

      await tester.pumpWidget(
        wrap(
          RetrievalPanel(
            phase: IntermediatePhase.reviewing,
            retrievedMemories: memories(2),
            failureContext: null,
            onRetry: () {},
            foldDelayMs: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // foldDelayMs=0：立即折叠，摘要列表不应可见
      expect(find.text('经历摘要 0'), findsNothing);
      expect(find.textContaining('找到'), findsOneWidget);
    });

    testWidgets('6. 失败态：渲染错误图标 + 重试按钮', (tester) async {
      await tester.pumpWidget(
        wrap(
          RetrievalPanel(
            phase: IntermediatePhase.failed,
            retrievedMemories: null,
            failureContext: const FailureContext(
              errorCode: 'E012',
              failedPhase: IntermediatePhase.retrieving,
              errorMessage: '检索失败',
              retryable: false,
            ),
            onRetry: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 错误图标可见
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      // 重试按钮可见
      expect(find.text('重试'), findsOneWidget);
    });
  });

  group('D3：语义模式 0 命中阈值口径说明', () {
    testWidgets('0 命中 + 语义模式：显示阈值口径说明行', (tester) async {
      await tester.pumpWidget(
        wrap(
          RetrievalPanel(
            phase: IntermediatePhase.idle,
            retrievedMemories: const [],
            retrievedFacts: const [],
            failureContext: null,
            onRetry: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('未找到相关经历'), findsOneWidget);
      expect(
        find.textContaining('相似度阈值'),
        findsOneWidget,
        reason: '语义模式 0 命中时应解释阈值口径，避免「徽标绿但 0 命中」误读',
      );
    });

    testWidgets('0 命中 + 关键词模式：不显示语义阈值说明', (tester) async {
      await tester.pumpWidget(
        wrap(
          RetrievalPanel(
            phase: IntermediatePhase.idle,
            retrievedMemories: const [],
            retrievedFacts: const [],
            failureContext: null,
            onRetry: () {},
            embeddingConfigured: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('未找到相关经历'), findsOneWidget);
      expect(
        find.textContaining('相似度阈值'),
        findsNothing,
        reason: '关键词模式无相似度阈值语义，不显示口径说明',
      );
    });

    testWidgets('有命中时不显示阈值说明', (tester) async {
      await tester.pumpWidget(
        wrap(
          RetrievalPanel(
            phase: IntermediatePhase.idle,
            retrievedMemories: memories(1),
            failureContext: null,
            onRetry: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('找到'), findsOneWidget);
      expect(find.textContaining('相似度阈值'), findsNothing);
    });
  });
}
