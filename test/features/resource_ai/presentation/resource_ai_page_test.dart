import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/agent/agent_runner.dart';
import 'package:lmstory/core/agent/agent_skill_registry.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/resource_ai_config.dart';
import 'package:lmstory/core/theme/simple/components/simple_markdown_body.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/resource_ai/data/resource_ai_save_service.dart';
import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';
import 'package:lmstory/features/resource_ai/domain/services/resource_ai_session.dart';
import 'package:lmstory/features/resource_ai/presentation/controllers/resource_ai_controller.dart';
import 'package:lmstory/features/resource_ai/presentation/pages/resource_ai_page.dart';
import 'package:lmstory/features/resource_ai/presentation/resource_ai_providers.dart';
import 'package:lmstory/features/resource_library/domain/entities/character_card.dart';
import 'package:lmstory/features/resource_library/domain/entities/worldbook.dart';
import 'package:lmstory/features/resource_library/domain/repositories/resource_library_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';
import '../../../test_helpers/stub_settings_notifier.dart';

void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  late AgentLlmGateway gateway;

  /// 页面自建 controller（builder 捕获，供门/保存流测试直接驱动）。
  ResourceAiController? captured;

  ResourceAiController buildController({bool withModel = true}) {
    return ResourceAiController(
      runner: AgentRunner(gateway: gateway),
      session: ResourceAiSession(
        skillRegistry: const AgentSkillRegistry([]),
        loadSkillBody: (_) async => null,
        settingsRepository: _SnapshotRepo(withModel: withModel),
      ),
      saveService: ResourceAiSaveService(repository: _SaveRepo()),
      resolveNaming: (p, m) async => NamingConfig(
        baseUrl: 'https://api.test',
        apiKey: 'k',
        modelId: m,
      ),
      config: const ResourceAiConfig(maxSteps: 3),
      kind: DraftKind.characterCard,
    );
  }

  /// 页面（home 或推入路由，后者用于验证 saved 自动退出）。
  Widget wrap({bool withModel = true, bool pushed = false}) {
    Widget page() => const ResourceAiPage(kind: DraftKind.characterCard);
    return ProviderScope(
      overrides: [
        resourceAiControllerBuilderProvider.overrideWithValue(
          ({
            required kind,
            targetCardId,
            targetBookId,
            targetSummary,
            originalRawJson,
          }) async {
            final c = buildController(withModel: withModel);
            captured = c;
            return c;
          },
        ),
        settingsNotifierProvider.overrideWith((ref) {
          return StubSettingsNotifier();
        }),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: pushed
              ? Scaffold(
                  body: Builder(
                    builder: (context) => ElevatedButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => page()),
                      ),
                      child: const SizedBox.shrink(),
                    ),
                  ),
                )
              : page(),
        ),
      ),
    );
  }

  Future<void> boot(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  setUp(() {
    captured = null;
  });

  testWidgets('无模型 → 内联模型选择门渲染', (tester) async {
    gateway = _ScriptedGateway(const []);
    await tester.pumpWidget(wrap(withModel: false));
    await boot(tester);

    expect(find.text('选择建卡模型'), findsOneWidget);
    expect(find.text('开始'), findsOneWidget);
  });

  testWidgets('模型门：选择器选中即持久化 → 标签更新 → 开始进入 ready', (tester) async {
    gateway = _ScriptedGateway(const []);
    await tester.pumpWidget(wrap(withModel: false));
    await boot(tester);

    // 打开内联选择器的嵌套模型面板
    await tester.tap(find.byIcon(Icons.tune_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('测试供应商'), findsOneWidget);

    // 分组默认折叠（未含当前选择）：先展开再选模型
    await tester.tap(find.text('测试供应商'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('测试模型'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 门标签显示所选引用（原始 id），选择已持久化 override
    expect(find.text('preset-1 / model-1'), findsOneWidget);

    await tester.tap(find.text('开始'));
    await boot(tester);

    expect(find.text('选择建卡模型'), findsNothing, reason: 'start 以快照进入 ready');
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('有模型 → 消息流 + 输入栏；发送后渲染用户与 agent 消息', (tester) async {
    gateway = _ScriptedGateway([
      _ScriptedGateway.text('好的，我们开始。'),
    ]);
    await tester.pumpWidget(wrap());
    await boot(tester);

    expect(find.text('选择建卡模型'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), '帮我建一个剑客');
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('帮我建一个剑客'), findsOneWidget);
    expect(find.text('好的，我们开始。'), findsOneWidget);
  });

  testWidgets('⚙ 打开会话设置面板', (tester) async {
    gateway = _ScriptedGateway(const []);
    await tester.pumpWidget(wrap());
    await boot(tester);

    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('会话设置'), findsOneWidget);
    expect(find.text('草稿预览'), findsOneWidget);
  });

  testWidgets('assistant 消息用 markdown 渲染，user 消息保持纯文本', (tester) async {
    gateway = _ScriptedGateway([
      _ScriptedGateway.text('**好的**，我们开始。'),
    ]);
    await tester.pumpWidget(wrap());
    await boot(tester);

    await tester.enterText(find.byType(TextField), '帮我建一个剑客');
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(SimpleMarkdownBody), findsOneWidget);
    expect(find.text('帮我建一个剑客'), findsOneWidget);
  });

  testWidgets('工具改稿过程线渲染本地化变更文案', (tester) async {
    gateway = _ScriptedGateway([
      _tool('update_draft', {
        'action': 'set_card_field',
        'field': 'personality',
        'value': '沉稳',
      }),
      _ScriptedGateway.text('写好了。'),
    ]);
    await tester.pumpWidget(wrap());
    await boot(tester);

    await tester.enterText(find.byType(TextField), '写个性格');
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('更新了性格'), findsOneWidget);
  });

  testWidgets('定稿横幅：草稿已定稿 + 完成创建入口', (tester) async {
    gateway = _ScriptedGateway([
      _tool('finalize_draft', <String, dynamic>{}),
      _ScriptedGateway.text('草稿完成。'),
    ]);
    await tester.pumpWidget(wrap());
    await boot(tester);

    await tester.enterText(find.byType(TextField), '完成它');
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // 「草稿已定稿」出现两处：tool 过程线 + 定稿横幅
    expect(find.text('草稿已定稿'), findsNWidgets(2));
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.widgetWithText(TextButton, '完成创建'), findsOneWidget);
  });

  testWidgets('保存成功 → savedToast + 页面自动退出', (tester) async {
    gateway = _ScriptedGateway([
      _tool('update_draft', {
        'action': 'set_card_field',
        'field': 'name',
        'value': '阿尔',
      }),
      _ScriptedGateway.text('写好了。'),
    ]);
    // 推入路由（资源库真实入口形态），saved 后 pop 才有处可退
    await tester.pumpWidget(wrap(pushed: true));
    await tester.tap(find.byType(ElevatedButton));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ResourceAiPage), findsOneWidget);

    await tester.enterText(find.byType(TextField), '写个名字');
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(captured!.state.canSave, isTrue);

    await captured!.save(overwrite: false);
    await tester.pump();
    // 退出动画（MaterialPageRoute 反向 300ms）走完页面才移除
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(captured!.state.phase, ResourceAiPhase.saved);
    expect(find.byType(ResourceAiPage), findsNothing, reason: 'saved 终态自动退出');
    expect(find.text('已保存到资源库'), findsOneWidget, reason: 'savedToast');
  });

  testWidgets('设置面板完成创建：saved 由页面统一收尾，不误弹下层页', (tester) async {
    gateway = _ScriptedGateway([
      _tool('update_draft', {
        'action': 'set_card_field',
        'field': 'name',
        'value': '贝拉',
      }),
      _ScriptedGateway.text('写好了。'),
    ]);
    // 推入形态：home 上的 ElevatedButton 充当资源库层——终审 P1 回归锚
    // （面板完成成功后面板与本页由页面 saved 监听弹出，绝不能再弹 home）。
    await tester.pumpWidget(wrap(pushed: true));
    await tester.tap(find.byType(ElevatedButton));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.enterText(find.byType(TextField), '写个名字');
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(captured!.state.canSave, isTrue);

    // ⚙ 打开会话设置面板 → 完成创建 → 确认
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('会话设置'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '完成创建'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 对话框确认（同名按钮取 overlay 中最后者=对话框内）
    await tester.tap(
      find.widgetWithText(FilledButton, '完成创建').last,
    );
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(captured!.state.phase, ResourceAiPhase.saved);
    expect(find.byType(ResourceAiPage), findsNothing, reason: '建卡页已退出');
    // 关键断言：充当资源库的 home 仍在（双弹缺陷会把它一起弹掉）
    expect(find.byType(ElevatedButton), findsOneWidget, reason: '下层页未被误弹');
    expect(find.text('已保存到资源库'), findsOneWidget);
  });

  testWidgets('生成中会话面板模型行禁用（避免选择器假成功）', (tester) async {
    gateway = _HangingGateway();
    await tester.pumpWidget(wrap());
    await boot(tester);

    await tester.enterText(find.byType(TextField), 'x');
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(captured!.state.phase, ResourceAiPhase.generating);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 模型行禁用：点击不弹选择器（否则选择器会报成功但 override 未写）
    await tester.tap(find.text('更换模型'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('测试供应商'), findsNothing, reason: '嵌套选择器未打开');
  });

  testWidgets('生成中显示停止键与协作提示', (tester) async {
    gateway = _ScriptedGateway([
      _ScriptedGateway.text('慢'),
    ]);
    // 生成中无法进 send 完成前断言——用慢速 gateway：第一步挂起
    gateway = _HangingGateway();
    await tester.pumpWidget(wrap());
    await boot(tester);

    await tester.enterText(find.byType(TextField), 'x');
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.byIcon(Icons.send_outlined), findsNothing);
    expect(find.text('正在与模型协作……'), findsOneWidget);
  });

  testWidgets('失败 → 错误横幅 + 重试按钮', (tester) async {
    gateway = _ScriptedGateway([
      _ScriptedGateway.text('第一轮'),
    ]);
    await tester.pumpWidget(wrap());
    await boot(tester);

    await tester.enterText(find.byType(TextField), '第一轮');
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('好的，我们开始。'), findsNothing);

    // 第二轮 script 耗尽 → fatal
    await tester.enterText(find.byType(TextField), '第二轮');
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // 结构化错误经 slang 映射：kind=turnIncomplete + detail=停止原因
    expect(
      find.text('本轮未完成（script exhausted（不可重试错误）），可重发。'),
      findsOneWidget,
    );
    expect(find.text('重试上一条'), findsOneWidget);
    expect(find.text('忽略'), findsOneWidget);
  });

  testWidgets('有对话未保存时退出拦截，确认后才退出', (tester) async {
    gateway = _ScriptedGateway([
      _ScriptedGateway.text('回复'),
    ]);
    await tester.pumpWidget(wrap());
    await boot(tester);

    await tester.enterText(find.byType(TextField), 'hi');
    await tester.tap(find.byIcon(Icons.send_outlined));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // 有对话 → PopScope 拦截：系统返回触发确认弹窗
    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(find.text('退出将丢弃本次对话'), findsOneWidget);
    expect(find.text('仍要退出'), findsOneWidget);

    // 取消 → 不退出（弹窗关闭，页面仍在）
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(find.byType(ResourceAiPage), findsOneWidget);
  });

  testWidgets('无对话时直接退出无拦截', (tester) async {
    gateway = _ScriptedGateway(const []);
    await tester.pumpWidget(wrap());
    await boot(tester);

    // hasConversation=false → 系统返回不弹确认直接退出
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('退出将丢弃本次对话'), findsNothing);
  });
}

AgentStepResponse _tool(String name, Map<String, dynamic> args) =>
    AgentStepResponse(
      text: '',
      toolCalls: [
        AgentToolCall(id: 'c${args.hashCode}', name: name, arguments: args),
      ],
    );

class _ScriptedGateway implements AgentLlmGateway {
  _ScriptedGateway(this.script);

  final List<AgentStepResponse> script;
  int cursor = 0;

  static AgentStepResponse text(String t) =>
      AgentStepResponse(text: t, toolCalls: const []);

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
    return script[cursor++];
  }
}

class _HangingGateway implements AgentLlmGateway {
  final completer = Completer<AgentStepResponse>();

  @override
  Future<AgentStepResponse> completeStep({
    required AgentModelEndpoint endpoint,
    required AgentStepRequest request,
    required AgentCancellationToken cancellation,
    void Function(String delta)? onTextDelta,
    void Function(String delta)? onThinkingDelta,
    void Function(String toolCallId, String toolName, String delta)?
        onToolArgDelta,
  }) =>
      completer.future;
}

/// 快照 fake：merge 已写入的 resource_ai.model.* override（门选择持久化后
/// start 能读到快照），其余静态。
class _SnapshotRepo implements SettingsRepository {
  _SnapshotRepo({required this.withModel});

  final bool withModel;
  final overrides = <String, dynamic>{};

  @override
  Future<AppConfig> getResolvedConfig() async {
    final overridePreset = overrides['resource_ai.model.preset_id'] as String?;
    final overrideModel = overrides['resource_ai.model.model_id'] as String?;
    return AppConfig(
      version: '0.1',
      broadcastChat: BroadcastChatConfig(
        presetId: withModel ? 'preset-1' : '',
        modelId: withModel ? 'model-1' : '',
      ),
      resourceAi: ResourceAiConfig(
        modelPresetId: overridePreset ?? (withModel ? 'preset-1' : null),
        modelId: overrideModel ?? (withModel ? 'model-1' : null),
      ),
    );
  }

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    overrides[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _SaveRepo implements ResourceLibraryRepository {
  @override
  Future<CharacterCard> createCharacterCard({
    required String name,
    required String rawJson,
    String? sourceFormat,
  }) async =>
      CharacterCard(
        cardId: 'c1',
        name: name,
        rawJson: rawJson,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  @override
  Future<Worldbook> createWorldbook({
    required String name,
    required String rawJson,
  }) async =>
      Worldbook(
        bookId: 'b1',
        name: name,
        rawJson: rawJson,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
