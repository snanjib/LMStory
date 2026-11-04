import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_compaction_summary_card.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_markdown_body.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_message_actions.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_message_bubble.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_message_navigation.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/core/utils/smooth_follow_scroller.dart'
    show streamingFollowCushionPx;
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/presentation/pages/director_chat_body.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_thinking_block.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_work_group.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/story_runtime/domain/entities/message_variant_record.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// DirectorChatBody 组件测试（2026-08-23 直播分块 + 2026-08-28 对话流重构）
///
/// 验证：
/// - 直播：装配器现算交错时间线进单一折叠组；升格正文的末个非空文本段
///   流式进稿件卡（组外）
/// - live 思考默认展开、正文流式接管焦点后自动收起为字数标签
/// - 首增量前呼吸标签；有步骤时由折叠组标题报告
/// - 历史轮（新数据 agentTimeline）：折叠组 + 稿件卡，消息行思考不重复
/// - 历史轮（旧数据仅 agentSteps）：回退 DirectorProcessRow + 思考折叠
ChatSession _testSession() => ChatSession(
      sessionId: 'dir-1',
      title: '测试导演',
      mode: 'advanced',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );

ChatMessage _message(String role, String content) => ChatMessage(
      messageId: 'm-${content.hashCode}',
      sessionId: 'dir-1',
      role: role,
      content: content,
      createdAt: DateTime(2026),
    );

void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap(
    AdvancedChatState state, {
    String? initialFocusMessageId,
    bool pureReading = false,
    double fontScale = 1.0,
  }) {
    return TranslationProvider(
      child: MaterialApp(
        theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
        home: Scaffold(
          body: DirectorChatBody(
            state: state,
            pureReading: pureReading,
            onCopy: (_) {},
            onRegenerate: (_) {},
            onEdit: (_) {},
            onDeleteRound: (_) {},
            initialFocusMessageId: initialFocusMessageId,
            fontScale: fontScale,
          ),
        ),
      ),
    );
  }

  testWidgets('长中间发言从首个增量开始留在幕后，不占正文位置', (tester) async {
    final narration = '我先核对前情，再查看人物关系。' * 20;
    await tester.pumpWidget(
      wrap(
        AdvancedChatState(
          phase: IntermediatePhase.reviewing,
          messages: const [],
          retryCounts: const {},
          session: _testSession(),
          liveBlocks: [
            AgentLiveBlock(
              kind: AgentLiveBlockKind.text,
              stepIndex: 0,
              text: narration,
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(DirectorWorkGroup),
        matching: find.text(narration),
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
    expect(
      find.descendant(
        of: find.byType(DirectorWorkGroup),
        matching: find.text(narration),
      ),
      findsOneWidget,
    );
  });

  group('直播分块时间线', () {
    testWidgets('1. 分块交错渲染：末个非空文本段进稿件卡，其余为话术块', (tester) async {
      const blocks = [
        AgentLiveBlock(
          kind: AgentLiveBlockKind.thinking,
          stepIndex: 0,
          text: '第一段思考',
        ),
        AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 0,
          text: '让我先查查设定',
        ),
        AgentLiveBlock(
          kind: AgentLiveBlockKind.thinking,
          stepIndex: 1,
          text: '核对完毕',
        ),
        AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 2,
          source: AgentTextSource.finishRoundProse,
          text: '第一章正文全文',
        ),
      ];
      await tester.pumpWidget(
        wrap(
          AdvancedChatState(
            phase: IntermediatePhase.reviewing,
            messages: const [],
            retryCounts: const {},
            session: _testSession(),
            liveBlocks: blocks,
          ),
        ),
      );
      await tester.pump();

      // 播报与稿件正文都可见（播报在折叠组内，正文在组外稿件卡）
      expect(find.text('让我先查查设定'), findsOneWidget);
      expect(find.text('第一章正文全文'), findsOneWidget);
      // 收起的思考块显示字数标签（非 live：均折叠）
      expect(find.text('思考 · 5 字'), findsOneWidget);
      expect(find.text('思考 · 4 字'), findsOneWidget);
      // 有增量后首增量前占位不再以呼吸标签形态叠加；纯思考直播的组
      // 标题回退「导演正在构思…」（标题行报告状态，非占位骨架）
      expect(find.text('等待模型响应…'), findsOneWidget);
    });

    testWidgets('活跃思考显示尾部预览，正文到达后思考完全收起', (tester) async {
      final thinkingOnly = AdvancedChatState(
        phase: IntermediatePhase.reviewing,
        agentActivity: AgentActivity.thinking,
        messages: const [],
        retryCounts: const {},
        session: _testSession(),
        liveBlocks: const [
          AgentLiveBlock(
            kind: AgentLiveBlockKind.thinking,
            stepIndex: 0,
            text: '想着',
          ),
        ],
      );
      await tester.pumpWidget(wrap(thinkingOnly));
      await tester.pump();
      // live 末块思考展开可见
      expect(find.byType(ThinkingTailPreview), findsOneWidget);

      // 追加正文块：思考自动收起（内容隐藏，出现字数标签），稿件卡出现
      final withText = AdvancedChatState(
        phase: IntermediatePhase.reviewing,
        agentActivity: AgentActivity.generating,
        messages: const [],
        retryCounts: const {},
        session: _testSession(),
        liveBlocks: const [
          AgentLiveBlock(
            kind: AgentLiveBlockKind.thinking,
            stepIndex: 0,
            text: '想着',
          ),
          AgentLiveBlock(
            kind: AgentLiveBlockKind.text,
            stepIndex: 0,
            source: AgentTextSource.finishRoundProse,
            text: '正文来了',
          ),
        ],
      );
      await tester.pumpWidget(wrap(withText));
      await tester.pump();

      expect(find.byType(ThinkingTailPreview), findsNothing);
      expect(find.text('思考 · 2 字'), findsOneWidget);
      expect(find.text('正文来了'), findsOneWidget);
    });

    testWidgets('3. 首增量前：无步骤显示呼吸标签；有步骤时不再追加', (tester) async {
      // 真实时序：发送瞬间即有 pending 用户气泡，正文增量未到
      final pending = AdvancedChatState(
        phase: IntermediatePhase.reviewing,
        messages: const [],
        retryCounts: const {},
        session: _testSession(),
        pendingUserMessage: _message('user', '推进剧情'),
      );
      await tester.pumpWidget(wrap(pending));
      await tester.pump();
      expect(find.text('等待模型响应…'), findsOneWidget);

      // 已有工具步骤时，过程行报告动作，占位标签不再叠加
      final withSteps = pending.copyWith(
        agentActivity: AgentActivity.tool,
        agentSteps: const [
          AgentWorkStep(
            callId: 'c1',
            toolName: 'search_story',
            status: AgentStepStatus.running,
          ),
        ],
      );
      await tester.pumpWidget(wrap(withSteps));
      await tester.pump();
      expect(find.text('导演正在构思…'), findsNothing);
    });

    testWidgets('4. 历史轮：思考折叠字数标签可展开，稿件卡显示定稿正文', (tester) async {
      final assistant = ChatMessage(
        messageId: 'm-a',
        sessionId: 'dir-1',
        role: 'assistant',
        content: '定稿正文',
        thinkingContent: '历史思考过程',
        createdAt: DateTime(2026),
      );
      await tester.pumpWidget(
        wrap(
          AdvancedChatState(
            phase: IntermediatePhase.idle,
            messages: [_message('user', '推进剧情'), assistant],
            retryCounts: const {},
            session: _testSession(),
          ),
        ),
      );
      await tester.pump();

      // 用户气泡 + 收起的思考 + 稿件正文
      expect(find.text('推进剧情'), findsOneWidget);
      expect(find.text('思考 · 6 字'), findsOneWidget);
      expect(find.text('历史思考过程'), findsNothing);
      expect(find.text('定稿正文'), findsOneWidget);

      // 展开思考可见原文
      await tester.tap(find.text('思考 · 6 字'));
      await tester.pump();
      expect(find.text('历史思考过程'), findsOneWidget);
    });
  });

  group('历史轮装配（对话流 T6）', () {
    ChatMessage assistant0() => ChatMessage(
          messageId: 'm-a',
          sessionId: 'dir-1',
          role: 'assistant',
          content: '定稿正文',
          // 新数据路径下消息行思考合并串仍在，但由折叠组承载、不重复渲染
          thinkingContent: '合并思考串',
          createdAt: DateTime(2026),
        );

    testWidgets('已完成历史轮的异常卡可折叠，不受当前轮失败状态影响', (tester) async {
      for (final phase in [IntermediatePhase.idle, IntermediatePhase.failed]) {
        await tester.pumpWidget(
          wrap(
            AdvancedChatState(
              phase: phase,
              messages: [_message('user', '继续'), assistant0()],
              retryCounts: const {},
              session: _testSession(),
              artifactsByTurnNumber: {
                1: StoryRoundArtifacts(
                  sessionId: 'dir-1',
                  turnNumber: 1,
                  createdAt: DateTime(2026),
                  agentTimeline: const [
                    AgentTimelineBlock(
                      kind: AgentTimelineKind.action,
                      stepIndex: 0,
                      action: AgentWorkStep(
                        toolName: 'search_story',
                        title: '检索未命中',
                        status: AgentStepStatus.warning,
                      ),
                    ),
                  ],
                ),
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('检索未命中'), findsNothing);
        expect(find.text('定稿正文'), findsOneWidget);
      }
    });

    testWidgets('只有工具的旧时间线仍可展开消息中的思考', (tester) async {
      await tester.pumpWidget(
        wrap(
          AdvancedChatState(
            phase: IntermediatePhase.idle,
            messages: [_message('user', '继续'), assistant0()],
            retryCounts: const {},
            session: _testSession(),
            artifactsByTurnNumber: {
              1: StoryRoundArtifacts(
                sessionId: 'dir-1',
                turnNumber: 1,
                createdAt: DateTime(2026),
                agentTimeline: const [
                  AgentTimelineBlock(
                    kind: AgentTimelineKind.action,
                    stepIndex: 0,
                    action: AgentWorkStep(toolName: 'search_story'),
                  ),
                ],
              ),
            },
          ),
        ),
      );
      await tester.pump();
      expect(find.text('思考 · 5 字'), findsOneWidget);
      await tester.tap(find.text('思考 · 5 字'));
      await tester.pump();
      expect(find.text('合并思考串'), findsOneWidget);
    });

    testWidgets('5. 新数据（agentTimeline）：折叠组 + 稿件卡，消息行思考不重复', (tester) async {
      await tester.pumpWidget(
        wrap(
          AdvancedChatState(
            phase: IntermediatePhase.idle,
            messages: [_message('user', '推进剧情'), assistant0()],
            retryCounts: const {},
            session: _testSession(),
            artifactsByTurnNumber: {
              1: StoryRoundArtifacts(
                sessionId: 'dir-1',
                turnNumber: 1,
                createdAt: DateTime(2026),
                agentTimeline: const [
                  AgentTimelineBlock(
                    kind: AgentTimelineKind.thinking,
                    stepIndex: 0,
                    text: '先查前情。',
                  ),
                  AgentTimelineBlock(
                    kind: AgentTimelineKind.action,
                    stepIndex: 0,
                    action: AgentWorkStep(toolName: 'search_story'),
                  ),
                  AgentTimelineBlock(
                    kind: AgentTimelineKind.narration,
                    stepIndex: 0,
                    text: '这轮让她自己出场。',
                  ),
                  AgentTimelineBlock(
                    kind: AgentTimelineKind.action,
                    stepIndex: 1,
                    action: AgentWorkStep(toolName: 'finish_round'),
                  ),
                ],
                agentWorkSummary: const AgentWorkSummary(
                  steps: 2,
                  totalTokens: 1000,
                  durationMs: 12000,
                ),
              ),
            },
          ),
        ),
      );
      await tester.pump();

      // 收工默认折叠：标题行由元数据算出
      expect(find.text('幕后 2 步 · 思考 1 段 · 12s'), findsOneWidget);
      // 稿件卡在组外常显
      expect(find.text('定稿正文'), findsOneWidget);
      // 消息行思考合并串不重复渲染（思考已进组）
      expect(find.text('思考 · 5 字'), findsNothing);

      // 展开组：思考/播报/动作交错可见（重进会话时间线重建）
      await tester.tap(find.byIcon(Icons.tungsten_outlined));
      await tester.pumpAndSettle();
      expect(find.text('思考 · 5 字'), findsOneWidget);
      expect(find.text('这轮让她自己出场。'), findsOneWidget);
      // 动作卡（翻阅前情）在思考与播报之间交错
      expect(find.text('翻阅前情'), findsOneWidget);
    });

    testWidgets('6. 旧数据（仅 agentSteps）：回退 DirectorProcessRow + 思考折叠',
        (tester) async {
      await tester.pumpWidget(
        wrap(
          AdvancedChatState(
            phase: IntermediatePhase.idle,
            messages: [_message('user', '推进剧情'), assistant0()],
            retryCounts: const {},
            session: _testSession(),
            artifactsByTurnNumber: {
              1: StoryRoundArtifacts(
                sessionId: 'dir-1',
                turnNumber: 1,
                createdAt: DateTime(2026),
                agentSteps: const [AgentWorkStep(toolName: 'search_story')],
              ),
            },
          ),
        ),
      );
      await tester.pump();

      // 旧路径：动词串标题（非新口径）+ 消息行思考折叠（兜底保留）
      expect(find.text('幕后 1 步 · 翻阅前情'), findsOneWidget);
      expect(find.text('幕后 2 步 · 思考 1 段 · 12s'), findsNothing);
      expect(find.text('思考 · 5 字'), findsOneWidget);
      expect(find.text('定稿正文'), findsOneWidget);
    });
  });

  group('滚动跟随与导航（2026-08-31 阅读体验修复）', () {
    /// 多轮历史（长稿件保证列表可滚）+ 可选直播稿件文本。
    AdvancedChatState stateFor({
      required IntermediatePhase phase,
      String? liveText,
      ChatMessage? pending,
    }) {
      String filler(int n) => '历史正文。' * n;
      final messages = <ChatMessage>[];
      for (var i = 1; i <= 6; i++) {
        messages
          ..add(
            ChatMessage(
              messageId: 'm-u$i',
              sessionId: 'dir-1',
              role: 'user',
              content: '推进剧情 $i',
              createdAt: DateTime(2026),
            ),
          )
          ..add(
            ChatMessage(
              messageId: 'm-a$i',
              sessionId: 'dir-1',
              role: 'assistant',
              content: filler(120),
              createdAt: DateTime(2026),
            ),
          );
      }
      return AdvancedChatState(
        phase: phase,
        messages: messages,
        retryCounts: const {},
        session: _testSession(),
        liveBlocks: liveText == null
            ? const []
            : [
                AgentLiveBlock(
                  kind: AgentLiveBlockKind.text,
                  stepIndex: 0,
                  source: AgentTextSource.finishRoundProse,
                  text: liveText,
                ),
              ],
        pendingUserMessage: pending,
      );
    }

    ScrollController controllerOf(WidgetTester tester) =>
        tester.widget<ListView>(find.byType(ListView)).controller!;

    /// 上拖并等惯性停止（reviewing 态的流式光标永动，不能 pumpAndSettle）。
    Future<void> dragUp(WidgetTester tester) async {
      await tester.drag(find.byType(ListView), const Offset(0, 400));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    /// 首帧对齐后等懒加载收敛贴底（普通方向列表不再天然贴底）。
    Future<void> pumpAligned(WidgetTester tester) async {
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
    }

    testWidgets('1. 初始停在最新；贴底时小步直播增长保持跟随', (tester) async {
      await tester.pumpWidget(
        wrap(
          stateFor(phase: IntermediatePhase.reviewing, liveText: 'a' * 100),
        ),
      );
      await pumpAligned(tester);
      final controller = controllerOf(tester);
      expect(
        controller.offset,
        closeTo(controller.position.maxScrollExtent, 1),
      );

      // 小步流式增长（一步过长会超出贴底容差、被当作阅读态不跟随）
      await tester.pumpWidget(
        wrap(
          stateFor(phase: IntermediatePhase.reviewing, liveText: 'a' * 180),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      // 惰性跟随：静止位允许 ≤ 缓冲的落后（缓冲内不推动视口），
      // 但最新一行必须留在视口内。
      expect(
        controller.position.maxScrollExtent - controller.offset,
        lessThanOrEqualTo(streamingFollowCushionPx + 1),
      );
    });

    testWidgets('2. 慢速上划首帧即冻结：直播增长不移动正在阅读的内容', (tester) async {
      final fillerText = '历史正文。' * 120;
      await tester.pumpWidget(
        wrap(
          stateFor(phase: IntermediatePhase.reviewing, liveText: 'a' * 100),
        ),
      );
      await pumpAligned(tester);
      final controller = controllerOf(tester);

      // 模拟慢速上划：3×20px 小步（累计约 60px，留在旧实现的 80px 底部
      // 容差带内——旧语义不冻结仍会拉回，新语义首帧即冻结）。builder
      // 列表上滚会实体化更早 item 使 maxScrollExtent 收敛，断言留余量。
      final bottomBefore = controller.position.maxScrollExtent;
      for (var i = 0; i < 3; i++) {
        controller.position.jumpTo(
          (controller.position.pixels - 20)
              .clamp(0, controller.position.maxScrollExtent),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        controller.offset,
        lessThan(bottomBefore - 10),
        reason: '前置：已慢速上划约 60px（阅读位）',
      );

      // 视口内最接近直播的一轮稿件作为阅读位置标记
      final marker = find.text(fillerText).last;
      final dyBefore = tester.getTopLeft(marker).dy;
      final pixelsBefore = controller.offset;
      final maxBefore = controller.position.maxScrollExtent;

      // 直播稿件增长：尾部增长发生在视口之外，首帧即冻结 → 阅读位置不动
      await tester.pumpWidget(
        wrap(stateFor(phase: IntermediatePhase.reviewing, liveText: 'a' * 600)),
      );
      await tester.pump();

      expect(controller.position.maxScrollExtent, greaterThan(maxBefore));
      expect(
        controller.offset,
        closeTo(pixelsBefore, 1.0),
        reason: '慢速上划首帧即冻结（不需脱离 80px 容差带）：直播增长不得拉回',
      );
      expect(tester.getTopLeft(marker).dy, closeTo(dyBefore, 2.0));
    });

    testWidgets('2b. 带内上划后连续小步增长保持冻结（帧末对账不得用 80px 容差带恢复跟随）', (tester) async {
      // 回归护栏：旧对账判据是 80px 容差带——带内
      // 上划（4-80px）被冻结后，下一个 delta 的帧末对账 forceFollowing、
      // 再下一个 delta 就把阅读位滑行拉回。原测试 2 只喂一次增长
      // （对账恢复后无后续 followGrowth 可驱动拉回），恰好绕开冲突窗口；
      // 本例喂连续两次增长，复现真实直播的小增量序列。
      await tester.pumpWidget(
        wrap(
          stateFor(phase: IntermediatePhase.reviewing, liveText: 'a' * 100),
        ),
      );
      await pumpAligned(tester);
      final controller = controllerOf(tester);

      // 带内慢速上划约 60px（超出 48px 恢复带、< 80px 旧容差带）
      for (var i = 0; i < 3; i++) {
        controller.position.jumpTo(
          (controller.position.pixels - 20)
              .clamp(0, controller.position.maxScrollExtent),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      final pixelsBefore = controller.offset;
      expect(
        controller.position.maxScrollExtent - pixelsBefore,
        allOf(greaterThan(4), lessThan(80)),
        reason: '前置：带内上划（48px 恢复带外、80px 旧容差带内）',
      );

      // 连续两次小步增长（真实直播节奏）：每次增长后帧末对账都运行
      for (var step = 0; step < 2; step++) {
        await tester.pumpWidget(
          wrap(
            stateFor(
              phase: IntermediatePhase.reviewing,
              liveText: 'a' * (160 + step * 60),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          controller.offset,
          lessThan(pixelsBefore + 4),
          reason: '第 ${step + 1} 次增长后阅读位不得被拉回（对账判据必须是状态机贴底线而非 80px 容差带）',
        );
      }
    });

    testWidgets('3. 阅读态发送新消息：强制回底并恢复跟随', (tester) async {
      await tester.pumpWidget(
        wrap(
          stateFor(phase: IntermediatePhase.reviewing, liveText: 'a' * 100),
        ),
      );
      await pumpAligned(tester);
      final controller = controllerOf(tester);
      await dragUp(tester);
      expect(
        controller.offset,
        lessThan(controller.position.maxScrollExtent - 80),
      );

      await tester.pumpWidget(
        wrap(
          stateFor(
            phase: IntermediatePhase.reviewing,
            liveText: 'a' * 100,
          ).copyWith(pendingUserMessage: _message('user', '继续')),
        ),
      );
      // 流式光标为永动动画，不用 pumpAndSettle；回底动画 250ms + 收敛校准
      await tester.pump(const Duration(milliseconds: 300));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        controller.offset,
        closeTo(controller.position.maxScrollExtent, 1),
      );
    });

    testWidgets('4. 浮层互斥：生成中脱离底部显胶囊；收工显导航条；贴底都无', (tester) async {
      // 生成中 + 脱离底部 → 胶囊
      await tester.pumpWidget(
        wrap(
          stateFor(phase: IntermediatePhase.reviewing, liveText: 'a' * 100),
        ),
      );
      await pumpAligned(tester);
      await dragUp(tester);
      expect(find.text('回到最新'), findsOneWidget);
      expect(find.byType(IntermediateMessageNavigation), findsNothing);

      // 收工 + 脱离底部 → 四键导航条
      await tester.pumpWidget(wrap(stateFor(phase: IntermediatePhase.idle)));
      await tester.pump();
      expect(find.text('回到最新'), findsNothing);
      expect(find.byType(IntermediateMessageNavigation), findsOneWidget);

      // 贴底 → 都不显示
      await tester.tap(find.byIcon(Icons.keyboard_double_arrow_down));
      await tester.pumpAndSettle();
      expect(
        controllerOf(tester).offset,
        closeTo(controllerOf(tester).position.maxScrollExtent, 1),
      );
      expect(find.byType(IntermediateMessageNavigation), findsNothing);
    });

    testWidgets('5. 脱离底部跳顶后点「回到底部」恢复贴底', (tester) async {
      await tester.pumpWidget(wrap(stateFor(phase: IntermediatePhase.idle)));
      await pumpAligned(tester);
      final controller = controllerOf(tester);

      // 贴底时导航条不显示，先上翻使其出现
      await dragUp(tester);
      await tester.tap(find.byIcon(Icons.keyboard_double_arrow_up));
      await tester.pumpAndSettle();
      expect(controller.offset, 0);

      await tester.tap(find.byIcon(Icons.keyboard_double_arrow_down));
      await tester.pumpAndSettle();
      expect(
        controller.offset,
        closeTo(controllerOf(tester).position.maxScrollExtent, 1),
      );
    });

    testWidgets('6. 冻结后滚回底部自动恢复跟随（新直播增长后贴底）', (tester) async {
      await tester.pumpWidget(
        wrap(
          stateFor(phase: IntermediatePhase.reviewing, liveText: 'a' * 100),
        ),
      );
      await pumpAligned(tester);
      final controller = controllerOf(tester);

      // 冻结：一次大幅上划脱离底部
      controller.position.jumpTo(
        (controller.position.maxScrollExtent - 400)
            .clamp(0, controller.position.maxScrollExtent),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        controller.offset,
        lessThan(controller.position.maxScrollExtent - 100),
        reason: '前置：已上划冻结于阅读位',
      );

      // 向下滚回底部（距底 0 在 48px 恢复带内）→ 自动恢复跟随
      controller.position.jumpTo(controller.position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 100));

      // 新直播内容多 delta 到达（真实流式逐帧增长）：恢复跟随后贴底
      for (var i = 1; i <= 3; i++) {
        await tester.pumpWidget(
          wrap(
            stateFor(
              phase: IntermediatePhase.reviewing,
              liveText: 'a' * (100 + 120 * i),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
      }
      // 收敛：显示层平滑揭示会在两次 state 更新之间继续放字（下一帧跟随
      // 才追上）；导演页有循环动画不能用 pumpAndSettle，故显式多泵几帧。
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        controller.position.maxScrollExtent - controller.offset,
        lessThanOrEqualTo(streamingFollowCushionPx + 1),
        reason: '滚回距底 ≤4px 应自动恢复跟随，最新一行留在视口内',
      );
    });

    testWidgets('7. 贴底流式中内容收缩（收工折叠/稿件并档钳位）不误冻结跟随', (tester) async {
      await tester.pumpWidget(
        wrap(
          stateFor(phase: IntermediatePhase.reviewing, liveText: 'a' * 600),
        ),
      );
      await pumpAligned(tester);
      final controller = controllerOf(tester);
      expect(
        controller.offset,
        closeTo(controller.position.maxScrollExtent, 1),
        reason: '前置：贴底跟随中',
      );

      // 内容收缩：直播稿件骤缩 → maxScrollExtent 下降、贴底视口 pixels
      // 被钳位同步下降——收缩不是用户上划，不得冻结跟随。
      await tester.pumpWidget(
        wrap(stateFor(phase: IntermediatePhase.reviewing, liveText: 'a' * 60)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        controller.offset,
        closeTo(controller.position.maxScrollExtent, 4),
        reason: '收缩后视口应仍钳位贴底',
      );

      // 收缩后的增长：跟随不得被误冻结，仍贴底
      await tester.pumpWidget(
        wrap(stateFor(phase: IntermediatePhase.reviewing, liveText: 'a' * 300)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      // 收敛：平滑揭示在两次 state 更新之间继续放字，跟随下一帧才追上
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        controller.position.maxScrollExtent - controller.offset,
        lessThanOrEqualTo(streamingFollowCushionPx + 1),
        reason: '内容收缩不得误冻结跟随，最新一行留在视口内',
      );
    });
  });

  group('隔断卡渲染与历史轮操作边界', () {
    // 局部构造器不带下划线前缀（very_good_analysis
    // no_leading_underscores_for_local_identifiers）
    ChatSession sessionOf(int messageCount) => ChatSession(
          sessionId: 'dir-1',
          title: '测试导演',
          mode: 'advanced',
          createdAt: DateTime(2026),
          lastActiveAt: DateTime(2026),
          messageCount: messageCount,
        );

    ChatMessage assistantMessageOf(String id, String content) => ChatMessage(
          messageId: id,
          sessionId: 'dir-1',
          role: 'assistant',
          content: content,
          createdAt: DateTime(2026),
        );

    ChatMessage userMessageOf(String id, String content) => ChatMessage(
          messageId: id,
          sessionId: 'dir-1',
          role: 'user',
          content: content,
          createdAt: DateTime(2026),
        );

    /// 压缩后形态：列表头部 isSummary=true 的 system 摘要行 + 其后可见轮次
    AdvancedChatState compactedState({required int messageCount}) {
      final summary = ChatMessage(
        messageId: 'm-summary',
        sessionId: 'dir-1',
        role: 'system',
        content: '宏观摘要：勇者已抵达北境边境。',
        isSummary: true,
        createdAt: DateTime(2026),
      );
      return AdvancedChatState(
        phase: IntermediatePhase.idle,
        messages: [
          summary,
          _message('user', '推进剧情'),
          assistantMessageOf('m-a1', '第一轮正文'),
        ],
        retryCounts: const {},
        session: sessionOf(messageCount),
      );
    }

    testWidgets('压缩摘要行渲染为隔断卡（对齐故事模式），不挂编辑/删除等消息操作', (tester) async {
      final regenerated = <String>[];
      final edited = <String>[];
      final deleted = <String>[];
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
            home: Scaffold(
              body: DirectorChatBody(
                state: compactedState(messageCount: 2),
                onCopy: (_) {},
                onRegenerate: (m) => regenerated.add(m.messageId),
                onEdit: (m) => edited.add(m.messageId),
                onDeleteRound: (m) => deleted.add(m.messageId),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // 摘要行以隔断卡形态渲染
      expect(
        find.byType(IntermediateCompactionSummaryCard),
        findsOneWidget,
      );
      // 摘要正文不进稿件卡（隔断卡默认折叠，正文不可见）
      expect(find.text('宏观摘要：勇者已抵达北境边境。'), findsNothing);
      // 隔断卡上没有任何消息操作
      expect(
        find.descendant(
          of: find.byType(IntermediateCompactionSummaryCard),
          matching: find.byType(IntermediateMessageActions),
        ),
        findsNothing,
      );
      // 全列表仅正常轮次挂一组消息操作
      expect(find.byType(IntermediateMessageActions), findsOneWidget);

      // 摘要内容可在隔断卡内展开查看（仍无操作入口）
      await tester.tap(find.byType(IntermediateCompactionSummaryCard));
      await tester.pumpAndSettle();
      expect(find.text('宏观摘要：勇者已抵达北境边境。'), findsOneWidget);
      expect(find.byType(IntermediateMessageActions), findsOneWidget);
    });

    testWidgets('窗口外历史轮的重生成/删除被拦截，窗口内正常触发', (tester) async {
      // 3 轮 + windowRounds 2 → 可操作窗口 = turn >= 3 - 2 + 1 = 2
      // 第 1 轮在窗口外，第 3 轮在窗口内。
      // 测试视口加高：生产中消息区下方还有输入区，600px 默认视口下
      // 底部浮层会压住末轮操作按钮
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final messages = <ChatMessage>[];
      for (var i = 1; i <= 3; i++) {
        messages
          ..add(userMessageOf('m-u$i', '推进 $i'))
          ..add(assistantMessageOf('m-a$i', '正文 $i'));
      }
      final regenerated = <String>[];
      final deleted = <String>[];
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
            home: Scaffold(
              body: DirectorChatBody(
                state: AdvancedChatState(
                  phase: IntermediatePhase.idle,
                  messages: messages,
                  retryCounts: const {},
                  session: sessionOf(6),
                ),
                onCopy: (_) {},
                onRegenerate: (m) => regenerated.add(m.messageId),
                onEdit: (_) {},
                onDeleteRound: (m) => deleted.add(m.messageId),
                windowRounds: 2,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final regenerateIcons = find.byIcon(Icons.refresh_rounded);
      final deleteIcons = find.byIcon(Icons.delete_outline);
      // 3 轮 assistant 各一组操作
      expect(regenerateIcons, findsNWidgets(3));

      // 窗口外（第 1 轮）：重生成/删除被窗口提示拦截，回调不触发
      await tester.tap(regenerateIcons.first, warnIfMissed: false);
      await tester.pump();
      expect(regenerated, isEmpty);
      // 拦截时弹出窗口超限提示（与故事模式同款交互）
      expect(find.byType(SnackBar), findsOneWidget);
      // SnackBar 定时器不排帧，pumpAndSettle 等不到它：显式推进 4s 时长
      // + 退场动画后再验下一项，避免遮挡造成假阳性/假阴性
      Future<void> dismissSnackBar() async {
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
      }

      await dismissSnackBar();
      await tester.tap(deleteIcons.first, warnIfMissed: false);
      await tester.pump();
      expect(deleted, isEmpty);
      expect(find.byType(SnackBar), findsOneWidget);

      // 窗口内（第 3 轮）：重生成正常触发
      await dismissSnackBar();
      await tester.tap(regenerateIcons.last);
      await tester.pump();
      expect(regenerated, ['m-a3']);
    });
  });

  group('搜索命中定位（/ ）', () {
    // 12 轮内容撑出可滚动高度
    List<ChatMessage> longHistory() {
      final messages = <ChatMessage>[];
      for (var i = 0; i < 12; i++) {
        messages
          ..add(
            ChatMessage(
              messageId: 'u$i',
              sessionId: 'dir-1',
              role: 'user',
              content: '推进剧情 第$i 轮：${'用户输入内容。' * 30}',
              createdAt: DateTime(2026),
            ),
          )
          ..add(
            ChatMessage(
              messageId: 'a$i',
              sessionId: 'dir-1',
              role: 'assistant',
              content: '第$i 轮定稿正文：${'叙事正文内容。' * 120}',
              createdAt: DateTime(2026),
            ),
          );
      }
      return messages;
    }

    AdvancedChatState stateOf(List<ChatMessage> messages) => AdvancedChatState(
          phase: IntermediatePhase.idle,
          messages: messages,
          retryCounts: const {},
          session: _testSession(),
        );

    ScrollPosition positionOf(WidgetTester tester) =>
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;

    testWidgets('同会话再次深链（focus id 变化）须重新定位', (tester) async {
      final messages = longHistory();
      await tester.pumpWidget(wrap(stateOf(messages)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 350));
      final position = positionOf(tester);
      expect(position.maxScrollExtent, greaterThan(0));
      expect(
        position.pixels,
        closeTo(position.maxScrollExtent, 8),
        reason: '前置：首帧对齐贴底',
      );

      // 页面壳无 key 复用 State：同一树位换入携带新 focus id 的 widget
      await tester
          .pumpWidget(wrap(stateOf(messages), initialFocusMessageId: 'u0'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        position.pixels,
        lessThan(position.maxScrollExtent / 2),
        reason: '同会话再次搜索命中须重新定位到首轮（旧实现被 _initialAligned '
            '单次门控挡死，纹丝不动）',
      );
    });

    testWidgets('首次挂载携带 focus id 仍正常定位（回归）', (tester) async {
      final messages = longHistory();
      await tester.pumpWidget(
        wrap(stateOf(messages), initialFocusMessageId: 'u0'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 350));
      final position = positionOf(tester);
      expect(position.maxScrollExtent, greaterThan(0));
      expect(
        position.pixels,
        lessThan(position.maxScrollExtent / 2),
        reason: '首次进入定位不得被  修复破坏',
      );
    });
  });

  // ── 手动压缩与消息操作互斥────────────────
  //
  // 导演侧手动压缩全程 phase 恒为 idle（advanced_chat_page:847 经
  // ContextUsageDetailSheet 触发 manualCompact）——消息动作若只看 phase，
  // 压缩中菜单照常渲染，点击后控制器静默 no-op（controller messages.dart
  // 四守卫），用户零反馈。
  group('手动压缩中消息动作锁定（同族）', () {
    List<ChatMessage> roundMessages() => [
          ChatMessage(
            messageId: 'u1',
            sessionId: 'dir-1',
            role: 'user',
            content: '上一轮输入',
            createdAt: DateTime(2026),
          ),
          ChatMessage(
            messageId: 'a1',
            sessionId: 'dir-1',
            role: 'assistant',
            content: '上一轮回复',
            createdAt: DateTime(2026),
          ),
        ];

    testWidgets('压缩挂起中（idle+isManualCompacting）：动作行不渲染', (tester) async {
      final state = AdvancedChatState(
        phase: IntermediatePhase.idle,
        isManualCompacting: true,
        messages: roundMessages(),
        retryCounts: const {},
        session: _testSession(),
      );

      await tester.pumpWidget(wrap(state));
      await tester.pumpAndSettle();

      // 点用户气泡呼出动作菜单（气泡 tap 切换）
      await tester.tap(find.text('上一轮输入'));
      await tester.pump();

      expect(
        find.byType(IntermediateMessageActions),
        findsNothing,
        reason: '压缩中用户菜单与助手行内动作应锁定（控制器侧静默 no-op）',
      );
    });

    testWidgets('非压缩 idle：动作照常渲染（对照组）', (tester) async {
      final state = AdvancedChatState(
        phase: IntermediatePhase.idle,
        messages: roundMessages(),
        retryCounts: const {},
        session: _testSession(),
      );

      await tester.pumpWidget(wrap(state));
      await tester.pumpAndSettle();

      // 助手行内动作行常驻渲染
      expect(find.byType(IntermediateMessageActions), findsOneWidget);

      // 点用户气泡呼出菜单后共两处
      await tester.tap(find.text('上一轮输入'));
      await tester.pump();
      expect(find.byType(IntermediateMessageActions), findsNWidgets(2));
    });
  });

  // ──  行懒构建──────────────────────
  //
  // _buildRows 全量急构建改 itemBuilder 按 index 现算后，用例锁定两件事：
  // 1. 行序零变化：混合形态（user 轮 + 摘要卡 + 孤儿 assistant + 裸 user
  //    + pending + live 组 + 稿件卡）的视觉自上而下顺序与旧 while 循环
  //    逐分支一致；列表项数 = messages + 尾槽（IndexedSemantics 计数）。
  // 2. 轮聚合键：删除中间轮后（轮号整体前移），用户展开的幕后组状态
  //    跟随轮（assistant 消息 id 键）迁移，不被错位继承给别的轮。
  group('行懒构建与轮聚合键', () {
    ChatMessage userMessage(String id, String content) => ChatMessage(
          messageId: id,
          sessionId: 'dir-1',
          role: 'user',
          content: content,
          createdAt: DateTime(2026),
        );

    ChatMessage assistantMessage(String id, String content) => ChatMessage(
          messageId: id,
          sessionId: 'dir-1',
          role: 'assistant',
          content: content,
          createdAt: DateTime(2026),
        );

    StoryRoundArtifacts timelineArtifacts(String narration) =>
        StoryRoundArtifacts(
          sessionId: 'dir-1',
          turnNumber: 0,
          createdAt: DateTime(2026),
          agentTimeline: [
            const AgentTimelineBlock(
              kind: AgentTimelineKind.thinking,
              stepIndex: 0,
              text: '先查前情。',
            ),
            const AgentTimelineBlock(
              kind: AgentTimelineKind.action,
              stepIndex: 0,
              action: AgentWorkStep(toolName: 'search_story'),
            ),
            AgentTimelineBlock(
              kind: AgentTimelineKind.narration,
              stepIndex: 1,
              text: narration,
            ),
            const AgentTimelineBlock(
              kind: AgentTimelineKind.action,
              stepIndex: 1,
              action: AgentWorkStep(toolName: 'finish_round'),
            ),
          ],
          agentWorkSummary: const AgentWorkSummary(
            steps: 2,
            totalTokens: 1000,
            durationMs: 12000,
          ),
        );

    testWidgets('混合历史 + 尾部直播：行序与旧急构建完全一致', (tester) async {
      // 视口加高保证懒构建把全部行都装进缓存范围
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final summary = ChatMessage(
        messageId: 'm-summary',
        sessionId: 'dir-1',
        role: 'system',
        content: '宏观摘要。',
        isSummary: true,
        createdAt: DateTime(2026),
      );
      await tester.pumpWidget(
        wrap(
          AdvancedChatState(
            phase: IntermediatePhase.reviewing,
            messages: [
              userMessage('u1', '用户一'),
              assistantMessage('a1', '正文一'),
              summary,
              // 孤儿 assistant（前面是摘要卡不是 user）→ 兜底正文行
              assistantMessage('a2', '孤儿正文'),
              // 裸 user（后面无 assistant）→ 只有用户气泡
              userMessage('u2', '用户二'),
            ],
            retryCounts: const {},
            session: _testSession(),
            artifactsByTurnNumber: {1: timelineArtifacts('这轮让她出场。')},
            pendingUserMessage: userMessage('p1', '继续推进'),
            liveBlocks: const [
              AgentLiveBlock(
                kind: AgentLiveBlockKind.thinking,
                stepIndex: 0,
                text: '想着',
              ),
              AgentLiveBlock(
                kind: AgentLiveBlockKind.text,
                stepIndex: 1,
                source: AgentTextSource.finishRoundProse,
                text: '直播正文',
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      // 列表项数 = messages(5) + pending(1) + live 组(1) + 稿件卡(1) = 8
      final indexes = tester
          .widgetList<IndexedSemantics>(find.byType(IndexedSemantics))
          .map((w) => w.index)
          .toList()
        ..sort();
      expect(indexes, List.generate(8, (i) => i));

      // 视觉自上而下顺序（旧 while 循环的行序）：用户气泡 → 幕后组标题 →
      // 正文稿件 → 摘要隔断卡 → 孤儿兜底正文 → 裸用户气泡 → pending 气泡
      // → live 组标题 → 直播稿件卡
      final markers = <Finder>[
        find.text('用户一'),
        find.text('幕后 2 步 · 思考 1 段 · 12s'),
        find.text('正文一'),
        find.byType(IntermediateCompactionSummaryCard),
        find.text('孤儿正文'),
        find.text('用户二'),
        find.text('继续推进'),
        find.text('等待模型响应…'),
        find.text('直播正文'),
      ];
      var previous = -1.0;
      for (final marker in markers) {
        final dy = tester.getTopLeft(marker).dy;
        expect(dy, greaterThan(previous), reason: '$marker 行序错位');
        previous = dy;
      }
    });

    testWidgets('删除中间轮后：展开的幕后组跟随轮迁移，不被错位继承', (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      ChatSession sessionOf(int messageCount) => ChatSession(
            sessionId: 'dir-1',
            title: '测试导演',
            mode: 'advanced',
            createdAt: DateTime(2026),
            lastActiveAt: DateTime(2026),
            messageCount: messageCount,
          );

      final threeRounds = [
        for (var i = 1; i <= 3; i++) ...[
          userMessage('u$i', '推进 $i'),
          assistantMessage('a$i', '正文 $i'),
        ],
      ];
      await tester.pumpWidget(
        wrap(
          AdvancedChatState(
            phase: IntermediatePhase.idle,
            messages: threeRounds,
            retryCounts: const {},
            session: sessionOf(6),
            artifactsByTurnNumber: {
              1: timelineArtifacts('播报一'),
              2: timelineArtifacts('播报二'),
              3: timelineArtifacts('播报三'),
            },
          ),
        ),
      );
      await tester.pump();

      // 展开第 2 轮幕后组（收起态图标第二个）
      await tester.tap(find.byIcon(Icons.tungsten_outlined).at(1));
      await tester.pumpAndSettle();
      expect(find.text('播报二'), findsOneWidget);
      expect(find.text('播报一'), findsNothing);
      expect(find.text('播报三'), findsNothing);

      // 删除第 1 轮：messages 去掉 u1/a1，后续轮号整体前移（artifacts
      // 键随之重映射），messageCount -2 —— 对齐真实删轮后的 state 形态
      await tester.pumpWidget(
        wrap(
          AdvancedChatState(
            phase: IntermediatePhase.idle,
            messages: [
              for (var i = 2; i <= 3; i++) ...[
                userMessage('u$i', '推进 $i'),
                assistantMessage('a$i', '正文 $i'),
              ],
            ],
            retryCounts: const {},
            session: sessionOf(4),
            artifactsByTurnNumber: {
              1: timelineArtifacts('播报二'),
              2: timelineArtifacts('播报三'),
            },
          ),
        ),
      );
      await tester.pump();

      // 第 2 轮（a2 键）保持展开；第 3 轮不得被错位继承为展开
      expect(
        find.text('播报二'),
        findsOneWidget,
        reason: '用户展开的幕后组应跟随轮（消息 id 键）保留展开态',
      );
      expect(
        find.text('播报三'),
        findsNothing,
        reason: '按索引错位匹配会让第 3 轮继承第 2 轮的展开态',
      );
    });
  });

  // ── ：会话打开 loading 态 ─────────────
  group('G-03：会话打开 loading 态', () {
    testWidgets('loading 且内容为空：渲染骨架，不闪空态引导', (tester) async {
      await tester.pumpWidget(
        wrap(
          AdvancedChatState(
            phase: IntermediatePhase.idle,
            messages: const [],
            retryCounts: const {},
            session: _testSession(),
            loadingHistory: true,
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('history-loading-skeleton')),
        findsOneWidget,
      );
      // 空态引导不出现（重会话打开瞬间不再误导）
      expect(find.textContaining('发送第一句话开始。'), findsNothing);
    });

    testWidgets('非 loading 且内容为空：空态引导正常出现', (tester) async {
      await tester.pumpWidget(
        wrap(
          AdvancedChatState(
            phase: IntermediatePhase.idle,
            messages: const [],
            retryCounts: const {},
            session: _testSession(),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('history-loading-skeleton')),
        findsNothing,
      );
      expect(find.textContaining('发送第一句话开始。'), findsOneWidget);
    });
  });

  // ── ：变体切换器 ────────────────────
  group('G-08+09：变体切换器', () {
    AdvancedChatState variantState() => AdvancedChatState(
          phase: IntermediatePhase.idle,
          messages: [_message('user', '推进剧情'), _message('assistant', '第二版正文')],
          retryCounts: const {},
          session: _testSession(),
          artifactsByTurnNumber: {
            1: StoryRoundArtifacts(
              sessionId: 'dir-1',
              turnNumber: 1,
              createdAt: DateTime(2026),
              currentVariantIndex: 1,
            ),
          },
          variantsByTurn: const {
            1: [
              MessageVariantRecord(
                variantIndex: 0,
                createdAtMs: 0,
                content: '第一版正文',
              ),
              MessageVariantRecord(
                variantIndex: 1,
                createdAtMs: 1,
                content: '第二版正文',
              ),
            ],
          },
        );

    testWidgets('>1 版本渲染 n/m 切换器；箭头回调切换相邻版本', (tester) async {
      final switches = <int>[];
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
            home: Scaffold(
              body: DirectorChatBody(
                state: variantState(),
                onCopy: (_) {},
                onRegenerate: (_) {},
                onEdit: (_) {},
                onDeleteRound: (_) {},
                onSwitchVariant: (_, index) async => switches.add(index),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('2/2'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pump();
      expect(switches, [0], reason: '左箭头切回上一版');
    });

    // 高亮 2s 从收稿时刻起算——
    // 行延迟物化时只闪剩余时长，超窗直接消费不高亮。
    testWidgets('起表超窗（收稿 3s 后才滚到该轮）→ 不高亮直接消费信号', (tester) async {
      final consumed = <int>[];
      final state = variantState().copyWith(
        variantFlashTurn: 1,
        variantFlashStartedAtMs: DateTime.now().millisecondsSinceEpoch - 3000,
      );
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
            home: Scaffold(
              body: DirectorChatBody(
                state: state,
                onCopy: (_) {},
                onRegenerate: (_) {},
                onEdit: (_) {},
                onDeleteRound: (_) {},
                onSwitchVariant: (_, index) async {},
                onVariantFlashConsumed: () => consumed.add(1),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(consumed, isNotEmpty, reason: '超窗信号在首帧后被消费');
      // 无 2s 计时器滞留：settle 不需要等 2s
      await tester.pumpAndSettle();
    });

    testWidgets('高亮在途行被卸载（dispose）→ 补消费信号不再滞留', (tester) async {
      final consumed = <int>[];
      final state = variantState().copyWith(
        variantFlashTurn: 1,
        variantFlashStartedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
            home: Scaffold(
              body: DirectorChatBody(
                state: state,
                onCopy: (_) {},
                onRegenerate: (_) {},
                onEdit: (_) {},
                onDeleteRound: (_) {},
                onSwitchVariant: (_, index) async {},
                onVariantFlashConsumed: () => consumed.add(1),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(consumed, isEmpty, reason: '窗口内高亮在途，尚未消费');

      // 行滚出懒加载视口/切页 = 卸载
      await tester.pumpWidget(const SizedBox());
      expect(consumed, isNotEmpty, reason: 'dispose 补消费，信号不滞留');
    });

    testWidgets('点计数开版本面板：预览可见，点非当前版本行触发切换', (tester) async {
      final switches = <int>[];
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
            home: Scaffold(
              body: DirectorChatBody(
                state: variantState(),
                onCopy: (_) {},
                onRegenerate: (_) {},
                onEdit: (_) {},
                onDeleteRound: (_) {},
                onSwitchVariant: (_, index) async => switches.add(index),
                onDeleteVariant: (_, __) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('2/2'));
      await tester.pumpAndSettle();

      expect(find.text('稿件版本'), findsOneWidget);
      expect(find.text('第一版正文'), findsOneWidget);
      expect(find.text('当前'), findsOneWidget);

      await tester.tap(find.text('第一版正文'));
      await tester.pumpAndSettle();
      expect(switches, [0], reason: '面板点非当前版本 = 设为当前');
    });

    testWidgets('单版本轮不渲染切换器', (tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
            home: Scaffold(
              body: DirectorChatBody(
                state: AdvancedChatState(
                  phase: IntermediatePhase.idle,
                  messages: [
                    _message('user', '推进剧情'),
                    _message('assistant', '唯一版本'),
                  ],
                  retryCounts: const {},
                  session: _testSession(),
                ),
                onCopy: (_) {},
                onRegenerate: (_) {},
                onEdit: (_) {},
                onDeleteRound: (_) {},
                onSwitchVariant: (_, __) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('1/1'), findsNothing);
    });
  });

  // ── ：阅读行宽钳制 ─────────────────────
  group('G-27：阅读行宽钳制', () {
    testWidgets('宽屏下稿件正文行宽不超过 readingWidth（800）', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const longText = '夜色沉下来，苏明远推开荒庙的门，门轴发出漫长的呻吟。'
          '他举起手电，光柱里浮尘翻涌，像一场倒放的雪。';
      await tester.pumpWidget(
        wrap(
          AdvancedChatState(
            phase: IntermediatePhase.idle,
            messages: [_message('assistant', longText)],
            retryCounts: const {},
            session: _testSession(),
          ),
        ),
      );
      await tester.pump();

      final cardWidth = tester.getSize(find.text(longText)).width;
      expect(
        cardWidth,
        lessThan(800),
        reason: '宽屏（1280px 视口）下稿件卡应钳制在 readingWidth 内并居中',
      );
    });

    testWidgets('宽屏下整列进版心：用户气泡与幕后折叠组与正文同列', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final artifacts = <int, StoryRoundArtifacts>{
        1: StoryRoundArtifacts(
          sessionId: 'dir-1',
          turnNumber: 1,
          createdAt: DateTime(2026),
          agentTimeline: const [
            AgentTimelineBlock(
              kind: AgentTimelineKind.action,
              stepIndex: 0,
              action: AgentWorkStep(
                toolName: 'search_story',
                callId: 'c1',
                title: '「古碑」',
              ),
            ),
          ],
        ),
      };
      await tester.pumpWidget(
        wrap(
          AdvancedChatState(
            phase: IntermediatePhase.idle,
            messages: [_message('user', '推进剧情'), _message('assistant', '正文')],
            retryCounts: const {},
            session: _testSession(),
            artifactsByTurnNumber: artifacts,
          ),
        ),
      );
      await tester.pump();

      // 用户气泡（含动作行）不超出版心（列表已整体收窄；行内仍有
      // 92% 列宽等自身约束，这里只守"不超版心"的上界）。
      // 流式版心：1280 窗口下 = max(800, 1280×85%) = 1088
      expect(
        tester.getSize(find.text('推进剧情')).width,
        lessThan(1088),
      );
      // 幕后折叠组（工作状态行）与用户气泡水平范围一致（同列）：
      // 折叠组标题行不再通铺整窗
      final bubbleRight = tester.getTopRight(find.text('推进剧情')).dx;
      final groupRow = find.byType(DirectorWorkGroup);
      expect(groupRow, findsOneWidget);
      expect(
        tester.getSize(groupRow).width,
        lessThan(1088),
        reason: '幕后折叠组应与正文同列（版心内），不得通铺整窗',
      );
      // 版心（1088）在 1280 视口居中：列表右缘 = 1280/2 + 1088/2 = 1184，
      // 减横向 padding 后内容右缘 1172；气泡右缘贴版心而不再贴窗口右缘
      expect(bubbleRight, lessThan(1172), reason: '用户气泡右缘应在版心内');
      expect(
        bubbleRight,
        greaterThan(1000),
        reason: '用户气泡仍右对齐版心右缘，而非失去右对齐',
      );
    });
  });

  group('G-30：纯净阅读模式', () {
    testWidgets('隐藏幕后折叠组与用户气泡，稿件+Recap 保留', (tester) async {
      final artifacts = <int, StoryRoundArtifacts>{
        1: StoryRoundArtifacts(
          sessionId: 'dir-1',
          turnNumber: 1,
          createdAt: DateTime(2026),
          agentTimeline: const [
            AgentTimelineBlock(
              kind: AgentTimelineKind.action,
              stepIndex: 0,
              action: AgentWorkStep(
                toolName: 'search_story',
                callId: 'c1',
                title: '「古碑」',
              ),
            ),
          ],
          storyAnchor: const StoryAnchor(
            updatedTurn: 1,
            arc: '弧线',
            oneLiner: '一句主线',
          ),
        ),
      };
      final state = AdvancedChatState(
        phase: IntermediatePhase.idle,
        messages: [_message('user', '推进'), _message('assistant', '稿件正文')],
        retryCounts: const {},
        session: _testSession(),
        artifactsByTurnNumber: artifacts,
      );

      // 正常态：幕后折叠组与用户气泡可见
      await tester.pumpWidget(wrap(state));
      await tester.pump();
      expect(find.byIcon(Icons.tungsten_outlined), findsOneWidget);
      expect(find.text('推进'), findsOneWidget);

      // 纯净阅读：两者隐藏，稿件与 Recap 书脊保留
      await tester.pumpWidget(
        wrap(state, pureReading: true),
      );
      await tester.pump();
      expect(find.byIcon(Icons.tungsten_outlined), findsNothing);
      expect(find.text('推进'), findsNothing);
      expect(find.text('稿件正文'), findsOneWidget);
      expect(find.textContaining('第 1 幕'), findsOneWidget);
    });
  });

  group('G-17：失败轮半截稿件「未定稿」徽标', () {
    testWidgets('失败轮稿件卡显示未定稿徽标，不渲染落幕线', (tester) async {
      await tester.pumpWidget(
        wrap(
          AdvancedChatState(
            phase: IntermediatePhase.failed,
            failureContext: const FailureContext(
              errorCode: 'EAGENT',
              failedPhase: IntermediatePhase.generating,
              errorMessage: '模型中断',
              retryable: true,
            ),
            messages: const [],
            retryCounts: const {},
            session: _testSession(),
            liveBlocks: const [
              AgentLiveBlock(
                kind: AgentLiveBlockKind.text,
                stepIndex: 0,
                source: AgentTextSource.finishRoundProse,
                text: '写了一半的正文',
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(find.text('未定稿'), findsOneWidget);
      expect(find.text('写了一半的正文'), findsOneWidget);
    });

    testWidgets('正常定稿轮不出现未定稿徽标', (tester) async {
      await tester.pumpWidget(
        wrap(
          AdvancedChatState(
            phase: IntermediatePhase.idle,
            messages: [_message('user', '推进'), _message('assistant', '完整正文')],
            retryCounts: const {},
            session: _testSession(),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('未定稿'), findsNothing);
      expect(find.text('完整正文'), findsOneWidget);
    });
  });

  group('T12：时间线装配签名缓存（build 期不重跑 assemble）', () {
    // 观测探针：DirectorWorkGroup.timeline 的列表实例 identity——
    // 缓存命中 → 装配结果列表复用（同一实例）；未命中 → 新列表。
    List<AgentTimelineBlock> liveTimelineOf(WidgetTester tester) => tester
        .widget<DirectorWorkGroup>(find.byType(DirectorWorkGroup))
        .timeline;

    testWidgets('live 输入不变时的无关重建（上下文用量变化）→ 时间线复用', (tester) async {
      final blocks = [
        const AgentLiveBlock(
          kind: AgentLiveBlockKind.thinking,
          stepIndex: 0,
          text: '想着',
        ),
        const AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 0,
          source: AgentTextSource.finishRoundProse,
          text: '第一句正文',
        ),
      ];
      AdvancedChatState stateOf({int? contextWindowTokens}) =>
          AdvancedChatState(
            phase: IntermediatePhase.reviewing,
            messages: const [],
            retryCounts: const {},
            session: _testSession(),
            liveBlocks: blocks,
            contextWindowTokens: contextWindowTokens,
          );

      await tester.pumpWidget(wrap(stateOf(contextWindowTokens: 100000)));
      await tester.pump();
      final before = liveTimelineOf(tester);

      // 同 liveBlocks/agentSteps 实例，仅无关标量变化（上下文窗口解析
      // 结果回流）→ 整页重建但装配输入未变
      await tester.pumpWidget(wrap(stateOf(contextWindowTokens: 120000)));
      await tester.pump();

      expect(
        identical(before, liveTimelineOf(tester)),
        isTrue,
        reason: '装配输入未变时必须复用上次装配结果（assemble 不重跑）',
      );
    });

    testWidgets('live 内容增长 → 重装配', (tester) async {
      // 思考块保组存在（纯 text 块会全部升格进稿件卡，无组可观测）
      final grownBlocks = [
        const AgentLiveBlock(
          kind: AgentLiveBlockKind.thinking,
          stepIndex: 0,
          text: '想着',
        ),
        const AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 0,
          source: AgentTextSource.finishRoundProse,
          text: '第一句正文',
        ),
      ];
      AdvancedChatState stateOf(List<AgentLiveBlock> blocks) =>
          AdvancedChatState(
            phase: IntermediatePhase.reviewing,
            messages: const [],
            retryCounts: const {},
            session: _testSession(),
            liveBlocks: blocks,
          );

      await tester.pumpWidget(wrap(stateOf(grownBlocks)));
      await tester.pump();
      final before = liveTimelineOf(tester);

      // 新块实例（文本追加 → 控制器换列表）
      final appended = [
        const AgentLiveBlock(
          kind: AgentLiveBlockKind.thinking,
          stepIndex: 0,
          text: '想着',
        ),
        const AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 0,
          source: AgentTextSource.finishRoundProse,
          text: '第一句正文，第二句来了',
        ),
      ];
      await tester.pumpWidget(wrap(stateOf(appended)));
      await tester.pump();

      expect(
        identical(before, liveTimelineOf(tester)),
        isFalse,
        reason: 'live 内容变化必须重新装配',
      );
      // 等平滑揭示补齐后再断言渲染内容（揭示窗口见 streaming_reveal_pacer.dart）
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.textContaining('第二句来了'), findsWidgets);
    });

    testWidgets('步数不变但步状态翻转 → 重装配', (tester) async {
      final blocks = [
        const AgentLiveBlock(
          kind: AgentLiveBlockKind.thinking,
          stepIndex: 0,
          text: '想着',
        ),
      ];
      AdvancedChatState stateOf(List<AgentWorkStep> steps) => AdvancedChatState(
            phase: IntermediatePhase.reviewing,
            messages: const [],
            retryCounts: const {},
            session: _testSession(),
            liveBlocks: blocks,
            agentSteps: steps,
          );

      await tester.pumpWidget(
        wrap(
          stateOf([
            const AgentWorkStep(
              toolName: 'search',
              status: AgentStepStatus.running,
            ),
          ]),
        ),
      );
      await tester.pump();
      final before = liveTimelineOf(tester);

      await tester.pumpWidget(
        wrap(
          stateOf([
            const AgentWorkStep(toolName: 'search'),
          ]),
        ),
      );
      await tester.pump();

      expect(
        identical(before, liveTimelineOf(tester)),
        isFalse,
        reason: '步实例替换（状态翻转）必须重新装配',
      );
    });
  });
  group('字号缩放接线（回归）', () {
    testWidgets('fontScale 透传稿件卡与用户气泡', (tester) async {
      final assistant = ChatMessage(
        messageId: 'm-a',
        sessionId: 'dir-1',
        role: 'assistant',
        content: '定稿正文',
        createdAt: DateTime(2026),
      );
      await tester.pumpWidget(
        wrap(
          AdvancedChatState(
            phase: IntermediatePhase.idle,
            messages: [_message('user', '推进剧情'), assistant],
            retryCounts: const {},
            session: _testSession(),
          ),
          fontScale: 1.5,
        ),
      );
      await tester.pump();

      final md = tester
          .widget<IntermediateMarkdownBody>(
            find.byType(IntermediateMarkdownBody).first,
          )
          .fontScale;
      expect(md, 1.5, reason: '稿件卡正文随全局字号缩放');

      final bubble = tester
          .widget<IntermediateMessageBubble>(
            find.byType(IntermediateMessageBubble).first,
          )
          .fontScale;
      expect(bubble, 1.5, reason: '用户气泡随全局字号缩放');
    });
  });

  // 回归：工作态直播把指令气泡（pending）挤出视口时，
  // 顶部显示可点击的「正在执行的指示」浮条；点击滚回指令气泡。
  group('工作态指示浮条（指令气泡出视口）', () {
    ChatMessage msg(String id, String role, String content) => ChatMessage(
          messageId: id,
          sessionId: 'dir-1',
          role: role,
          content: content,
          createdAt: DateTime(2026),
        );

    const instruction = '让主角进入地下城探险';

    AdvancedChatState stateOf({
      required IntermediatePhase phase,
      required List<AgentLiveBlock> blocks,
      required List<AgentWorkStep> steps,
    }) {
      return AdvancedChatState(
        phase: phase,
        messages: const [],
        retryCounts: const {},
        session: _testSession(),
        pendingUserMessage: msg('p1', 'user', instruction),
        liveBlocks: blocks,
        agentSteps: steps,
      );
    }

    List<AgentWorkStep> stepsFor(String prefix, int count) =>
        List<AgentWorkStep>.generate(
          count,
          (i) => AgentWorkStep(
            callId: '$prefix$i',
            toolName: 'search_story',
            title: '检索',
            startedAtMs: 0,
          ),
        );

    /// 直播内容长到把 pending 气泡（列表倒数第 2 项之前）挤出手机视口。
    final longStreamingBlocks = <AgentLiveBlock>[
      for (var i = 0; i < 8; i++)
        AgentLiveBlock(
          kind: AgentLiveBlockKind.thinking,
          stepIndex: i,
          text: '思考片段 $i ' * 20,
        ),
      AgentLiveBlock(
        kind: AgentLiveBlockKind.text,
        stepIndex: 9,
        source: AgentTextSource.finishRoundProse,
        text: '夜色沉下来，长稿件流式正文。' * 60,
      ),
    ];

    final stripFinder = find.text('正在执行的指示 · $instruction');

    testWidgets('失败态指令可见→无浮条；续跑直播挤出→浮条出现；点击回看后消失', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // ① 失败态：折叠组单行 + 短思考块，指令气泡在视口内 → 无浮条
      await tester.pumpWidget(
        wrap(
          stateOf(
            phase: IntermediatePhase.failed,
            blocks: const [
              AgentLiveBlock(
                kind: AgentLiveBlockKind.thinking,
                stepIndex: 0,
                text: '想了想',
              ),
            ],
            steps: stepsFor('c', 2),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(instruction), findsOneWidget);
      expect(stripFinder, findsNothing);

      // ② 续跑直播态：直播尾区把指令气泡挤出视口 → 浮条出现
      await tester.pumpWidget(
        wrap(
          stateOf(
            phase: IntermediatePhase.reviewing,
            blocks: longStreamingBlocks,
            steps: stepsFor('r', 5),
          ),
        ),
      );
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(stripFinder, findsOneWidget);

      // ③ 点击浮条 → 滚回指令气泡（重新可见）→ 浮条消失
      await tester.tap(stripFinder);
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text(instruction), findsOneWidget);
      expect(stripFinder, findsNothing);
    });

    testWidgets('收工（idle）后浮条不显示', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        wrap(
          stateOf(
            phase: IntermediatePhase.reviewing,
            blocks: longStreamingBlocks,
            steps: stepsFor('r', 5),
          ),
        ),
      );
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(stripFinder, findsOneWidget);

      // 收工：pending 落库清空 + liveBlocks 折叠 → 浮条随之消失
      await tester.pumpWidget(
        wrap(
          AdvancedChatState(
            phase: IntermediatePhase.idle,
            messages: [
              msg('u1', 'user', instruction),
              msg('a1', 'assistant', '正文'),
            ],
            retryCounts: const {},
            session: _testSession(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(stripFinder, findsNothing);
    });
  });
}
