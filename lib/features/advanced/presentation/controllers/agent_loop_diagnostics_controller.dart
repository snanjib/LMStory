import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/agent/agent_budget.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_events.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/agent/agent_runner.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/features/advanced/domain/services/agent_event_bus.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';
import 'package:lmstory/features/advanced/domain/services/api_key_lookup.dart';
import 'package:lmstory/features/advanced/presentation/tools/agent_diagnostic_tools.dart';
import 'package:lmstory/features/chat/data/agent/llm_service_agent_gateway.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 诊断时间线条目（UI 渲染用的扁平行）
class AgentDiagnosticEntry {
  const AgentDiagnosticEntry({
    required this.kind,
    required this.text,
    this.isError = false,
    this.detail,
  });

  /// 行类型：turn / step / text / tool / inject / doom / result
  final String kind;
  final String text;
  final String? detail;
  final bool isError;
}

class AgentLoopDiagnosticsState {
  const AgentLoopDiagnosticsState({
    this.modelLabel = '',
    this.resolveError,
    this.isRunning = false,
    this.entries = const [],
    this.summary,
  });

  final String modelLabel;
  final String? resolveError;
  final bool isRunning;
  final List<AgentDiagnosticEntry> entries;
  final String? summary;

  AgentLoopDiagnosticsState copyWith({
    String? modelLabel,
    String? resolveError,
    bool? isRunning,
    List<AgentDiagnosticEntry>? entries,
    String? summary,
  }) {
    return AgentLoopDiagnosticsState(
      modelLabel: modelLabel ?? this.modelLabel,
      resolveError: resolveError ?? this.resolveError,
      isRunning: isRunning ?? this.isRunning,
      entries: entries ?? this.entries,
      summary: summary ?? this.summary,
    );
  }
}

/// Agent Loop 诊断控制器（开发者自检，无产品 UI）
///
/// 用全局默认对话模型跑一轮最小循环：echo → get_current_time → finish_demo。
/// 覆盖验证：多步 turn/step、流式 tool-call 增量、能力降级、取消、预算。
class AgentLoopDiagnosticsController
    extends StateNotifier<AgentLoopDiagnosticsState> {
  AgentLoopDiagnosticsController({
    required ConfigurationResolver configurationResolver,
    required ApiPresetRepository presetRepository,
    required ApiKeyLookup apiKeyLookup,
    required AgentLlmGateway gateway,
  })  : _configurationResolver = configurationResolver,
        _presetRepository = presetRepository,
        _apiKeyLookup = apiKeyLookup,
        _gateway = gateway,
        super(const AgentLoopDiagnosticsState());

  final ConfigurationResolver _configurationResolver;
  final ApiPresetRepository _presetRepository;
  final ApiKeyLookup _apiKeyLookup;
  final AgentLlmGateway _gateway;

  AgentCancellationToken? _runningToken;
  StreamSubscription<AgentRunEvent>? _eventSubscription;

  Future<void> load() async {
    try {
      final snapshot = await _configurationResolver.snapshotSimpleDefaults();
      final presetId = snapshot.presetId;
      if (presetId == null || presetId.isEmpty) {
        state = state.copyWith(
          resolveError: t.settings.diagnostics.agentLoop.resolveNoPreset,
        );
        return;
      }
      final preset = await _presetRepository.getPreset(presetId);
      final modelId = snapshot.modelId ??
          (preset.cachedModels.isNotEmpty
              ? preset.cachedModels.first.modelId
              : '');
      if (modelId.isEmpty) {
        state = state.copyWith(
          resolveError: t.settings.diagnostics.agentLoop.resolveNoModel,
        );
        return;
      }
      // ignore: unnecessary_nullable_for_final_variable_declarations
      state = AgentLoopDiagnosticsState(
        modelLabel: '${preset.name} / $modelId',
        isRunning: state.isRunning,
        entries: state.entries,
        summary: state.summary,
      );
    } catch (e) {
      state = state.copyWith(
        resolveError: t.settings.diagnostics.agentLoop.resolveFailed(
          error: '$e',
        ),
      );
    }
  }

  Future<void> run() async {
    if (state.isRunning) return;
    if (state.resolveError != null) {
      await load();
      if (state.resolveError != null) return;
    }

    final snapshot = await _configurationResolver.snapshotSimpleDefaults();
    final presetId = snapshot.presetId;
    if (presetId == null || presetId.isEmpty) return;
    final preset = await _presetRepository.getPreset(presetId);
    final modelId = snapshot.modelId ??
        (preset.cachedModels.isNotEmpty
            ? preset.cachedModels.first.modelId
            : '');
    final apiKey = await _apiKeyLookup(presetId);

    final endpoint = AgentModelEndpoint(
      baseUrl: preset.baseUrl,
      apiKey: apiKey,
      modelId: modelId,
      protocol: preset.protocol.name,
      providerOptions: preset.providerOptions,
    );

    final sink = BroadcastAgentEventSink();
    final cancellation = AgentCancellationToken();
    _runningToken = cancellation;
    state = AgentLoopDiagnosticsState(
      modelLabel: state.modelLabel,
      resolveError: state.resolveError,
      isRunning: true,
    );

    _eventSubscription = sink.stream.listen(_onEvent);

    final runner = AgentRunner(gateway: _gateway);
    try {
      final result = await runner.runTurn(
        AgentTurnSpec(
          sessionId: 'diagnostics',
          surface: [
            AgentMessage.system(kAgentDiagnosticPrompt),
          ],
          tools: const [EchoTool(), CurrentTimeTool(), FinishDemoTool()],
          endpoint: endpoint,
          budget: const AgentBudget(
            maxSteps: 6,
            maxDuration: Duration(minutes: 2),
          ),
          events: sink,
          cancellation: cancellation,
        ),
      );

      final usage = result.usage;
      final tl = t.settings.diagnostics.agentLoop.timeline;
      state = state.copyWith(
        summary: result.errorMessage == null
            ? tl.summary(
                reason: _reasonLabel(result.reason),
                steps: result.steps,
                tokens: usage.totalTokens,
              )
            : tl.summaryWithError(
                reason: _reasonLabel(result.reason),
                steps: result.steps,
                tokens: usage.totalTokens,
                error: result.errorMessage!,
              ),
      );
    } catch (e) {
      state = state.copyWith(
        summary: t.settings.diagnostics.agentLoop.timeline.summaryError(e: e),
      );
    } finally {
      await _eventSubscription?.cancel();
      _eventSubscription = null;
      _runningToken = null;
      await sink.dispose();
    }
  }

  void cancel() {
    _runningToken?.cancel('用户手动停止');
  }

  void _onEvent(AgentRunEvent event) {
    final tl = t.settings.diagnostics.agentLoop.timeline;
    final entry = switch (event) {
      AgentResponseCompleted() => null,
      AgentTurnStarted() => AgentDiagnosticEntry(
          kind: 'turn',
          text: tl.turnStarted(maxSteps: event.maxSteps),
        ),
      AgentStepStarted() => AgentDiagnosticEntry(
          kind: 'step',
          text: tl.stepRequesting(index: event.stepIndex + 1),
        ),
      // 重试等待上抛为事件后此处只需留痕一行（诊断页可观察退避节奏）
      AgentRetryScheduled() => AgentDiagnosticEntry(
          kind: 'step',
          text: tl.retryScheduled(waitMs: event.waitMs, attempt: event.attempt),
        ),
      AgentTextDeltaEvent() => null, // 文本流不逐条展示，避免刷屏
      AgentThinkingDeltaEvent() => null,
      AgentToolCallReceived() => AgentDiagnosticEntry(
          kind: 'tool',
          text: tl.toolCallReceived(name: event.call.name, id: event.call.id),
          detail: event.call.arguments.toString(),
        ),
      AgentAssistantMessageEvent() => AgentDiagnosticEntry(
          kind: 'step',
          text: event.message.hasToolCalls
              ? tl.assistantEnqueuedWithTools(
                  count: event.message.toolCalls!.length,
                )
              : tl.assistantEnqueued,
          detail: event.message.preview(),
        ),
      AgentToolExecutionStarted() => AgentDiagnosticEntry(
          kind: 'tool',
          text: tl.toolExecuting(name: event.toolName),
          detail: event.argsPreview,
        ),
      AgentToolExecutionFinished() => AgentDiagnosticEntry(
          kind: 'tool',
          text: tl.toolFinished(
                name: event.toolName,
                ms: event.duration.inMilliseconds,
              ) +
              (event.isError ? tl.toolFailedSuffix : ''),
          detail: () {
            final output =
                AgentLogRecoveryService.isInterruptedOutput(event.output)
                    ? t.advanced.process.interruptedToolOutput
                    : event.output;
            return output.length > 160
                ? '${output.substring(0, 160)}…'
                : output;
          }(),
          isError: event.isError,
        ),
      AgentStepFinished() => AgentDiagnosticEntry(
          kind: 'step',
          text: event.totalTokens == null
              ? tl.stepFinishedNoUsage(index: event.stepIndex + 1)
              : tl.stepFinished(
                  index: event.stepIndex + 1,
                  tokens: event.totalTokens!,
                ),
        ),
      AgentInjectedMessageEvent() => AgentDiagnosticEntry(
          kind: 'inject',
          text: tl.injected(kind: event.kind, preview: event.message.preview()),
        ),
      AgentDoomLoopDetected() => AgentDiagnosticEntry(
          kind: 'doom',
          text: tl.doomLoop(
            toolName: event.toolName,
            count: event.consecutiveCalls,
          ),
          isError: true,
        ),
      AgentTurnFinished() => AgentDiagnosticEntry(
          kind: 'turn',
          text: tl.turnFinished(reason: _reasonLabel(event.reason)),
        ),
      AgentSurfaceReplaced() => null, // 日志事件，诊断页不展示
    };
    if (entry == null) return;
    state = state.copyWith(entries: [...state.entries, entry]);
  }

  String _reasonLabel(AgentStopReason reason) {
    // 终止原因文案入 slang（白名单只减不增）
    final labels = t.settings.diagnostics.agentLoop.stopReason;
    return switch (reason) {
      AgentStopReason.completed => labels.completed,
      AgentStopReason.completedByTool => labels.completedByTool,
      AgentStopReason.maxSteps => labels.maxSteps,
      AgentStopReason.budgetTokens => labels.budgetTokens,
      AgentStopReason.budgetDuration => labels.budgetDuration,
      AgentStopReason.contextHeadroom => labels.contextHeadroom,
      AgentStopReason.doomLoop => labels.doomLoop,
      AgentStopReason.cancelled => labels.cancelled,
      AgentStopReason.hookRejected => labels.hookRejected,
      AgentStopReason.error => labels.error,
    };
  }

  @override
  void dispose() {
    _runningToken?.cancel('页面关闭');
    _eventSubscription?.cancel();
    super.dispose();
  }
}

final agentLoopDiagnosticsControllerProvider = StateNotifierProvider<
    AgentLoopDiagnosticsController, AgentLoopDiagnosticsState>((ref) {
  return AgentLoopDiagnosticsController(
    configurationResolver: ref.watch(configurationResolverProvider),
    presetRepository: ref.watch(apiPresetRepositoryProvider),
    apiKeyLookup: ref.watch(apiKeyLookupProvider),
    gateway: LlmServiceAgentGateway(llmService: ref.watch(llmServiceProvider)),
  );
});
