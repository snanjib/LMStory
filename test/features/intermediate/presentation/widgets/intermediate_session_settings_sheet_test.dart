import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/network/http_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/chat/data/datasources/llm_remote_datasource.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/intermediate/presentation/controllers/intermediate_chat_controller.dart';
import 'package:lmstory/features/intermediate/presentation/pages/intermediate_chat_page.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/intermediate_session_settings_sheet.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';
import 'package:lmstory/features/story_runtime/presentation/pages/memory_browser_page.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/session_settings_fields.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../test_helpers/stub_failure_log_repository.dart';

/// IntermediateSessionSettingsSheet Widget 测试（2026-07-18 重构后）
///
/// v0.2 重构（用户需求：故事模式每个对话需要单独的配置选项）：
/// - 恢复 4 类会话级配置：模型/供应商、提示词、生成参数、上下文/压缩
/// - 保留工具调用会话级覆盖（3 态：使用全局/启用/禁用）
/// - 底部"故事模式默认配置"链接
///
/// 验证：
/// - 骨架：标题 + 5 个区段标题 + 底部全局设置链接
/// - 工具调用三态：使用全局 / 启用 / 禁用
/// - 切换工具调用 → controller.updateSession 被调用

// ── Fakes / Stubs ─────────────────────────────────────────────────────

class _FakeApiPresetRepository implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubSettingsRepository implements SettingsRepository {
  final Map<String, dynamic> _overrides = {};

  @override
  Future<AppConfig> getResolvedConfig() async => const AppConfig(
        version: '0.1',
        broadcastChat: BroadcastChatConfig(),
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

class _StubHttpClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubExperienceRepository implements ExperienceRepository {
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
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubChatRepository implements ChatRepository {
  /// 2026-07-22 快照语义：草稿会话首次修改配置会触发物化（createSession +
  /// updateSession），需要实现这两个方法返回合理的 ChatSession。
  /// 其他方法仍走 noSuchMethod 兜底。
  @override
  Future<ChatSession> createSession({
    required String title,
    String mode = ChatMode.chat,
    String? modelId,
    String? presetId,
  }) async {
    return ChatSession(
      sessionId: 'materialized-${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      mode: mode,
      modelId: modelId,
      presetId: presetId,
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );
  }

  @override
  Future<ChatSession> updateSession(ChatSession session) async => session;

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

// ── Fixtures ──────────────────────────────────────────────────────────

ChatSession _draftSession() => ChatSession(
      sessionId: '${IntermediateChatController.draftSessionIdPrefix}test',
      title: '测试故事',
      mode: 'intermediate',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );

// ── Pump helper ───────────────────────────────────────────────────────

/// [level]：配置显示模式（默认进阶 = 现状全量，既有用例语义不变）；
/// 简单模式过滤行为由「配置显示模式过滤」组显式传 simple 验证。
Future<ProviderContainer> _pumpSheet(
  WidgetTester tester,
  ChatSession session, {
  ConfigLevel level = ConfigLevel.advanced,
}) async {
  // Sheet 内容较长（5 个区段），默认 800x600 视口下底部"工具调用"区段
  // 会被裁剪到屏幕外导致 tap 无法命中。改用手机尺寸的视口。
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // 配置显示模式持久化桩：mock 值与 initialValue 一致，
  // notifier _load 兜底重读后不回跳默认值。
  SharedPreferences.setMockInitialValues({
    if (level == ConfigLevel.advanced) ConfigLevelNotifier.prefKey: 'advanced',
  });
  final prefs = Preferences(prefs: await SharedPreferences.getInstance());

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // override sheet 依赖的 provider，避免触发真实数据库初始化
        // 2026-07-21 补充 experienceRepositoryProvider：_loadInitialData 新增
        // getMemoriesWithoutEmbedding 调用，未 override 会导致 hang 住 pumpAndSettle
        apiPresetRepositoryProvider
            .overrideWithValue(_FakeApiPresetRepository()),
        templateRepositoryProvider.overrideWithValue(_StubTemplateRepository()),
        settingsRepositoryProvider.overrideWithValue(_StubSettingsRepository()),
        experienceRepositoryProvider
            .overrideWithValue(_StubExperienceRepository()),
        intermediateConfigProvider
            .overrideWith((ref) async => const IntermediateConfig()),
        configLevelProvider.overrideWith(
          (ref) => ConfigLevelNotifier(prefs, initialValue: level),
        ),
        intermediateChatControllerProvider(session).overrideWith((ref) {
          return IntermediateChatController(
            chatRepository: _StubChatRepository(),
            configurationResolver: ConfigurationResolver(
              presetRepository: _FakeApiPresetRepository(),
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
        }),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(
            body: IntermediateSessionSettingsSheet(session: session),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(IntermediateSessionSettingsSheet)),
  );
}

// ── Tests ─────────────────────────────────────────────────────────────

void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('IntermediateSessionSettingsSheet', () {
    testWidgets('1. 骨架：标题 + 6 个区段标题 + 底部全局设置链接', (tester) async {
      await _pumpSheet(tester, _draftSession());

      // 标题
      expect(find.text('会话设置'), findsOneWidget);
      // 6 个区段标题（2026-07-21 重构：模型与供应商 → 分步骤模型配置 + 记忆管理）
      // 分步骤模型配置出现 2 次：区段标题 + IntermediatePhaseModelsSection 内部标题
      expect(find.text('分步骤模型配置'), findsNWidgets(2));
      expect(find.text('提示词'), findsOneWidget);
      expect(find.text('生成参数'), findsOneWidget);
      expect(find.text('上下文窗口'), findsOneWidget);
      // 工具调用区段标题 + IntermediateJsonModeSelector label 都叫"工具调用"
      expect(find.text('工具调用'), findsNWidgets(2));
      // 记忆管理区段（2026-07-21 新增）
      expect(find.text('记忆管理'), findsOneWidget);
      // 底部全局设置链接
      expect(find.text('故事模式默认配置'), findsOneWidget);
    });

    testWidgets('2. 工具调用默认显示"启用"（快照语义：null 回退全局 true）', (tester) async {
      await _pumpSheet(tester, _draftSession());

      // session.jsonModeOverride 为 null → 回退全局（测试中 globalConfig 为空 → 兜底 true）
      // 2026-07-22 重构：移除"使用全局设置"选项，直接显示具体值
      expect(find.text('启用'), findsOneWidget);
    });

    testWidgets('3. 切换工具调用到"禁用" → controller state 更新', (tester) async {
      final session = _draftSession();
      final container = await _pumpSheet(tester, session);

      // 初始 jsonModeOverride 为 null（显示"启用"）
      expect(
        container
            .read(intermediateChatControllerProvider(session))
            .session
            .jsonModeOverride,
        isNull,
      );

      // 滚动到工具调用区段并打开下拉
      await tester.ensureVisible(find.text('启用'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('启用'), warnIfMissed: false);
      await tester.pumpAndSettle();

      // 在弹出的下拉菜单中选"禁用"
      await tester.tap(find.text('禁用').last);
      await tester.pumpAndSettle();

      expect(
        container
            .read(intermediateChatControllerProvider(session))
            .session
            .jsonModeOverride,
        false,
      );
    });

    testWidgets('4. 已有覆盖值"禁用"时显示对应选项', (tester) async {
      // session 已设置 jsonModeOverride=false
      final session = _draftSession().copyWith(jsonModeOverride: false);
      await _pumpSheet(tester, session);

      // 工具调用下拉应显示"禁用"（reasoningEffort 默认 disabled 也显示"禁用"，
      // 需用 descendant finder 精确定位到 IntermediateJsonModeSelector 内部）
      expect(
        find.descendant(
          of: find.byType(IntermediateJsonModeSelector),
          matching: find.text('禁用'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('5. 查看记忆库使用物化后的真实 session（非草稿 session，2026-07-22 修复）',
        (tester) async {
      // 复现 bug：sheet 用 draft session 构造，发消息后 controller 物化为
      // real-xxx，但"查看记忆库"按钮原传 widget.session（仍是 draft-xxx），
      // 导致 MemoryBrowserPage 拿 draft-xxx 查询 → 记忆库始终为空。
      // 修复：改传 _session（从 controller.state.session 同步的真实 session）。
      final session = _draftSession();
      final container = await _pumpSheet(tester, session);

      // 触发物化：切换工具调用 → controller.updateSession → createSession
      await tester.ensureVisible(find.text('启用'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('启用'), warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.tap(find.text('禁用').last);
      await tester.pumpAndSettle();

      // 确认物化已发生：controller.state.session 不再是 draft
      final materializedSession =
          container.read(intermediateChatControllerProvider(session)).session;
      expect(
        materializedSession.sessionId.startsWith('materialized-'),
        isTrue,
        reason: '物化后 sessionId 应以 materialized- 开头',
      );

      // 滚动到"查看记忆库"按钮并点击
      await tester.ensureVisible(find.text('查看记忆库'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看记忆库'));
      await tester.pumpAndSettle();

      // 验证 MemoryBrowserPage 已推入
      final browserPage = find.byType(MemoryBrowserPage);
      expect(browserPage, findsOneWidget);

      // 验证推入的页面使用的是物化后的真实 session（非草稿）
      final pushedSession =
          tester.widget<MemoryBrowserPage>(browserPage).session;
      expect(
        pushedSession.sessionId,
        materializedSession.sessionId,
        reason: '记忆库应使用物化后的真实 sessionId，否则查询结果为空',
      );
    });

    testWidgets("6. 思考预算 null 时显示'未单独设置'并展示当前生效值（DOC-14 §3.2）", (tester) async {
      await _pumpSheet(tester, _draftSession());

      await tester.ensureVisible(find.text('思考预算'));
      await tester.pumpAndSettle();

      // 会话级 reasoningEffort 为 null → 下拉显示"跟随全局"
      expect(
        find.descendant(
          of: find.byType(IntermediateReasoningEffortSelector),
          matching: find.text('未单独设置'),
        ),
        findsOneWidget,
      );
      // 且展示"当前生效：…"（全局未配置 → 模型默认）
      expect(
        find.descendant(
          of: find.byType(IntermediateReasoningEffortSelector),
          matching: find.textContaining('当前生效'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('7. 点击分区标题折叠后内容隐藏（DOC-14 §3.4）', (tester) async {
      await _pumpSheet(tester, _draftSession());

      // 默认展开：温度（生成参数分区内）存在于树中
      expect(find.text('温度'), findsOneWidget);

      // 滚动到「生成参数」标题并点击折叠该分区
      await tester.ensureVisible(find.text('生成参数'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成参数'));
      await tester.pumpAndSettle();

      // 折叠后该分区内容（温度）不再渲染
      expect(find.text('温度'), findsNothing);
    });

    testWidgets('8. 一键折叠保留记忆管理（常驻），一键展开恢复（DOC-14 §3.4）', (tester) async {
      await _pumpSheet(tester, _draftSession());
      await tester.ensureVisible(find.text('记忆管理'));
      await tester.pumpAndSettle();

      // 一键折叠
      await tester.tap(find.byTooltip('全部折叠'));
      await tester.pumpAndSettle();

      // 记忆管理常驻：查看记忆库仍可见
      expect(find.text('查看记忆库'), findsOneWidget);
      // 其它分区被折叠：温度不可见
      expect(find.text('温度'), findsNothing);

      // 一键展开恢复
      await tester.tap(find.byTooltip('全部展开'));
      await tester.pumpAndSettle();
      expect(find.text('温度'), findsOneWidget);
    });
  });

  group('配置显示模式过滤（过滤只动展示层，存储与已有用户值不动）', () {
    testWidgets('S1. 简单模式：9 区收敛为 5 区，上下文/工具/推荐回复整区隐藏', (tester) async {
      await _pumpSheet(tester, _draftSession(), level: ConfigLevel.simple);

      // 保留区：记忆管理 / 角色卡世界书 / 分步骤模型 / 提示词 / 生成参数
      expect(find.text('记忆管理'), findsOneWidget);
      expect(find.text('角色卡/世界书'), findsWidgets);
      expect(find.text('分步骤模型配置'), findsNWidgets(2));
      expect(find.text('提示词'), findsOneWidget);
      expect(find.text('生成参数'), findsOneWidget);
      // 隐藏区：整区不渲染
      expect(find.text('上下文窗口'), findsNothing);
      expect(find.text('上下文预算'), findsNothing);
      expect(find.text('工具调用'), findsNothing);
      expect(find.text('推荐回复'), findsNothing);
    });

    testWidgets('S2. 生成参数区壳恒显、行级过滤：仅思考预算行可见', (tester) async {
      await _pumpSheet(tester, _draftSession(), level: ConfigLevel.simple);

      await tester.ensureVisible(find.text('生成参数'));
      await tester.pumpAndSettle();

      // 区内仅思考预算行（区壳与思考预算行保留，采样参数行全部隐藏）
      expect(find.text('温度'), findsNothing);
      expect(find.text('Top P'), findsNothing);
      expect(find.text('存在惩罚'), findsNothing);
      expect(find.text('频率惩罚'), findsNothing);
      expect(
        find.byType(IntermediateReasoningEffortSelector),
        findsOneWidget,
      );
    });

    testWidgets('S3. 记忆管理区整区保留，白话文案「重建记忆索引」生效', (tester) async {
      await _pumpSheet(tester, _draftSession(), level: ConfigLevel.simple);

      // 整区保留（不拆区）：状态行 + 两按钮全显示
      //（stub 仓库无记忆 → 状态行渲染「全部记忆已向量化」）
      expect(find.text('全部记忆已向量化'), findsOneWidget);
      expect(find.text('查看记忆库'), findsOneWidget);
      expect(find.text('重建记忆索引'), findsOneWidget);
      expect(find.text('重建向量索引'), findsNothing);
    });

    testWidgets('S4. 一键折叠/展开只作用于当前模式可见区', (tester) async {
      await _pumpSheet(tester, _draftSession(), level: ConfigLevel.simple);

      // 展开（默认态）：分步骤模型区标题 + 区内标题 = 2 处
      expect(find.text('分步骤模型配置'), findsNWidgets(2));

      // 一键折叠：可见区折叠，记忆管理常驻展开
      await tester.tap(find.byTooltip('全部折叠'));
      await tester.pumpAndSettle();
      expect(find.text('分步骤模型配置'), findsOneWidget);
      expect(find.text('查看记忆库'), findsOneWidget);

      // 一键展开恢复
      await tester.tap(find.byTooltip('全部展开'));
      await tester.pumpAndSettle();
      expect(find.text('分步骤模型配置'), findsNWidgets(2));
    });

    testWidgets('S5. 进阶模式：隐藏区与采样参数行原样回归', (tester) async {
      // 缺省 level 即进阶（现状全量基线）
      await _pumpSheet(tester, _draftSession());

      expect(find.text('上下文窗口'), findsOneWidget);
      expect(find.text('工具调用'), findsNWidgets(2));
      // 生成参数区六行全量
      expect(find.text('温度'), findsOneWidget);
      expect(find.text('Top P'), findsOneWidget);
      expect(find.text('存在惩罚'), findsOneWidget);
      expect(find.text('频率惩罚'), findsOneWidget);
    });
  });
}
