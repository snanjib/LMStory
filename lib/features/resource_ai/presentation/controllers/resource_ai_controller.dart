/// resource_ai 会话控制器：状态机 + agent 轮驱动 + 保存流。
///
/// 状态相：idle（未选模型）→ ready ⇄ generating →（save）saving → saved；
/// 失败进 fatal（保留现场，可重发）。草稿经工具回调原子替换。
///
/// 会话级设置（模型 updateModel / 生成参数 updateGenerationParams）
/// 持久化为 override、下一轮生效；轮内工具改稿经 summarizeDraftChanges
/// 即时产出 role=tool 过程消息（实时草稿预览 + 过程线）。错误结构化：
/// fatal 与保存失败产出 [ResourceAiError]（kind+detail），UI 按 kind 映射
/// slang 文案、detail 仅作技术细节拼入。save 失败不进 fatal：返回错误
/// 对象并回 ready（现场保留，可重试）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:lmstory/core/agent/agent_budget.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_events.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/agent/agent_runner.dart';
import 'package:lmstory/core/config/resource_ai_config.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/resource_ai/data/resource_ai_save_service.dart';
import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';
import 'package:lmstory/features/resource_ai/domain/services/draft_change_summary.dart';
import 'package:lmstory/features/resource_ai/domain/services/resource_ai_prompts.dart';
import 'package:lmstory/features/resource_ai/domain/services/resource_ai_session.dart';
import 'package:lmstory/features/resource_ai/domain/services/resource_ai_tools.dart';

enum ResourceAiPhase {
  /// 未选模型（等待内联选择或全局配置）
  idle,

  /// 可对话
  ready,

  /// agent 执行中
  generating,

  /// 落库中
  saving,

  /// 保存成功（终态，页面随后关闭）
  saved,

  /// 错误（现场保留，可重发）
  fatal,
}

enum ResourceAiMessageRole { user, assistant, material, tool }

/// fatal/保存失败的结构化错误（UI 按 kind 映射 slang 文案，detail 为技术细节）。
enum ResourceAiErrorKind { modelUnavailable, turnIncomplete, saveFailed }

class ResourceAiError {
  const ResourceAiError({required this.kind, required this.detail});

  final ResourceAiErrorKind kind;

  /// 技术细节（模型引用 / 停止原因 / 异常串），由 UI 拼进本地化模板。
  final String detail;
}

class ResourceAiMessage {
  const ResourceAiMessage({
    required this.role,
    required this.text,
    this.name,
    this.change,
  });

  final ResourceAiMessageRole role;
  final String text;

  /// 附件材料名（role=material 时非空）。
  final String? name;

  /// 草稿变更记录（role=tool 时非空；过程线，text 可为空串）。
  final DraftChangeRecord? change;
}

class ResourceAiState {
  const ResourceAiState({
    required this.phase,
    this.messages = const [],
    this.draft,
    this.error,
    this.modelPresetId,
    this.modelId,
    this.temperature,
    this.maxSteps = 6,
  });

  final ResourceAiPhase phase;
  final List<ResourceAiMessage> messages;
  final DraftState? draft;

  /// fatal 时的结构化错误（kind 映射文案，detail 为技术细节）。
  final ResourceAiError? error;

  /// 当前生效模型引用（快照后）。
  final String? modelPresetId;
  final String? modelId;

  /// 当前采样温度（null = 未解析；start 时解析，随 callConfig 下发）。
  final double? temperature;

  /// 单轮步数预算（start 取配置默认，可随时调整，下一轮生效）。
  final int maxSteps;

  /// 可保存：就绪或失败轮后 + 草稿已动笔或已定稿（finalize 即 agent
  /// 声明可交付）。
  ///
  /// 失败轮的草稿未回滚、
  /// 已持久在内存（工具回调即时写稿，_fail 只切 phase=fatal 保留草稿）
  /// ——「预览有内容但完成创建禁用」的双源矛盾根因即 phase 门把 fatal
  /// 排除。保存不依赖在途轮次（用户取消路径 cancelled→ready 已可保存，
  /// fatal 对齐同语义：草稿现场保留，可重试也可直接完成创建）。
  bool get canSave =>
      (phase == ResourceAiPhase.ready || phase == ResourceAiPhase.fatal) &&
      draft != null &&
      (draft!.isDirty || draft!.finalized);
}

class ResourceAiController extends ChangeNotifier {
  ResourceAiController({
    required AgentRunner runner,
    required ResourceAiSession session,
    required ResourceAiSaveService saveService,
    required Future<NamingConfig?> Function(String presetId, String modelId)
        resolveNaming,
    required ResourceAiConfig config,
    required this.kind,
    this.initialDraft,
    this.targetCardId,
    this.targetBookId,
    this.targetSummary,
    this.originalRawJson,
  })  : _runner = runner,
        _session = session,
        _saveService = saveService,
        _resolveNaming = resolveNaming,
        _config = config;

  final AgentRunner _runner;
  final ResourceAiSession _session;
  final ResourceAiSaveService _saveService;
  final Future<NamingConfig?> Function(String presetId, String modelId)
      _resolveNaming;
  final ResourceAiConfig _config;

  final DraftKind kind;

  /// 编辑模式预填草稿（原文解析而来，agent 在其上小步修改）。
  final DraftState? initialDraft;

  /// 编辑模式目标（新建会话两者皆空）。
  final String? targetCardId;
  final String? targetBookId;
  final String? targetSummary;

  /// 编辑留底（覆盖保存 patch 用）。
  final String? originalRawJson;

  ResourceAiState _state = const ResourceAiState(phase: ResourceAiPhase.idle);
  ResourceAiState get state => _state;

  final List<AgentMessage> _surface = [];
  AgentCancellationToken? _cancelToken;

  /// RA12-1：fatal 轮已注入 surface 的 user 文本（重发同文本时不重复
  /// 注入）；null = 无在途 fatal 注入（成功/取消/换文本即失效）。
  String? _fatalInjectedUserText;

  /// 首用快照模型；无模型 → 保持 idle（UI 走内联选择）。
  Future<void> start() async {
    if (_state.phase != ResourceAiPhase.idle) return;
    final snapshot = await _session.ensureModelSnapshot();
    if (!snapshot.isModelConfigured) {
      _setState(
        ResourceAiState(
          phase: ResourceAiPhase.idle,
          draft: DraftState.empty(kind),
        ),
      );
      return;
    }
    final temperature = await _session.resolveInitialTemperature();
    _surface
      ..clear()
      ..add(
        AgentMessage.system(
          ResourceAiPrompts.build(kind: kind, targetSummary: targetSummary),
        ),
      );
    // 编辑模式：原文 JSON 预注入为首条材料消息（数 KB 不另做摘要）
    final rawJson = originalRawJson;
    if (rawJson != null) {
      _surface.add(AgentMessage.user(buildEditTargetInjection(rawJson)));
    }
    _setState(
      ResourceAiState(
        phase: ResourceAiPhase.ready,
        draft: initialDraft ?? DraftState.empty(kind),
        modelPresetId: snapshot.modelPresetId,
        modelId: snapshot.modelId,
        temperature: temperature,
        maxSteps: _config.maxSteps,
      ),
    );
  }

  /// 更换模型（持久化 override + 更新状态，下一轮生效）。
  ///
  /// generating/saving 中拒绝（返回 false，无副作用）；成功返回 true。
  Future<bool> updateModel({
    required String presetId,
    required String modelId,
  }) async {
    if (_state.phase == ResourceAiPhase.generating ||
        _state.phase == ResourceAiPhase.saving) {
      return false;
    }
    await _session.updateModelOverride(presetId, modelId);
    _setState(
      ResourceAiState(
        phase: _state.phase,
        messages: _state.messages,
        draft: _state.draft,
        error: _state.error,
        modelPresetId: presetId,
        modelId: modelId,
        temperature: _state.temperature,
        maxSteps: _state.maxSteps,
      ),
    );
    return true;
  }

  /// 调整生成参数（持久化非空项 + 更新状态）。随时可调，下一轮生效。
  Future<void> updateGenerationParams({
    double? temperature,
    int? maxSteps,
  }) async {
    if (temperature != null) {
      await _session.setTemperature(temperature);
    }
    if (maxSteps != null) {
      await _session.setMaxSteps(maxSteps);
    }
    _setState(
      ResourceAiState(
        phase: _state.phase,
        messages: _state.messages,
        draft: _state.draft,
        error: _state.error,
        modelPresetId: _state.modelPresetId,
        modelId: _state.modelId,
        temperature: temperature ?? _state.temperature,
        maxSteps: maxSteps ?? _state.maxSteps,
      ),
    );
  }

  /// 重置温度为当前全局默认（快照哲学：写入即快照当前全局值）。
  Future<void> resetTemperatureToBroadcast() async {
    final broadcast = await _session.currentBroadcastTemperature();
    await updateGenerationParams(temperature: broadcast);
  }

  /// 发送一轮用户输入。
  Future<void> send(String text) async {
    final presetId = _state.modelPresetId;
    final modelId = _state.modelId;
    if (presetId == null || modelId == null) return;
    if (_state.phase == ResourceAiPhase.generating ||
        _state.phase == ResourceAiPhase.saving) {
      return;
    }

    final token = AgentCancellationToken();
    _cancelToken = token;
    // RA12-1：fatal 重发不再重复注入 user 消息
    // ——首轮失败时 user(text) 已进 surface，页面「重发」拿同文本再调
    // send() 会把同一句话第二次写给模型（上下文里出现两份）。
    // 仅当「fatal 且该文本已注入」时跳过；naming 预检失败发生在注入前，
    // 重发照常注入。
    final isRetryOfInjected =
        _state.phase == ResourceAiPhase.fatal && _fatalInjectedUserText == text;
    _fatalInjectedUserText = null;
    _setState(
      ResourceAiState(
        phase: ResourceAiPhase.generating,
        messages: [
          ..._state.messages,
          ResourceAiMessage(role: ResourceAiMessageRole.user, text: text),
        ],
        draft: _state.draft,
        modelPresetId: presetId,
        modelId: modelId,
        temperature: _state.temperature,
        maxSteps: _state.maxSteps,
      ),
    );

    final naming = await _resolveNaming(presetId, modelId);
    if (naming == null) {
      _fail(
        ResourceAiErrorKind.modelUnavailable,
        'preset=$presetId model=$modelId',
      );
      return;
    }

    if (!isRetryOfInjected) {
      _surface.add(AgentMessage.user(text));
    }
    var draft = _state.draft ?? DraftState.empty(kind);
    if (!draft.hasConversation) {
      draft = draft.withConversation();
    }

    // 工具改稿即时落状态（有意在 runTurn 期间 _setState）：diff 出变更
    // 记录追加为 role=tool 过程消息并替换草稿——实时草稿预览 + 过程线。
    void applyDraft(DraftState next) {
      final changes = summarizeDraftChanges(draft, next);
      draft = next;
      _setState(
        ResourceAiState(
          phase: ResourceAiPhase.generating,
          messages: changes.isEmpty
              ? _state.messages
              : [
                  ..._state.messages,
                  for (final c in changes)
                    ResourceAiMessage(
                      role: ResourceAiMessageRole.tool,
                      text: '',
                      change: c,
                    ),
                ],
          draft: next,
          modelPresetId: presetId,
          modelId: modelId,
          temperature: _state.temperature,
          maxSteps: _state.maxSteps,
        ),
      );
    }

    final result = await _runner.runTurn(
      AgentTurnSpec(
        sessionId: 'resource-ai',
        surface: _surface,
        tools: [
          UpdateDraftTool(
            kind: kind,
            readState: () => draft,
            onDraftChanged: applyDraft,
          ),
          FinalizeDraftTool(
            readState: () => draft,
            onDraftChanged: applyDraft,
          ),
          ResourceAiReadSkillTool(
            skillNames: [
              for (final s in ResourceAiPrompts.skillDirectory) s.$1,
            ],
            loadSkillBody: _session.loadSkillBody,
          ),
        ],
        endpoint: AgentModelEndpoint(
          baseUrl: naming.baseUrl,
          apiKey: naming.apiKey,
          modelId: naming.modelId,
          protocol: naming.protocol.name,
          providerOptions: naming.providerOptions,
          maxOutputTokens: naming.maxOutputTokens,
        ),
        budget: AgentBudget(maxSteps: _state.maxSteps),
        callConfig: AgentCallConfig(temperature: _state.temperature),
        events: _NoopEventSink(),
        cancellation: token,
      ),
    );
    _cancelToken = null;
    _surface.addAll(result.appendedMessages);

    final reply = result.lastAssistantText;
    if (!result.isSuccessful) {
      if (result.reason == AgentStopReason.cancelled) {
        // 用户取消：回 ready，现场保留（本轮 user 消息与过程线已在流中）
        _setState(
          ResourceAiState(
            phase: ResourceAiPhase.ready,
            messages: _state.messages,
            draft: draft,
            modelPresetId: presetId,
            modelId: modelId,
            temperature: _state.temperature,
            maxSteps: _state.maxSteps,
          ),
        );
        return;
      }
      // RA12-1：本轮 user 消息已注入 surface，fatal 重发同文本免重复注入
      _fatalInjectedUserText = text;
      _fail(
        ResourceAiErrorKind.turnIncomplete,
        result.errorMessage ?? '${result.reason}',
      );
      return;
    }

    // 成功：消息流在轮内已含过程线（applyDraft 实时追加），此处只补
    // assistant 回复——_state.messages 读的是当前值，不会重复过程线。
    _setState(
      ResourceAiState(
        phase: ResourceAiPhase.ready,
        messages: [
          ..._state.messages,
          if (reply.isNotEmpty)
            ResourceAiMessage(
              role: ResourceAiMessageRole.assistant,
              text: reply,
            ),
        ],
        draft: draft,
        modelPresetId: presetId,
        modelId: modelId,
        temperature: _state.temperature,
        maxSteps: _state.maxSteps,
      ),
    );
  }

  /// 取消当前轮（取消后回 ready，现场保留）。
  void cancel() {
    _cancelToken?.cancel();
  }

  /// 附件材料注入（模型可见 + 消息流标记）。
  void attachReference(String content, String name) {
    _surface.add(AgentMessage.user(buildReferenceInjection(name, content)));
    _setState(
      ResourceAiState(
        phase: _state.phase,
        messages: [
          ..._state.messages,
          ResourceAiMessage(
            role: ResourceAiMessageRole.material,
            text: content,
            name: name,
          ),
        ],
        draft: _state.draft,
        error: _state.error,
        modelPresetId: _state.modelPresetId,
        modelId: _state.modelId,
        temperature: _state.temperature,
        maxSteps: _state.maxSteps,
      ),
    );
  }

  /// 保存草稿（overwrite=true 且有编辑目标 → 覆盖；否则新建/另存）。
  ///
  /// 返回 null=成功（phase→saved）；非 null=结构化错误（kind=saveFailed，
  /// detail 为异常串）——不进 fatal：现场保留、回 ready（error 不动），
  /// 可重试保存。
  Future<ResourceAiError?> save({required bool overwrite}) async {
    final draft = _state.draft;
    // 非 ready/fatal（含未配置）不是失败，视作无操作。：
    // fatal 放行——草稿现场保留（canSave 同口径），保存是纯本地操作。
    if (draft == null ||
        (_state.phase != ResourceAiPhase.ready &&
            _state.phase != ResourceAiPhase.fatal)) {
      return null;
    }

    _setState(
      ResourceAiState(
        phase: ResourceAiPhase.saving,
        messages: _state.messages,
        draft: draft,
        modelPresetId: _state.modelPresetId,
        modelId: _state.modelId,
        temperature: _state.temperature,
        maxSteps: _state.maxSteps,
      ),
    );

    try {
      if (kind == DraftKind.characterCard) {
        await _saveService.saveCharacterCard(
          draft: draft.card ?? CardDraft.initial(),
          existingCardId: overwrite ? targetCardId : null,
          originalRawJson: overwrite ? originalRawJson : null,
        );
      } else {
        await _saveService.saveWorldbook(
          draft: draft.book ?? WorldbookDraft.initial(),
          existingBookId: overwrite ? targetBookId : null,
          originalRawJson: overwrite ? originalRawJson : null,
        );
      }
      _setState(
        ResourceAiState(
          phase: ResourceAiPhase.saved,
          messages: _state.messages,
          draft: draft,
          modelPresetId: _state.modelPresetId,
          modelId: _state.modelId,
          temperature: _state.temperature,
          maxSteps: _state.maxSteps,
        ),
      );
      return null;
    } on Exception catch (e) {
      return _saveFailed(_saveError(e));
    } catch (e) {
      return _saveFailed(_saveError(e));
    }
  }

  /// 仓储异常 → 结构化保存失败错误（detail 为异常串）。
  ResourceAiError _saveError(Object e) =>
      ResourceAiError(kind: ResourceAiErrorKind.saveFailed, detail: '$e');

  /// 保存失败收尾：回 ready（现场与 error 均保留），返回结构化错误。
  ResourceAiError _saveFailed(ResourceAiError error) {
    _setState(
      ResourceAiState(
        phase: ResourceAiPhase.ready,
        messages: _state.messages,
        draft: _state.draft,
        modelPresetId: _state.modelPresetId,
        modelId: _state.modelId,
        temperature: _state.temperature,
        maxSteps: _state.maxSteps,
      ),
    );
    return error;
  }

  void _fail(ResourceAiErrorKind kind, String detail) {
    _setState(
      ResourceAiState(
        phase: ResourceAiPhase.fatal,
        messages: _state.messages,
        draft: _state.draft,
        error: ResourceAiError(kind: kind, detail: detail),
        modelPresetId: _state.modelPresetId,
        modelId: _state.modelId,
        temperature: _state.temperature,
        maxSteps: _state.maxSteps,
      ),
    );
  }

  void _setState(ResourceAiState next) {
    _state = next;
    notifyListeners();
  }
}

class _NoopEventSink implements AgentEventSink {
  @override
  void emit(AgentRunEvent event) {}
}
