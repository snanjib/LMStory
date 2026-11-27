import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_message_actions.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_message_bubble.dart';
import 'package:lmstory/core/utils/smooth_follow_scroller.dart'
    show streamingFollowCushionPx;
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/intermediate/presentation/pages/intermediate_chat_body.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../helpers/round_navigation_checks.dart';

/// IntermediateChatBody Widget 测试（Stage 3：pendingUserMessage 即时显示）
///
/// 验证：
/// - pendingUserMessage 非空时渲染用户消息气泡（即时显示）
/// - pendingUserMessage 为 null 时不渲染占位
/// - pendingUserMessage 与 state.messages 共存时两者都显示
/// - 空状态：pendingUserMessage 非空时不显示引导文案
///
/// 独立文件原因：intermediate_chat_page_test.dart 已 321 行（接近 500 行红线），
/// Stage 3 新增测试单独成文件便于维护（用户规则第 4 条）。

ChatSession _testSession() => ChatSession(
      sessionId: 'session-1',
      title: '测试故事',
      mode: 'intermediate',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );

ChatMessage _userMessage(String content) => ChatMessage(
      messageId: 'msg-${content.hashCode}',
      sessionId: 'session-1',
      role: 'user',
      content: content,
      createdAt: DateTime(2026),
    );

// body 转 ConsumerStatefulWidget（阅读位置缓存），
// 测试宿主补 ProviderScope
Widget _wrap(Widget child) => ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );

IntermediateChatBody _buildBody(
  IntermediateChatState state, {
  String? initialFocusMessageId,
}) =>
    IntermediateChatBody(
      state: state,
      onRetryRetrieval: () {},
      windowRounds: 5,
      canOperate: (_) => false,
      onCopy: (_) {},
      onRegenerate: (_) {},
      onEdit: (_) {},
      onDeleteRound: (_) {},
      initialFocusMessageId: initialFocusMessageId,
    );

void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('IntermediateChatBody - Stage 3 pendingUserMessage', () {
    testWidgets('1. pendingUserMessage 非空时渲染用户消息气泡', (tester) async {
      final state = IntermediateChatState(
        phase: IntermediatePhase.generating,
        messages: const [],
        retryCounts: const {},
        session: _testSession(),
        pendingUserMessage: _userMessage('我发送的消息'),
      );

      await tester.pumpWidget(_wrap(_buildBody(state)));

      // 用户消息内容渲染
      expect(find.text('我发送的消息'), findsOneWidget);
      // 渲染的是 IntermediateMessageBubble
      expect(find.byType(IntermediateMessageBubble), findsOneWidget);
    });

    testWidgets('2. pendingUserMessage 为 null 时不渲染额外气泡', (tester) async {
      final state = IntermediateChatState(
        phase: IntermediatePhase.idle,
        messages: const [],
        retryCounts: const {},
        session: _testSession(),
      );

      await tester.pumpWidget(_wrap(_buildBody(state)));

      // 空状态显示引导文案
      expect(find.text('开始你的故事'), findsOneWidget);
      // 不渲染任何消息气泡
      expect(find.byType(IntermediateMessageBubble), findsNothing);
    });

    testWidgets(
        '3. pendingUserMessage 与 messages 共存时两者都显示（pendingUserMessage 在底部）',
        (tester) async {
      final persistedMsg = ChatMessage(
        messageId: 'persisted-1',
        sessionId: 'session-1',
        role: 'assistant',
        content: '上一轮回复',
        createdAt: DateTime(2026),
      );
      final state = IntermediateChatState(
        phase: IntermediatePhase.generating,
        messages: [persistedMsg],
        retryCounts: const {},
        session: _testSession(),
        pendingUserMessage: _userMessage('新一轮用户消息'),
      );

      await tester.pumpWidget(_wrap(_buildBody(state)));

      // pendingUserMessage 与 persisted message 都显示
      final pendingFinder = find.text('新一轮用户消息');
      final persistedFinder = find.text('上一轮回复');
      expect(pendingFinder, findsOneWidget);
      expect(persistedFinder, findsOneWidget);

      // 验证顺序：pendingUserMessage 在 persisted message 之后（列表底部，紧贴 DraftPanel）
      // P3 修订：原顺序 [pendingUserMessage, ...messages] 在滚动到底部时
      // pendingUserMessage 被推到顶部不可见。新顺序 [...messages, pendingUserMessage]
      // 让用户发送消息后立即可见。
      final pendingCenter = tester.getCenter(pendingFinder);
      final persistedCenter = tester.getCenter(persistedFinder);
      expect(pendingCenter.dy, greaterThan(persistedCenter.dy));
    });

    testWidgets('4. 空状态：pendingUserMessage 非空时不显示引导文案', (tester) async {
      final state = IntermediateChatState(
        phase: IntermediatePhase.generating,
        messages: const [],
        retryCounts: const {},
        session: _testSession(),
        pendingUserMessage: _userMessage('首次发送'),
      );

      await tester.pumpWidget(_wrap(_buildBody(state)));

      // pendingUserMessage 非空时不显示空状态引导文案
      expect(find.text('开始你的故事'), findsNothing);
      expect(find.text('输入一句话，让故事展开'), findsNothing);
      // 用户消息渲染
      expect(find.text('首次发送'), findsOneWidget);
    });

    testWidgets('5. failed 阶段 pendingUserMessage 仍保留显示（失败时保留）', (tester) async {
      final state = IntermediateChatState(
        phase: IntermediatePhase.failed,
        messages: const [],
        retryCounts: const {},
        session: _testSession(),
        pendingUserMessage: _userMessage('失败前的消息'),
      );

      await tester.pumpWidget(_wrap(_buildBody(state)));

      // 失败态下用户消息仍可见（DOC-09A-2 §6.5）
      expect(find.text('失败前的消息'), findsOneWidget);
    });

    testWidgets('6. pendingUserMessage 出现时强制滚动到底部（B1-1 修复：解决后续消息不可见）',
        (tester) async {
      // 复现场景：已有大量历史消息使 ListView 可滚动，
      // 初始在顶部（_isNearBottom=false），用户发送消息后 pendingUserMessage 出现。
      // 旧逻辑：hasNewContent=false（messages 没变）→ 不滚动 → pendingUserMessage 不可见。
      //  修复：pendingUserMessageAppeared=true → 强制滚动到底部。
      final historyMessages = <ChatMessage>[];
      for (var i = 0; i < 30; i++) {
        historyMessages.add(
          ChatMessage(
            messageId: 'msg-$i',
            sessionId: 'session-1',
            role: i.isEven ? 'user' : 'assistant',
            content: '历史消息 $i\n这是用于撑高 ListView 的多行内容\n第三行\n第四行\n第五行',
            createdAt: DateTime(2026),
          ),
        );
      }

      // 初始状态：idle + 历史消息
      var state = IntermediateChatState(
        phase: IntermediatePhase.idle,
        messages: historyMessages,
        retryCounts: const {},
        session: _testSession(),
      );

      await tester.pumpWidget(_wrap(_buildBody(state)));
      await tester.pumpAndSettle();

      // SelectableText 内部也有 Scrollable，需精确定位主 ListView 的 Scrollable。
      // 遍历所有 ScrollableState，找到 maxScrollExtent > 0 的那个（即主 ListView）。
      final scrollStates = tester.stateList<ScrollableState>(
        find.byType(Scrollable),
      );
      final scrollPosition = scrollStates
          .firstWhere((s) => s.position.maxScrollExtent > 0)
          .position;

      // 前置条件：ListView 可滚动且初始在顶部
      expect(
        scrollPosition.maxScrollExtent,
        greaterThan(100),
        reason: 'ListView 应可滚动',
      );
      expect(scrollPosition.pixels, 0);

      // 用户发送消息，pendingUserMessage 出现（从 null 变为非 null）
      state = state.copyWith(
        phase: IntermediatePhase.generating,
        pendingUserMessage: _userMessage('新发送的消息'),
      );
      await tester.pumpWidget(_wrap(_buildBody(state)));
      // pump 触发 didUpdateWidget → 执行器强制回底（postFrameCallback）
      // 用 pump(Duration) 推进 postFrame 与 settle 校准（避免 pumpAndSettle 因动画循环超时）
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 150));

      //  修复验证：应已滚动到底部附近（maxScrollExtent - pixels < 150）
      // 旧逻辑（无）：pixels 仍为 0，差值远大于 150 → 测试失败
      // 阈值 150 比 _isNearBottom 的 100 略宽松，容忍 animateTo 收尾误差
      expect(
        scrollPosition.maxScrollExtent - scrollPosition.pixels,
        lessThan(150),
        reason: 'pendingUserMessage 出现后应滚动到底部（B1-1 修复）',
      );
    });

    testWidgets('7. 长故事仅构建可视消息，避免首帧实例化全部 Markdown', (tester) async {
      final messages = List<ChatMessage>.generate(
        200,
        (index) => ChatMessage(
          messageId: 'long-$index',
          sessionId: 'session-1',
          role: index.isEven ? 'user' : 'assistant',
          content: '长故事消息 $index',
          createdAt: DateTime(2026),
        ),
      );
      final state = IntermediateChatState(
        phase: IntermediatePhase.idle,
        messages: messages,
        retryCounts: const {},
        session: _testSession(),
      );

      await tester.pumpWidget(_wrap(_buildBody(state)));
      await tester.pump();

      final builtBubbleCount =
          find.byType(IntermediateMessageBubble).evaluate().length;
      expect(builtBubbleCount, lessThan(30));
      expect(find.text('长故事消息 199'), findsNothing);
    });
  });

  // ── ：手动压缩与消息菜单互斥 ──────────────────────
  //
  // 手动压缩全程 phase 恒为 idle——actionsEnabled 若只看 phase，压缩中
  // 消息动作菜单照常渲染，点击后控制器静默 no-op，用户零反馈。
  group('手动压缩中消息动作菜单锁定', () {
    List<ChatMessage> roundMessages() => [
          ChatMessage(
            messageId: 'u1',
            sessionId: 'session-1',
            role: 'user',
            content: '上一轮输入',
            createdAt: DateTime(2026),
          ),
          ChatMessage(
            messageId: 'a1',
            sessionId: 'session-1',
            role: 'assistant',
            content: '上一轮回复',
            createdAt: DateTime(2026),
          ),
        ];

    testWidgets('压缩挂起中（idle+isManualCompacting）：动作菜单不渲染', (tester) async {
      final state = IntermediateChatState(
        phase: IntermediatePhase.idle,
        isManualCompacting: true,
        messages: roundMessages(),
        retryCounts: const {},
        session: _testSession(),
      );

      await tester.pumpWidget(_wrap(_buildBody(state)));
      await tester.pumpAndSettle();

      expect(find.text('上一轮回复'), findsOneWidget);
      expect(
        find.byType(IntermediateMessageActions),
        findsNothing,
        reason: '压缩中动作菜单应锁定',
      );
    });

    testWidgets('非压缩 idle：动作菜单照常渲染（对照组）', (tester) async {
      final state = IntermediateChatState(
        phase: IntermediatePhase.idle,
        messages: roundMessages(),
        retryCounts: const {},
        session: _testSession(),
      );

      await tester.pumpWidget(_wrap(_buildBody(state)));
      await tester.pumpAndSettle();

      // 末条 assistant 消息动作菜单常驻显示（isLastAssistantMessage）
      expect(find.byType(IntermediateMessageActions), findsOneWidget);
    });
  });

  // ── ：搜索定位目标已归档时回退跳底 ────────────────
  //
  // 全局搜索会索引库内全部消息，命中已被压缩归档的消息是真实可达路径。
  // 此前未命中时既不置 _focusHandled 也不回退，用户停在默认位置，
  // 「点搜索结果毫无反应」。
  group('搜索定位目标不可见时回退跳底', () {
    testWidgets('目标消息不在可见列表（已归档）→ 回退滚动到底部', (tester) async {
      final historyMessages = <ChatMessage>[];
      for (var i = 0; i < 30; i++) {
        historyMessages.add(
          ChatMessage(
            messageId: 'msg-$i',
            sessionId: 'session-1',
            role: i.isEven ? 'user' : 'assistant',
            content: '历史消息 $i\n这是用于撑高 ListView 的多行内容\n第三行\n第四行\n第五行',
            createdAt: DateTime(2026),
          ),
        );
      }
      final state = IntermediateChatState(
        phase: IntermediatePhase.idle,
        messages: historyMessages,
        retryCounts: const {},
        session: _testSession(),
      );

      await tester.pumpWidget(
        _wrap(_buildBody(state, initialFocusMessageId: 'archived-msg')),
      );
      await tester.pumpAndSettle();

      final scrollStates = tester.stateList<ScrollableState>(
        find.byType(Scrollable),
      );
      final scrollPosition = scrollStates
          .firstWhere((s) => s.position.maxScrollExtent > 0)
          .position;
      // 修复前：定位失败静默返回，pixels 恒 0（落在列表顶部）
      expect(
        scrollPosition.maxScrollExtent - scrollPosition.pixels,
        // 阈值取应用自认「在底部」的 50px 容差（见 body 的 _onScroll），
        // 而不是旧值 150：旧值放过了「落在真实底部之上」的回归——
        //  阅读列限宽后气泡变高，惰性列表 maxScrollExtent 的早估偏差
        // 被放大到 226.5px，用户会看到最新一轮被截掉。
        lessThan(50),
        reason: '目标不可见时应回退跳底，而非静默停在默认位置、或停在底部之上',
      );
    });

    testWidgets('目标消息可见 → 正常定位（回归对照）', (tester) async {
      final historyMessages = <ChatMessage>[];
      for (var i = 0; i < 30; i++) {
        historyMessages.add(
          ChatMessage(
            messageId: 'msg-$i',
            sessionId: 'session-1',
            role: i.isEven ? 'user' : 'assistant',
            content: '历史消息 $i\n这是用于撑高 ListView 的多行内容\n第三行\n第四行\n第五行',
            createdAt: DateTime(2026),
          ),
        );
      }
      final state = IntermediateChatState(
        phase: IntermediatePhase.idle,
        messages: historyMessages,
        retryCounts: const {},
        session: _testSession(),
      );

      await tester.pumpWidget(
        _wrap(_buildBody(state, initialFocusMessageId: 'msg-0')),
      );
      await tester.pumpAndSettle();

      // 目标可见：闪示高亮生效（fallthrough 不触发跳底路径）
      final flashContainer = tester.widgetList<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      expect(flashContainer, isNotEmpty);
      expect(
        find.byType(IntermediateMessageBubble),
        findsWidgets,
        reason: '可见目标走正常定位路径',
      );
    });
  });

  testWidgets('轮导航在长稿件中按相邻轮提问定位', (tester) async {
    final session = _testSession();
    final state = IntermediateChatState(
      phase: IntermediatePhase.idle,
      messages: navigationMessages(session.sessionId),
      retryCounts: const {},
      session: session,
    );
    await tester.pumpWidget(_wrap(_buildBody(state)));
    await checkRoundNavigation(tester);
  });

  group('IntermediateChatBody -  轮完成反馈', () {
    List<ChatMessage> history(int count) => List<ChatMessage>.generate(
          count,
          (i) => ChatMessage(
            messageId: 'st9-$i',
            sessionId: 'session-1',
            role: i.isEven ? 'user' : 'assistant',
            content: '历史消息 $i\n多行内容撑高列表\n第三行\n第四行\n第五行',
            createdAt: DateTime(2026),
          ),
        );

    ScrollPosition mainScrollPosition(WidgetTester tester) => tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .firstWhere((s) => s.position.maxScrollExtent > 0)
        .position;

    testWidgets('轮完成时在跟随态（未上划）：贴底且不显示提示胶囊', (tester) async {
      // 初始停在顶部（远离底部），phase=summarizing；轮完成时用户从未
      // 上划，处于跟随态 →  门控：轮完成即时贴底（面板追加
      // 在流式气泡之下造成的远离底部不是用户的阅读位）。
      var state = IntermediateChatState(
        phase: IntermediatePhase.summarizing,
        messages: history(30),
        retryCounts: const {},
        session: _testSession(),
      );
      await tester.pumpWidget(_wrap(_buildBody(state)));
      await tester.pumpAndSettle();

      // 轮完成：phase→idle 且消息数增长（persist 落库 assistant 消息）
      state = state.copyWith(
        phase: IntermediatePhase.idle,
        messages: [
          ...state.messages,
          ChatMessage(
            messageId: 'st9-new',
            sessionId: 'session-1',
            role: 'assistant',
            content: '本轮正文产出',
            createdAt: DateTime(2026),
          ),
        ],
      );
      await tester.pumpWidget(_wrap(_buildBody(state)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 150));

      final position = mainScrollPosition(tester);
      expect(
        position.maxScrollExtent - position.pixels,
        lessThan(150),
        reason: '轮完成且处于跟随态（未上划）应贴底'
            '（summarize/facts 面板追加造成的远离底部不是阅读意图）',
      );
      // 跟随态不显示提示胶囊
      expect(find.text('本轮已完成 · 点按查看'), findsNothing);
    });

    testWidgets('轮完成时在上划阅读位：不拽回且顶部胶囊出现', (tester) async {
      var state = IntermediateChatState(
        phase: IntermediatePhase.summarizing,
        messages: history(30),
        retryCounts: const {},
        session: _testSession(),
      );
      await tester.pumpWidget(_wrap(_buildBody(state)));
      await tester.pumpAndSettle();

      // 先拖到底部（恢复 _lastPixels 基线），再向下拖回历史方向 =
      // pixels 减小且不在底部 → _userScrolledUp=true（阅读历史中）
      final listView = find.byType(ListView).first;
      await tester.drag(listView, const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.drag(listView, const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(
        mainScrollPosition(tester).pixels,
        greaterThan(0),
        reason: '前置条件：应已离开顶部',
      );
      final readingOffset = mainScrollPosition(tester).pixels;

      // 轮完成：不拽回底部，出现顶部轻提示胶囊
      state = state.copyWith(
        phase: IntermediatePhase.idle,
        messages: [
          ...state.messages,
          ChatMessage(
            messageId: 'st9-new',
            sessionId: 'session-1',
            role: 'assistant',
            content: '本轮正文产出',
            createdAt: DateTime(2026),
          ),
        ],
      );
      await tester.pumpWidget(_wrap(_buildBody(state)));
      await tester.pump();

      expect(
        mainScrollPosition(tester).pixels,
        closeTo(readingOffset, 1),
        reason: '上划阅读位不得被轮完成拽回底部',
      );
      expect(
        find.text('本轮已完成 · 点按查看'),
        findsOneWidget,
        reason: '上划阅读中轮完成应显示非打断式提示胶囊',
      );

      // 点按胶囊 → 跳底查看
      await tester.tap(find.text('本轮已完成 · 点按查看'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        mainScrollPosition(tester).maxScrollExtent -
            mainScrollPosition(tester).pixels,
        lessThan(150),
        reason: '点按提示胶囊应跳到底部',
      );
    });
  });

  // ── 贴底跟随状态机（2026-09-10 chatbox smooth-follow-output 语义移植）──
  //
  // 上划即停：任意上划（多帧小步、无需脱离底部容差带）首帧即冻结，
  // 流式增长不拉回；滚回距底 ≤4px 自动恢复跟随，新内容到达后贴底。
  group('IntermediateChatBody - 贴底跟随状态机', () {
    List<ChatMessage> history(int count) => List<ChatMessage>.generate(
          count,
          (i) => ChatMessage(
            messageId: 'sf-$i',
            sessionId: 'session-1',
            role: i.isEven ? 'user' : 'assistant',
            content: '历史消息 $i\n多行内容撑高列表\n第三行\n第四行\n第五行',
            createdAt: DateTime(2026),
          ),
        );

    ScrollPosition mainScrollPosition(WidgetTester tester) => tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .firstWhere((s) => s.position.maxScrollExtent > 0)
        .position;

    /// 进入「发送后流式中」状态：pending 出现强制贴底 + 首段流式内容。
    Future<IntermediateChatState> startStreaming(
      WidgetTester tester,
      IntermediateChatState state,
    ) async {
      final sent = state.copyWith(
        phase: IntermediatePhase.generating,
        pendingUserMessage: _userMessage('状态机测试发送'),
      );
      await tester.pumpWidget(_wrap(_buildBody(sent)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      final streaming = sent.copyWith(streamingGenerated: '流式开头的正文。' * 4);
      await tester.pumpWidget(_wrap(_buildBody(streaming)));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      return streaming;
    }

    testWidgets('慢速上划（多帧小步）首帧即冻结，流式增长不拉回', (tester) async {
      var state = IntermediateChatState(
        phase: IntermediatePhase.idle,
        messages: history(30),
        retryCounts: const {},
        session: _testSession(),
      );
      await tester.pumpWidget(_wrap(_buildBody(state)));
      await tester.pumpAndSettle();
      state = await startStreaming(tester, state);

      final position = mainScrollPosition(tester);
      expect(
        position.maxScrollExtent - position.pixels,
        lessThanOrEqualTo(streamingFollowCushionPx + 1),
        reason: '前置：发送后跟随中，最新一行留在视口内（惰性缓冲允许 ≤ 缓冲的落后）',
      );

      // 模拟慢速上划：2×20px 小步（累计约 40px，留在旧实现的 50px
      // atBottom 容差带内——旧语义不冻结仍会拉回，新语义首帧即冻结）。
      // builder 列表上滚会实体化更早 item 使 maxScrollExtent 收敛下调
      // 并可能钳位 pixels，断言留出余量。
      final followBottom = position.pixels;
      for (var i = 0; i < 2; i++) {
        position.jumpTo(
          (position.pixels - 20).clamp(0, position.maxScrollExtent),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        position.pixels,
        lessThan(followBottom - 10),
        reason: '前置：已慢速上划约 40px（阅读位）',
      );

      // 首帧即冻结：更多流式 delta 不得拉回底部，阅读位置基本静止。
      final readingOffset = position.pixels;
      state = state.copyWith(
        streamingGenerated: '流式开头的正文。' * 4 + '更多流式内容。' * 8,
      );
      await tester.pumpWidget(_wrap(_buildBody(state)));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        (position.pixels - readingOffset).abs(),
        lessThan(80),
        reason: '慢速上划首帧即冻结（不需脱离底部容差带）：阅读位置应静止',
      );
      expect(
        position.maxScrollExtent - position.pixels,
        greaterThan(4),
        reason: '距底远超 48px 恢复带：流式增长不得拉回',
      );
    });

    testWidgets('冻结后滚回底部自动恢复跟随（新内容到达后贴底）', (tester) async {
      var state = IntermediateChatState(
        phase: IntermediatePhase.idle,
        messages: history(30),
        retryCounts: const {},
        session: _testSession(),
      );
      await tester.pumpWidget(_wrap(_buildBody(state)));
      await tester.pumpAndSettle();
      state = await startStreaming(tester, state);
      final position = mainScrollPosition(tester);

      // 冻结：一次大幅上划脱离底部
      position.jumpTo(
        (position.maxScrollExtent - 400).clamp(0, position.maxScrollExtent),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        position.pixels,
        lessThan(position.maxScrollExtent - 100),
        reason: '前置：已上划冻结于阅读位',
      );

      // 向下滚回底部（距底 0 在 48px 恢复带内）→ 自动恢复跟随
      position.jumpTo(position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 100));

      // 新内容多 delta 到达（真实流式逐帧增长，每个 delta 重新贴底；
      // 懒加载列表的 maxScrollExtent 在远端内容布局后修正）：
      // 恢复跟随后应贴底。
      final base = '流式开头的正文。' * 4;
      for (var i = 1; i <= 3; i++) {
        state = state.copyWith(
          streamingGenerated: '$base${'后续内容。' * (4 * i)}',
        );
        await tester.pumpWidget(_wrap(_buildBody(state)));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        position.pixels,
        closeTo(position.maxScrollExtent, 8),
        reason: '滚回距底 ≤4px 应自动恢复贴底跟随',
      );
    });
  });
}
