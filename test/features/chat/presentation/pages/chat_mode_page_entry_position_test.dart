import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/di/providers.dart'
    show apiPresetRepositoryProvider, settingsRepositoryProvider;
import 'package:lmstory/core/di/providers.dart' as di
    show templateRepositoryProvider;
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_message_bubble.dart';
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
import 'package:lmstory/features/chat/presentation/utils/scroll_position_cache.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../test_helpers/stub_failure_log_repository.dart';

/// ChatModePage 进入会话初始定位/后台分支呈现 页面级测试
///
/// 现有页面测试全部「新建容器 + overrideWith 新 controller」，永远走
/// listen 的「空→非空」跃迁——缓存控制器（非 autoDispose family）+
/// fresh-mount（HomePage↔ChatModePage 不同 runtimeType 同位替换、State
/// 全新）这条生产路径零覆盖（测试盲区）：
/// 1. ：缓存控制器 fresh-mount 必须三选一定位（深链 > 恢复缓存 > 贴底）
/// 2. ：陈旧深链 id（不在当前会话）不得吞掉恢复缓存/贴底
/// 3. ：后台分支生成中——尾部无误导「生成中」占位气泡 + 输入区
///    上方轻量指示
/// 4. ：流式中手动压缩菜单禁用；忙态重生成给 floating SnackBar
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  final session = ChatSession(
    sessionId: 'entry-session',
    title: '进入定位测试',
    mode: 'chat',
    createdAt: DateTime(2026),
    lastActiveAt: DateTime(2026),
    messageCount: 0,
    presetId: 'p1',
    modelId: 'm1',
  );

  late _EntryChatRepository repo;
  late _ScriptedLlmService llmService;
  late StreamController<LlmStreamEvent> events;

  setUp(() {
    repo = _EntryChatRepository();
    llmService = _ScriptedLlmService();
    events = StreamController<LlmStreamEvent>();
    llmService.stream = events.stream;
  });

  tearDown(() {
    // 不 await：controller 的流订阅未取消时 close() 完成时机不确定，
    // 会挂起 teardown（同 chat_mode_controller_interrupt_test 的处理）
    unawaited(events.close());
  });

  Future<ProviderContainer> warmContainer(WidgetTester tester) async {
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
            streamDeltaCoalesceInterval: Duration.zero,
          );
        }),
        settingsRepositoryProvider.overrideWithValue(
          _FakeSettingsRepository(),
        ),
        apiPresetRepositoryProvider.overrideWithValue(
          _NoopPresetRepository(),
        ),
        di.templateRepositoryProvider.overrideWithValue(
          _NoopTemplateRepository(),
        ),
      ],
    )
      // 模拟「会话曾打开过」：provider 非 autoDispose，read 即创建并长存，
      // 再 fresh-mount 页面——controller 复用、State 全新。testWidgets 处于
      // fake-async zone，Future.delayed 不自走——用 tester.pump 驱动控制器
      // 构造触发的异步消息加载。
      ..read(chatModeControllerProvider(session));
    for (var i = 0;
        i < 20 &&
            (c.read(chatModeControllerProvider(session)).isLoading ||
                c.read(chatModeControllerProvider(session)).messages.isEmpty);
        i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      c.read(chatModeControllerProvider(session)).messages,
      isNotEmpty,
      reason: '预热失败：控制器未完成消息加载',
    );
    return c;
  }

  Future<void> pumpFresh(
    WidgetTester tester,
    ProviderContainer c, {
    String? focusMessageId,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: TranslationProvider(
          child: MaterialApp(
            home: SizedBox(
              width: 800,
              height: 600,
              child: ExcludeSemantics(
                child: ChatModePage(
                  session: session,
                  initialFocusMessageId: focusMessageId,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // 等首帧 postFrame 定位 + 贴底收敛（定时 pump：常驻动画禁 pumpAndSettle）
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  final primaryScrollableFinder = find
      .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
      .first;

  ScrollPosition positionOf(WidgetTester tester) =>
      tester.state<ScrollableState>(primaryScrollableFinder).position;

  testWidgets('缓存控制器 fresh-mount 无缓存时贴底（此前停在顶部）', (
    tester,
  ) async {
    final c = await warmContainer(tester);
    addTearDown(c.dispose);
    await pumpFresh(tester, c);

    final position = positionOf(tester);
    expect(position.maxScrollExtent, greaterThan(0), reason: '种子消息须撑出滚动高度');
    expect(
      position.pixels,
      position.maxScrollExtent,
      reason: 'fresh-mount 必须贴底显示最新消息（此前停在 offset 0）',
    );
  });

  testWidgets('缓存控制器 fresh-mount 有缓存时恢复上次位置', (tester) async {
    final c = await warmContainer(tester);
    addTearDown(c.dispose);
    // 取小值：懒加载列表首帧 maxScrollExtent 可能尚未撑满，跳偏移按
    // 当帧 max 收敛，20.0 必在范围内
    const cachedOffset = 20.0;
    c.read(scrollPositionCacheProvider).save(session.sessionId, cachedOffset);
    await pumpFresh(tester, c);

    expect(
      positionOf(tester).pixels,
      cachedOffset,
      reason: 'fresh-mount 必须恢复缓存的阅读位置（此前停在 offset 0）',
    );
  });

  testWidgets('陈旧深链 id 不在当前会话时回落恢复缓存（此前被吞）', (
    tester,
  ) async {
    final c = await warmContainer(tester);
    addTearDown(c.dispose);
    const cachedOffset = 30.0;
    c.read(scrollPositionCacheProvider).save(session.sessionId, cachedOffset);
    // 模拟 main_layout 深链后返回再进 Y 会话：_focusMessageId 残留 X 的
    // 消息 id，不属于当前会话
    await pumpFresh(tester, c, focusMessageId: 'ghost-from-session-x');

    expect(
      positionOf(tester).pixels,
      cachedOffset,
      reason: '焦点 id 不在当前会话时必须回落「恢复缓存>贴底」，不得深链早返回吞掉定位',
    );
  });

  testWidgets('后台分支生成中——无误导占位气泡 + 输入区上方轻指示', (
    tester,
  ) async {
    final c = await warmContainer(tester);
    addTearDown(c.dispose);
    await pumpFresh(tester, c);

    final controller = c.read(chatModeControllerProvider(session).notifier);
    unawaited(controller.sendMessage('再来一轮'));
    events.add(const LlmTextDelta('前台流式内容'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    // 前台流式：流式气泡可见（delta 已到，占位已物化为真实气泡）
    expect(
      find.byWidgetPredicate(
        (w) => w is SimpleMessageBubble && w.isStreaming,
      ),
      findsOneWidget,
      reason: '前台流式应显示流式气泡',
    );

    // 流式中切看旧分支 → 后台模式
    await controller.switchFork('u7', ForkSwitchDirection.next);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byKey(const ValueKey('__generating_placeholder__')),
      findsNothing,
      reason: '后台分支生成中被查看分支尾部不得渲染「生成中」占位气泡',
    );
    expect(
      find.text(t.chat.backgroundGenerating),
      findsOneWidget,
      reason: '输入区上方应以轻量指示告知后台生成',
    );
  });

  testWidgets('流式中手动压缩菜单禁用 + 忙态重生成给 floating SnackBar', (
    tester,
  ) async {
    final c = await warmContainer(tester);
    addTearDown(c.dispose);
    await pumpFresh(tester, c);

    final controller = c.read(chatModeControllerProvider(session).notifier);
    unawaited(controller.sendMessage('再来一轮'));
    events.add(const LlmTextDelta('流式内容'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      c.read(chatModeControllerProvider(session)).isStreaming,
      isTrue,
      reason: '前置：流式进行中',
    );

    // 手动压缩菜单项必须禁用（enabled 此前只查 isCompressing）
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump(const Duration(milliseconds: 300));
    ListTile? compressTile;
    for (final element in find
        .descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(ListTile),
        )
        .evaluate()) {
      final tile = element.widget as ListTile;
      final title = tile.title;
      if (title is Text && title.data == t.chat.compaction.manualTrigger) {
        compressTile = tile;
        break;
      }
    }
    expect(compressTile, isNotNull, reason: '前置：找到手动压缩菜单项');
    expect(compressTile!.enabled, isFalse, reason: '流式中手动压缩须禁用');

    // 关闭菜单（点击半透明屏障），再验证忙态重生成反馈
    await tester.tapAt(const Offset(400, 50));
    await tester.pump(const Duration(milliseconds: 300));

    //  hover 唤出操作条（消息行级 MouseRegion，同时验证新接线）：
    // 鼠标悬停最后一条非流式助手气泡（.last=最靠近底部、必然在视口内）
    final assistantBubble = find
        .byWidgetPredicate(
          (w) =>
              w is SimpleMessageBubble &&
              w.message.role == 'assistant' &&
              !w.isStreaming,
        )
        .last;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(assistantBubble));
    await tester.pump(const Duration(milliseconds: 100));

    // 重生成按钮锚定 _ActionButton 祖先——裸 byIcon 会误中流式头像的
    // 旋转图标（Icons.refresh_rounded，size 18）
    final regenerateButton = find.ancestor(
      of: find.byIcon(Icons.refresh_rounded),
      matching: find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_ActionButton',
      ),
    );
    expect(
      regenerateButton,
      findsOneWidget,
      reason: '前置：hover 消息行后重生成按钮可见',
    );
    await tester.tap(regenerateButton);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.text(t.chat.failure.busyOperation),
      findsOneWidget,
      reason: '忙态重生成此前静默 no-op，必须给 SnackBar 反馈',
    );
    await mouse.removePointer();
  });
}

CompactionService _compactionService() => CompactionService(
      chatRepository: _EntryChatRepository(),
      tokenCounter: TokenCounter(),
      settingsRepository: _FakeSettingsRepository(),
      presetRepository: _NoopPresetRepository(),
      streamer: CompactionStreamer(llmService: _NoopLlmService()),
      llmService: _NoopLlmService(),
    );

class _EntryChatRepository implements ChatRepository {
  _EntryChatRepository() {
    // 短消息 ×40 轮：既撑出可滚动高度（定位用例），又保证气泡完整
    // 可见可点（忙态反馈用例；长消息会被视口裁剪、点击中心落空）
    for (var i = 0; i < 40; i++) {
      messages
        ..add(
          ChatMessage(
            messageId: 'u$i',
            sessionId: 'entry-session',
            role: 'user',
            content: '用户消息 $i',
            createdAt: DateTime(2026, 1, 1, 1, i),
          ),
        )
        ..add(
          ChatMessage(
            messageId: 'a$i',
            sessionId: 'entry-session',
            role: 'assistant',
            content: '助手回复 $i',
            parentUserMsgId: 'u$i',
            createdAt: DateTime(2026, 1, 1, 1, i, 30),
          ),
        );
    }
  }

  final List<ChatMessage> messages = [];

  /// u7 锚点预置两分支：流式中 switchFork('u7') 走后台模式 + 普通切换
  List<ForkAnchor> forkAnchors = const [
    ForkAnchor(parentUserMsgId: 'u7', activeIndex: 0, branchCount: 2),
  ];

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async =>
      List.of(messages);

  @override
  Future<ChatMessage> addMessage(ChatMessage message) async {
    messages.add(message);
    return message;
  }

  @override
  Future<List<ForkAnchor>> getForkAnchors(String sessionId) async =>
      forkAnchors;

  @override
  Future<List<ChatMessage>> switchForkBranchWithSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required int newActiveIndex,
    required List<ChatMessage> currentTailMessages,
  }) async =>
      // 切到旧分支：只展示锚点前的历史 + 旧分支回复
      [
        ...messages
            .where((m) => m.messageId != 'u7' && m.messageId != 'a7')
            .where((m) => !(m.content ?? '').contains('再来一轮')),
        ChatMessage(
          messageId: 'old-branch-reply',
          sessionId: sessionId,
          role: 'assistant',
          content: '旧分支的回复',
          parentUserMsgId: 'u7',
          createdAt: DateTime(2026, 1, 1, 2),
        ),
      ];

  @override
  Future<bool> appendMessageToBranchSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required int branchIndex,
    required ChatMessage message,
  }) async =>
      true;

  @override
  Future<ChatSession> updateSession(ChatSession session) async => session;

  @override
  Future<void> updateSessionLastActive(String sessionId) async {}

  @override
  Future<void> updateSessionMessageCount(String sessionId, int count) async {}

  @override
  Future<int> getMessageCount(String sessionId) async => messages.length;

  @override
  Future<int> updateMessageError(String messageId, String? error) async =>
      messages.any((m) => m.messageId == messageId) ? 1 : 0;

  @override
  Future<void> deleteMessage(String messageId) async {
    messages.removeWhere((m) => m.messageId == messageId);
  }

  @override
  Future<List<Map<String, dynamic>>> getCompactionPoints(String sessionId) =>
      Future.value(const []);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _ScriptedLlmService implements LlmService {
  Stream<LlmStreamEvent>? stream;

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) => stream!;

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
        broadcastChat: BroadcastChatConfig(
          presetId: 'preset-test',
          modelId: 'model-test',
          // 定位/呈现用例关闭自动压缩：压缩预检的真实 token 计数在
          // widget 测试环境不可用（tiktoken 资产加载挂起）
          autoCompaction: false,
        ),
      );

  @override
  Future<String?> getApiKey(String presetId) async => 'test-key';

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
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopTemplateRepository implements TemplateRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
