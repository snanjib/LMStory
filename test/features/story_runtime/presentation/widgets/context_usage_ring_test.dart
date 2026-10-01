import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/context_usage_ring.dart';
import 'package:lmstory/i18n/strings.g.dart';

void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap(Widget child) {
    return TranslationProvider(
      child: MaterialApp(
        theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
        home: Scaffold(body: child),
      ),
    );
  }

  group('ContextUsageRing（纯视觉，S6 缩至 chip 内，EXP-11 放大到 20px）', () {
    testWidgets('有数据：渲染进度环', (tester) async {
      await tester.pumpWidget(
        wrap(
          const ContextUsageRing(numerator: 152000, denominator: 500000),
        ),
      );
      expect(find.byType(ContextUsageRing), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ContextUsageRing),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
    });

    testWidgets('无数据：渲染空轨道环', (tester) async {
      await tester.pumpWidget(
        wrap(const ContextUsageRing(numerator: null, denominator: null)),
      );
      expect(
        find.descendant(
          of: find.byType(ContextUsageRing),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
    });

    test('三态语义色：常态 muted / ≥70% warning / ≥100% error / 无数据轨道', () {
      const dark = ClassicPaletteValues.dark;
      Color colorOf(int? numerator, int? denominator) => ContextUsageRing(
            numerator: numerator,
            denominator: denominator,
          ).progressColorFor(dark);

      expect(colorOf(150000, 500000), dark.muted);
      expect(colorOf(360000, 500000), dark.warning);
      expect(colorOf(500000, 500000), dark.error);
      expect(colorOf(600000, 500000), dark.error, reason: '超刻度钳制到 1.0');
      expect(colorOf(null, 500000), dark.divider);
    });
  });

  group('ContextUsageChip（S6：工具栏 chip 外衣，交互在此）', () {
    testWidgets('点击 chip 触发 onTap，Tooltip 补充语义', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        wrap(
          ContextUsageChip(
            numerator: 152000,
            denominator: 500000,
            onTap: () => tapped = true,
          ),
        ),
      );
      expect(find.byType(ContextUsageChip), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ContextUsageChip),
          matching: find.byType(ContextUsageRing),
        ),
        findsOneWidget,
      );

      // 命中区 ≥32px（PRODUCT.md 触达标准）
      final chipBox =
          tester.renderObject<RenderBox>(find.byType(ContextUsageChip));
      expect(chipBox.size.height, greaterThanOrEqualTo(32.0));

      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, '上下文用量（点开详情）');

      await tester.tap(find.byType(ContextUsageChip));
      expect(tapped, isTrue);
    });

    testWidgets('无数据：空轨道 chip 仍可点击', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        wrap(
          ContextUsageChip(
            numerator: null,
            denominator: null,
            onTap: () => tapped = true,
          ),
        ),
      );
      await tester.tap(find.byType(ContextUsageChip));
      expect(tapped, isTrue);
    });
  });

  group('ContextUsageDetailSheet', () {
    testWidgets('完整数据：显示窗口用量/触发线/缓存/最近请求/轮数/压缩按钮', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 600,
            child: SingleChildScrollView(
              child: ContextUsageDetailSheet(
                contextWindowTokens: 1000000,
                compactionTriggerTokens: 500000,
                lastPromptTokens: 152000,
                lastCompletionTokens: 1800,
                lastCacheReadTokens: 132000,
                averageCacheHit: 0.912,
                sessionRounds: 130,
                isManualCompacting: false,
                manualCompactionDelta: '',
                manualCompactionError: null,
                isRoundActive: false,
                onManualCompact: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.text('上下文用量'), findsOneWidget);
      // 2026-09-04 重排：通用 k/M 格式 + 显式 tokens 单位（弃「万」），
      // hero 分数与占比独立渲染
      expect(find.text('152k / 1M tokens'), findsOneWidget);
      expect(find.text('15.2%'), findsOneWidget);
      // 2026-09-13 上下文配置收敛：措辞统一「上下文压缩阈值」
      expect(find.textContaining('上下文压缩阈值'), findsOneWidget);
      // 缓存命中率：标签左、数值右的键值行
      expect(find.text('最近一轮'), findsOneWidget);
      expect(find.text('86.8%'), findsOneWidget);
      expect(find.text('会话平均'), findsOneWidget);
      expect(find.text('91.2%'), findsOneWidget);
      // 最近一轮请求：三个键值行
      expect(find.text('输入'), findsOneWidget);
      expect(find.text('152k tokens'), findsOneWidget);
      expect(find.text('输出'), findsOneWidget);
      expect(find.text('1800 tokens'), findsOneWidget);
      expect(find.text('缓存读取'), findsOneWidget);
      expect(find.text('132k tokens'), findsOneWidget);
      expect(find.text('已完成轮次'), findsOneWidget);
      expect(find.text('130'), findsOneWidget);
      expect(find.text('立即压缩'), findsOneWidget);
    });

    testWidgets('S6：handle bar + 关闭按钮齐备，点关闭 pop 所在路由', (tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          body: SizedBox(
                            height: 600,
                            child: SingleChildScrollView(
                              child: ContextUsageDetailSheet(
                                contextWindowTokens: 96000,
                                compactionTriggerTokens: 48000,
                                lastPromptTokens: 40000,
                                lastCompletionTokens: 800,
                                lastCacheReadTokens: null,
                                averageCacheHit: null,
                                sessionRounds: 5,
                                isManualCompacting: false,
                                manualCompactionDelta: '',
                                manualCompactionError: null,
                                isRoundActive: false,
                                onManualCompact: () {},
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // handle bar（36×4 divider 圆角条，对齐 director_session_settings_sheet）
      final handle = find.descendant(
        of: find.byType(ContextUsageDetailSheet),
        matching: find.byType(Container),
      );
      expect(handle, findsWidgets);
      // 关闭按钮：tooltip=关闭，点击后返回上一页
      final close = find.byTooltip('关闭');
      expect(close, findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('旧数据无命中率：显示 — 且压缩按钮可用', (tester) async {
      var compacted = false;
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 600,
            child: SingleChildScrollView(
              child: ContextUsageDetailSheet(
                contextWindowTokens: 96000,
                compactionTriggerTokens: 48000,
                lastPromptTokens: null,
                lastCompletionTokens: null,
                lastCacheReadTokens: null,
                averageCacheHit: null,
                sessionRounds: 3,
                isManualCompacting: false,
                manualCompactionDelta: '',
                manualCompactionError: null,
                isRoundActive: false,
                onManualCompact: () => compacted = true,
              ),
            ),
          ),
        ),
      );

      expect(find.text('—'), findsNWidgets(6));
      await tester.tap(find.text('立即压缩'));
      expect(compacted, isTrue);
    });

    testWidgets('压缩中：按钮置灰，流式文本带「正在生成前情摘要」标注', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 600,
            child: SingleChildScrollView(
              child: ContextUsageDetailSheet(
                contextWindowTokens: 96000,
                compactionTriggerTokens: 48000,
                lastPromptTokens: 40000,
                lastCompletionTokens: 800,
                lastCacheReadTokens: null,
                averageCacheHit: null,
                sessionRounds: 5,
                isManualCompacting: true,
                manualCompactionDelta: '主角抵达北境…',
                manualCompactionError: null,
                isRoundActive: false,
                onManualCompact: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.textContaining('压缩中'), findsOneWidget);
      // 流式区必须有标题标注（用户反馈：裸流式正文像剧情生成，不明所以）
      expect(find.text('正在生成前情摘要…'), findsOneWidget);
      expect(find.text('主角抵达北境…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '压缩中…'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('DX-D2：轮进行中（isRoundActive）按钮置灰', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 600,
            child: SingleChildScrollView(
              child: ContextUsageDetailSheet(
                contextWindowTokens: 96000,
                compactionTriggerTokens: 48000,
                lastPromptTokens: 40000,
                lastCompletionTokens: 800,
                lastCacheReadTokens: null,
                averageCacheHit: null,
                sessionRounds: 5,
                isManualCompacting: false,
                manualCompactionDelta: '',
                manualCompactionError: null,
                isRoundActive: true,
                onManualCompact: () {},
              ),
            ),
          ),
        ),
      );

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '立即压缩'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('DX-D2：失败态按钮文案换「重试」且可点', (tester) async {
      var retried = false;
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 600,
            child: SingleChildScrollView(
              child: ContextUsageDetailSheet(
                contextWindowTokens: 96000,
                compactionTriggerTokens: 48000,
                lastPromptTokens: 40000,
                lastCompletionTokens: 800,
                lastCacheReadTokens: null,
                averageCacheHit: null,
                sessionRounds: 5,
                isManualCompacting: false,
                manualCompactionDelta: '',
                manualCompactionError: '压缩失败：超时',
                isRoundActive: false,
                onManualCompact: () => retried = true,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('重试'));
      expect(retried, isTrue);
    });

    testWidgets('流式 delta 超长时限高内滚动，不溢出', (tester) async {
      // 模拟 bottom sheet 的高度上限：放大测试视口后给 sheet 一个有界
      // 高度，且不加外层 ScrollView——delta 无限增长时面板必须自行兜底，
      // 否则 RenderFlex 溢出。
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final longDelta = List.filled(600, '主角在北境的暴风雪中前行。').join();
      await tester.pumpWidget(
        wrap(
          SizedBox(
            height: 1200,
            child: ContextUsageDetailSheet(
              contextWindowTokens: 96000,
              compactionTriggerTokens: 48000,
              lastPromptTokens: 40000,
              lastCompletionTokens: 800,
              lastCacheReadTokens: null,
              averageCacheHit: null,
              sessionRounds: 5,
              isManualCompacting: true,
              manualCompactionDelta: longDelta,
              manualCompactionError: null,
              isRoundActive: false,
              onManualCompact: () {},
            ),
          ),
        ),
      );

      expect(
        tester.takeException(),
        isNull,
        reason: '手动压缩流式 delta 无限增长时详情面板不得 RenderFlex 溢出',
      );
      // 2026-09-04 重排后双层兜底：整面滚动（0.9 屏高上限）+ 流式区固定
      // 高滚动（内层），按钮位置不随流式追加跳动。
      expect(
        find.descendant(
          of: find.byType(ContextUsageDetailSheet),
          matching: find.byType(SingleChildScrollView),
        ),
        findsNWidgets(2),
        reason: '整面与流式 delta 区都必须有滚动兜底',
      );
    });
  });

  group('ContextUsageDetailSheet 上下文构成区（G-25R）', () {
    testWidgets('传入 composition 渲染堆叠条+分段行+估算注；null 不渲染', (
      tester,
    ) async {
      Widget build({List<ContextCompositionSegment>? composition}) {
        return wrap(
          SizedBox(
            height: 800,
            child: SingleChildScrollView(
              child: ContextUsageDetailSheet(
                contextWindowTokens: 100000,
                compactionTriggerTokens: 50000,
                lastPromptTokens: 10000,
                lastCompletionTokens: 800,
                lastCacheReadTokens: 5000,
                averageCacheHit: 0.5,
                sessionRounds: 3,
                isManualCompacting: false,
                manualCompactionDelta: '',
                manualCompactionError: null,
                isRoundActive: false,
                onManualCompact: () {},
                composition: composition,
                compositionNote: '估算口径说明',
              ),
            ),
          ),
        );
      }

      const segments = [
        ContextCompositionSegment(
          label: '系统提示词（含项目规则）',
          fraction: 0.25,
          tokens: 2500,
        ),
        ContextCompositionSegment(
          label: '场记板（世界状态）',
          fraction: 0.25,
          tokens: 2500,
        ),
        ContextCompositionSegment(label: '历史对话', fraction: 0.4, tokens: 4000),
        ContextCompositionSegment(label: '本轮指令', fraction: 0.1, tokens: 1000),
      ];
      await tester.pumpWidget(build(composition: segments));
      expect(find.text('上下文构成'), findsOneWidget);
      expect(find.text('系统提示词（含项目规则）（25%）'), findsOneWidget);
      expect(find.text('历史对话（40%）'), findsOneWidget);
      expect(find.text('2500 tokens'), findsNWidgets(2));
      expect(find.text('4000 tokens'), findsOneWidget);
      expect(find.text('估算口径说明'), findsOneWidget);

      await tester.pumpWidget(build());
      expect(find.text('上下文构成'), findsNothing);
    });
  });

  group('ContextUsageDetailSheet.formatTokenCount（通用 k/M 格式，弃「万」）', () {
    test('分段边界：<1 万原样 / ≥1 万 k / ≥100 万 M', () {
      expect(ContextUsageDetailSheet.formatTokenCount(0), '0');
      expect(ContextUsageDetailSheet.formatTokenCount(800), '800');
      expect(ContextUsageDetailSheet.formatTokenCount(1383), '1383');
      expect(ContextUsageDetailSheet.formatTokenCount(9999), '9999');
      expect(ContextUsageDetailSheet.formatTokenCount(10000), '10k');
      expect(ContextUsageDetailSheet.formatTokenCount(108000), '108k');
      expect(ContextUsageDetailSheet.formatTokenCount(999999), '1000k');
      expect(ContextUsageDetailSheet.formatTokenCount(1000000), '1M');
      expect(ContextUsageDetailSheet.formatTokenCount(1500000), '1.5M');
      expect(ContextUsageDetailSheet.formatTokenCount(15000000), '15M');
    });
  });
}

///  回归：轮进行中按钮置灰 + 失败态按钮文案换「重试」
