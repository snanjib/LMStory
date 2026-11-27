import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/agent/agent_runner.dart';
import 'package:lmstory/core/agent/agent_skill_registry.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/resource_ai_config.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/resource_ai/data/resource_ai_save_service.dart';
import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';
import 'package:lmstory/features/resource_ai/domain/services/resource_ai_session.dart';
import 'package:lmstory/features/resource_ai/presentation/controllers/resource_ai_controller.dart';
import 'package:lmstory/features/resource_ai/presentation/widgets/resource_ai_session_settings_sheet.dart';
import 'package:lmstory/features/resource_library/domain/entities/character_card.dart';
import 'package:lmstory/features/resource_library/domain/entities/worldbook.dart';
import 'package:lmstory/features/resource_library/domain/repositories/resource_library_repository.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';
import '../../../test_helpers/stub_settings_notifier.dart';

// ── Fakes（与 resource_ai_controller_test 同套路） ─────────────────────

class _ScriptedGateway implements AgentLlmGateway {
  _ScriptedGateway(this.script);

  final List<dynamic> script;
  int cursor = 0;

  @override
  Future<AgentStepResponse> completeStep({
    required AgentModelEndpoint endpoint,
    required AgentStepRequest request,
    required AgentCancellationToken cancellation,
    void Function(String delta)? onTextDelta,
    void Function(String delta)? onThinkingDelta,
    void Function(String toolCallId, String toolName, String delta)?
        onToolArgDelta,
  }) async {
    if (cursor >= script.length) {
      throw const AgentLlmException('script exhausted', retryable: false);
    }
    return script[cursor++] as AgentStepResponse;
  }
}

/// 控制器侧 settings fake（记录 override 写入）。
class _ControllerSettingsRepo implements SettingsRepository {
  _ControllerSettingsRepo({this.broadcastTemperature = 0.7});

  final double broadcastTemperature;

  @override
  Future<AppConfig> getResolvedConfig() async => AppConfig(
        version: '0.1',
        broadcastChat: BroadcastChatConfig(
          presetId: 'preset-1',
          modelId: 'model-1',
          temperature: broadcastTemperature,
        ),
        resourceAi: const ResourceAiConfig(
          modelPresetId: 'preset-1',
          modelId: 'model-1',
        ),
      );

  @override
  Future<void> setUserOverride(String key, dynamic value) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 记录保存调用的仓储 fake。
class _RecordingRepository implements ResourceLibraryRepository {
  int createCalls = 0;

  @override
  Future<CharacterCard> createCharacterCard({
    required String name,
    required String rawJson,
    String? sourceFormat,
  }) async {
    createCalls++;
    return CharacterCard(
      cardId: 'card-new',
      name: name,
      rawJson: rawJson,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
  }

  @override
  Future<Worldbook> createWorldbook({
    required String name,
    required String rawJson,
  }) async {
    createCalls++;
    return Worldbook(
      bookId: 'book-new',
      name: name,
      rawJson: rawJson,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  late _RecordingRepository repo;

  Future<ResourceAiController> buildController({
    bool dirty = false,
    double broadcastTemperature = 0.7,
  }) async {
    final settingsRepo = _ControllerSettingsRepo(
      broadcastTemperature: broadcastTemperature,
    );
    final controller = ResourceAiController(
      runner: AgentRunner(gateway: _ScriptedGateway(const [])),
      session: ResourceAiSession(
        skillRegistry: const AgentSkillRegistry([]),
        loadSkillBody: (_) async => null,
        settingsRepository: settingsRepo,
      ),
      saveService: ResourceAiSaveService(repository: repo),
      resolveNaming: (p, m) async => NamingConfig(
        baseUrl: 'https://api.test',
        apiKey: 'k',
        modelId: m,
      ),
      config: const ResourceAiConfig(),
      kind: DraftKind.characterCard,
      initialDraft: dirty
          ? DraftState.empty(DraftKind.characterCard).withCard(
              const CardDraft(fields: {CardField.name: '阿尔'}),
            )
          : null,
    );
    await controller.start();
    return controller;
  }

  /// 经真实入口（modal bottom sheet）泵出面板。
  Future<void> pumpSheet(
    WidgetTester tester,
    ResourceAiController controller, {
    List<ApiPreset>? presets,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsNotifierProvider.overrideWith((ref) {
            return StubSettingsNotifier(presets: presets);
          }),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => showResourceAiSessionSettingsSheet(
                    context,
                    controller: controller,
                  ),
                  child: const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // SettingsNotifier 异步装载完成
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  setUp(() {
    repo = _RecordingRepository();
  });

  testWidgets('渲染三个区块标题与模型行显示名', (tester) async {
    final controller = await buildController();
    await pumpSheet(tester, controller);

    expect(find.text('会话设置'), findsOneWidget);
    expect(find.text('模型'), findsOneWidget);
    // 卡片行标签为动作语义（更换模型），与区块标题不重复
    expect(find.text('更换模型'), findsOneWidget);
    expect(find.text('生成参数'), findsOneWidget);
    expect(find.text('草稿预览'), findsOneWidget);
    // 模型行解析出显示名（而非原始 id）
    expect(find.text('测试供应商 / 测试模型'), findsOneWidget);
    expect(find.text('温度'), findsOneWidget);
    expect(find.text('单轮最大步数'), findsOneWidget);
  });

  testWidgets('资源助手按当前供应商设置隐藏温度', (tester) async {
    final controller = await buildController();
    await pumpSheet(
      tester,
      controller,
      presets: [
        ApiPreset(
          presetId: 'preset-1',
          name: 'Relay',
          baseUrl: 'https://relay.test',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          providerOptions: const {'omit_sampling_params': true},
        ),
      ],
    );

    expect(find.text(t.resourceAi.temperatureLabel), findsNothing);
    expect(find.text(t.resourceAi.maxStepsLabel), findsOneWidget);
  });

  testWidgets('干净草稿：完成按钮禁用 + 提示文案', (tester) async {
    final controller = await buildController();
    await pumpSheet(tester, controller);

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(find.textContaining('草稿还没有内容'), findsOneWidget);
  });

  testWidgets('脏草稿：完成流确认 → 保存成功（面板不自弹，退出由页面收尾）', (tester) async {
    final controller = await buildController(dirty: true);
    await pumpSheet(tester, controller);

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNotNull);

    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    // 新建模式：确认对话框正文含草稿名
    expect(find.textContaining('将保存「阿尔」到资源库并结束本次写卡。'), findsOneWidget);

    // 对话框里的确认按钮（标题与确认文案同为「完成创建」，按类型定位）
    final confirm = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(FilledButton),
    );
    await tester.tap(confirm);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(repo.createCalls, 1, reason: '确认后走新建保存');
    expect(controller.state.phase, ResourceAiPhase.saved);
    // 面板成功后不自弹（终审 P1：saved 的弹路由页面监听统一收尾，
    // 本装配无页面监听故面板仍在；页面级集成断言见 page 测试）。
    expect(find.byType(ResourceAiSessionSettingsSheet), findsOneWidget);
  });

  testWidgets('温度滑块释放才提交 → 状态与 override 更新；重置回全局值', (tester) async {
    final controller = await buildController(broadcastTemperature: 0.5);
    await pumpSheet(tester, controller);

    expect(controller.state.temperature, 0.5);
    expect(find.text('0.5'), findsOneWidget);

    // 向右拖温度滑块（第一个 Slider），释放提交
    await tester.drag(find.byType(Slider).first, const Offset(60, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final committed = controller.state.temperature;
    expect(committed, isNotNull, reason: '拖动释放后提交新温度');
    expect(committed, greaterThan(0.5));

    // 重置为全局默认（fake 广播值 0.5）
    await tester.tap(find.byTooltip('重置为全局默认'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(controller.state.temperature, 0.5);
    expect(find.text('0.5'), findsOneWidget);
  });
}
