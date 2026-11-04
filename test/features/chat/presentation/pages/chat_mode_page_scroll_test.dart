import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/di/providers.dart'
    show apiPresetRepositoryProvider, settingsRepositoryProvider;
import 'package:lmstory/core/di/providers.dart' as di
    show templateRepositoryProvider;
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/fork_anchor.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/compaction_service.dart';
import 'package:lmstory/features/chat/domain/services/compaction_streamer.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/chat/presentation/controllers/chat_mode_controller.dart';
import 'package:lmstory/features/chat/presentation/pages/chat/chat_mode_page.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../test_helpers/stub_failure_log_repository.dart';

/// ChatModePage 滚动语义 widget 测试
///
/// 普通方向列表贴底跟随（2026-09-10 起 chatbox smooth-follow-output 语义）：
/// 1. 首帧对齐贴底（进入已有会话直接显示最新消息）
/// 2. 上划即停——任意上划首帧即冻结（不需脱离 80px 容差带），阅读态不被
///    流式更新拉回底部
/// 3. 滚回距底 ≤48px 恢复带自动恢复跟随（：max(4, cushion)）；向下滚
///    但距底超出 48px 恢复带不恢复
/// 4. 内容收缩（maxScrollExtent 下降伴随 pixels 钳位下降）不误冻结
/// 5. 发送新消息/点「回到最新」胶囊强制回底恢复跟随
void main() {
  // slang 初始化为中文（保证 Translations.of(context) 返回中文文案）
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  late _SeededChatRepository repo;
  late _ScriptedLlmService llmService;
  late StreamController<LlmStreamEvent> events;
  final session = ChatSession(
    sessionId: 'scroll-session',
    title: '滚动测试',
    mode: 'chat',
    createdAt: DateTime(2026),
    lastActiveAt: DateTime(2026),
    messageCount: 0,
    // 会话级供应商/模型（_resolveSettings 优先读会话字段，缺失走 S001）
    presetId: 'p1',
    modelId: 'm1',
  );

  setUp(() {
    repo = _SeededChatRepository();
    llmService = _ScriptedLlmService();
    events = StreamController<LlmStreamEvent>();
    llmService.stream = events.stream;
  });

  tearDown(() {
    // 不 await：controller 的流订阅未取消时 close() 完成时机不确定，
    // 会挂起 teardown（同 chat_mode_controller_interrupt_test 的处理）
    unawaited(events.close());
  });

  ProviderContainer? container;

  Future<void> pumpPage(WidgetTester tester) async {
    final c = ProviderContainer(
      overrides: [
        chatModeControllerProvider(session).overrideWith((ref) {
          return ChatModeController(
            chatRepository: repo,
            presetRepository: _NoopPresetRepository(),
            settingsRepository: _FakeSettingsRepository(),
            compactionService: _compactionService(),
            llmService: llmService,
            logger: const Logger('test'),
            failureLogRepository: const StubFailureLogRepository(),
            session: session,
            // widget 测试直接驱动真实定时器节奏，零间隔保证 delta 即时可见
            streamDeltaCoalesceInterval: Duration.zero,
          );
        }),
        settingsRepositoryProvider.overrideWithValue(
          _FakeSettingsRepository(),
        ),
        // 页面 watch settingsNotifierProvider，其构造链会读
        // template/preset 仓库——空桩避免真实数据库/资产加载
        apiPresetRepositoryProvider.overrideWithValue(
          _NoopPresetRepository(),
        ),
        di.templateRepositoryProvider.overrideWithValue(
          _NoopTemplateRepository(),
        ),
      ],
    );
    addTearDown(c.dispose);
    container = c;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: TranslationProvider(
          child: MaterialApp(
            home: SizedBox(
              // 800px 宽：给模型选择芯片等 Flexible 控件留足空间，避免
              // 窄视口溢出噪声干扰滚动语义断言
              width: 800,
              height: 600,
              // 排除语义层：可选择的 Markdown + 流式增长在伪时钟下的
              // semantics 断言属框架内部噪声，与滚动语义无关
              child: ExcludeSemantics(child: ChatModePage(session: session)),
            ),
          ),
        ),
      ),
    );
    // 等待消息加载 + 首帧对齐 + 收敛校准（定时 pump：页面存在常驻
    // 动画/帧回调时 pumpAndSettle 有永不 settle 的风险）
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// 消息列表的主 Scrollable（气泡内可能有嵌套滚动体，取第一个）
  final primaryScrollableFinder = find
      .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
      .first;

  ScrollableState scrollable(WidgetTester tester) =>
      tester.stateList<ScrollableState>(primaryScrollableFinder).first;

  /// 胶囊可见性：AnimatedOpacity 的目标 opacity（胶囊常驻树，靠透明度
  /// 显隐——Text 查找器无法区分可见态）。
  double pillOpacity(WidgetTester tester) {
    final textFinder = find.text(t.chat.scrollToLatest);
    final opacity = tester.widget<AnimatedOpacity>(
      find.ancestor(of: textFinder, matching: find.byType(AnimatedOpacity)),
    );
    return opacity.opacity;
  }

  /// 发送消息并等到流式贴底跟随就绪（首条 delta 已贴底）。
  Future<void> startStreamingAtBottom(WidgetTester tester) async {
    unawaited(
      container!
          .read(chatModeControllerProvider(session).notifier)
          .sendMessage('继续写'),
    );
    await tester.pump(const Duration(milliseconds: 400));
    events.add(const LlmTextDelta('回复开头'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// 收尾流：终结生成态动画/流式回调，并冲刷 pending timers
  /// （空闲 2s / token 防抖 500ms）。
  Future<void> finishStream(WidgetTester tester) async {
    events.add(const LlmStreamDone());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('首帧贴底：进入已有会话直接显示最新消息', (tester) async {
    await pumpPage(tester);

    final position = scrollable(tester).position;
    expect(position.maxScrollExtent, greaterThan(0), reason: '消息足够多可滚动');
    expect(
      position.pixels,
      closeTo(position.maxScrollExtent, 1),
      reason: '普通方向列表首帧须跳底并收敛（reverse 列表曾免费获得此初值）',
    );

    await finishStream(tester);
  });

  testWidgets('发送进入流式后贴底跟随', (tester) async {
    await pumpPage(tester);
    final position = scrollable(tester).position;

    await startStreamingAtBottom(tester);
    expect(
      position.pixels,
      closeTo(position.maxScrollExtent, 8),
      reason: '贴底跟随中：流式更新应保持贴底',
    );

    await finishStream(tester);
  });

  testWidgets('慢速上划（每帧 -25px）首帧即冻结，流式更新不拉回', (tester) async {
    await pumpPage(tester);
    final position = scrollable(tester).position;
    await startStreamingAtBottom(tester);
    expect(
      position.pixels,
      closeTo(position.maxScrollExtent, 8),
      reason: '前置：贴底跟随中',
    );

    // 模拟用户慢速上划：多帧小步 jumpTo（同样触发 controller 监听，
    // 与手势来源无关），累计约 75px 仍留在 80px 胶囊容差带内。
    final followBottom = position.pixels;
    for (var i = 0; i < 3; i++) {
      position
          .jumpTo((position.pixels - 25).clamp(0, position.maxScrollExtent));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final readingOffset = position.pixels;
    expect(
      readingOffset,
      lessThan(followBottom - 60),
      reason: '前置：已慢速上划约 75px（未脱离 80px 容差带）',
    );

    // 冻结：更多流式 delta 不得拉回底部，阅读位置基本静止。
    for (var i = 0; i < 5; i++) {
      events.add(const LlmTextDelta('更多的流式内容……'));
      await tester.pump(const Duration(milliseconds: 120));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      (position.pixels - readingOffset).abs(),
      lessThan(80),
      reason: '上划即停（不需要脱离 80px 容差带）：阅读位置应基本静止',
    );
    expect(
      position.maxScrollExtent - position.pixels,
      greaterThan(4),
      reason: '距底远超 4px 恢复线：流式更新不得把视口拉回底部',
    );

    await finishStream(tester);
  });

  testWidgets('冻结后向下滚回底部自动恢复跟随（新 delta 到达后贴底）', (tester) async {
    await pumpPage(tester);
    final position = scrollable(tester).position;
    await startStreamingAtBottom(tester);

    // 冻结：一次大幅上划脱离容差带（新老语义都冻结）
    position.jumpTo(
      (position.maxScrollExtent - 400).clamp(0, position.maxScrollExtent),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      position.pixels,
      lessThan(position.maxScrollExtent - 100),
      reason: '前置：已上滚冻结于阅读位置',
    );

    // 向下滚回底部（距底 0 ≤ 4px 恢复线）→ 自动恢复跟随
    position.jumpTo(position.maxScrollExtent);
    await tester.pump(const Duration(milliseconds: 100));

    for (var i = 0; i < 3; i++) {
      events.add(const LlmTextDelta('后续内容……'));
      await tester.pump(const Duration(milliseconds: 120));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      position.pixels,
      closeTo(position.maxScrollExtent, 8),
      reason: '滚回距底 ≤4px 应自动恢复贴底跟随',
    );

    await finishStream(tester);
  });

  testWidgets('向下滚但距底超出 48px 恢复带不恢复跟随', (tester) async {
    await pumpPage(tester);
    final position = scrollable(tester).position;
    await startStreamingAtBottom(tester);

    // 冻结：大幅上划脱离容差带
    position.jumpTo(
      (position.maxScrollExtent - 400).clamp(0, position.maxScrollExtent),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // 向下滚但停在距底 60px（后恢复带 = max(4, cushion=48)px，60px 在
    // 带外、仍在 80px 胶囊容差内）。builder 列表向上滚动会实体化更早的
    // item、maxScrollExtent 估算随之收敛（可能变小把越界 pixels 钳位），
    // 跳一次、收敛一拍后再锚定。
    for (var i = 0; i < 2; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      position.jumpTo(
        (position.maxScrollExtent - 60).clamp(0, position.maxScrollExtent),
      );
    }
    await tester.pump(const Duration(milliseconds: 100));
    final anchor = position.pixels;
    expect(
      position.maxScrollExtent - anchor,
      allOf(greaterThan(48), lessThan(80)),
      reason: '前置：距底约 60px（>48px 恢复带、<80px 胶囊容差）',
    );

    for (var i = 0; i < 5; i++) {
      events.add(const LlmTextDelta('后续内容：这是一段新的流式正文。'));
      await tester.pump(const Duration(milliseconds: 120));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      (position.pixels - anchor).abs(),
      lessThan(80),
      reason: '距底 60px > 48px 恢复带：不恢复跟随，不得拉回',
    );
    expect(
      position.maxScrollExtent - position.pixels,
      greaterThan(48),
      reason: '距底应保持在恢复带之外',
    );

    await finishStream(tester);
  });

  testWidgets('贴底态内容收缩（pixels 钳位下降）不误冻结跟随', (tester) async {
    await pumpPage(tester);
    final position = scrollable(tester).position;
    expect(
      position.pixels,
      closeTo(position.maxScrollExtent, 1),
      reason: '前置：贴底态',
    );

    // 内容收缩：把最后一条助手消息换成短文本 → maxScrollExtent 下降，
    // 贴底视口 pixels 被钳位同步下降（负 pixelsDelta + 负 maxExtentDelta）。
    await container!
        .read(chatModeControllerProvider(session).notifier)
        .editMessageContent('a7', '短回复');
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      position.pixels,
      closeTo(position.maxScrollExtent, 1),
      reason: '收缩后视口仍钳位在底部',
    );

    // 收缩不是用户上划：跟随不得被误冻结，新 delta 到达仍贴底。
    await startStreamingAtBottom(tester);
    expect(
      position.pixels,
      closeTo(position.maxScrollExtent, 8),
      reason: '内容收缩不得误冻结贴底跟随',
    );

    await finishStream(tester);
  });

  testWidgets('阅读态冻结时发送新消息强制回底恢复跟随', (tester) async {
    await pumpPage(tester);
    final position = scrollable(tester).position;

    // 冻结：大幅上划脱离容差带
    position.jumpTo(
      (position.maxScrollExtent - 400).clamp(0, position.maxScrollExtent),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // 发送 = 用户意图明确看最新：强制回底并恢复跟随（绕过阅读态判定）
    await startStreamingAtBottom(tester);
    expect(
      position.pixels,
      closeTo(position.maxScrollExtent, 8),
      reason: '发送新消息应强制回底并恢复贴底跟随',
    );

    await finishStream(tester);
  });

  testWidgets('「回到最新」胶囊：脱离底部浮现，点击回底并恢复跟随', (tester) async {
    await pumpPage(tester);
    final position = scrollable(tester).position;
    await startStreamingAtBottom(tester);

    // 上滚脱离容差带 → 冻结 + 胶囊浮现
    final bottom = position.maxScrollExtent;
    position.jumpTo((bottom - 400).clamp(0, bottom));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      position.pixels,
      lessThan(bottom - 100),
      reason: '前置：已上滚脱离底部',
    );
    final readingOffset = position.pixels;

    // 冻结：更多流式 delta 不拉回底部
    events.add(const LlmTextDelta('冻结期流式内容……'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      position.pixels,
      lessThan(bottom + 50),
      reason: '阅读态冻结：流式更新不得把用户拉回底部',
    );
    expect(
      (position.pixels - readingOffset).abs(),
      lessThan(80),
      reason: '普通方向列表尾部增长发生在视口外，阅读位置应基本静止',
    );

    // 胶囊浮现（常驻树、AnimatedOpacity 显隐）
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      pillOpacity(tester),
      1.0,
      reason: '生成中上滚脱离底部应显示「回到最新」胶囊',
    );

    // 点击胶囊 → 回底 + 恢复跟随
    await tester.tap(find.text(t.chat.scrollToLatest));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      position.pixels,
      closeTo(position.maxScrollExtent, 8),
      reason: '点击「回到最新」应回到底部',
    );

    // 恢复跟随：新 delta 继续贴底
    for (var i = 0; i < 3; i++) {
      events.add(const LlmTextDelta('后续内容……'));
      await tester.pump(const Duration(milliseconds: 120));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      position.pixels,
      closeTo(position.maxScrollExtent, 8),
      reason: '回底后应恢复贴底跟随',
    );

    await finishStream(tester);
  });
}

CompactionService _compactionService() => CompactionService(
      chatRepository: _SeededChatRepository(),
      tokenCounter: TokenCounter(),
      settingsRepository: _FakeSettingsRepository(),
      presetRepository: _NoopPresetRepository(),
      streamer: CompactionStreamer(llmService: _NoopLlmService()),
      llmService: _NoopLlmService(),
    );

/// 预置 8 轮长对话（足够撑出可滚动高度）
class _SeededChatRepository implements ChatRepository {
  _SeededChatRepository() {
    for (var i = 0; i < 8; i++) {
      messages
        ..add(
          ChatMessage(
            messageId: 'u$i',
            sessionId: 'scroll-session',
            role: 'user',
            content: '用户消息 $i：${'这是一段较长的用户输入内容。' * 6}',
            createdAt: DateTime(2026, 1, 1, 1, i),
          ),
        )
        ..add(
          ChatMessage(
            messageId: 'a$i',
            sessionId: 'scroll-session',
            role: 'assistant',
            content: '助手回复 $i：${'这是一段较长的助手回复正文内容。' * 6}',
            createdAt: DateTime(2026, 1, 1, 1, i, 30),
          ),
        );
    }
  }

  final List<ChatMessage> messages = [];
  final List<ChatMessage> addMessageCalls = [];

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async =>
      List.of(messages);

  @override
  Future<ChatMessage> addMessage(ChatMessage message) async {
    addMessageCalls.add(message);
    messages.add(message);
    return message;
  }

  @override
  Future<ChatSession> createSession({
    required String title,
    String mode = 'chat',
    String? modelId,
    String? presetId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<ChatSession> getSession(String sessionId) async =>
      throw UnimplementedError();

  @override
  Future<ChatSession> updateSession(ChatSession session) async => session;

  @override
  Future<int> getMessageCount(String sessionId) async => messages.length;

  @override
  Future<void> updateSessionMessageCount(String sessionId, int count) async {}

  @override
  Future<void> updateSessionLastActive(String sessionId) async {}

  @override
  Future<void> deleteSession(String sessionId) async {}

  @override
  Future<void> deleteAllSessions() async {}

  @override
  Future<void> recreateConversationTables() async {}

  @override
  Future<void> deleteMessage(String messageId) async {
    messages.removeWhere((m) => m.messageId == messageId);
  }

  @override
  Future<void> updateMessageContent(String messageId, String content) async {
    final i = messages.indexWhere((m) => m.messageId == messageId);
    if (i >= 0) messages[i] = messages[i].copyWith(content: content);
  }

  @override
  Future<List<ForkAnchor>> getForkAnchors(String sessionId) async => [];

  @override
  Future<void> updateMessageTokensUsed(
    String messageId,
    int? tokensUsed,
  ) async {}

  @override
  Future<int> updateMessageError(String messageId, String? error) async => 0;

  @override
  Future<void> addCompactionPoint({
    required String sessionId,
    required String summaryMessageId,
    required String boundaryMessageId,
    required DateTime createdAt,
  }) async {}

  @override
  Future<List<Map<String, dynamic>>> getCompactionPoints(
    String sessionId,
  ) async =>
      [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _ScriptedLlmService implements LlmService {
  Stream<LlmStreamEvent>? stream;

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) => stream!;

  @override
  Future<LlmResponse> chat(LlmRequest request) async =>
      throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopLlmService implements LlmService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeSettingsRepository implements SettingsRepository {
  @override
  Future<AppConfig> getResolvedConfig() async => const AppConfig(
        version: 'test',
        // 滚动语义用例关闭自动压缩：压缩预检会对 16 条种子消息做真实
        // token 计数（tiktoken 资产加载在 widget 测试环境不可用会挂起）
        broadcastChat: BroadcastChatConfig(
          presetId: 'preset-test',
          modelId: 'model-test',
          autoCompaction: false,
        ),
      );

  @override
  Future<Map<String, dynamic>> getUserOverrides() async => const {};

  @override
  Future<void> setUserOverride(String key, dynamic value) async {}

  @override
  Future<void> clearAllUserOverrides() async {}

  @override
  Future<String?> getApiKey(String presetId) async => 'test-key';

  @override
  Future<void> saveApiKey(String presetId, String apiKey) async {}

  @override
  Future<int> getUserOverrideCount() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopTemplateRepository implements TemplateRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopPresetRepository implements ApiPresetRepository {
  @override
  Future<ApiPreset> getPreset(String presetId) async => ApiPreset(
        presetId: presetId,
        name: 'Test Provider',
        baseUrl: 'https://api.test.com/v1',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  @override
  Future<List<ApiPreset>> getAllPresets() async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
