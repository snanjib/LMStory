import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/di/providers.dart'
    show
        apiPresetRepositoryProvider,
        settingsRepositoryProvider,
        templateRepositoryProvider;
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
import 'package:lmstory/features/story_runtime/presentation/widgets/context_usage_ring.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../test_helpers/stub_failure_log_repository.dart';

/// chat 模式上下文用量圆环——三模式体验一致的验收面。
///
/// 1. 圆环 chip 出现在输入区工具栏，替换旧文本徽章；数据同源：
///    numerator = 最近一次落库 tokensUsed（+草稿输入），
///    denominator = chat 压缩触发线（availableWindow × 阈值）
/// 2. 点开与故事/导演同款 ContextUsageDetailSheet
/// 3. 手动压缩入口可达，复用 CompressResult 分态（insufficient 专属文案）
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  final session = ChatSession(
    sessionId: 'ring-session',
    title: '圆环测试',
    mode: 'chat',
    createdAt: DateTime(2026),
    lastActiveAt: DateTime(2026),
    messageCount: 1,
    presetId: 'p1',
    modelId: 'm1',
  );

  late _RingChatRepository repo;

  setUp(() {
    repo = _RingChatRepository();
  });

  Future<ProviderContainer> pumpPage(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        chatModeControllerProvider(session).overrideWith((ref) {
          return ChatModeController(
            chatRepository: repo,
            presetRepository: _RingPresetRepository(),
            settingsRepository: _RingSettingsRepository(),
            compactionService: _compactionService(),
            llmService: _NoopLlmService(),
            logger: const Logger('test'),
            failureLogRepository: const StubFailureLogRepository(),
            session: session,
          );
        }),
        settingsRepositoryProvider.overrideWithValue(
          _RingSettingsRepository(),
        ),
        apiPresetRepositoryProvider.overrideWithValue(
          _RingPresetRepository(),
        ),
        templateRepositoryProvider.overrideWithValue(
          _NoopTemplateRepository(),
        ),
      ],
    );
    addTearDown(container.dispose);
    // 详情面板内容（用量主区+三组键值行+压缩按钮）超 600px 默认视口，
    // 拉高窗口让「立即压缩」按钮无需滚动即可命中
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            home: ExcludeSemantics(child: ChatModePage(session: session)),
          ),
        ),
      ),
    );
    // 消息加载 + 显示信息解析（异步 resolveModelDisplayInfo 收敛）
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    return container;
  }

  testWidgets('圆环出现在输入区工具栏，数字与旧徽章同源', (tester) async {
    await pumpPage(tester);

    final state = tester.state<State>(find.byType(ChatModePage));
    expect(state, isNotNull); // 页面存活（consumer 容器同页）

    final chip = tester.widget<ContextUsageChip>(
      find.byType(ContextUsageChip),
    );
    // 落库 tokensUsed = 48000（唯一一条带 usage 的消息）+ 草稿 0
    expect(chip.numerator, 48000, reason: 'numerator 走旧徽章取数路径');
    // 128000 窗口 × 0.6 阈值：max(96000, 64000) × 0.6 = 57600
    expect(chip.denominator, 57600, reason: 'denominator = chat 压缩触发线');

    // 旧文本徽章不再存在（同一信息只有圆环一个 UI）
    expect(find.byIcon(Icons.arrow_upward), findsNothing);
  });

  testWidgets('点圆环 → 同款详情面板，用量数字与圆环一致', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byType(ContextUsageChip));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(ContextUsageDetailSheet), findsOneWidget);
    // usageFraction 模板 "$used / $total tokens"；48000 → 48k、128000 → 128k
    expect(find.textContaining('48k / 128k tokens'), findsOneWidget);
    // 压缩触发线行（57600 → 57.6k）
    expect(find.textContaining('57.6k'), findsOneWidget);
  });

  testWidgets('详情面板手动压缩 → 不足时分态文案（复用 CompressResult）', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byType(ContextUsageChip));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));

    // 「立即压缩」位于面板内容底部、测试视口的命中线以下（modal 底部
    // 定位在测试绑定的坐标异常）——改调按钮 onPressed 直验接线：
    // 入口存在、非生成/压缩态可用、触发走 _handleCompressHistory
    final compactButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text(t.common.contextRing.compactNow),
        matching: find.byType(FilledButton),
      ),
    );
    expect(
      compactButton.onPressed,
      isNotNull,
      reason: '非压缩/生成态下手动压缩入口应可用',
    );
    compactButton.onPressed!();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));

    // 仅 1 条非摘要消息 → insufficient → 既有专属文案的 floating SnackBar
    expect(find.text(t.chat.compaction.insufficient), findsOneWidget);
  });

  testWidgets('最近一轮输出/缓存分项随流式完成进入面板；缺失时「—」+ 口径脚注', (
    tester,
  ) async {
    final container = await pumpPage(tester);
    final notifier =
        container.read(chatModeControllerProvider(session).notifier);

    // 流式完成前的初始态：输出/缓存读取行「—」，脚注解释口径
    await tester.tap(find.byType(ContextUsageChip));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    // 三个「—」：输出行 + 缓存读取行 + 命中率最近一轮 + 会话平均 = 4
    expect(find.text('—'), findsNWidgets(4));
    expect(find.textContaining('「≈」为本地估算值'), findsOneWidget);

    // 模拟一轮流式完成（_onFinishStreaming 写入 usage 分项）——面板经
    // Consumer watch 原位刷新，无需重开
    notifier.state = notifier.state.copyWith(
      lastCompletionTokens: 800,
      lastCacheReadTokens: 132000,
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('800 tokens'), findsOneWidget);
    expect(find.text('132k tokens'), findsOneWidget);
    // 最近一轮命中率：132000/(132000+48000) ≈ 73.3%
    expect(find.text('73.3%'), findsOneWidget);
    // 分项齐全后脚注退场（会话平均仍「—」：chat 不做命中率累计）
    expect(find.text('—'), findsOneWidget);
    expect(find.textContaining('「≈」为本地估算值'), findsNothing);
  });
}

CompactionService _compactionService() => CompactionService(
      chatRepository: _RingChatRepository(),
      tokenCounter: TokenCounter(),
      settingsRepository: _RingSettingsRepository(),
      presetRepository: _RingPresetRepository(),
      streamer: CompactionStreamer(llmService: _NoopLlmService()),
      llmService: _NoopLlmService(),
    );

/// 单条带 usage 的助手消息（非摘要 < 2 条 → 手动压缩走 insufficient 分态）
class _RingChatRepository implements ChatRepository {
  final List<ChatMessage> messages = [
    ChatMessage(
      messageId: 'a0',
      sessionId: 'ring-session',
      role: 'assistant',
      content: '一条已有回复',
      createdAt: DateTime(2026),
      tokensUsed: 48000,
    ),
  ];

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async =>
      List.of(messages);

  @override
  Future<ChatSession> updateSession(ChatSession session) async => session;

  @override
  Future<int> getMessageCount(String sessionId) async => messages.length;

  @override
  Future<void> updateSessionMessageCount(String sessionId, int count) async {}

  @override
  Future<void> updateSessionLastActive(String sessionId) async {}

  @override
  Future<List<ForkAnchor>> getForkAnchors(String sessionId) async => [];

  @override
  Future<void> updateMessageTokensUsed(String messageId, int? tokensUsed) =>
      Future.value();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// p1/m1 模型窗口 128000（resolveModelDisplayInfo 由此取 contextWindowTokens）
class _RingPresetRepository implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => [
        ApiPreset(
          presetId: 'p1',
          name: '测试供应商',
          baseUrl: 'https://example.com',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          cachedModels: const [
            ModelInfo(
              modelId: 'm1',
              displayName: '测试模型',
              contextWindow: 128000,
            ),
          ],
        ),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// broadcastChat 走 p1/m1（压缩阈值走默认 0.6 档——触发线 96000×0.6=57600）
class _RingSettingsRepository implements SettingsRepository {
  @override
  Future<AppConfig> getResolvedConfig() async => const AppConfig(
        version: 'test',
        broadcastChat: BroadcastChatConfig(
          presetId: 'p1',
          modelId: 'm1',
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

class _NoopLlmService implements LlmService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopTemplateRepository implements TemplateRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
