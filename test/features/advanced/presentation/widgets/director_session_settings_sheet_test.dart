import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/network/http_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/core/widgets/commit_slider.dart';
import 'package:lmstory/features/advanced/domain/entities/retrieval_profile.dart';
import 'package:lmstory/features/advanced/domain/entities/tool_permissions.dart';
import 'package:lmstory/features/advanced/presentation/controllers/advanced_chat_controller.dart';
import 'package:lmstory/features/advanced/presentation/pages/advanced_chat_page.dart'
    show advancedChatControllerProvider;
import 'package:lmstory/features/advanced/presentation/widgets/director_session_settings_sheet.dart';
import 'package:lmstory/features/chat/data/datasources/llm_remote_datasource.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';
import 'package:lmstory/features/resource_library/domain/entities/character_card.dart';
import 'package:lmstory/features/resource_library/domain/entities/worldbook.dart';
import 'package:lmstory/features/resource_library/domain/repositories/resource_library_repository.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/widgets/director_compaction_threshold_field.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_model_picker_sheet.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/session_settings_fields.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../helpers/fake_factual_repository.dart';
import '../../../../test_helpers/load_app_fonts.dart';
import '../../../../test_helpers/stub_failure_log_repository.dart';
import '../../../../test_helpers/stub_settings_notifier.dart';

/// DirectorSessionSettingsSheet Widget 测试（种子资源区段挂载）
///
/// 覆盖：
/// 1. 骨架：8 个可折叠分区含「角色卡/世界书」（默认折叠）
/// 2. 展开种子分区：三张卡（应用角色卡/应用世界书/取消应用资源）
/// 3. 空资源库点「应用角色卡」→ 暂无资源 SnackBar（共享组件运行链路）

// ── Fakes / Stubs ─────────────────────────────────────────────────────

class _FakeApiPresetRepository implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubSettingsRepository implements SettingsRepository {
  _StubSettingsRepository({this.advanced = const AdvancedConfig()});

  final Map<String, dynamic> _overrides = {};

  /// 与 advancedConfigProvider 同源（对齐生产——resolver 物化与
  /// 面板显示的全局值必须一致，分叉会让物化写入错误的默认值）
  final AdvancedConfig advanced;

  @override
  Future<AppConfig> getResolvedConfig() async => AppConfig(
        version: '0.1',
        broadcastChat: const BroadcastChatConfig(),
        advanced: advanced,
      );

  @override
  Future<Map<String, dynamic>> getUserOverrides() async =>
      Map<String, dynamic>.of(_overrides);

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    _overrides[key] = value;
  }

  @override
  Future<void> removeUserOverride(String key) async {
    _overrides.remove(key);
  }

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

class _StubExperienceRepository implements ExperienceRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubChatRepository implements ChatRepository {
  _StubChatRepository(this._session);

  ChatSession _session;
  List<ChatMessage> messages = const [];

  // 捕获最近一次 updateSession（断言检索松紧度快照写库）
  ChatSession? lastUpdatedSession;

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async => messages;

  @override
  Future<DirectorInputs> getDirectorInputs(String sessionId) async =>
      (pending: null, queued: null);

  @override
  Future<ChatSession> createSession({
    required String title,
    String? sessionId,
    String mode = 'simple',
    String? modelId,
    String? presetId,
  }) async =>
      ChatSession(
        sessionId: sessionId ?? 'real-director-1',
        title: title,
        mode: mode,
        createdAt: DateTime(2026),
        lastActiveAt: DateTime(2026),
        messageCount: 0,
      );

  @override
  Future<ChatSession> updateSession(ChatSession session) async {
    lastUpdatedSession = session;
    _session = session;
    return session;
  }

  @override
  Future<ChatSession> getSession(String sessionId) async => _session;

  @override
  Future<void> deleteSession(String sessionId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubPersistenceService implements StoryPersistenceService {
  @override
  Future<Map<int, StoryRoundArtifacts>> loadArtifactsBySession(
    String sessionId,
  ) async =>
      {};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubHttpClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubEmbeddingService implements EmbeddingService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubResourceLibraryRepository implements ResourceLibraryRepository {
  @override
  Future<List<CharacterCard>> getAllCharacterCards() async => [];

  @override
  Future<List<Worldbook>> getAllWorldbooks() async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

// ── Fixtures ──────────────────────────────────────────────────────────

ChatSession _directorSession() => ChatSession(
      sessionId: 'director-session-1',
      title: '测试导演',
      mode: 'advanced',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );

// ── Pump helper ───────────────────────────────────────────────────────

/// harness 缺省进阶模式：既有用例 = 「进阶=现状全量」回归组；
/// 配置显示模式过滤组显式传 level 验证双态。
Future<_StubChatRepository> _pumpSheet(
  WidgetTester tester, {
  ChatSession? sessionOverride,
  AdvancedConfig? config,
  ConfigLevel level = ConfigLevel.advanced,
  List<ApiPreset>? presets,
}) async {
  // 面板分区多，用手机尺寸视口避免底部裁剪
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // mock 持久化值与 initialValue 一致，notifier _load 兜底重读不回跳。
  SharedPreferences.setMockInitialValues({
    if (level == ConfigLevel.advanced) ConfigLevelNotifier.prefKey: 'advanced',
  });
  final configPrefs = Preferences(prefs: await SharedPreferences.getInstance());

  final session = sessionOverride ?? _directorSession();
  final resolvedConfig = config ?? const AdvancedConfig();
  final chatRepository = _StubChatRepository(session);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        factualRepositoryProvider.overrideWithValue(FakeFactualRepository()),
        if (presets != null)
          settingsNotifierProvider.overrideWith(
            (ref) => StubSettingsNotifier(presets: presets),
          ),
        apiPresetRepositoryProvider
            .overrideWithValue(_FakeApiPresetRepository()),
        templateRepositoryProvider.overrideWithValue(_StubTemplateRepository()),
        settingsRepositoryProvider.overrideWithValue(_StubSettingsRepository()),
        experienceRepositoryProvider
            .overrideWithValue(_StubExperienceRepository()),
        advancedConfigProvider.overrideWith((ref) async => resolvedConfig),
        configLevelProvider.overrideWith(
          (ref) => ConfigLevelNotifier(configPrefs, initialValue: level),
        ),
        resourceLibraryRepositoryProvider
            .overrideWithValue(_StubResourceLibraryRepository()),
        advancedChatControllerProvider(session).overrideWith((ref) {
          return AdvancedChatController(
            chatRepository: chatRepository,
            configurationResolver: ConfigurationResolver(
              presetRepository: _FakeApiPresetRepository(),
              settingsRepository: _StubSettingsRepository(
                advanced: resolvedConfig,
              ),
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
            getConfig: () async => resolvedConfig,
            logger: const Logger('test'),
            session: session,
          );
        }),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: DirectorSessionSettingsSheet(session: session),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return chatRepository;
}

/// 展开默认折叠的「预算」分区（滑条/无上限 chip 所在）。
Future<void> _expandBudgetSection(WidgetTester tester) async {
  await tester.ensureVisible(find.text('预算'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('预算'));
  await tester.pumpAndSettle();
}

/// 展开默认折叠的「上下文与压缩」分区（上下文配置收敛分区）。
Future<void> _expandContextSection(WidgetTester tester) async {
  await tester.ensureVisible(find.text('上下文与压缩'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('上下文与压缩'));
  await tester.pumpAndSettle();
}

// ── Tests ─────────────────────────────────────────────────────────────

void main() {
  testWidgets('导演草稿回显并预选全局主模型，按该模型显示采样控件', (tester) async {
    await _pumpSheet(
      tester,
      sessionOverride: _directorSession().copyWith(
        sessionId: '${AdvancedChatController.draftSessionIdPrefix}new',
      ),
      config: const AdvancedConfig(
        generatingPresetId: 'relay',
        generatingModelId: 'grok-4.7',
      ),
      presets: [
        ApiPreset(
          presetId: 'relay',
          name: 'Relay',
          baseUrl: 'https://relay.test',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          providerOptions: const {'omit_sampling_params': true},
        ),
      ],
    );
    final labels = t.advanced.settings.generation;
    expect(find.text(labels.temperature), findsNothing);
    expect(find.text(labels.topP), findsNothing);
    expect(find.text(labels.presencePenalty), findsNothing);
    expect(find.text(labels.frequencyPenalty), findsNothing);
    expect(find.byType(IntermediateMaxTokensField), findsOneWidget);
    expect(find.byType(IntermediateReasoningEffortSelector), findsOneWidget);
    expect(find.text('Relay · grok-4.7'), findsOneWidget);
    await tester.tap(find.text(t.advanced.settings.selectModel));
    await tester.pumpAndSettle();
    final picker = tester.widget<IntermediateModelPickerSheet>(
      find.byType(IntermediateModelPickerSheet),
    );
    expect(picker.selectedPresetId, 'relay');
    expect(picker.selectedModelId, 'grok-4.7');
  });

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
    // Use shipped fonts for the threshold row at phone width.
    await loadAppFonts();
  });

  group('DirectorSessionSettingsSheet（B6 种子资源区段）', () {
    testWidgets('1. 骨架：含「角色卡/世界书」分区标题（默认折叠，卡片不渲染）', (tester) async {
      await _pumpSheet(tester);

      expect(find.text('角色卡/世界书'), findsOneWidget);
      // 默认折叠：三张卡不可见
      expect(find.text('应用角色卡'), findsNothing);
      expect(find.text('取消应用资源'), findsNothing);
    });

    testWidgets('2. 展开种子分区：三张卡齐备（与故事模式同款）', (tester) async {
      await _pumpSheet(tester);

      await tester.ensureVisible(find.text('角色卡/世界书'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('角色卡/世界书'));
      await tester.pumpAndSettle();

      expect(find.text('应用角色卡'), findsOneWidget);
      expect(find.text('应用世界书'), findsOneWidget);
      expect(find.text('取消应用资源'), findsOneWidget);
    });

    testWidgets('3. 空资源库点「应用角色卡」→ 暂无资源 SnackBar（共享组件链路）', (tester) async {
      await _pumpSheet(tester);

      await tester.ensureVisible(find.text('角色卡/世界书'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('角色卡/世界书'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('应用角色卡'));
      await tester.pumpAndSettle();

      expect(
        find.text('暂无资源，请先在「设置 → 角色卡/世界书」导入'),
        findsOneWidget,
      );
    });

    testWidgets('T4：展开记忆管理→三档 chip；点「保守」写快照 JSON', (tester) async {
      final chatRepo = await _pumpSheet(tester);

      // 记忆管理默认展开（默认折叠至 2 区），滚动到位即可
      await tester.ensureVisible(find.text('记忆管理'));
      await tester.pumpAndSettle();

      // 三档齐备（剧情节奏档同有「保守/平衡」chip，用 Key 消歧）；
      // 存量会话未物化 → 无选中态（：平衡以「默认」态高亮）
      expect(find.text('检索松紧度'), findsOneWidget);
      const conservativeKey = ValueKey('retrieval-profile-conservative');
      expect(find.byKey(conservativeKey), findsOneWidget);
      expect(
        find.byKey(const ValueKey('retrieval-profile-balanced')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('retrieval-profile-loose')),
        findsOneWidget,
      );
      expect(
        find.text('少而准：检索默认返回 5 条，并过滤低分向量命中'),
        findsNothing,
      );

      // 点「保守」→ 快照具体值写入会话列
      await tester.tap(find.byKey(conservativeKey));
      await tester.pumpAndSettle();

      final updated = chatRepo.lastUpdatedSession;
      expect(updated, isNotNull);
      final profile = RetrievalProfile.tryDecode(updated!.retrievalOverrides);
      expect(profile, isNotNull);
      expect(profile!.sameAs(RetrievalProfile.conservative), isTrue);
      // 选中态回显档位说明
      expect(
        find.text('少而准：检索默认返回 5 条，并过滤低分向量命中'),
        findsOneWidget,
      );
    });

    testWidgets('未物化会话「平衡」chip 以「默认」态高亮并回显默认说明', (tester) async {
      final chatRepo = await _pumpSheet(tester);

      // 记忆管理默认展开，滚动到位即可
      await tester.ensureVisible(find.text('记忆管理'));
      await tester.pumpAndSettle();

      // NULL 快照：平衡 chip 徽标 + 默认说明行；保守/宽松无徽标
      const balancedKey = ValueKey('retrieval-profile-balanced');
      expect(
        find.descendant(
          of: find.byKey(balancedKey),
          matching: find.text('平衡 · 默认'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('retrieval-profile-conservative')),
          matching: find.textContaining('· 默认'),
        ),
        findsNothing,
      );
      expect(
        // 打开即物化——retrieval 已是平衡档快照值，说明行显示平衡档
        // 描述（「与当前全局行为一致」），而非未设置的 defaultDesc
        find.text('与当前全局行为一致：默认 8 条，不过滤'),
        findsOneWidget,
      );

      // 点「保守」→ 徽标消失、说明切到快照档（快照语义不被默认态干扰）
      await tester
          .tap(find.byKey(const ValueKey('retrieval-profile-conservative')));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(balancedKey),
          matching: find.textContaining('· 默认'),
        ),
        findsNothing,
      );
      final updated = chatRepo.lastUpdatedSession;
      expect(updated, isNotNull);
      final profile = RetrievalProfile.tryDecode(updated!.retrievalOverrides);
      expect(profile!.sameAs(RetrievalProfile.conservative), isTrue);
    });
  });

  // ── ：参数来源标注接入导演会话面板 ─────────────────
  //
  // UA 批 6 给共享字段加了 isCustomized/globalValueText，但导演
  // _ModelGenerationBody 未传参，isCustomized 默认恒 true——会话未
  // 自定义时既看不到全局值，重置按钮也照常可点。
  group('maxTokens 提交收口', () {
    Finder maxTokensField() => find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              (w.decoration?.hintText?.contains('输入 0 或任意正整数') ?? false),
        );

    testWidgets('清空+回车（已装载）→ 写全局快照而非显式 null', (tester) async {
      final repo = await _pumpSheet(
        tester,
        sessionOverride: _directorSession().copyWith(maxTokens: 8192),
        config: const AdvancedConfig(
          generation: GenerationConfig(maxTokens: 4096),
        ),
      );

      final field = maxTokensField();
      expect(field, findsOneWidget);
      await tester.enterText(field, '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(
        repo.lastUpdatedSession?.maxTokens,
        4096,
        reason: '空输入提交=重置为全局当前值快照（D4），不写显式 null',
      );
    });

    testWidgets('点重置 → 写全局快照且输入框回显（不再滞留旧值）', (tester) async {
      final repo = await _pumpSheet(
        tester,
        sessionOverride: _directorSession().copyWith(maxTokens: 8192),
        config: const AdvancedConfig(
          generation: GenerationConfig(maxTokens: 4096),
        ),
      );

      // 定位 maxTokens 字段所在 Column（含唯一重置 IconButton）
      final column = find
          .ancestor(of: maxTokensField(), matching: find.byType(Column))
          .first;
      final reset =
          find.descendant(of: column, matching: find.byType(IconButton));
      await tester.ensureVisible(reset);
      await tester.pumpAndSettle();
      await tester.tap(reset);
      await tester.pumpAndSettle();

      expect(repo.lastUpdatedSession?.maxTokens, 4096, reason: '重置=写全局当前值快照');
      expect(
        (maxTokensField().evaluate().single.widget as TextField)
            .controller!
            .text,
        '4096',
        reason: '保存后回显输入框（不再滞留 8192 旧值）',
      );
    });
  });

  group('生成参数来源标注', () {
    testWidgets('会话未自定义：滑块行显示「全局 X」徽标', (tester) async {
      await _pumpSheet(tester);

      // advanced.generation 默认 temperature 0.8 —— 未自定义时展示全局值
      expect(
        find.text('全局 0.80', skipOffstage: false),
        findsWidgets,
        reason: '会话列 NULL 时应标注来源为全局值（UA 批 6 同款徽标）',
      );
    });

    testWidgets('会话已自定义温度：不显示温度的全局徽标', (tester) async {
      await _pumpSheet(
        tester,
        sessionOverride: _directorSession().copyWith(temperature: 0.55),
      );

      expect(
        find.text('全局 0.80', skipOffstage: false),
        findsNothing,
        reason: '已自定义字段不应标注全局值徽标',
      );
    });
  });

  // ── ：maxSteps 三口径统一 ─────────────
  //
  // 回显走 effectiveMaxSteps(全局当前值)；「无上限」关闭写回 null
  //（跟全局）而非写死 8；runner 预算读数同源（单测见
  // director_session_extension_test.dart）。
  group('G-36：maxSteps 三口径统一', () {
    testWidgets('会话未设置：滑条回显全局当前值（12），非硬编码 8', (tester) async {
      await _pumpSheet(
        tester,
        config: const AdvancedConfig(
          defaults: AdvancedDefaultsConfig(maxSteps: 12),
        ),
      );

      await _expandBudgetSection(tester);

      expect(find.text('每轮 12 步'), findsOneWidget);
      expect(find.text('每轮 8 步'), findsNothing);
    });

    testWidgets('会话已设置（3）：回显会话值', (tester) async {
      await _pumpSheet(
        tester,
        sessionOverride: _directorSession().copyWith(maxSteps: 3),
        config: const AdvancedConfig(
          defaults: AdvancedDefaultsConfig(maxSteps: 12),
        ),
      );

      await _expandBudgetSection(tester);

      expect(find.text('每轮 3 步'), findsOneWidget);
    });

    testWidgets('开「无上限」写 0；再关写全局当前快照（D4：不再 null 跟随）', (tester) async {
      final chatRepo = await _pumpSheet(
        tester,
        config: const AdvancedConfig(
          defaults: AdvancedDefaultsConfig(maxSteps: 12),
        ),
      );

      await _expandBudgetSection(tester);

      // 开无上限 → maxSteps=0（AgentBudget 0=不限制语义）
      await tester.ensureVisible(find.text('无上限'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('无上限'));
      await tester.pumpAndSettle();
      expect(chatRepo.lastUpdatedSession?.maxSteps, 0);

      // 关无上限 → 写全局当前快照（12），不再写死 8、不再 null 跟随
      await tester.ensureVisible(find.text('无上限'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('无上限'));
      await tester.pumpAndSettle();
      expect(chatRepo.lastUpdatedSession?.maxSteps, 12);
      // 回显全局当前值 12
      expect(find.text('每轮 12 步'), findsOneWidget);
    });
  });

  group('上下文配置收敛（2026-09-13）：上下文与压缩分区', () {
    testWidgets('D4：单态滑杆恒显（物化保底）；重置 chip 写全局快照不置回 null', (tester) async {
      final chatRepo = await _pumpSheet(tester);
      await _expandContextSection(tester);

      // 打开即物化：阈值列已是全局快照 0.5，直接显示滑杆双显
      expect(find.text('上下文压缩阈值'), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('≈ 48k tokens'), findsOneWidget);
      // 三态已删：不再有「全局 X」跟随行文案
      expect(find.text('全局 50% · ≈ 48k tokens'), findsNothing);
      // 故事三段式遗产两行不再出现
      expect(find.text('原文区下限'), findsNothing);
      expect(find.text('检索区比例'), findsNothing);
      // 窗口上限在高级子折叠内（折叠态不可见）
      expect(find.text('单次请求 Token 上限'), findsNothing);

      // 点「重置为全局当前值」→ 写全局当前值快照 0.5，不写 null
      await tester.ensureVisible(find.text('重置为全局当前值'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重置为全局当前值'));
      await tester.pumpAndSettle();
      expect(
        chatRepo.lastUpdatedSession?.compactionTriggerRatioOverride,
        0.5,
        reason: '重置=写全局当前值快照，禁止 null 跟随态',
      );
      expect(find.text('50%'), findsOneWidget);
    });

    for (final engineeringEnabled in [false, true]) {
      final mode = engineeringEnabled ? '开启' : '关闭';
      testWidgets('快速拖动压缩阈值并在松手时保存（工程上下文$mode）', (tester) async {
        final chatRepo = await _pumpSheet(
          tester,
          sessionOverride: _directorSession().copyWith(
            engineeringContextEnabled: engineeringEnabled,
            compactionTriggerRatioOverride: 0.5,
          ),
        );
        tester.view.physicalSize = const Size(390, 760);
        await tester.pumpAndSettle();
        await _expandContextSection(tester);

        final field = find.byType(DirectorCompactionThresholdField);
        final slider = find.descendant(
          of: field,
          matching: find.byType(CommitSlider),
        );
        await tester.ensureVisible(slider);
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: field, matching: find.text('50%')),
          findsOneWidget,
        );
        final savedBeforeDrag = chatRepo.lastUpdatedSession;
        final bounds = tester.getRect(slider);
        // 50% is 40% of the way from the minimum (30%) to the maximum (80%).
        final thumb = bounds.centerLeft + Offset(bounds.width * 0.4, 0);

        final gesture = await tester.startGesture(thumb);
        await gesture.moveBy(const Offset(60, 0));
        await gesture.moveTo(bounds.centerRight - const Offset(2, 0));
        await tester.pump();
        expect(
          find.descendant(of: slider, matching: find.text('80%')),
          findsOneWidget,
        );
        expect(find.text('50%'), findsNothing);
        expect(find.text('≈ 76.8k tokens'), findsOneWidget);
        expect(chatRepo.lastUpdatedSession, same(savedBeforeDrag));

        await gesture.up();
        await tester.pumpAndSettle();

        expect(
          find.descendant(of: field, matching: find.text('80%')),
          findsOneWidget,
        );
        expect(find.text('≈ 76.8k tokens'), findsOneWidget);
        final saved = chatRepo.lastUpdatedSession;
        expect(saved?.compactionTriggerRatioOverride, 0.8);
        expect(saved?.engineeringContextEnabled, engineeringEnabled);
      });
    }

    testWidgets('窗口上限高级子折叠：展开见滑杆（0=无限制哨兵）', (tester) async {
      await _pumpSheet(tester);
      await _expandContextSection(tester);

      await tester.ensureVisible(find.text('高级：窗口上限'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高级：窗口上限'));
      await tester.pumpAndSettle();

      expect(find.text('单次请求 Token 上限'), findsOneWidget);
      expect(find.text('无限制'), findsWidgets);
    });
  });

  // ── ：监督开关读侧判据 ────────────────────────────
  //
  // 批四快照宪法下拨「关」写的是全 allow 快照（写侧不动）——「关」只能靠
  // 读侧判据「无任何 ask/deny 约束」表达。判据单源=ToolPermissions.
  // hasActiveConstraints（widget 消费点与这里共用）。
  group('监督开关读侧判据', () {
    test('判据纯函数：null/全 allow=关；含 ask/deny=开', () {
      expect(ToolPermissions.hasActiveConstraints(null), isFalse);
      expect(
        ToolPermissions.hasActiveConstraints(
          ToolPermissions.fromJson(
            ToolPermissions.toJson({
              for (final tool in ToolPermissions.allTools) tool: 'allow',
            }),
          ),
        ),
        isFalse,
        reason: '全 allow 快照（拨关后形态）= 关',
      );
      expect(
        ToolPermissions.hasActiveConstraints(ToolPermissions.supervised),
        isTrue,
        reason: 'supervised 预设含 ask = 开',
      );
      expect(
        ToolPermissions.hasActiveConstraints(const {
          'update_facts': 'ask',
          'spawn': 'deny',
        }),
        isTrue,
        reason: '自定义约束 = 开·自定义',
      );
    });
    // 注：widget 层三态显示归真机验收（面板懒加载环境在 widget 测试中
    // 滚动定位不稳，判据已由上方纯函数三态全覆盖；消费点仅一行委托）。
  });
  group('DirectorSessionSettingsSheet 配置显示模式过滤（8 区 → 5 区）', () {
    testWidgets(
        '简单模式：保留记忆管理/规则/模型与生成/剧情节奏/角色卡世界书，'
        '其余隐藏', (tester) async {
      await _pumpSheet(tester, level: ConfigLevel.simple);

      expect(find.text('记忆管理'), findsOneWidget);
      expect(find.text('项目规则'), findsOneWidget);
      expect(find.text('模型与生成'), findsOneWidget);
      expect(find.text('剧情节奏'), findsOneWidget);
      expect(find.text('角色卡/世界书'), findsOneWidget);
      expect(find.text('查看记忆库'), findsOneWidget);
      expect(find.text('监督与工具'), findsNothing);
      expect(find.text('预算'), findsNothing);
      expect(find.text('上下文与压缩'), findsNothing);
    });

    testWidgets('简单模式模型与生成区：GM 行+思考档保留，采样参数行隐藏', (tester) async {
      await _pumpSheet(tester, level: ConfigLevel.simple);

      // 区内行级：主模型与思考预算在，采样参数与组内滑杆不在
      expect(find.text('主模型'), findsOneWidget);
      expect(find.text('思考预算'), findsOneWidget);
      expect(find.text('温度'), findsNothing);
      expect(find.text('Top P'), findsNothing);
      expect(find.text('存在惩罚'), findsNothing);
      expect(find.text('频率惩罚'), findsNothing);
    });

    testWidgets('进阶模式：8 区 + 采样参数行全量渲染', (tester) async {
      await _pumpSheet(tester);

      expect(find.text('记忆管理'), findsOneWidget);
      expect(find.text('项目规则'), findsOneWidget);
      expect(find.text('模型与生成'), findsOneWidget);
      expect(find.text('剧情节奏'), findsOneWidget);
      expect(find.text('监督与工具'), findsOneWidget);
      expect(find.text('预算'), findsOneWidget);
      expect(find.text('上下文与压缩'), findsOneWidget);
      expect(find.text('角色卡/世界书'), findsOneWidget);
      // 模型与生成区采样参数行回归（组内唯一标签，温度/Top P 各一处）
      expect(find.text('温度'), findsOneWidget);
      expect(find.text('Top P'), findsOneWidget);
      expect(find.text('存在惩罚'), findsOneWidget);
      expect(find.text('频率惩罚'), findsOneWidget);
    });
  });

  // 回归：配置回显纪律——项目规则输入框恒显当前生效值
  //（会话覆盖 null 时回填全局 system_prompt，不再空白）。
  group('项目规则输入框回填', () {
    TextField rulesFieldOf(WidgetTester tester) => tester
        .widgetList<TextField>(find.byType(TextField))
        .firstWhere((f) => f.decoration?.hintText == '世界观、人设、文风、叙事守则…');

    Future<void> expandRules(WidgetTester tester) async {
      await tester.ensureVisible(find.text('项目规则'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('项目规则'));
      await tester.pumpAndSettle();
    }

    testWidgets('会话无覆盖 → 回填全局当前值', (tester) async {
      await _pumpSheet(
        tester,
        config: const AdvancedConfig(systemPrompt: '全局编辑部规则：夜航文风。'),
      );
      await expandRules(tester);

      expect(rulesFieldOf(tester).controller!.text, '全局编辑部规则：夜航文风。');
    });

    testWidgets('会话覆盖优先于全局', (tester) async {
      await _pumpSheet(
        tester,
        sessionOverride: _directorSession().copyWith(
          systemPromptOverride: '会话专属规则',
        ),
        config: const AdvancedConfig(systemPrompt: '全局编辑部规则'),
      );
      await expandRules(tester);

      expect(rulesFieldOf(tester).controller!.text, '会话专属规则');
    });

    testWidgets('会话覆盖为空串（快照语义）→ 不回退全局', (tester) async {
      await _pumpSheet(
        tester,
        sessionOverride: _directorSession().copyWith(systemPromptOverride: ''),
        config: const AdvancedConfig(systemPrompt: '全局编辑部规则'),
      );
      await expandRules(tester);

      expect(rulesFieldOf(tester).controller!.text, '');
    });
  });

  group('DirectorSessionSettingsSheet 更新标题行', () {
    testWidgets('模型与生成分区默认展开并渲染「更新标题」行', (tester) async {
      await _pumpSheet(tester);
      await tester.pumpAndSettle();

      expect(find.text('更新标题'), findsWidgets);
      expect(find.text('根据当前剧情重新生成标题'), findsOneWidget);
    });
  });
}
