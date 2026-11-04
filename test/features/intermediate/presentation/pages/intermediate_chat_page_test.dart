import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/network/http_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_message_bubble.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/chat/data/datasources/llm_remote_datasource.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/search_result.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/presentation/widgets/in_session_search_bar.dart';
import 'package:lmstory/features/intermediate/presentation/controllers/intermediate_chat_controller.dart';
import 'package:lmstory/features/intermediate/presentation/pages/intermediate_chat_page.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/intermediate_session_settings_sheet.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/story_runtime/domain/entities/message_variant_record.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/intermediate_chat_input.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../test_helpers/stub_failure_log_repository.dart';

/// IntermediateChatPage 页面级 Widget 测试（§7.4）
///
/// 验证：
/// - 页面骨架：Scaffold + AppBar + IntermediateChatInput 挂载正常
/// - AppBar 标题：显示 state.session.title
/// - 空状态：idle + 无消息时显示引导文案
/// - 输入框占位符：i18n 文案渲染
///
/// 测试策略：
/// - 使用草稿会话（`__draft_intermediate_` 前缀）→ loadHistory() 自动跳过
/// - 用 ProviderScope.overrides 注入 stub 依赖构造的 Controller
/// - tester.pumpAndSettle() 等 EntryTransition 动画播完（500ms）

// ── Fake / Stub（与 controller_test 同模式，测试文件间不共享私有类）──────

class _FakeChatRepository implements ChatRepository {
  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

///  集成测试用：返回预设的 3 轮（6 条）消息
///
/// 消息顺序：u1/a1/u2/a2/u3/a3
/// - 最后一条助手消息：a3（isLastAssistantMessage=true）
/// - 所有消息 turn 1-3，windowRounds=5 → canOperate=true
class _FakeChatRepositoryWithMessages implements ChatRepository {
  /// 会话内搜索——按 content 包含过滤（测试专用，
  /// 不复刻 LIKE 转义），升序返回。
  @override
  Future<List<SearchResult>> searchMessagesInSession(
    String sessionId,
    String query,
  ) async {
    if (sessionId != 'test-session-with-messages') return const [];
    final all = await getMessages(sessionId);
    final q = query.toLowerCase();
    return [
      for (final m in all)
        if ((m.content ?? '').toLowerCase().contains(q))
          SearchResult(
            sessionId: sessionId,
            sessionName: '测试故事',
            messageId: m.messageId,
            content: m.content ?? '',
            role: m.role,
            createdAt: m.createdAt,
          ),
    ];
  }

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async {
    if (sessionId == 'test-session-with-messages') {
      final base = DateTime(2026);
      return [
        ChatMessage(
          messageId: 'u1',
          sessionId: sessionId,
          role: 'user',
          content: '用户消息1',
          createdAt: base,
        ),
        ChatMessage(
          messageId: 'a1',
          sessionId: sessionId,
          role: 'assistant',
          content: '助手回复1',
          createdAt: base.add(const Duration(seconds: 1)),
        ),
        ChatMessage(
          messageId: 'u2',
          sessionId: sessionId,
          role: 'user',
          content: '用户消息2',
          createdAt: base.add(const Duration(seconds: 2)),
        ),
        ChatMessage(
          messageId: 'a2',
          sessionId: sessionId,
          role: 'assistant',
          content: '助手回复2',
          createdAt: base.add(const Duration(seconds: 3)),
        ),
        ChatMessage(
          messageId: 'u3',
          sessionId: sessionId,
          role: 'user',
          content: '用户消息3',
          createdAt: base.add(const Duration(seconds: 4)),
        ),
        ChatMessage(
          messageId: 'a3',
          sessionId: sessionId,
          role: 'assistant',
          content: '助手回复3',
          createdAt: base.add(const Duration(seconds: 5)),
        ),
      ];
    }
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubApiPresetRepository implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubSettingsRepository implements SettingsRepository {
  @override
  Future<AppConfig> getResolvedConfig() async => const AppConfig(
        version: '0.1',
        broadcastChat: BroadcastChatConfig(),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubTemplateRepository implements TemplateRepository {
  @override
  Future<List<Template>> getTemplatesByKind(TemplateKind kind) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubHttpClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubExperienceRepository implements ExperienceRepository {
  @override
  Future<List<ExperientialMemory>> searchExperiencesBySubstring(
    String sessionId,
    List<String> terms, {
    int limit = 5,
    bool includeArchived = false,
  }) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubEmbeddingService implements EmbeddingService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubPersistenceService implements StoryPersistenceService {
  /// 返回空 Map（stub 不持久化 artifacts，loadHistory 应正常完成）
  @override
  Future<Map<int, StoryRoundArtifacts>> loadArtifactsBySession(
    String sessionId,
  ) async =>
      const {};

  /// loadHistory 第三路并行装载变体表；空实现
  /// 保既有用例绿（noSuchMethod 会让整个 loadHistory 中止）。
  @override
  Future<Map<int, List<MessageVariantRecord>>> loadMessageVariants(
    String sessionId,
  ) async =>
      const {};

  @override
  Future<int> snapshotMessageVariant({
    required String sessionId,
    required int turnNumber,
    required String? content,
    String? thinkingContent,
    String? sourceInput,
    StoryRoundArtifacts? process,
  }) async =>
      0;

  @override
  Future<void> deleteMessageVariant({
    required String sessionId,
    required int turnNumber,
    required int variantIndex,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

// ── 测试数据 ────────────────────────────────────────────────────────

ChatSession _draftSession() => ChatSession(
      sessionId: '${IntermediateChatController.draftSessionIdPrefix}test',
      title: '测试故事',
      mode: 'intermediate',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );

///  集成测试用：3 轮（6 条消息）的非草稿会话
ChatSession _sessionWithMessages() => ChatSession(
      sessionId: 'test-session-with-messages',
      title: '测试故事',
      mode: 'intermediate',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 6,
    );

/// 构造测试用 widget 树：ProviderScope + TranslationProvider + MaterialApp
///
/// [chatRepository] 可选，用于注入返回预设消息的 fake（集成测试）。
/// 默认用 [_FakeChatRepository]（返回空列表，配合草稿会话）。
Future<void> _pumpPage(
  WidgetTester tester,
  ChatSession session, {
  ChatRepository? chatRepository,
  void Function(IntermediateChatController controller)? onCreated,
}) async {
  // Callback wiring uses a viewport that can expose the short conversation.
  // Compact reading and navigation are covered by the body layout tests.
  if (chatRepository is _FakeChatRepositoryWithMessages) {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // override sheet 依赖的 provider，避免点击设置按钮时触发真实数据库初始化
        // 2026-07-21 补充 experienceRepositoryProvider：sheet _loadInitialData 新增
        // getMemoriesWithoutEmbedding 调用，未 override 会导致 hang 住 pumpAndSettle
        apiPresetRepositoryProvider
            .overrideWithValue(_StubApiPresetRepository()),
        templateRepositoryProvider.overrideWithValue(_StubTemplateRepository()),
        settingsRepositoryProvider.overrideWithValue(_StubSettingsRepository()),
        experienceRepositoryProvider
            .overrideWithValue(_StubExperienceRepository()),
        intermediateConfigProvider
            .overrideWith((ref) async => const IntermediateConfig()),
        // 会话内搜索走页面层 chatRepositoryProvider——
        // 注入 fake 时同步 override，否则打到真实 drift 库（恒 0 命中）
        if (chatRepository != null)
          chatRepositoryProvider.overrideWithValue(chatRepository),
        intermediateChatControllerProvider(session).overrideWith((ref) {
          final controller = IntermediateChatController(
            chatRepository: chatRepository ?? _FakeChatRepository(),
            configurationResolver: ConfigurationResolver(
              presetRepository: _StubApiPresetRepository(),
              settingsRepository: _StubSettingsRepository(),
              logger: const Logger('test'),
            ),
            llmService: LlmRemoteDataSource(
              httpClient: _StubHttpClient(),
              adapterFactory: LlmAdapterFactory(),
            ),
            experienceRepository: _StubExperienceRepository(),
            embeddingService: _StubEmbeddingService(),
            persistenceService: _StubPersistenceService(),
            failureLogRepository: const StubFailureLogRepository(),
            tokenCounter: TokenCounter(),
            getConfig: () async => const IntermediateConfig(),
            logger: const Logger('test'),
            session: session,
          );
          onCreated?.call(controller);
          return controller;
        }),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: IntermediateChatPage(session: session),
        ),
      ),
    ),
  );
  // 等 EntryTransition（500ms）动画播完，内容淡入完成
  // 非草稿会话还需等 loadHistory 异步加载消息
  await tester.pumpAndSettle();
}

// ── 测试 ────────────────────────────────────────────────────────────

void main() {
  setUpAll(() {
    // slang 初始化为中文（保证 Translations.of(context) 返回中文文案）
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('IntermediateChatPage', () {
    testWidgets('1. 页面骨架：Scaffold + AppBar + IntermediateChatInput 挂载',
        (tester) async {
      await _pumpPage(tester, _draftSession());

      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(IntermediateChatInput), findsOneWidget);
    });

    testWidgets('世界状态条：persist 后轮内事实清空，事实槽回落 artifacts 仍显示', (tester) async {
      late IntermediateChatController controller;
      await _pumpPage(
        tester,
        _sessionWithMessages(),
        chatRepository: _FakeChatRepositoryWithMessages(),
        onCreated: (c) => controller = c,
      );

      // 模拟 persist 完成后的状态（：轮内中间态已清空 +
      // artifacts 持有本轮检索事实）——世界状态条事实槽
      // 应从 artifacts 取值而不是消失。
      const entityName = '守夜人阿槿';
      controller.state = controller.state.copyWith(
        retrievedFacts: null,
        session: controller.state.session.copyWith(
          currentNarrativeTime: '三年前',
        ),
        artifactsByTurnNumber: {
          1: StoryRoundArtifacts(
            sessionId: 'test-session-with-messages',
            turnNumber: 1,
            createdAt: DateTime(2026),
            retrievedFacts: [
              RetrievedFact(
                entity: FactualEntity(
                  entityId: 'e1',
                  sessionId: 'test-session-with-messages',
                  type: FactualEntityType.character,
                  primaryName: entityName,
                  aliases: const [],
                  importance: 4,
                  createdTurn: 1,
                  createdAt: DateTime(2026),
                ),
                attributes: const [],
                isKeyEntity: true,
                isKeywordMatched: true,
              ),
            ],
          ),
        },
      );
      await tester.pump();

      // 世界状态条仍显示（含实体名摘要），不再轮完成即消失
      expect(find.byIcon(Icons.public_outlined), findsOneWidget);
      expect(find.textContaining(entityName), findsOneWidget);
    });

    testWidgets('2. AppBar 标题显示会话标题', (tester) async {
      await _pumpPage(tester, _draftSession());

      // AppBar 内的 Text 显示 '测试故事'
      expect(find.text('测试故事'), findsOneWidget);
    });

    testWidgets('3. 空状态：显示引导文案 + auto_stories 图标', (tester) async {
      await _pumpPage(tester, _draftSession());

      // idle + 无消息 → 显示空状态文案
      expect(find.text('开始你的故事'), findsOneWidget);
      expect(find.text('输入一句话，让故事展开'), findsOneWidget);
      // 空状态图标
      expect(find.byIcon(Icons.auto_stories), findsOneWidget);
    });

    testWidgets('4. 输入框占位符显示 i18n 文案', (tester) async {
      await _pumpPage(tester, _draftSession());

      // idle 阶段输入框可输入，显示占位符
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('推动故事发展...'), findsOneWidget);
    });

    testWidgets('5. AppBar 设置按钮 → 弹出会话设置面板', (tester) async {
      await _pumpPage(tester, _draftSession());

      // 设置按钮存在
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);

      // 点击设置按钮
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();

      // 弹出 IntermediateSessionSettingsSheet
      expect(find.byType(IntermediateSessionSettingsSheet), findsOneWidget);
      // sheet 标题显示"会话设置"
      expect(find.text('会话设置'), findsWidgets);
    });
  });

  // ──  Fork 集成测试 ─────────────────────────────────────────────
  // 用 _FakeChatRepositoryWithMessages 注入 3 轮（6 条）消息，
  // 验证 body 透传 Fork 参数 + page 连接回调 + 弹窗流程。
  group('IntermediateChatPage - P2.6 Fork 集成', () {
    testWidgets('5. 有消息时渲染列表 + 最后一条助手消息常驻动作按钮', (tester) async {
      await _pumpPage(
        tester,
        _sessionWithMessages(),
        chatRepository: _FakeChatRepositoryWithMessages(),
      );

      // 6 条消息都渲染（抽样验证首条 + 末条）
      expect(find.text('用户消息1'), findsOneWidget);
      expect(find.text('助手回复3'), findsOneWidget);

      // 最后一条助手消息（a3）常驻显示动作按钮（横排 IconButton Row）
      // 仅助手消息有 refresh_rounded（重新生成）按钮，断言 findsOneWidget 最精确
      expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    });

    testWidgets('6. tap 普通消息气泡显示动作按钮', (tester) async {
      await _pumpPage(
        tester,
        _sessionWithMessages(),
        chatRepository: _FakeChatRepositoryWithMessages(),
      );

      // 初始只有 a3 常驻动作按钮（delete_outline 在用户和助手消息都有）
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);

      // tap 用户消息2 → u2 的 actions 显示（共 2 个 delete_outline：u2 + a3）
      await tester.tap(find.text('用户消息2'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.delete_outline), findsNWidgets(2));
    });

    testWidgets('7. 点击删除动作按钮 → 删除整轮 → 弹确认弹窗', (tester) async {
      await _pumpPage(
        tester,
        _sessionWithMessages(),
        chatRepository: _FakeChatRepositoryWithMessages(),
      );

      // 直接点击 a3 常驻的删除图标（横排 IconButton，无需打开菜单）
      // 2026-09-10：列表新增底部缓冲留白（惰性跟随用），末条动作图标可能
      // 落到视口外，先滚动入视口再点。
      final deleteIcon = find.byIcon(Icons.delete_outline);
      await tester.ensureVisible(deleteIcon);
      await tester.pumpAndSettle();
      await tester.tap(deleteIcon);
      await tester.pumpAndSettle();

      // 弹出确认弹窗：标题"确认删除" + 内容 + 删除按钮
      expect(find.text('确认删除'), findsOneWidget);
      expect(
        find.text('删除此轮及之后的所有消息？此操作不可恢复。'),
        findsOneWidget,
      );
      // confirmLabel = t.common.delete = "删除"
      expect(find.text('删除'), findsOneWidget);
    });

    testWidgets('8. 点击编辑动作按钮 → 弹编辑弹窗 + 回显初始内容', (tester) async {
      await _pumpPage(
        tester,
        _sessionWithMessages(),
        chatRepository: _FakeChatRepositoryWithMessages(),
      );

      // tap 用户消息2 → u2 的 actions 显示
      await tester.tap(find.text('用户消息2'));
      await tester.pumpAndSettle();

      // 用户和助手消息都有编辑动作；把 finder 限定到 u2 气泡。
      final userBubble = find.ancestor(
        of: find.text('用户消息2'),
        matching: find.byType(IntermediateMessageBubble),
      );
      final editButton = find.descendant(
        of: userBubble,
        matching: find.byIcon(Icons.edit_outlined),
      );
      await tester.tap(editButton);
      await tester.pumpAndSettle();

      // 弹出编辑弹窗：标题"编辑消息" + TextField 回显"用户消息2"
      expect(find.text('编辑消息'), findsOneWidget);
      // "用户消息2" 出现 2 次：u2 气泡 + TextField 内的初始内容
      expect(find.text('用户消息2'), findsNWidgets(2));
      // "保存并重发"按钮存在（未修改时 disabled）
      expect(find.text('保存并重发'), findsOneWidget);
    });
  });

  // ── ：会话内搜索（自 ChatModePage 移植）─────────
  group('会话内搜索', () {
    testWidgets('菜单入口呼出搜索条，命中计数与首条定位', (tester) async {
      await _pumpPage(
        tester,
        _sessionWithMessages(),
        chatRepository: _FakeChatRepositoryWithMessages(),
      );
      await tester.pumpAndSettle();
      final t = Translations.of(
        tester.element(find.byType(Scaffold).first),
      );

      // ⋮ 菜单 → 会话内搜索
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.chat.inSessionSearch.menuTitle));
      await tester.pumpAndSettle();

      // 输入关键词（300ms 防抖后落库查询）——目标=搜索条内输入框
      //（页面底部还有 IntermediateChatInput 的 TextField，不能按 first 取）
      final searchField = find.descendant(
        of: find.byType(InSessionSearchBar),
        matching: find.byType(TextField),
      );
      await tester.enterText(searchField, '用户消息');
      await tester.pump(const Duration(milliseconds: 400));

      // 3 条命中（u1/u2/u3），定位第一条
      expect(find.text('1/3'), findsOneWidget);
    });

    testWidgets('无命中显示空结果提示', (tester) async {
      await _pumpPage(
        tester,
        _sessionWithMessages(),
        chatRepository: _FakeChatRepositoryWithMessages(),
      );
      await tester.pumpAndSettle();
      final t = Translations.of(
        tester.element(find.byType(Scaffold).first),
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.chat.inSessionSearch.menuTitle));
      await tester.pumpAndSettle();

      final searchField = find.descendant(
        of: find.byType(InSessionSearchBar),
        matching: find.byType(TextField),
      );
      await tester.enterText(searchField, '不存在的词');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text(t.chat.inSessionSearch.noResults), findsOneWidget);
    });
  });
}
