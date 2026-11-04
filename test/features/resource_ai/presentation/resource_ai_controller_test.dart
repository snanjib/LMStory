import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/agent/agent_runner.dart';
import 'package:lmstory/core/agent/agent_skill_registry.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/resource_ai_config.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/resource_ai/data/resource_ai_save_service.dart';
import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';
import 'package:lmstory/features/resource_ai/domain/services/draft_change_summary.dart';
import 'package:lmstory/features/resource_ai/domain/services/resource_ai_session.dart';
import 'package:lmstory/features/resource_ai/presentation/controllers/resource_ai_controller.dart';
import 'package:lmstory/features/resource_library/domain/entities/character_card.dart';
import 'package:lmstory/features/resource_library/domain/entities/worldbook.dart';
import 'package:lmstory/features/resource_library/domain/repositories/resource_library_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';

class _ScriptedGateway implements AgentLlmGateway {
  _ScriptedGateway(this.script);

  final List<AgentStepResponse> script;
  final List<AgentStepRequest> requests = [];
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
    requests.add(request);
    if (cursor >= script.length) {
      throw const AgentLlmException('script exhausted', retryable: false);
    }
    return script[cursor++];
  }
}

/// 永不自动完成的网关：把控制器钉在 generating 相。
class _HangingGateway implements AgentLlmGateway {
  final Completer<AgentStepResponse> response = Completer();

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
      response.future;
}

AgentStepResponse _text(String t) =>
    AgentStepResponse(text: t, toolCalls: const []);

AgentStepResponse _tool(String name, Map<String, dynamic> args) =>
    AgentStepResponse(
      text: '',
      toolCalls: [
        AgentToolCall(id: 'c${args.hashCode}', name: name, arguments: args),
      ],
    );

/// 可编排快照结果的 settings fake（记录 override 写入；其余 noSuchMethod 兜底）。
class _SnapshotSettingsRepository implements SettingsRepository {
  _SnapshotSettingsRepository({
    this.withModel = true,
    this.broadcastTemperature = 0.7,
  });

  final bool withModel;
  final double broadcastTemperature;
  final overrides = <String, dynamic>{};

  @override
  Future<AppConfig> getResolvedConfig() async => AppConfig(
        version: '0.1',
        broadcastChat: BroadcastChatConfig(
          presetId: withModel ? 'preset-1' : '',
          modelId: withModel ? 'model-1' : '',
          temperature: broadcastTemperature,
        ),
        resourceAi: ResourceAiConfig(
          modelPresetId: withModel ? 'preset-1' : null,
          modelId: withModel ? 'model-1' : null,
        ),
      );

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    overrides[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 记录保存调用的仓储 fake。
class _RecordingRepository implements ResourceLibraryRepository {
  int createCalls = 0;
  int updateCalls = 0;

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
      sourceFormat: sourceFormat,
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
  Future<void> updateCharacterCard({
    required String cardId,
    required String name,
    required String rawJson,
  }) async {
    updateCalls++;
  }

  @override
  Future<void> updateWorldbook({
    required String bookId,
    required String name,
    required String rawJson,
  }) async {
    updateCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 保存恒抛错的仓储 fake。
class _FailingSaveRepository extends _RecordingRepository {
  @override
  Future<CharacterCard> createCharacterCard({
    required String name,
    required String rawJson,
    String? sourceFormat,
  }) async {
    throw Exception('db locked');
  }

  @override
  Future<Worldbook> createWorldbook({
    required String name,
    required String rawJson,
  }) async {
    throw Exception('db locked');
  }
}

void main() {
  late _ScriptedGateway gateway;
  late ResourceAiController controller;
  late List<ResourceAiState> states;

  late _RecordingRepository repo;
  late _SnapshotSettingsRepository settingsRepo;

  ResourceAiController build({
    AgentLlmGateway? gw,
    ResourceAiConfig config = const ResourceAiConfig(maxSteps: 3),
    bool withModel = true,
    _RecordingRepository? repository,
    double broadcastTemperature = 0.7,
  }) {
    repo = repository ?? _RecordingRepository();
    settingsRepo = _SnapshotSettingsRepository(
      withModel: withModel,
      broadcastTemperature: broadcastTemperature,
    );
    final c = ResourceAiController(
      runner: AgentRunner(gateway: gw ?? gateway),
      session: ResourceAiSession(
        skillRegistry: const AgentSkillRegistry([]),
        loadSkillBody: (_) async => null,
        settingsRepository: settingsRepo,
      ),
      saveService: ResourceAiSaveService(repository: repo),
      resolveNaming: (preset, model) async => const NamingConfig(
        baseUrl: 'https://api.test',
        apiKey: 'k',
        modelId: 'm',
      ),
      config: config,
      kind: DraftKind.characterCard,
    );
    c.addListener(() => states.add(c.state));
    return c;
  }

  setUp(() {
    gateway = _ScriptedGateway(const []);
    states = [];
  });

  test('start 无模型 → idle；有模型 → ready + 空草稿', () async {
    controller = build(withModel: false);
    await controller.start();
    expect(controller.state.phase, ResourceAiPhase.idle);

    controller = build();
    await controller.start();
    expect(controller.state.phase, ResourceAiPhase.ready);
    expect(controller.state.draft!.card, isNotNull);
    expect(controller.state.draft!.hasConversation, isFalse);
  });

  test('文本轮：agent 回复进消息流，surface 追加', () async {
    controller = build(gw: _ScriptedGateway([_text('你好，我们开始建卡。')]));
    await controller.start();

    await controller.send('帮我建一个剑客');

    expect(controller.state.phase, ResourceAiPhase.ready);
    expect(
      controller.state.messages.last,
      isA<ResourceAiMessage>()
          .having((m) => m.role, 'role', ResourceAiMessageRole.assistant)
          .having((m) => m.text, 'text', '你好，我们开始建卡。'),
    );
    expect(controller.state.draft!.hasConversation, isTrue);
    // 用户消息与 agent 消息都在
    expect(
      controller.state.messages
          .where((m) => m.role == ResourceAiMessageRole.user),
      isNotEmpty,
    );
  });

  test('工具轮：update_draft 驱动草稿更新并产出 role=tool 过程消息', () async {
    controller = build(
      gw: _ScriptedGateway([
        _tool('update_draft', {
          'action': 'set_card_field',
          'field': 'name',
          'value': '阿尔',
        }),
        _text('已写入名字。'),
      ]),
    );
    await controller.start();
    await controller.send('开始');

    expect(controller.state.draft!.card!.value(CardField.name), '阿尔');
    expect(controller.state.phase, ResourceAiPhase.ready);

    final toolMessages = controller.state.messages
        .where((m) => m.role == ResourceAiMessageRole.tool)
        .toList();
    expect(toolMessages, hasLength(1));
    expect(toolMessages.single.change?.kind, DraftChangeKind.fieldUpdated);
    expect(toolMessages.single.change?.field, CardField.name);
  });

  test('同轮多次改稿：过程线逐条追加不重复，收尾只补一条 assistant', () async {
    controller = build(
      gw: _ScriptedGateway([
        _tool('update_draft', {
          'action': 'set_card_field',
          'field': 'name',
          'value': '阿尔',
        }),
        _tool('update_draft', {
          'action': 'set_card_tags',
          'tags': ['奇幻'],
        }),
        _text('完成'),
      ]),
    );
    await controller.start();
    await controller.send('建卡');

    final msgs = controller.state.messages;
    expect(
      msgs.where((m) => m.role == ResourceAiMessageRole.user),
      hasLength(1),
    );
    expect(
      msgs.where((m) => m.role == ResourceAiMessageRole.assistant),
      hasLength(1),
    );
    final toolMsgs =
        msgs.where((m) => m.role == ResourceAiMessageRole.tool).toList();
    expect(toolMsgs, hasLength(2));
    expect(toolMsgs[0].change?.kind, DraftChangeKind.fieldUpdated);
    expect(toolMsgs[1].change?.kind, DraftChangeKind.tagsUpdated);
    expect(msgs, hasLength(4), reason: 'user + 2 过程线 + assistant，无重复');
  });

  test('finalize 置位且非终止', () async {
    controller = build(
      gw: _ScriptedGateway([
        _tool('finalize_draft', <String, dynamic>{}),
        _text('草稿完成。'),
      ]),
    );
    await controller.start();
    await controller.send('完成它');

    expect(controller.state.draft!.finalized, isTrue);
    expect(controller.state.phase, ResourceAiPhase.ready);
    expect(controller.state.canSave, isTrue);
  });

  test('失败保留现场：fatal 后消息与草稿都在，可重发恢复', () async {
    controller = build(gw: _ScriptedGateway([_text('第一轮回复')]));
    await controller.start();
    await controller.send('第一轮');
    expect(controller.state.phase, ResourceAiPhase.ready);

    // 第二轮 script 耗尽 → 失败
    await controller.send('第二轮');
    expect(controller.state.phase, ResourceAiPhase.fatal);
    expect(
      controller.state.error?.kind,
      ResourceAiErrorKind.turnIncomplete,
      reason: '结构化错误：按 kind 区分，文案由 UI 本地化',
    );
    expect(
      controller.state.error?.detail,
      'script exhausted（不可重试错误）',
      reason: 'detail 为技术细节（runner 错误消息，缺失时回退停止原因），非用户文案',
    );
    expect(
      controller.state.messages,
      isNotEmpty,
      reason: '失败时保留现场',
    );
  });

  test('cancel：生成中取消回 ready，现场保留', () async {
    final slowGateway = _ScriptedGateway([
      const AgentStepResponse(text: '慢回复', toolCalls: []),
    ]);
    controller = build(gw: slowGateway);
    await controller.start();

    final turn = controller.send('慢请求');
    controller.cancel();
    await turn;

    expect(controller.state.phase, ResourceAiPhase.ready);
    expect(
      controller.state.messages.where((m) => m.text == '慢回复'),
      isEmpty,
      reason: '取消轮的回复不落流',
    );
  });

  test('save：成功 → saved（返回 null）；新建走 create 路径', () async {
    final recording = _RecordingRepository();
    controller = build(
      gw: _ScriptedGateway([
        _tool('update_draft', {
          'action': 'set_card_field',
          'field': 'name',
          'value': '阿尔',
        }),
        _text('ok'),
      ]),
      repository: recording,
    );
    await controller.start();
    await controller.send('写个名字');

    final error = await controller.save(overwrite: false);

    expect(error, isNull);
    expect(controller.state.phase, ResourceAiPhase.saved);
    expect(recording.createCalls, 1);
    expect(recording.updateCalls, 0);
  });

  test('save 空名 → nameMissing 失败信封：不落库、现场保留可补名再存', () async {
    final recording = _RecordingRepository();
    controller = build(
      gw: _ScriptedGateway([
        _tool('update_draft', {
          'action': 'set_card_field',
          'field': 'name',
          'value': '阿尔',
        }),
        _text('好，名字定了'),
      ]),
      repository: recording,
    );
    await controller.start();

    final error = await controller.save(overwrite: false);

    expect(error, isNotNull);
    expect(error?.kind, ResourceAiErrorKind.nameMissing);
    expect(controller.state.phase, ResourceAiPhase.ready, reason: '现场保留');
    expect(recording.createCalls, 0, reason: '不落未命名条目');

    // 补名后再存 → 成功
    final turn = controller.send('就叫他阿尔');
    await turn;
    final retry = await controller.save(overwrite: false);
    expect(retry, isNull);
    expect(controller.state.phase, ResourceAiPhase.saved);
    expect(recording.createCalls, 1);
  });

  test('save 失败 → 回 ready 返回文案，现场保留可再存（不进 fatal）', () async {
    final failing = _FailingSaveRepository();
    controller = build(
      gw: _ScriptedGateway([
        _tool('update_draft', {
          'action': 'set_card_field',
          'field': 'name',
          'value': '阿尔',
        }),
        _text('ok'),
      ]),
      repository: failing,
    );
    await controller.start();
    await controller.send('写个名字');
    expect(controller.state.canSave, isTrue);

    final error = await controller.save(overwrite: false);

    expect(error, isNotNull);
    expect(error?.kind, ResourceAiErrorKind.saveFailed, reason: '结构化错误');
    expect(error?.detail, contains('db locked'), reason: '错误来自仓储抛出的异常');
    expect(controller.state.phase, ResourceAiPhase.ready, reason: '不进 fatal');
    expect(controller.state.error, isNull, reason: '保存失败不置 error');
    expect(controller.state.canSave, isTrue, reason: '可重试保存');
    // 现场保留：消息与草稿仍在
    expect(controller.state.messages, isNotEmpty);
    expect(controller.state.draft!.card!.value(CardField.name), '阿尔');
  });

  test('attachReference：材料消息进 surface（模型可见）与消息流', () async {
    final gw = _ScriptedGateway([_text('收到材料')]);
    controller = build(gw: gw);
    await controller.start();

    controller.attachReference('这是原卡 JSON', '原卡.json');
    await controller.send('看看材料');

    expect(
      controller.state.messages
          .where((m) => m.role == ResourceAiMessageRole.material),
      isNotEmpty,
    );
    // 模型请求里能看到材料文本
    final sawMaterial = gw.requests.any(
      (r) => r.messages.any(
        (m) => (m['content'] as String?)?.contains('这是原卡 JSON') ?? false,
      ),
    );
    expect(sawMaterial, isTrue);
  });

  test('runTurn 组装：system 首条 + callConfig 温度随状态下发', () async {
    final gw = _ScriptedGateway([_text('ok')]);
    controller = build(gw: gw, config: const ResourceAiConfig(maxSteps: 5));
    await controller.start();
    await controller.updateGenerationParams(temperature: 0.4);
    await controller.send('x');

    final first = gw.requests.first.messages.first;
    expect(first['role'], 'system');
    expect(first['content'] as String, contains('角色卡'));
    expect(gw.requests.first.config.temperature, 0.4);
  });

  test('send：budget 取 state.maxSteps（调整后下一轮生效）', () async {
    // maxSteps=1：首个工具步耗尽预算 → 软着陆，第二个请求不再带工具
    final gw = _ScriptedGateway([
      _tool('update_draft', {
        'action': 'set_card_field',
        'field': 'name',
        'value': 'A',
      }),
      _text('收尾'),
    ]);
    controller = build(gw: gw, config: const ResourceAiConfig(maxSteps: 5));
    await controller.start();
    await controller.updateGenerationParams(maxSteps: 1);
    await controller.send('x');

    expect(gw.requests, hasLength(2));
    expect(gw.requests.first.tools, isNotEmpty);
    expect(gw.requests.last.tools, isEmpty, reason: 'maxSteps=1 软着陆停用工具');
    expect(controller.state.phase, ResourceAiPhase.ready);
  });

  test('updateModel：持久化 override 并更新状态，下一轮生效', () async {
    controller = build();
    await controller.start();

    final ok = await controller.updateModel(presetId: 'p2', modelId: 'm2');

    expect(ok, isTrue);
    expect(settingsRepo.overrides['resource_ai.model.preset_id'], 'p2');
    expect(settingsRepo.overrides['resource_ai.model.model_id'], 'm2');
    expect(controller.state.modelPresetId, 'p2');
    expect(controller.state.modelId, 'm2');
    expect(controller.state.phase, ResourceAiPhase.ready);
  });

  test('updateModel：generating 中拒绝（false，无副作用）', () async {
    final hang = _HangingGateway();
    controller = build(gw: hang);
    await controller.start();

    final turn = controller.send('慢请求');
    expect(controller.state.phase, ResourceAiPhase.generating);
    final ok = await controller.updateModel(presetId: 'p2', modelId: 'm2');
    expect(ok, isFalse);
    expect(settingsRepo.overrides, isEmpty, reason: '被拒时不写 override');
    expect(controller.state.modelPresetId, 'preset-1');

    hang.response.complete(_text('慢回复'));
    await turn;
    expect(controller.state.phase, ResourceAiPhase.ready);
  });

  test('updateGenerationParams：持久化非空项，未传项保持', () async {
    controller = build(config: const ResourceAiConfig(maxSteps: 4));
    await controller.start();
    expect(controller.state.maxSteps, 4, reason: 'start 取配置默认');

    await controller.updateGenerationParams(temperature: 0.2, maxSteps: 9);

    expect(settingsRepo.overrides['resource_ai.temperature'], 0.2);
    expect(settingsRepo.overrides['resource_ai.max_steps'], 9);
    expect(controller.state.temperature, 0.2);
    expect(controller.state.maxSteps, 9);

    await controller.updateGenerationParams(maxSteps: 5);
    expect(controller.state.temperature, 0.2, reason: '未传项保持原值');
    expect(controller.state.maxSteps, 5);
  });

  test('start：温度无 override 时从 broadcast 回退解析', () async {
    controller = build(broadcastTemperature: 0.85);
    await controller.start();

    expect(controller.state.temperature, 0.85);
    expect(controller.state.maxSteps, 3);
  });
}
