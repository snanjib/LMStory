import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/network/http_client.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/compaction_service.dart';
import 'package:lmstory/features/chat/domain/services/compaction_streamer.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/chat/presentation/controllers/chat_mode_controller.dart';
import 'package:lmstory/features/chat/presentation/pages/chat/chat_mode_page.dart';
import 'package:lmstory/features/chat/presentation/widgets/session_settings_sheet.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../test_helpers/stub_failure_log_repository.dart';

/// SessionSettingsSheet Widget 测试
///
///  修复回归测试（2026-07-22 审查补充）：
/// - 验证 sheet 通过 controller.updateSession 持久化（而非直接调 chatRepo）
/// - 验证草稿会话切换配置触发物化（createSession 被调用）
/// - 验证 sheet 内连续修改不会因 sessionId 过期失败

// ── Fakes / Stubs ─────────────────────────────────────────────────────

/// 跟踪 ChatRepository 调用，记录 createSession/updateSession 参数。
class _TrackingChatRepository implements ChatRepository {
  final List<({String title, String mode, String? modelId, String? presetId})>
      createCalls = [];
  final List<ChatSession> updateCalls = [];

  @override
  Future<ChatSession> createSession({
    required String title,
    String mode = 'simple',
    String? modelId,
    String? presetId,
  }) async {
    createCalls.add(
      (title: title, mode: mode, modelId: modelId, presetId: presetId),
    );
    return ChatSession(
      sessionId: 'real-${createCalls.length}',
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
  Future<ChatSession> updateSession(ChatSession session) async {
    updateCalls.add(session);
    return session;
  }

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _FakeApiPresetRepository implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => [
        ApiPreset(
          presetId: 'test-preset',
          name: 'Test',
          baseUrl: 'https://test.com',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ];

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
  Future<Map<String, dynamic>> getUserOverrides() async => {};

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

/// Stub LlmService（Simple 模式 ChatModeController 依赖）
///
/// 本测试聚焦 SessionSettingsSheet UI 交互，不会真正发起 LLM 调用，
/// 故用 noSuchMethod 抛 UnimplementedError 兜底。
class _StubLlmService implements LlmService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

// ── Fixtures ──────────────────────────────────────────────────────────

ChatSession _draftSession() => ChatSession(
      sessionId: '${ChatModeController.draftSessionIdPrefix}test',
      title: '测试会话',
      mode: 'simple',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );

/// 物化后的会话（列非 null）——值恰等于全局默认
ChatSession _materializedSession() => ChatSession(
      sessionId: 'materialized-session-1',
      title: '测试会话',
      mode: 'simple',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
      temperature: 0.7,
      topP: 1,
    );

// ── Pump helper ───────────────────────────────────────────────────────

/// harness 缺省进阶模式：既有用例 = 「进阶=现状全量」回归组；
/// 配置显示模式过滤组显式传 level 验证双态。
Future<ProviderContainer> _pumpSheet(
  WidgetTester tester,
  ChatSession session, {
  _TrackingChatRepository? trackingRepo,
  ConfigLevel level = ConfigLevel.advanced,
}) async {
  // Sheet 内容较长，用手机尺寸视口避免裁剪
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  // mock 持久化值与 initialValue 一致，notifier _load 兜底重读不回跳。
  SharedPreferences.setMockInitialValues({
    if (level == ConfigLevel.advanced) ConfigLevelNotifier.prefKey: 'advanced',
  });
  final configPrefs = Preferences(prefs: await SharedPreferences.getInstance());

  final chatRepo = trackingRepo ?? _TrackingChatRepository();
  final presetRepo = _FakeApiPresetRepository();
  final settingsRepo = _StubSettingsRepository();
  final httpClient = _StubHttpClient();
  final llmService = _StubLlmService();
  const logger = Logger('test');
  const failureLogRepo = StubFailureLogRepository();
  final compactionService = CompactionService(
    chatRepository: chatRepo,
    tokenCounter: TokenCounter(),
    settingsRepository: settingsRepo,
    presetRepository: presetRepo,
    streamer: CompactionStreamer(llmService: llmService),
    llmService: llmService,
  );

  await tester.pumpWidget(
    ProviderScope(
      // ignore: invalid_use_of_provider_in_test
      overrides: [
        chatRepositoryProvider.overrideWithValue(chatRepo),
        apiPresetRepositoryProvider.overrideWithValue(presetRepo),
        templateRepositoryProvider.overrideWithValue(_StubTemplateRepository()),
        settingsRepositoryProvider.overrideWithValue(settingsRepo),
        compactionServiceProvider.overrideWithValue(compactionService),
        httpClientProvider.overrideWithValue(httpClient),
        llmServiceProvider.overrideWithValue(llmService),
        loggerProvider.overrideWithValue(logger),
        failureLogRepositoryProvider.overrideWithValue(failureLogRepo),
        configLevelProvider.overrideWith(
          (ref) => ConfigLevelNotifier(configPrefs, initialValue: level),
        ),
        chatModeControllerProvider(session).overrideWith((ref) {
          return ChatModeController(
            chatRepository: chatRepo,
            presetRepository: presetRepo,
            settingsRepository: settingsRepo,
            compactionService: compactionService,
            llmService: llmService,
            logger: logger,
            failureLogRepository: failureLogRepo,
            session: session,
          );
        }),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: Scaffold(
            body: SessionSettingsSheet(
              session: session,
              onSessionUpdated: (_) {},
              onSessionDeleted: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(SessionSettingsSheet)),
  );
}

// ── Tests ─────────────────────────────────────────────────────────────

void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('跟随全局标注判据', () {
    testWidgets('物化后温度/TopP 恰等于全局 → 「全局 X」标注可见（值比较）', (tester) async {
      await _pumpSheet(tester, _materializedSession());

      // 修复前：null 判据下物化列恒非 null → 标注永久消失
      expect(find.text('全局 0.70'), findsOneWidget, reason: '温度=全局默认 0.7');
      expect(find.text('全局 1.00'), findsOneWidget, reason: 'TopP=全局默认 1.0');
    });

    testWidgets('温度偏离全局 → 标注消失（自定义态）', (tester) async {
      await _pumpSheet(
        tester,
        _materializedSession().copyWith(temperature: 0.5),
      );

      expect(find.text('全局 0.50'), findsNothing, reason: '0.5 非全局值，无标注');
      expect(find.text('全局 1.00'), findsOneWidget, reason: 'TopP 仍等于全局');
    });
  });

  group('SessionSettingsSheet C1 修复回归', () {
    testWidgets('1. 草稿会话切换流式输出 → 触发物化（createSession 被调用）', (tester) async {
      final trackingRepo = _TrackingChatRepository();
      final session = _draftSession();
      await _pumpSheet(tester, session, trackingRepo: trackingRepo);

      // 初始状态：无 createSession / updateSession 调用
      expect(trackingRepo.createCalls, isEmpty);
      expect(trackingRepo.updateCalls, isEmpty);

      // 找到流式输出开关（唯一的 SwitchListTile）并切换
      final switchFinder = find.byType(SwitchListTile);
      expect(switchFinder, findsOneWidget);
      await tester.ensureVisible(switchFinder);
      await tester.pumpAndSettle();
      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      //  修复验证：物化触发 → createSession 被调用
      expect(
        trackingRepo.createCalls.length,
        1,
        reason: '草稿会话切换配置应触发物化（createSession）',
      );
      // 物化后 updateSession 也被调用（持久化快照）
      expect(
        trackingRepo.updateCalls.length,
        greaterThanOrEqualTo(1),
        reason: '物化后应调用 updateSession 持久化快照',
      );
    });

    testWidgets('2. 物化后 controller.state.session 不再是草稿', (tester) async {
      final session = _draftSession();
      final container = await _pumpSheet(tester, session);

      // 初始：sessionId 以 __draft_ 开头
      expect(
        container.read(chatModeControllerProvider(session)).session.sessionId,
        startsWith('__draft_'),
      );

      // 切换流式输出开关
      final switchFinder = find.byType(SwitchListTile);
      await tester.ensureVisible(switchFinder);
      await tester.pumpAndSettle();
      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      // 物化后：sessionId 变成 real-xxx
      final updatedSession =
          container.read(chatModeControllerProvider(session)).session;
      expect(
        updatedSession.sessionId,
        startsWith('real-'),
        reason: '物化后 sessionId 应从 __draft_ 变成 real-',
      );
      // streamEnabled 应被更新
      expect(
        updatedSession.streamEnabled,
        isNotNull,
        reason: '物化时 streamEnabled 应从快照填充',
      );
    });

    testWidgets('3. 连续两次切换 → 第二次也成功（sessionId 同步）', (tester) async {
      final trackingRepo = _TrackingChatRepository();
      final session = _draftSession();
      final container = await _pumpSheet(
        tester,
        session,
        trackingRepo: trackingRepo,
      );

      // 第一次切换
      final switchFinder = find.byType(SwitchListTile);
      await tester.ensureVisible(switchFinder);
      await tester.pumpAndSettle();
      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      // 第一次物化成功
      expect(trackingRepo.createCalls.length, 1);
      final firstSession =
          container.read(chatModeControllerProvider(session)).session;
      expect(firstSession.sessionId, startsWith('real-'));

      // 第二次切换
      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      // 第二次不应再触发 createSession（已是真实会话）
      expect(trackingRepo.createCalls.length, 1, reason: '第二次修改不应再触发物化');
      // 第二次应调用 updateSession（直接更新真实会话）
      expect(
        trackingRepo.updateCalls.length,
        greaterThanOrEqualTo(2),
        reason: '第二次修改应通过 updateSession 持久化',
      );

      // 验证（核心）：第二次修改后，用草稿 key 查找的 controller state
      // 必须反映第二次修改。
      // 时序：初始 streamEnabled=null（fallbackDefault=true，开关显示开启）
      //   第一次 tap → onChanged(false) → 物化后 streamEnabled=false（开关关闭）
      //   第二次 tap → onChanged(true) → 第二次修改后 streamEnabled=true（开关开启）
      // 修复前 bug：sheet 用 _session（物化后变成 real-xxx）查找 family provider，
      // key 变化导致创建新 controller 实例，第二次修改写到新 controller，
      // 草稿 controller state 仍是 false（第一次的值）。
      // 修复后：sheet 用 widget.session（草稿 key）查找，始终复用草稿 controller，
      // state 正确反映为 true（第二次切换把开关打开）。
      final draftControllerState =
          container.read(chatModeControllerProvider(session));
      expect(
        draftControllerState.session.streamEnabled,
        isTrue,
        reason: '草稿 controller state 应反映第二次修改（开关切回 true），'
            ' 修复前 bug 会导致此处仍为 false（第一次的值）',
      );
    });
  });

  group('SessionSettingsSheet 配置显示模式过滤（8 字段 → 3 字段）', () {
    testWidgets('简单模式：模型/系统提示词/思考预算保留，采样参数族隐藏', (tester) async {
      await _pumpSheet(
        tester,
        _materializedSession(),
        level: ConfigLevel.simple,
      );

      expect(find.text('模型'), findsWidgets);
      expect(find.text('系统提示词'), findsOneWidget);
      expect(find.text('思考预算'), findsOneWidget);
      expect(find.text('删除会话'), findsOneWidget);
      expect(find.text('温度'), findsNothing);
      expect(find.text('Top P'), findsNothing);
      expect(find.text('最大 Token 数'), findsNothing);
      expect(find.text('最大上下文消息数'), findsNothing);
      expect(find.text('流式输出'), findsNothing);
    });

    testWidgets('进阶模式：8 字段全量渲染', (tester) async {
      await _pumpSheet(tester, _materializedSession());

      expect(find.text('模型'), findsWidgets);
      expect(find.text('系统提示词'), findsOneWidget);
      expect(find.text('温度'), findsOneWidget);
      expect(find.text('Top P'), findsOneWidget);
      expect(find.text('最大 Token 数'), findsOneWidget);
      expect(find.text('最大上下文消息数'), findsOneWidget);
      expect(find.text('流式输出'), findsOneWidget);
      expect(find.text('思考预算'), findsOneWidget);
    });

    testWidgets('简单模式被隐藏字段的已有值继续生效（温度 0.7 保持）', (tester) async {
      final container = await _pumpSheet(
        tester,
        _materializedSession(),
        level: ConfigLevel.simple,
      );

      // 过滤只动展示层：温度行隐藏但会话值不被清除
      expect(
        container
            .read(chatModeControllerProvider(_materializedSession()))
            .session
            .temperature,
        0.7,
      );
    });
  });
}
