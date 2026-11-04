import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/network/http_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/domain/entities/tool_permissions.dart';
import 'package:lmstory/features/advanced/domain/services/agent_session_stats.dart';
import 'package:lmstory/features/advanced/presentation/controllers/advanced_chat_controller.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/datasources/llm_remote_datasource.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session_settings.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/diagnostics/domain/entities/failure_log_entry.dart';
import 'package:lmstory/features/diagnostics/domain/repositories/failure_log_repository.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/data/repositories/factual_repository_impl.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_apply_service.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/story_runtime/data/persistence_service_impl.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/domain/services/compaction_service.dart';
import 'package:lmstory/features/story_runtime/domain/services/manual_compact_result.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../test_helpers/stub_failure_log_repository.dart';

/// 导演模式 kernel swap 集成测试（v0.3）
///
/// 验证：mode==advanced 时，AdvancedChatController 走 agent loop
/// （而非六步管线），agent 的检索/写事实/正文经 RoundContext → _runPersistPhase
/// 落库，复用故事模式持久化。使用真实 SSE 解析链 + 内存 drift + 真实 FactApplier。
class _FakeResolver extends ConfigurationResolver {
  _FakeResolver()
      : super(
          presetRepository: _StubPresetRepo(),
          settingsRepository: _ThrowingSettingsRepo(),
          logger: const Logger('test'),
        );

  @override
  Future<({ChatSessionSettings settings, String? apiKey})>
      resolveAdvancedSettings(ChatSession session) async {
    return (
      settings: const ChatSessionSettings(
        modelId: 'test-model',
        presetId: 'test-preset',
        systemPrompt: '世界观：剑与魔法。',
        temperature: 0.8,
        topP: 0.9,
        maxTokens: 4096,
        autoCompaction: true,
        compactionThreshold: 0.6,
        streamEnabled: true,
        reasoningEffort: ReasoningEffort.disabled,
      ),
      apiKey: null,
    );
  }

  @override
  Future<NamingConfig?> resolveAdvancedGeneratingNamingConfig(
    ChatSession session,
  ) async {
    return const NamingConfig(
      baseUrl: 'https://api.openai.com/v1',
      apiKey: 'test-key',
      modelId: 'test-model',
      presetId: 'test-preset',
    );
  }

  @override
  Future<int> resolveContextWindowForPhase({
    String? presetId,
    String? modelId,
    int? effectiveContextLimit,
  }) async =>
      32000;

  @override
  Future<EmbeddingApiConfig?> resolveAdvancedEmbeddingConfig() async => null;
}

/// embedding 配置可用且 fallback_on_failure=false 的解析器
/// 变体——host._resolveQueryVector 在 embed 失败时抛
/// EmbeddingCallFailedException（E104 链路入口）。
class _EmbeddingFailResolver extends _FakeResolver {
  @override
  Future<EmbeddingApiConfig?> resolveAdvancedEmbeddingConfig() async =>
      const EmbeddingApiConfig(
        model: 'embed-model',
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'test-key',
        timeoutMs: 5000,
        fallbackOnFailure: false,
      );
}

/// GM（导演主模型）未配置的解析器变体——
/// resolveAdvancedGeneratingNamingConfig 返回 null，触发 E010 守卫。
class _GmMissingResolver extends _FakeResolver {
  @override
  Future<NamingConfig?> resolveAdvancedGeneratingNamingConfig(
    ChatSession session,
  ) async =>
      null;
}

/// GM 配置可运行时切换的解析器变体——模拟用户失败后去设置补齐配置。
class _ToggleGmResolver extends _FakeResolver {
  bool gmConfigured = false;
  @override
  Future<NamingConfig?> resolveAdvancedGeneratingNamingConfig(
    ChatSession session,
  ) async =>
      gmConfigured
          ? const NamingConfig(
              baseUrl: 'https://api.openai.com/v1',
              apiKey: 'test-key',
              modelId: 'test-model',
              presetId: 'test-preset',
            )
          : null;
}

/// 先吐一条 delta 再挂门闸——delta 进入 32ms 合帧缓冲后压缩
/// 挂起，模拟 dispose 恰落在缓冲窗口内。
class _GatedDeltaCompactionService extends StoryCompactionService {
  _GatedDeltaCompactionService()
      : super(
          tokenCounter: TokenCounter(),
          llmService: _NoopLlmService(),
        );

  final Completer<void> release = Completer<void>();
  int compactCalls = 0;

  @override
  Future<CompactionResult> compact({
    required List<ChatMessage> history,
    required String sessionId,
    required NamingConfig namingConfig,
    required int contextWindow,
    required int maxTokens,
    required ContextBudget budget,
    Duration? connectTimeout,
    Duration? readTimeout,
    Duration? responseStartTimeout,
    String? existingCompactionSummary,
    int baseContextTokens = 0,
    bool manual = false,
    void Function(String delta)? onSummaryDelta,
    CancellationToken? cancelToken,
  }) async {
    compactCalls++;
    onSummaryDelta?.call('挂起中的压缩尾段。');
    await release.future;
    return CompactionResult(
      summary: '前情摘要（累积）',
      boundaryMessageId: history[history.length - 3].messageId,
      compactedHistory: const [],
    );
  }
}

/// 立即成功的压缩服务（manualCompact 成功链路测试用）
class _ImmediateCompactionService extends StoryCompactionService {
  _ImmediateCompactionService(this.summaryMessage)
      : super(
          tokenCounter: TokenCounter(),
          llmService: _NoopLlmService(),
        );

  final ChatMessage summaryMessage;
  int compactCalls = 0;

  @override
  Future<CompactionResult> compact({
    required List<ChatMessage> history,
    required String sessionId,
    required NamingConfig namingConfig,
    required int contextWindow,
    required int maxTokens,
    required ContextBudget budget,
    Duration? connectTimeout,
    Duration? readTimeout,
    Duration? responseStartTimeout,
    String? existingCompactionSummary,
    int baseContextTokens = 0,
    bool manual = false,
    void Function(String delta)? onSummaryDelta,
    CancellationToken? cancelToken,
  }) async {
    compactCalls++;
    onSummaryDelta?.call('摘要流式增量。');
    final boundary = history[history.length - 3];
    return CompactionResult(
      summary: summaryMessage.content ?? '',
      boundaryMessageId: boundary.messageId,
      compactedHistory: [summaryMessage, ...history.skip(history.length - 2)],
    );
  }
}

class _NoopLlmService implements LlmService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// 轮前自动压缩服务：shouldCompact 恒真，返回固定摘要与保留段。
class _AutoCompactionService extends StoryCompactionService {
  _AutoCompactionService(this.summaryMessage)
      : super(
          tokenCounter: TokenCounter(),
          llmService: _NoopLlmService(),
        );

  final ChatMessage summaryMessage;
  int compactCalls = 0;

  @override
  Future<bool> shouldCompact({
    required List<ChatMessage> history,
    required int contextWindow,
    required ContextBudget budget,
    required String rolePrompt,
    required String userInput,
    String? compactionSummary,
  }) async =>
      true;

  @override
  Future<CompactionResult> compact({
    required List<ChatMessage> history,
    required String sessionId,
    required NamingConfig namingConfig,
    required int contextWindow,
    required int maxTokens,
    required ContextBudget budget,
    Duration? connectTimeout,
    Duration? readTimeout,
    Duration? responseStartTimeout,
    String? existingCompactionSummary,
    int baseContextTokens = 0,
    bool manual = false,
    void Function(String delta)? onSummaryDelta,
    CancellationToken? cancelToken,
  }) async {
    compactCalls++;
    final boundary = history[5];
    return CompactionResult(
      summary: summaryMessage.content ?? '',
      boundaryMessageId: boundary.messageId,
      compactedHistory: [summaryMessage, ...history.skip(6)],
    );
  }
}

class _StubPresetRepo implements ApiPresetRepository {
  @override
  Future<ApiPreset> getPreset(String presetId) async => ApiPreset(
        presetId: presetId,
        name: 'Test',
        baseUrl: 'https://api.openai.com/v1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _ThrowingSettingsRepo implements SettingsRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _StubEmbeddingService implements EmbeddingService {
  @override
  Future<Float32List> embed({
    required String text,
    required EmbeddingInputKind kind,
    required String model,
    required String baseUrl,
    required String? apiKey,
    Duration? timeout,
  }) async {
    throw UnimplementedError();
  }
}

/// 记录 insertLog 入参的 FailureLogRepository（mode 误标修复断言用）
class _RecordingFailureLogRepository implements FailureLogRepository {
  final modes = <String>[];

  @override
  @override
  Future<void> markRecovered(int logId) async {}

  @override
  Future<FailureLogEntry> insertLog({
    required String sessionId,
    required String mode,
    required String errorCategory,
    String? errorCode,
    String? failedPhase,
    int? httpStatus,
    String? errorMessage,
    String? rawError,
    String? outcome,
  }) async {
    modes.add(mode);
    return FailureLogEntry(
      id: 1,
      sessionId: sessionId,
      mode: mode,
      errorCategory: errorCategory,
      errorCode: errorCode,
      failedPhase: failedPhase,
      httpStatus: httpStatus,
      errorMessage: errorMessage,
      rawError: rawError,
      createdAt: DateTime(2026),
    );
  }

  @override
  Future<List<FailureLogEntry>> getRecentLogs({
    int limit = 50,
    String? mode,
    String? sessionId,
  }) async {
    return const <FailureLogEntry>[];
  }

  @override
  Future<int> countAll() async => 0;

  @override
  Future<void> clearAll() async {}

  @override
  Future<int> deleteBySession(String sessionId) async => 0;
}

// ── SSE HTTP client stub ────────────────────────────────────────────

class _SseHttpClient implements HttpClient {
  _SseHttpClient(
    this.responses, {
    this.bodyLog,
    this.partialStreamErrorAt,
    this.hangAt,
  });

  final List<String> responses;

  /// 每次请求的 body 快照（首回合提示注入断言用）
  final List<String>? bodyLog;

  /// 该次调用吐一条文本增量后流中断（模拟连接中途断开；
  /// 契约 §7.1 的 step 重试直播块污染场景）。中断次不消费 responses 列表
  /// （重试从列表头读起）
  final int? partialStreamErrorAt;

  /// 第 [hangAt] 次调用吐一条文本增量后挂住，[hangReleased] 置位后以
  /// 流错误收尾——模拟「正文直播到一半用户点停止」。挂住次一次性
  /// （不消费 responses 列表、不推进计数）。
  final int? hangAt;
  static const _hangChunk = '夜色沉下来，苏明远推开荒庙的门。';
  bool hangReleased = false;
  var _hangFired = false;

  /// 挂闸已吐首帧的确定性信号（测试 await 它替代轮询直播块）。
  final hangFired = Completer<void>();
  int callCount = 0;
  var _partialFired = false;

  @override
  Stream<String> streamPost(
    String url,
    Map<String, String> headers, {
    String? body,
    Encoding encoding = utf8,
    CancellationToken? cancelToken,
    Duration? connectTimeout,
    Duration? readTimeout,
    Duration? responseStartTimeout,
  }) {
    bodyLog?.add(body ?? '');
    if (hangAt != null &&
        callCount == hangAt &&
        !_hangFired &&
        !_partialFired) {
      _hangFired = true;
      late final StreamController<String> controller;
      Timer? poller;
      controller = StreamController<String>(
        onListen: () {
          final chunkJson = jsonEncode({
            'choices': [
              {
                'delta': {'content': _hangChunk},
              },
            ],
          });
          controller.add('data: $chunkJson\n\n');
          if (!hangFired.isCompleted) hangFired.complete();
          final deadline = DateTime.now().add(const Duration(seconds: 12));
          poller = Timer.periodic(const Duration(milliseconds: 10), (_) {
            if (hangReleased ||
                (cancelToken?.isCancelled ?? false) ||
                DateTime.now().isAfter(deadline)) {
              poller?.cancel();
              controller
                ..addError(Exception('cancelled mid-stream'))
                ..close();
            }
          });
        },
        onCancel: () => poller?.cancel(),
      );
      return controller.stream;
    }
    if (partialStreamErrorAt != null &&
        callCount == partialStreamErrorAt &&
        !_partialFired) {
      callCount++;
      _partialFired = true;
      return (() async* {
        // 与 main 内 _sse([_textDelta(...)]) 等价的内联 SSE（类外不可见局部函数）
        const chunk = '半截正文，流到这里断';
        yield 'data: {"choices":[{"delta":{"content":"$chunk"},"finish_reason":null}]}\n\n';
        throw Exception('connection reset mid-stream');
      })();
    }
    final response = responses[_partialFired ? callCount - 1 : callCount];
    callCount++;
    return Stream.value(response);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late AppDatabase db;
  late _SseHttpClient hangClient;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  // ── SSE 脚本（OpenAI 兼容，官方端点 → 流式工具可靠）────────────────

  String sse(List<String> jsons) => jsons.map((j) => 'data: $j\n\n').join();

  String textDelta(String content) =>
      '{"choices":[{"delta":{"content":${jsonEncode(content)}},"finish_reason":null}]}';

  String toolCallStart(int index, String id, String name, String args) =>
      '{"choices":[{"delta":{"tool_calls":[{"index":$index,"id":"$id","type":"function","function":{"name":"$name","arguments":${jsonEncode(args)}}}]},"finish_reason":null}]}';

  String finish(String reason) =>
      '{"choices":[{"delta":{},"finish_reason":"$reason"}]}';

  /// finish_round 一步：正文经 prose 参数交付（正文交付契约——content
  /// 只留过场播报，正文唯一载体是 prose 参数）
  String finishRoundStep(String callId, String prose) => sse([
        toolCallStart(
          0,
          callId,
          'finish_round',
          '{"prose":${jsonEncode(prose)}}',
        ),
        finish('tool_calls'),
        '[DONE]',
      ]);

  /// 终审闸门 B 的一次性豁免步：无事件记忆的首次 finish_round 被拒后，
  /// 脚本模型直接再次 finish_round（豁免放行）
  String finishRoundExemption(String callId, String prose) =>
      finishRoundStep(callId, prose);

  // ── 配置 stub ───────────────────────────────────────────────────────

  /// 轮询等待条件成立（超时返回 false 交由断言报错）。
  Future<bool> until(
    bool Function() cond, {
    // 并发全量下事件循环粒度放大，5s 窗会假超时——15s 保负载边界
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final sw = Stopwatch()..start();
    while (!cond()) {
      if (sw.elapsed > timeout) return false;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return true;
  }

  AdvancedChatController buildController(
    List<String> sseResponses, {
    int? maxSteps,
    int? maxDurationMinutes,
    bool withEventLog = false,
    bool watchMode = false,
    List<String>? bodyLog,
    FailureLogRepository? failureLogRepository,
    bool failConfig = false,
    int? partialStreamErrorAt,
    AdvancedConfig? config,
    ConfigurationResolver? resolver,
    StoryCompactionService? compactionService,
    String sessionId = 'dir-test-1',
    int? hangAt,
    String? characterInitPrompt,
    String? characterInitCardId,
    ResourceApplyService? resourceApplyService,
  }) {
    final chatRepo = ChatRepositoryImpl(database: db);
    hangClient = _SseHttpClient(
      sseResponses,
      bodyLog: bodyLog,
      partialStreamErrorAt: partialStreamErrorAt,
      hangAt: hangAt,
    );
    final experienceRepo = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
    final factualRepo = FactualRepositoryImpl(database: db);

    return AdvancedChatController(
      chatRepository: chatRepo,
      configurationResolver: resolver ?? _FakeResolver(),
      llmService: LlmRemoteDataSource(
        httpClient: hangClient,
        adapterFactory: LlmAdapterFactory(),
      ),
      experienceRepository: experienceRepo,
      embeddingService: _StubEmbeddingService(),
      persistenceService: StoryPersistenceServiceImpl(
        database: db,
        chatRepository: chatRepo,
        experienceRepository: experienceRepo,
        factApplier: FactApplier(repository: factualRepo),
      ),
      failureLogRepository:
          failureLogRepository ?? const StubFailureLogRepository(),
      tokenCounter: TokenCounter(),
      getConfig: failConfig
          ? () => throw const FormatException('config bad')
          : () async => config ?? const AdvancedConfig(),
      logger: const Logger('test'),
      session: ChatSession(
        sessionId: sessionId,
        title: '测试导演',
        mode: 'advanced',
        createdAt: DateTime.now(),
        lastActiveAt: DateTime.now(),
        messageCount: 0,
        maxSteps: maxSteps,
        maxDurationMinutes: maxDurationMinutes,
        // v44 语义：监督模式经 tool_permissions 监督预设生效
        //（watchMode 列迁移后仅留档，运行时不再读取）
        watchMode: watchMode,
        toolPermissions: watchMode
            ? ToolPermissions.toJson(ToolPermissions.supervised)
            : null,
        // 向导「初始化你的角色」产物（草稿带至物化）
        characterInitPrompt: characterInitPrompt,
        characterInitCardId: characterInitCardId,
      ),
      factualRepository: factualRepo,
      agentEventLogRepository:
          withEventLog ? AgentEventLogRepository(database: db) : null,
      compactionService: compactionService,
      resourceApplyService: resourceApplyService,
    );
  }

  // ── ：dispose 冲刷压缩缓冲 ────────────────────────

  /// 先吐一条 delta 再挂门闸——delta 进入 32ms 合帧缓冲后压缩挂起，
  /// 精确模拟「dispose 恰落在缓冲窗口内」。
  test('dispose 冲刷压缩缓冲尾段，之后零写入', () async {
    final chatRepo = ChatRepositoryImpl(database: db);
    // 5 轮完整对话（满足 minDialogueMessages=8 下限）
    for (var i = 1; i <= 10; i++) {
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'dm$i',
          sessionId: 'dir-test-1',
          role: i.isOdd ? 'user' : 'assistant',
          content: '第${(i + 1) ~/ 2}轮',
          createdAt: DateTime(2026),
        ),
      );
    }

    final gated = _GatedDeltaCompactionService();
    final controller = buildController(
      const [],
      compactionService: gated,
    );
    // 构造函数触发的 loadHistory 是异步链
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // 前置：delta 已先于门闸到达并进入 32ms 合帧缓冲（state 未写入）
    unawaited(controller.manualCompact());
    // manualCompact 到 compact 之间有多级 await，轮询等到达门闸
    for (var i = 0; i < 50 && gated.compactCalls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(gated.compactCalls, 1);
    expect(controller.state.isManualCompacting, isTrue);
    expect(controller.state.manualCompactionDelta, isEmpty);

    String? lastDelta;
    controller
      ..addListener((s) => lastDelta = s.manualCompactionDelta)
      // 压缩挂起中销毁控制器
      ..dispose();

    // 冲刷语义：挂起尾段在 dispose 时落账
    expect(
      lastDelta,
      isNotEmpty,
      reason: 'dispose 应冲刷压缩缓冲尾段',
    );

    // 零写入语义：等待超过合帧间隔，不得有任何挂起 Timer 再写 state
    await Future<void>.delayed(const Duration(milliseconds: 60));
  });

  // ── 2026-09-08 用户报告排查：导演手动压缩完成后摘要必须可见 ──────────
  //
  // 用户实测：流式压缩内容正常，但完成后「会话中没有压缩摘要、圆环数据
  // 不变、不确定是否成功」。本用例钉死成功链路的可观察产物：
  // persistManualCompaction 落库 + 重载后 state.messages 头部是摘要消息。
  test('manualCompact 成功：摘要消息落库并出现在过滤后历史头部', () async {
    final chatRepo = ChatRepositoryImpl(database: db);
    // 5 轮完整对话（满足 minDialogueMessages=8 下限）
    for (var i = 1; i <= 10; i++) {
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'mc$i',
          sessionId: 'dir-test-1',
          role: i.isOdd ? 'user' : 'assistant',
          content: '第${(i + 1) ~/ 2}轮的对话内容，长度足够参与压缩。',
          createdAt: DateTime(2026),
        ),
      );
    }

    final summaryMessage = ChatMessage(
      messageId: 'mc-summary',
      sessionId: 'dir-test-1',
      role: 'system',
      content: '这是压缩后的前情摘要。',
      isSummary: true,
      createdAt: DateTime(2026, 1, 1, 0, 0, 30),
    );
    final fake = _ImmediateCompactionService(summaryMessage);
    final controller = buildController(const [], compactionService: fake);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final result = await controller.manualCompact();
    expect(result, ManualCompactResult.success, reason: '压缩应成功');
    expect(controller.state.isManualCompacting, isFalse);
    expect(
      controller.state.manualCompactionError,
      isNull,
      reason: '成功路径不得残留错误态',
    );
    expect(fake.compactCalls, 1);

    // 落库验证：压缩点存在
    final points = await chatRepo.getCompactionPoints('dir-test-1');
    expect(points, hasLength(1), reason: 'persistManualCompaction 必须落压缩点');
    expect(points.single['summaryMessageId'], 'mc-summary');

    // 重载验证：过滤后历史头部是摘要消息（会话内可见摘要卡的判据）
    expect(
      controller.state.messages.first.isSummary,
      isTrue,
      reason: '压缩完成后会话历史头部应是摘要消息（用户可见反馈）',
    );
    expect(controller.state.messages.first.messageId, 'mc-summary');
    // 保留区仍在（boundary 之后的近期对话不丢）
    expect(
      controller.state.messages.any((m) => m.messageId == 'mc10'),
      isTrue,
      reason: '压缩保留区必须保留近期消息',
    );
  });

  test('轮前自动压缩：state.messages/compactedTurnBase 与摘要同步', () async {
    final chatRepo = ChatRepositoryImpl(database: db);
    for (var i = 1; i <= 10; i++) {
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'ac$i',
          sessionId: 'dir-test-1',
          role: i.isOdd ? 'user' : 'assistant',
          content: '第${(i + 1) ~/ 2}轮的历史对话内容。',
          createdAt: DateTime(2026),
        ),
      );
    }
    final summaryMessage = ChatMessage(
      messageId: 'auto-summary',
      sessionId: 'dir-test-1',
      role: 'system',
      content: '自动压缩摘要。',
      isSummary: true,
      createdAt: DateTime(2026, 1, 1, 0, 0, 30),
    );
    final compaction = _AutoCompactionService(summaryMessage);
    final controller = buildController(
      [
        sse([
          textDelta('夜色沉下来。'),
          finish('stop'),
          '[DONE]',
        ]),
      ],
      compactionService: compaction,
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    await controller.sendMessage('继续');

    expect(compaction.compactCalls, 1);
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.messages.first.isSummary, isTrue);
    expect(controller.state.messages.first.messageId, 'auto-summary');
    expect(controller.state.compactedTurnBase, 3);
  });

  test('mode=advanced：agent 检索 → finish_round → 复用 persistRound 落库', () async {
    final controller = buildController([
      // Step 1：search_story（参数分片）
      sse([
        textDelta('我先查一下。'),
        toolCallStart(0, 'call_s1', 'search_story', '{"query":'),
        r'{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"古碑\"}"}}]},"finish_reason":null}]}',
        finish('tool_calls'),
        '[DONE]',
      ]),
      // Step 2：正文经 prose 参数交付 + finish_round（终审闸门 B：尚无事件记忆 → 拒绝）
      finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
      // Step 3：补记事件记忆（闸门 B 的可行动反馈）
      sse([
        toolCallStart(
          0,
          'call_m1',
          'record_event_memory',
          '{"what":"苏明远夜探荒庙","importance":3}',
        ),
        finish('tool_calls'),
        '[DONE]',
      ]),
      // Step 4：二次 finish_round 放行
      finishRoundStep('call_f2', '夜色沉下来，苏明远推开荒庙的门。'),
    ]);

    await controller.sendMessage('苏明远进入荒庙');

    // 消息落库（复用故事模式 persistRound）
    final messages = await db.customSelect(
      'SELECT role, content FROM chat_messages WHERE session_id = ? '
      'ORDER BY created_at ASC',
      variables: [Variable.withString('dir-test-1')],
    ).get();
    expect(messages, hasLength(2));
    expect(messages.first.read<String>('role'), 'user');
    expect(messages.last.read<String>('content'), contains('夜色沉下来'));

    // 状态收敛
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.messages, hasLength(2));
  });

  test('mode=advanced：事实写入经 FactApplier 生效', () async {
    final controller = buildController([
      sse([
        toolCallStart(
          0,
          'call_u1',
          'update_facts',
          '{"deltas":[{"action":"create_entity","confidence":4,'
              '"primary_name":"苏明远","entity_type":"character","importance":4}]}',
        ),
        finish('tool_calls'),
        '[DONE]',
      ]),
      finishRoundStep('call_f2', '故事继续。'),
      finishRoundExemption('call_f2b', '故事继续。'),
    ]);

    await controller.sendMessage('推进剧情');

    final entities = await db.customSelect(
      'SELECT COUNT(*) AS c FROM factual_entities WHERE session_id = ?',
      variables: [Variable.withString('dir-test-1')],
    ).getSingle();
    expect(entities.read<int>('c'), 1);
  });

  test('mode=advanced：工具失败后空响应弃疗 → failed 可重试（不再静默 idle）', () async {
    final script = <String>[
      // 步骤 1：update_facts 参数缺定位字段（弱模型形态）→ 失败信封回喂
      sse([
        toolCallStart(
          0,
          'call_bad',
          'update_facts',
          '{"deltas":[{"action":"create","confidence":4}]}',
        ),
        finish('tool_calls'),
        '[DONE]',
      ]),
    ];
    // 步骤 2 起：空响应（弃疗）。批 D 归一后 EMPTY_RESPONSE 会先自动
    // 重试（P5 默认 5 次）——脚本补足重试消耗的空响应条目，全部空后
    // 耗尽进 failed（终态语义不变：failed 可重试）
    for (var i = 0; i < 7; i++) {
      script.add(sse([finish('stop'), '[DONE]']));
    }
    final controller = buildController(script);

    await controller.sendMessage('推进剧情');

    // 空正文完成进 failed（此前静默回 idle，整轮无声消失）
    expect(controller.state.phase, IntermediatePhase.failed);
    expect(controller.state.failureContext?.errorCode, 'EAGENT');
    expect(controller.state.failureContext?.retryable, isTrue);
    // 批 D/E：空响应已被 EMPTY_RESPONSE 语义归一——先自动重试 5 次（P5）
    // 耗尽后进 failed；终态语义不变（failed 可重试），消息含空响应原因
    expect(controller.state.failureContext?.errorMessage, contains('空响应'));
    // 临时用户消息保留（重试入口的数据基础）
    expect(controller.state.pendingUserMessage, isNotNull);
    // DD2：先失败后弃疗 → 肇事步骤转红（只有中断本轮才用红色；
    // 同一轮里被模型修复的失败是 warning）
    final badStep = controller.state.agentSteps
        .where((s) => s.toolName == 'update_facts')
        .toList();
    expect(badStep, isNotEmpty, reason: '失败工具卡应留在步骤列表');
    expect(
      badStep.first.status,
      AgentStepStatus.error,
      reason: '中断轮的肇事步骤应升级为 error',
    );
    // 无任何消息落库
    final count = await db.customSelect(
      'SELECT COUNT(*) AS c FROM chat_messages WHERE session_id = ?',
      variables: [Variable.withString('dir-test-1')],
    ).getSingle();
    expect(count.read<int>('c'), 0);

    // pending 重新生成入口：重发后整轮恢复正常落库
    script.addAll([
      finishRoundStep('call_f9', '雨停了，他走出荒庙。'),
      finishRoundExemption('call_f9b', '雨停了，他走出荒庙。'),
    ]);
    await controller.retryPendingUserMessage();

    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.pendingUserMessage, isNull);
    final messages = await db.customSelect(
      'SELECT role, content FROM chat_messages WHERE session_id = ? '
      'ORDER BY created_at ASC',
      variables: [Variable.withString('dir-test-1')],
    ).get();
    expect(messages, hasLength(2));
    expect(messages.last.read<String>('content'), contains('雨停了'));
  });

  test('mode=advanced：失败日志记录真实 mode（不再硬编码 intermediate）', () async {
    // 解耦重构 0.2 修复：_fail 此前硬编码 mode: 'intermediate'，
    // 导演轮失败被误记为故事模式，污染诊断页筛选。
    // 经 _getConfig 抛错 → E010 → _fail 落日志（agent 空正文路径不经 _fail）。
    final failureLog = _RecordingFailureLogRepository();
    final controller = buildController(
      const [],
      failureLogRepository: failureLog,
      failConfig: true,
    );

    await controller.sendMessage('推进剧情');

    expect(controller.state.phase, IntermediatePhase.failed);
    expect(failureLog.modes, ['advanced']);
  });

  test('GM 未配置 → E010 落 generating + 报点级建议覆盖', () async {
    // 导演主模型未配置时失败卡此前标「关键词提取」阶段
    //（导演无此阶段）且建议是通用「前往设置配置 API 供应商和模型」，
    // 指不到导演设置的真实入口——连探索者都被误导成解析回归疑案。
    final controller =
        buildController(const [], resolver: _GmMissingResolver());

    await controller.sendMessage('推进剧情');

    expect(controller.state.phase, IntermediatePhase.failed);
    final ctx = controller.state.failureContext!;
    expect(ctx.errorCode, 'E010');
    // 导演无六步 phase：失败阶段不再误标 extracting（关键词提取）
    expect(ctx.failedPhase, IntermediatePhase.generating);
    expect(ctx.errorCategory, ErrorCategory.config);
    // 报点级建议覆盖指向导演设置具体入口
    expect(ctx.suggestionOverride, t.advanced.failure.gmMissing);
  });

  test('草稿会话 GM 未配置 → E010 保留输入（气泡可重放，不蒸发）', () async {
    // 预检发生在落 userInput/pendingUserMessage 之前，而输入框在
    // onSend 前已被清空——若预检失败不回填 state，新用户首条消息
    // 直接蒸发（导演默认开启后这是全新用户的第一条路径）。
    final script = <String>[];
    final gm = _ToggleGmResolver();
    final controller = buildController(
      script,
      resolver: gm,
      sessionId: '${AdvancedChatController.draftSessionIdPrefix}new-user',
    );

    await controller.sendMessage('开启我的故事');

    expect(controller.state.phase, IntermediatePhase.failed);
    expect(controller.state.failureContext?.errorCode, 'E010');
    // 输入保留：气泡与失败栏「整轮重试」的数据基础
    expect(controller.state.userInput, '开启我的故事');
    expect(controller.state.pendingUserMessage?.content, '开启我的故事');

    // 补齐配置后从失败栏重试：同一份输入可重放（走正常轮链）
    gm.gmConfigured = true;
    script.addAll([
      finishRoundStep('call_d1', '雨夜，城门开了。'),
      finishRoundExemption('call_d1b', '雨夜，城门开了。'),
    ]);
    await controller.retryPendingUserMessage();
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.pendingUserMessage, isNull);
  });

  test('草稿物化：初始化角色两列随草稿落库；卡路径物化时应用一次', () async {
    // 向导「初始化你的角色」产物随草稿带到首条消息物化：
    // 描述列留档（供第 1 轮尾部一次性注入读取），卡在拿到真实
    // sessionId 后走资料通道应用。
    final appliedCards = <String>[];
    final controller = buildController(
      [
        finishRoundStep('call_ci1', '林九推开酒馆的门。'),
        finishRoundExemption('call_ci1b', '林九推开酒馆的门。'),
      ],
      sessionId: '${AdvancedChatController.draftSessionIdPrefix}ci-user',
      characterInitPrompt: '林九，男，落魄刀客',
      characterInitCardId: 'card-1',
      resourceApplyService: _RecordingApplyService(appliedCards),
    );

    await controller.sendMessage('开始');

    expect(controller.state.phase, IntermediatePhase.idle);
    expect(appliedCards, ['card-1'], reason: '卡应用恰一次（物化后）');
    // 两列随草稿快照落库，重读仍在
    final persisted = await ChatRepositoryImpl(database: db)
        .getSession(controller.state.session.sessionId);
    expect(persisted.characterInitPrompt, '林九，男，落魄刀客');
    expect(persisted.characterInitCardId, 'card-1');
  });

  test('mode=advanced：推理烧完输出预算（length 截断空正文）→ failed 带诊断', () async {
    final controller = buildController([
      // 流式只有 finish_reason=length（无 content，推理耗尽预算）→ 直接诊断停止
      sse([finish('length'), '[DONE]']),
    ]);

    await controller.sendMessage('推进剧情');

    expect(controller.state.phase, IntermediatePhase.failed);
    expect(controller.state.failureContext?.errorCode, 'EAGENT');
    expect(controller.state.failureContext?.retryable, isTrue);
    expect(
      controller.state.failureContext?.errorMessage,
      contains('finish_reason=length'),
    );
    expect(
      controller.state.failureContext?.rawError,
      contains('输出上限'),
    );
  });

  test('mode=advanced：D5 修复——会话 maxDurationMinutes 优先于全局时间预算', () async {
    // 会话列 0 分钟 → 首步前时间预算即耗尽（修复前只读全局 5 分钟，
    // 会话面板的「单轮时间预算」写入后被静默忽略）
    final controller = buildController(
      [
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      maxDurationMinutes: 0,
    );

    await controller.sendMessage('苏明远进入荒庙');

    expect(controller.state.phase, IntermediatePhase.failed);
    expect(controller.state.failureContext?.errorCode, 'EAGENT');
    // budgetDuration 的 i18n 文案（时间预算耗尽映射为「本轮超时」）
    expect(
      controller.state.failureContext?.errorMessage,
      contains('本轮超时'),
    );
  });

  test('mode=advanced：失败后 continueFromFailed 重跑 agent loop（不再误入六步管线）',
      () async {
    // maxSteps=1 → 首步检索工具后即达上限：软着陆（工具停用）后模型仍调
    // 工具 → 停用信封 → 二次耗尽失败。注意 0 现在表示「无上限」（对齐
    // AgentBudget 约定），不能再当作零预算触发失败路径。
    final controller = buildController(
      [
        // 首轮步骤 1：预算未到，检索工具正常执行
        sse([
          toolCallStart(0, 'call_x1', 'search_story', '{"query":"古碑"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        // 首轮步骤 2：软着陆通牒后模型仍调工具 → 停用信封 → 二次耗尽失败
        sse([
          toolCallStart(0, 'call_x2', 'search_story', '{"query":"月光"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        // continueFromFailed 后的一次成功 agent 步：正文经 prose 参数交付
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      maxSteps: 1,
    );

    await controller.sendMessage('苏明远进入荒庙');

    // 首轮失败：agent loop 以 generating 阶段失败，保留 _round
    expect(controller.state.phase, IntermediatePhase.failed);
    expect(controller.state.failureContext?.errorCode, 'EAGENT');
    expect(
      controller.state.failureContext?.failedPhase,
      IntermediatePhase.generating,
    );

    // 用户调大每轮步数后，从中断处重试（此前会误入故事模式 _runGeneratePhase）
    await controller.updateSession(
      controller.state.session.copyWith(maxSteps: 8),
    );
    await controller.continueFromFailed();

    // 重跑的是 agent loop：finish_round 工具步骤已随 artifacts 持久化
    // （故事模式六步管线不产生 agentSteps，可据此区分内核）
    expect(controller.state.phase, IntermediatePhase.idle);
    final artifacts = controller.state.artifactsByTurnNumber?[1];
    expect(artifacts, isNotNull);
    expect(artifacts!.agentSteps, isNotEmpty);
    expect(artifacts.agentSteps.first.toolName, 'finish_round');

    final messages = await db.customSelect(
      'SELECT role, content FROM chat_messages WHERE session_id = ? '
      'ORDER BY created_at ASC',
      variables: [Variable.withString('dir-test-1')],
    ).get();
    expect(messages, hasLength(2));
    expect(messages.last.read<String>('content'), contains('夜色沉下来'));
  });

  // 失败续跑（真续跑）：上次尝试的事件是唯一真实历史，不再删除重写——
  // 双计防线=不重发已完成请求 + 不重写 bootstrap + 步号续起（旧「删除
  // 上一尝试」契约服务于重放式重跑，真续跑不重放，保留才准确）。
  test('mode=advanced：失败真续跑——不重发已完成请求，事件不双计', () async {
    final bodies = <String>[];
    final controller = buildController(
      [
        // 首轮步骤 1：检索工具正常执行
        sse([
          toolCallStart(0, 'call_x1', 'search_story', '{"query":"古碑"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        // 首轮步骤 2：软着陆后仍调工具 → 停用信封 → 二次耗尽失败
        sse([
          toolCallStart(0, 'call_x2', 'search_story', '{"query":"月光"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        // 续跑成功步（finish_round 首被事件记忆闸门拒 → 豁免重提）
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      maxSteps: 1,
      withEventLog: true,
      bodyLog: bodies,
    );

    await controller.sendMessage('苏明远进入荒庙');
    expect(controller.state.phase, IntermediatePhase.failed);

    // 步数预算含前序尝试（种子 2 步已烧）：调大上限后续跑
    await controller.updateSession(
      controller.state.session.copyWith(maxSteps: 8),
    );
    await controller.continueFromFailed();
    expect(controller.state.phase, IntermediatePhase.idle);

    // 不重发证明：全程恰 4 次 LLM 请求（上次 2 + 续跑 2），已完成的
    // 检索步不重烧；续跑首请求体含上次尝试的 search_story 调用
    // （surface 投影回放，非重新装配）
    expect(hangClient.callCount, 4);
    expect(bodies, hasLength(4));
    expect(bodies[2], contains('search_story'));
    expect(bodies[2], contains('古碑'));

    final events = await AgentEventLogRepository(
      database: db,
    ).readEvents('dir-test-1');

    // 事件不双计：两段各一次 turn/begin（续跑段带 resumed 标记）
    final turnBegins =
        events.where((e) => e.type == AgentEventTypes.turnBegin).toList();
    expect(turnBegins, hasLength(2));
    expect(turnBegins.last.data['resumed'], isTrue);
    // bootstrap 单份：真实用户消息只落一次（续跑不重写补账）
    final userMessages = events.where(
      (e) =>
          e.type == AgentEventTypes.userMessage && e.data['source'] == 'user',
    );
    expect(userMessages, hasLength(1));
    // 步号跨尝试连续无重叠：1,2（上次）→ 3,4（续跑；stepEnd 为后置
    // 递增的 1 基序号，续跑种子 2 使其从 3 续起）
    final stepEnds = events
        .where((e) => e.type == AgentEventTypes.stepEnd)
        .map((e) => e.data['stepIndex'])
        .toList();
    expect(stepEnds, [1, 2, 3, 4]);
    // 聚合口径：统计=两段真实消耗之和（4 步），无重复计数
    final stats = agentSessionStatsFrom(events);
    expect(stats.stepsByTurn[1], 4);
  });

  test('mode=advanced：E104 临时降级 → 真续跑不重烧已完成的检索步', () async {
    final bodies = <String>[];
    final controller = buildController(
      [
        sse([
          toolCallStart(0, 'call_s1', 'search_story', '{"query":"古碑"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      resolver: _EmbeddingFailResolver(),
      withEventLog: true,
      bodyLog: bodies,
    );

    await controller.sendMessage('推进剧情');
    expect(controller.state.phase, IntermediatePhase.failed);
    expect(controller.state.failureContext?.errorCode, 'E104');
    final callsAtFailure = hangClient.callCount;

    await controller.continueWithFts5Only();
    expect(controller.state.phase, IntermediatePhase.idle);

    // 真续跑：续跑段只发 2 个请求（finish_round + 豁免重提），上次已完成的
    // 检索步不重烧；致命步骤由占位结果配对后模型直接执笔
    expect(callsAtFailure, 1);
    expect(hangClient.callCount, callsAtFailure + 2);
    expect(bodies.last, contains('search_story'), reason: '续跑请求体复用上次已完成的检索步骤');
    final events = await AgentEventLogRepository(
      database: db,
    ).readEvents('dir-test-1');
    expect(
      events
          .where((e) => e.type == AgentEventTypes.turnBegin)
          .last
          .data['resumed'],
      isTrue,
    );
  });

  test('mode=advanced：user_stopped 半截正文 → 续跑合成进 surface 可见断句', () async {
    final bodies = <String>[];
    final controller = buildController(
      [
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。雾里有人影。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。雾里有人影。'),
      ],
      hangAt: 0,
      withEventLog: true,
      bodyLog: bodies,
    );

    unawaited(controller.sendMessage('苏明远进入荒庙'));
    await hangClient.hangFired.future.timeout(const Duration(seconds: 20));
    expect(
      await until(
        () => controller.state.liveBlocks.any(
          (b) => b.kind == AgentLiveBlockKind.text && !b.isEmpty,
        ),
      ),
      isTrue,
    );
    await controller.cancel();
    expect(
      await until(
        () =>
            controller.state.phase == IntermediatePhase.failed &&
            !controller.state.isStopping,
      ),
      isTrue,
    );
    expect(controller.state.failureContext?.errorCode, 'user_stopped');

    // 等上一尝试的取消 unwind 完全落库（turn/end{cancelled} 与半截分片
    // 冲刷入账）再续跑——与真机时序等价（unwind 毫秒级完成，用户点击
    // 在秒级之后；不等会让续跑读到处置中的事件流）
    final unwindRepo = AgentEventLogRepository(database: db);
    var unwound = false;
    for (var i = 0; i < 500 && !unwound; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 4));
      final evs = await unwindRepo.readEvents('dir-test-1');
      unwound = evs.any(
        (e) => e.type == AgentEventTypes.turnEnd && e.data['turn'] == 1,
      );
    }
    expect(unwound, isTrue, reason: '等待取消轮完全退场（turn/end 落账）');
    // 取消终态稳定：user_stopped failed 不被防御性 idle 覆写
    expect(controller.state.phase, IntermediatePhase.failed);

    await controller.continueFromFailed();
    expect(controller.state.phase, IntermediatePhase.idle);

    // 半截正文合成 assistant/message（interrupted 标记）落日志
    final events = await unwindRepo.readEvents('dir-test-1');
    final synthesized = events.where(
      (e) =>
          e.type == AgentEventTypes.assistantMessage &&
          e.data['interrupted'] == true,
    );
    expect(synthesized, hasLength(1));
    // 续跑请求体含半截正文（模型从自己写过的断句处继续）
    expect(bodies.last, contains('夜色沉下来'));
    // 轮成功收口：消息对落库
    final messages = await db.customSelect(
      'SELECT role, content FROM chat_messages WHERE session_id = ? '
      'ORDER BY created_at ASC',
      variables: [Variable.withString('dir-test-1')],
    ).get();
    expect(messages, hasLength(2));
    expect(messages.last.read<String>('content'), contains('雾里有人影'));
  });

  test('mode=advanced：无事件日志仓库 → 续跑回退整轮重跑（现状行为等价）', () async {
    // withEventLog=false：无仓库可投影，回退旧路径（清理无门、重新装配、
    // 整轮重进 agent loop）——回退面保证与既有行为等价
    final bodies = <String>[];
    final controller = buildController(
      [
        sse([
          toolCallStart(0, 'call_x1', 'search_story', '{"query":"古碑"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        sse([
          toolCallStart(0, 'call_x2', 'search_story', '{"query":"月光"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      maxSteps: 1,
      bodyLog: bodies,
    );

    await controller.sendMessage('苏明远进入荒庙');
    expect(controller.state.phase, IntermediatePhase.failed);

    await controller.updateSession(
      controller.state.session.copyWith(maxSteps: 8),
    );
    await controller.continueFromFailed();
    expect(controller.state.phase, IntermediatePhase.idle);

    // 回退=重新装配整轮重跑：续跑首请求不含上次尝试的检索调用
    // （fresh surface 只含 bootstrap 面与历史；「古碑」只存在于上次
    // 尝试的 assistant 工具调用参数里，tool 定义里没有）
    expect(bodies, hasLength(4));
    expect(bodies[2], isNot(contains('古碑')));
  });

  test('step 请求中断重试：半截直播块清空，不与重试全文拼接（契约 §7.1）', () async {
    final controller = buildController(
      [
        sse([textDelta('重试后的完整正文。'), finish('stop'), '[DONE]']),
      ],
      partialStreamErrorAt: 0,
    );

    await controller.sendMessage('推进剧情');

    expect(controller.state.phase, IntermediatePhase.idle);
    // 修复前：半截文本与重试全文拼进同一直播块 → 落库正文被污染
    final messages = await db.customSelect(
      'SELECT role, content FROM chat_messages WHERE session_id = ? '
      'ORDER BY created_at ASC',
      variables: [Variable.withString('dir-test-1')],
    ).get();
    expect(messages.last.read<String>('content'), '重试后的完整正文。');
    expect(messages.last.read<String>('content'), isNot(contains('半截')));
  });

  test('mode=advanced：durable 事件日志落库（体验重构 C1）', () async {
    final controller = buildController(
      [
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      withEventLog: true,
    );

    await controller.sendMessage('苏明远进入荒庙');

    // agent_events 表：turn/begin + turn/end 成对落库（崩溃可重放）
    final events = await db.customSelect(
      'SELECT type FROM agent_events WHERE session_id = ? ORDER BY seq ASC',
      variables: [Variable.withString('dir-test-1')],
    ).get();
    final types = events.map((row) => row.read<String>('type')).toList();
    expect(types, contains('turn/begin'));
    expect(types, contains('turn/end'));
    expect(types.indexOf('turn/begin'), lessThan(types.indexOf('turn/end')));
    // 工具结果与 assistant 消息进 surface 投影
    expect(types, contains('tool/result'));
    expect(types, contains('assistant/message'));
  });

  test('mode=advanced：editAndResend/deleteRound 清理事件日志（B4-4 补全）', () async {
    Future<int> agentEventCount() async {
      final row = await db.customSelect(
        'SELECT COUNT(*) AS c FROM agent_events WHERE session_id = ?',
        variables: [Variable.withString('dir-test-1')],
      ).getSingle();
      return row.read<int>('c');
    }

    Future<int> turnBeginCount() async {
      final row = await db.customSelect(
        'SELECT COUNT(*) AS c FROM agent_events WHERE session_id = ? '
        "AND type = 'turn/begin'",
        variables: [Variable.withString('dir-test-1')],
      ).getSingle();
      return row.read<int>('c');
    }

    final controller = buildController(
      [
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
        // 编辑重发后的同轮重跑
        finishRoundStep('call_f2', '改写后的正文。'),
        finishRoundExemption('call_f2b', '改写后的正文。'),
      ],
      withEventLog: true,
    );

    await controller.sendMessage('苏明远进入荒庙');
    expect(await agentEventCount(), greaterThan(0));
    expect(await turnBeginCount(), 1);

    // 编辑重发：同轮号重跑，旧尝试的事件必须被清理（不与新的混算）
    final userMessage =
        controller.state.messages.firstWhere((m) => m.role == 'user');
    await controller.editAndResend(userMessage, '换个写法再讲一遍');
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(await turnBeginCount(), 1);
    expect(await agentEventCount(), greaterThan(0));

    // 删除整轮：轮事件随之清空（：会话级 system/frozen 前缀豁免保留）
    final assistant =
        controller.state.messages.firstWhere((m) => m.role == 'assistant');
    await controller.deleteRound(assistant);
    final remainingTypes = await db.customSelect(
      'SELECT type FROM agent_events WHERE session_id = ?',
      variables: [Variable.withString('dir-test-1')],
    ).get();
    expect(
      remainingTypes.map((row) => row.read<String>('type')),
      everyElement('system/frozen'),
    );
  });

  test('mode=advanced：剧情锚全链路（update_story_anchor → artifacts + 会话）', () async {
    // 会话行需预先存在（控制器不建行；story_anchor UPDATE 依赖它）
    await db.customStatement(
      'INSERT INTO chat_sessions (session_id, title, mode, created_at, '
      'last_active_at, message_count) '
      "VALUES ('dir-test-1', '测试导演', 'advanced', 0, 0, 0)",
    );
    final controller = buildController([
      sse([
        toolCallStart(
          0,
          'call_a1',
          'update_story_anchor',
          '{"arc":"古碑遗迹的真相","one_liner":"主角进入古碑遗迹",'
              '"narrative_time":"第三天黄昏","foreshadows":'
              '[{"text":"守碑人的身份"}]}',
        ),
        finish('tool_calls'),
        '[DONE]',
      ]),
      finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
      finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      // 编辑重发后的同轮重跑（不再动锚）
      finishRoundStep('call_f2', '改写后的正文。'),
      finishRoundExemption('call_f2b', '改写后的正文。'),
    ]);

    await controller.sendMessage('苏明远进入荒庙');

    // artifacts：该轮结束时的锚快照（Recap 卡数据源）
    final artifacts = controller.state.artifactsByTurnNumber?[1];
    expect(artifacts?.storyAnchor, isNotNull);
    expect(artifacts!.storyAnchor!.arc, '古碑遗迹的真相');
    expect(artifacts.storyAnchor!.openForeshadows.single.text, '守碑人的身份');

    // 会话当前锚同步（DB + 内存 state）
    final sessionRow = await db.customSelect(
      'SELECT story_anchor FROM chat_sessions WHERE session_id = ?',
      variables: [Variable.withString('dir-test-1')],
    ).getSingle();
    expect(sessionRow.read<String>('story_anchor'), contains('古碑遗迹的真相'));
    expect(controller.state.session.storyAnchor?.oneLiner, '主角进入古碑遗迹');

    // 剧情锚对称回滚：编辑重发删第 1 轮 → 该轮写的锚必须
    // 清空，DB 与内存态一致——
    // 否则被删稿经 update_story_anchor 登记的伏笔/弧线经 coreBlocks
    // 重新进入重生成轮上下文（用户实测「不该有的人物」根因）
    final anchorUserMessage =
        controller.state.messages.firstWhere((m) => m.role == 'user');
    await controller.editAndResend(anchorUserMessage, '换个写法再讲一遍');
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.session.storyAnchor, isNull);
    final sessionRowAfterResend = await db.customSelect(
      'SELECT story_anchor FROM chat_sessions WHERE session_id = ?',
      variables: [Variable.withString('dir-test-1')],
    ).getSingle();
    expect(sessionRowAfterResend.readNullable<String>('story_anchor'), isNull);
  });

  test('mode=advanced：ask_user 全链路（体验重构 C2）', () async {
    final controller = buildController([
      sse([
        toolCallStart(
          0,
          'call_q1',
          'ask_user',
          '{"question":"守碑人是谁？","options":["旧友","仇人"]}',
        ),
        finish('tool_calls'),
        '[DONE]',
      ]),
      finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
      finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
    ]);

    final round = controller.sendMessage('推进剧情');
    // 等待 ask_user 横幅出现（工具挂起等待回答）
    for (var i = 0; i < 50 && controller.state.agentAskPrompt == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(controller.state.agentAskPrompt?.question, '守碑人是谁？');
    expect(controller.state.agentAskPrompt?.options, ['旧友', '仇人']);

    // 回答后轮次继续走完
    controller.answerDirectorAsk('旧友');
    await round;

    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.agentAskPrompt, isNull);
    expect(controller.state.messages, hasLength(2));
  });

  test('mode=advanced：ask_user 0=一直等待（B8）——挂起期间无超时裁决，回答后照常走完', () async {
    final controller = buildController(
      [
        sse([
          toolCallStart(
            0,
            'call_q1',
            'ask_user',
            '{"question":"守碑人是谁？","options":["旧友","仇人"]}',
          ),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      // ask_user_timeout_minutes=0 → tuning.askUserTimeout=null →
      // runner 不挂 completer.timeout（走 await completer.future 分支）
      config: const AdvancedConfig(
        hitl: AdvancedHitlConfig(askUserTimeoutMinutes: 0),
      ),
    );

    final round = controller.sendMessage('推进剧情');
    for (var i = 0; i < 50 && controller.state.agentAskPrompt == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(controller.state.agentAskPrompt?.question, '守碑人是谁？');

    // 挂起等待：未回答期间轮次保持阻塞（无超时自动裁决）
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(controller.state.agentAskPrompt, isNotNull);
    expect(controller.state.phase, isNot(IntermediatePhase.idle));

    // 回答后照常走完
    controller.answerDirectorAsk('仇人');
    await round;

    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.agentAskPrompt, isNull);
  });

  test('mode=advanced：B12 E104 链路——embedding 失败 → E104 → 临时降级 → 轮成功', () async {
    // fallback_on_failure=false：host._resolveQueryVector 把 embed 失败
    // （stub 的 UnimplementedError）包装为 EmbeddingCallFailedException；
    // SearchStoryTool 不再吞（此前 catchError 吞成静默 FTS），
    // 经管线致命通道上抛 → runner error → ⑤ 判 E104。
    final controller = buildController(
      [
        sse([
          toolCallStart(0, 'call_s1', 'search_story', '{"query":"古碑"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      resolver: _EmbeddingFailResolver(),
    );

    await controller.sendMessage('推进剧情');

    // ① 首轮：search_story 的 embedding 调用失败 → E104（可临时降级）
    expect(controller.state.phase, IntermediatePhase.failed);
    expect(controller.state.failureContext?.errorCode, 'E104');
    expect(controller.state.embeddingDegradedForRound, isFalse);

    // ② 临时降级继续：置 degraded 后重跑导演轮。 修复后标记是
    // 轮内生命周期（置位 → persist 成功即复位），整轮在本次 await 内闭环，
    // 完成后无法再观测到 true——用监听器钉住轮内确曾置位。
    var sawDegradedDuringRound = false;
    controller.addListener((s) {
      if (s.embeddingDegradedForRound) sawDegradedDuringRound = true;
    });
    await controller.continueWithFts5Only();
    expect(sawDegradedDuringRound, isTrue);

    // ③ 降级轮：resolveQueryVector 跳过 embedding（FTS 兜底），轮成功
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.failureContext, isNull);
    expect(controller.state.messages, hasLength(2));
    // 降级轮 persist 成功后重置跨轮降级标记——
    // 此前成功 copyWith 漏带，标记泄漏到后续所有轮次（永久跳过 embedding）
    expect(controller.state.embeddingDegradedForRound, isFalse);
  });

  // persist 阶段嵌入失败
  // 不再以 E104 阻断收稿——自动降级 has_embedding=false（FTS5 兜底）+
  // durable 事件留痕。E104 手动降级出口仍由检索侧（search_story）链路触达
  // （见上方  用例）。
  test('mode=advanced：G-01 persist 嵌入致命异常 → 自动降级收稿 + 事件留痕', () async {
    // importance=5 ≥ microVectorizeThreshold(4) → persist 阶段调用
    // _resolveEmbedding；_EmbeddingFailResolver（fallback=false）把 stub 的
    // UnimplementedError 包装为 EmbeddingCallFailedException 上抛。
    final controller = buildController(
      [
        sse([
          toolCallStart(
            0,
            'call_m1',
            'record_event_memory',
            '{"what":"苏明远夜探荒庙","importance":5}',
          ),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      resolver: _EmbeddingFailResolver(),
      withEventLog: true,
    );

    await controller.sendMessage('推进剧情');

    // ① 轮次正常收稿：不再 failed + E104，消息照常落库
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.failureContext, isNull);
    expect(controller.state.messages, hasLength(2));

    // ② 记忆条目落库且 has_embedding=false（FTS5 检索兜底仍在）
    final memory = await db.customSelect(
      'SELECT has_embedding FROM experiential_memories WHERE session_id = ?',
      variables: [Variable.withString('dir-test-1')],
    ).getSingle();
    expect(memory.read<bool>('has_embedding'), isFalse);

    // ③ durable 事件留痕（log-only，轨迹页可查）
    final events = await AgentEventLogRepository(
      database: db,
    ).readEvents('dir-test-1');
    expect(
      events.any((e) => e.type == AgentEventTypes.persistEmbeddingDegraded),
      isTrue,
    );
  });

  // 非破坏性重生成端到端
  //
  // 重生成旧版快照为变体 0、新版记变体 1 并移指针；切回旧版后消息 content
  // 物化为旧版，下一轮请求上下文含所选版本（content 即上下文）。
  test('mode=advanced：G-08+09 重生成保留旧版可切换+切换后上下文含所选版', () async {
    final bodies = <String>[];
    final controller = buildController(
      [
        sse([
          toolCallStart(
            0,
            'call_m1',
            'record_event_memory',
            '{"what":"开局","importance":3}',
          ),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f1', '第一版正文：夜色沉下来。'),
        sse([
          toolCallStart(
            0,
            'call_m2',
            'record_event_memory',
            '{"what":"重生成","importance":3}',
          ),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f2', '第二版正文：雨还在下。'),
        sse([
          toolCallStart(
            0,
            'call_m3',
            'record_event_memory',
            '{"what":"第三轮","importance":3}',
          ),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f3', '第三版正文：天亮了。'),
      ],
      bodyLog: bodies,
    );

    await controller.sendMessage('推进剧情');
    expect(controller.state.messages, hasLength(2));
    expect(controller.state.messages.last.content, contains('第一版正文'));

    // ① 重生成：旧版不销毁（快照为 variant 0），新版 = variant 1
    await controller.regenerateMessage(controller.state.messages.last);
    expect(controller.state.messages, hasLength(2));
    expect(controller.state.messages.last.content, contains('第二版正文'));
    expect(controller.state.variantFlashTurn, 1, reason: '新变体收稿高亮信号');
    // 收稿即同步内存变体面——切换器渲染条件为
    // variants.length>1 && currentVariantIndex!=null，此前两值在收稿后
    // 均不刷新（variantsByTurn 无写点、指针默认 null），切换器只在
    // 重开会话后可见， 主流程（重生成→切换）不可达。
    expect(
      controller.state.variantsByTurn?[1],
      hasLength(2),
      reason: '收稿后内存变体表立即可用（不依赖重开会话）',
    );
    expect(
      controller.state.artifactsByTurnNumber?[1]?.currentVariantIndex,
      1,
      reason: '内存变体指针随收稿回写为新版',
    );

    final svc = StoryPersistenceServiceImpl(
      database: db,
      chatRepository: ChatRepositoryImpl(database: db),
      experienceRepository: ExperienceRepositoryImpl(
        database: db,
        vectorEngine: const VectorEngine(),
      ),
    );
    final variants = await svc.loadMessageVariants('dir-test-1');
    expect(variants[1], hasLength(2), reason: '重生成后两版本并存');
    expect(variants[1]![0].content, contains('第一版正文'));
    expect(variants[1]![1].content, contains('第二版正文'));
    var artifactsMap = await svc.loadArtifactsBySession('dir-test-1');
    expect(artifactsMap[1]!.currentVariantIndex, 1, reason: '指针指向新版');

    // ② 切回 variant 0：消息正文物化为第一版，指针回 0
    await controller.switchMessageVariant(controller.state.messages.last, 0);
    expect(controller.state.messages.last.content, contains('第一版正文'));
    artifactsMap = await svc.loadArtifactsBySession('dir-test-1');
    expect(artifactsMap[1]!.currentVariantIndex, 0);
    expect(controller.state.variantFlashTurn, isNull);

    // ③ 下一轮请求上下文含所选版本（content 即上下文组装源）
    await controller.sendMessage('继续');
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.messages, hasLength(4));
    expect(bodies.last, contains('第一版正文'), reason: '切换后下一轮请求含所选版本');

    // ④ 清除高亮信号可幂等调用
    controller.clearVariantFlash();
    expect(controller.state.variantFlashTurn, isNull);
  });

  test('mode=advanced：监督模式写前审批（体验重构 C2）', () async {
    final controller = buildController(
      [
        sse([
          toolCallStart(
            0,
            'call_u1',
            'update_facts',
            '{"deltas":[{"action":"create_entity","confidence":4,'
                '"primary_name":"苏明远","entity_type":"character","importance":4}]}',
          ),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f2', '故事继续。'),
        finishRoundExemption('call_f2b', '故事继续。'),
      ],
      watchMode: true,
    );

    final round = controller.sendMessage('推进剧情');
    // 等待审批横幅出现（写档工具被审批 seam 拦住）
    for (var i = 0;
        i < 500 && controller.state.agentApprovalPrompt == null;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(controller.state.agentApprovalPrompt?.toolName, 'update_facts');
    expect(controller.state.agentApprovalPrompt?.summary, '1 处设定修订');

    // 允许后写入生效、轮次走完
    controller.resolveDirectorApproval(allow: true);
    await round;

    expect(controller.state.phase, IntermediatePhase.idle);
    final entities = await db.customSelect(
      'SELECT COUNT(*) AS c FROM factual_entities WHERE session_id = ?',
      variables: [Variable.withString('dir-test-1')],
    ).getSingle();
    expect(entities.read<int>('c'), 1);
  });

  test('mode=advanced：B12 投影等价——每步 outgoing == deriveAgentSurface(事件前缀)',
      () async {
    // 断言先行（不换真相源）：取真实轮的 durable 事件 + 当轮实际 outgoing
    // （HTTP body 快照），断言投影重建与真实请求逐字节等价。
    //
    // 已知近似项（显式豁免清单，随 / 逐项收敛）：
    // 1. 跨轮旧尾部残影：多轮会话的轮首 surface 从 chat_messages 重建
    //    （丢弃往轮注入面与工具结果，仅回插 round-work trace），投影则
    //    保留全部 append——本断言只覆盖「首轮起算的轮内增量」（本用例
    //    即首轮两步）；跨轮口径待请求面日志派生（远期）后收编。
    // 2. 子代理事件（起 log-only 中继落账）不进投影——relay 剥离
    //    surfaceOp，天然豁免。
    // 3. 恢复器补写的 assistant/message（interrupted 半截正文）只在投影
    //    侧存在——已恢复会话不在本断言范围。
    // 4. finish_round 的 prose 参数流（onToolArgDelta 直播）不产生 durable
    //    事件——终值经 assistant/message 与收割链路落账。
    final bodies = <String>[];
    final controller = buildController(
      [
        sse([
          textDelta('我先查一下。'),
          toolCallStart(0, 'call_s1', 'search_story', '{"query":"古碑"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      withEventLog: true,
      bodyLog: bodies,
    );

    await controller.sendMessage('苏明远进入荒庙');

    expect(controller.state.phase, IntermediatePhase.idle);
    expect(bodies, hasLength(3), reason: '三步：检索 + finish_round 两段（闸门 B 豁免）');

    final events = await AgentEventLogRepository(database: db).readEvents(
      'dir-test-1',
    );
    expect(events, isNotEmpty);

    // 各步 outgoing = 该步 assistant/message 事件之前的全部事件投影
    final assistantIndexes = <int>[];
    for (var i = 0; i < events.length; i++) {
      if (events[i].type == AgentEventTypes.assistantMessage) {
        assistantIndexes.add(i);
      }
    }
    expect(assistantIndexes, hasLength(3));

    final wire = AgentWireOptions.forProtocolName('openaiCompatible');
    for (var step = 0; step < assistantIndexes.length; step++) {
      final projection = deriveAgentSurface(
        events.sublist(0, assistantIndexes[step]),
      );
      final projected = [
        for (final message in projection.messages) message.toRequestMap(wire),
      ];
      final wireMessages = (jsonDecode(bodies[step])
          as Map<String, dynamic>)['messages'] as List<dynamic>;
      expect(
        projected,
        equals(wireMessages),
        reason: '第 ${step + 1} 步请求面与事件投影不等价',
      );
    }

    // 结构性抽检：第 1 步含冻结前缀 system + 本轮 user 输入；
    // 第 2 步追加 assistant(tool_calls) 与 tool 结果（配对合法）
    final firstRequest = (jsonDecode(bodies[0])
        as Map<String, dynamic>)['messages'] as List<dynamic>;
    expect((firstRequest.first as Map<String, dynamic>)['role'], 'system');
    expect(
      firstRequest.any(
        (m) => (m as Map<String, dynamic>)['role'] == 'user',
      ),
      isTrue,
    );
    final secondRequest = (jsonDecode(bodies[1])
        as Map<String, dynamic>)['messages'] as List<dynamic>;
    expect(
      secondRequest.any(
        (m) => (m as Map<String, dynamic>)['role'] == 'tool',
      ),
      isTrue,
      reason: '工具结果进第 2 步请求（投影与真实面同源）',
    );
  });

  test('mode=advanced：B7-4 审批「本会话总是允许」——后续同工具免审留痕，清除后恢复审批', () async {
    final script = <String>[
      sse([
        toolCallStart(
          0,
          'call_u1',
          'update_facts',
          '{"deltas":[{"action":"create_entity","confidence":4,'
              '"primary_name":"苏明远","entity_type":"character","importance":4}]}',
        ),
        finish('tool_calls'),
        '[DONE]',
      ]),
      finishRoundStep('call_f2', '故事继续。'),
      finishRoundExemption('call_f2b', '故事继续。'),
    ];
    final controller = buildController(script, watchMode: true);

    // ── 轮 1：首次审批，选「本会话总是允许」 ──
    final round1 = controller.sendMessage('推进剧情');
    for (var i = 0;
        i < 500 && controller.state.agentApprovalPrompt == null;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(controller.state.agentApprovalPrompt?.toolName, 'update_facts');
    controller.resolveDirectorApproval(allow: true, always: true);
    await round1;
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.sessionApprovalAllowCount, 1);
    // 记忆写入的留痕随 artifacts 持久化（live 列表轮末清空）
    final turn1Steps =
        controller.state.artifactsByTurnNumber?[1]?.agentSteps ?? const [];
    expect(
      turn1Steps.any((s) => s.title.contains('本会话放行')),
      isTrue,
    );

    // ── 轮 2：同工具再次写入——不再弹横幅，自动放行留痕，轮次不阻塞 ──
    script.addAll([
      sse([
        toolCallStart(
          0,
          'call_u3',
          'update_facts',
          '{"deltas":[{"action":"create_entity","confidence":4,'
              '"primary_name":"林玉","entity_type":"character","importance":3}]}',
        ),
        finish('tool_calls'),
        '[DONE]',
      ]),
      finishRoundStep('call_f4', '故事推进。'),
      finishRoundExemption('call_f4b', '故事推进。'),
    ]);
    await controller.sendMessage('再推进');
    // 轮 2 结束后：审批横幅从未出现（无阻塞等待），写入已直接放行
    expect(controller.state.phase, IntermediatePhase.idle);
    final turn2Steps =
        controller.state.artifactsByTurnNumber?[2]?.agentSteps ?? const [];
    expect(
      turn2Steps.any((s) => s.title.contains('自动放行')),
      isTrue,
      reason: '会话级放行命中时 approvalRequiredFor 直接放行并留痕 L2',
    );

    // ── 清除放行后恢复逐次审批 ──
    expect(controller.clearSessionApprovalAllows(), 1);
    expect(controller.sessionApprovalAllowCount, 0);
  });

  test('mode=advanced：首回合能力提示注入、第二回合消失（P3.4）', () async {
    final bodies = <String>[];
    final script = <String>[
      finishRoundStep('call_f1', '第一幕开场。'),
      finishRoundExemption('call_f1b', '第一幕开场。'),
    ];
    final controller = buildController(script, bodyLog: bodies);

    await controller.sendMessage('开场');

    expect(controller.state.phase, IntermediatePhase.idle);
    // 首回合首个请求：surface 尾部（本轮用户输入之后）带能力提示
    expect(bodies.first, contains('能力提示'));
    expect(bodies.first, contains('spawn'));

    // 第二回合：提示不注入（历史回放也不含——surface 消息未持久化）
    script.addAll([
      finishRoundStep('call_f2', '第二幕推进。'),
      finishRoundExemption('call_f2b', '第二幕推进。'),
    ]);
    await controller.sendMessage('继续');

    expect(controller.state.phase, IntermediatePhase.idle);
    final turn2FirstRequest = bodies[2];
    expect(turn2FirstRequest, isNot(contains('能力提示')));
  });

  test('mode=advanced：重新生成后请求中该用户消息恰好出现一次', () async {
    const userText = '勇者进入边境庄园';
    final bodies = <String>[];
    final script = <String>[
      finishRoundStep('call_f1', '第一幕开场。'),
      finishRoundExemption('call_f1b', '第一幕开场。'),
    ];
    final controller = buildController(script, bodyLog: bodies);

    await controller.sendMessage(userText);
    expect(controller.state.phase, IntermediatePhase.idle);

    // 重新生成第一轮的 assistant 回复：user_N 刻意保留在库中（Fork 语义）
    script.addAll([
      finishRoundStep('call_f2', '重新生成第一幕。'),
      finishRoundExemption('call_f2b', '重新生成第一幕。'),
    ]);
    final assistantMessage = controller.state.messages
        .where((m) => m.role == 'assistant')
        .reduce((a, b) => b);
    await controller.regenerateMessage(assistantMessage);

    expect(controller.state.phase, IntermediatePhase.idle);
    expect(bodies.length, greaterThanOrEqualTo(4));
    // 修复前：history 重载末尾含 user_N，surface 组装再追加 userInput →
    // 同一条用户消息进上下文两次。断言重新生成的每个请求（含 step 续传）
    // 中该文本作为独立 user 消息恰好一次。
    for (final body in bodies.sublist(2)) {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final messages = decoded['messages']! as List<dynamic>;
      expect(
        messages.where(
          (m) => m is Map && m['role'] == 'user' && m['content'] == userText,
        ),
        hasLength(1),
      );
    }
  });

  test('mode=advanced：轮时间线随 artifacts 持久化（思考/播报/动作交错，T4）', () async {
    final controller = buildController([
      // Step 0：思考 + 播报 + search_story
      sse([
        '{"choices":[{"delta":{"reasoning_content":"先查前情。"},"finish_reason":null}]}',
        textDelta('让我先翻翻前情。'),
        toolCallStart(0, 'call_s1', 'search_story', '{"query":"古碑"}'),
        finish('tool_calls'),
        '[DONE]',
      ]),
      // Step 1：正文经 prose 参数交付 + finish_round（闸门 B 拒绝）
      finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
      // Step 2：补记事件记忆
      sse([
        toolCallStart(
          0,
          'call_m1',
          'record_event_memory',
          '{"what":"苏明远夜探荒庙","importance":3}',
        ),
        finish('tool_calls'),
        '[DONE]',
      ]),
      // Step 3：二次 finish_round 放行
      finishRoundStep('call_f2', '夜色沉下来，苏明远推开荒庙的门。'),
    ]);

    await controller.sendMessage('苏明远进入荒庙');
    expect(controller.state.phase, IntermediatePhase.idle);

    final artifacts = controller.state.artifactsByTurnNumber?[1];
    expect(artifacts, isNotNull);

    expect(artifacts!.agentSteps, isNotEmpty);
    expect(artifacts.agentTimeline.map((b) => b.kind).toList(), [
      AgentTimelineKind.thinking,
      AgentTimelineKind.narration,
      AgentTimelineKind.action,
      AgentTimelineKind.action,
      AgentTimelineKind.action,
      AgentTimelineKind.action,
    ]);
    expect(artifacts.agentTimeline[0].text, '先查前情。');
    expect(artifacts.agentTimeline[1].text, '让我先翻翻前情。');
    expect(artifacts.agentTimeline[2].action!.toolName, 'search_story');
    expect(artifacts.agentTimeline[2].stepIndex, 0);
    expect(
      artifacts.agentTimeline
          .where((b) => b.kind == AgentTimelineKind.narration)
          .length,
      1,
    );

    // 消息行 thinkingContent 合并串保持写入（现有消费者不感知）
    final assistant = controller.state.messages
        .where((m) => m.role == 'assistant')
        .reduce((a, b) => b);
    expect(assistant.thinkingContent, '先查前情。');

    // 数据库 agent_timeline 列实际落库
    final row = await db.customSelect(
      'SELECT agent_timeline FROM intermediate_round_artifacts '
      'WHERE session_id = ? AND turn_number = 1',
      variables: [Variable.withString('dir-test-1')],
    ).getSingle();
    expect(row.readNullable<String>('agent_timeline'), contains('narration'));
  });

  test('mode=advanced：重生成覆盖同轮时间线（T4）', () async {
    final script = <String>[
      finishRoundStep('call_f1', '旧版正文。'),
      finishRoundExemption('call_f1b', '旧版正文。'),
    ];
    final controller = buildController(script);

    await controller.sendMessage('推进剧情');
    expect(controller.state.phase, IntermediatePhase.idle);
    final artifactsV1 = controller.state.artifactsByTurnNumber![1]!;
    expect(
      artifactsV1.agentTimeline.map((b) => b.kind),
      [AgentTimelineKind.action, AgentTimelineKind.action],
    );
    expect(
      controller.state.messages.lastWhere((m) => m.role == 'assistant').content,
      '旧版正文。',
    );

    script.addAll([
      sse([
        '{"choices":[{"delta":{"reasoning_content":"换个写法。"},"finish_reason":null}]}',
        toolCallStart(0, 'call_f2', 'finish_round', '{"prose":"新版正文，换了开场。"}'),
        finish('tool_calls'),
        '[DONE]',
      ]),
      finishRoundExemption('call_f2b', '新版正文，换了开场。'),
    ]);
    final assistantMessage = controller.state.messages
        .where((m) => m.role == 'assistant')
        .reduce((a, b) => b);
    await controller.regenerateMessage(assistantMessage);
    expect(controller.state.phase, IntermediatePhase.idle);

    final regenerated = controller.state.artifactsByTurnNumber?[1];
    expect(regenerated, isNotNull);
    // 覆盖后是新版时间线：首块为思考，正文升格不进时间线
    expect(regenerated!.agentTimeline.first.kind, AgentTimelineKind.thinking);
    expect(regenerated.agentTimeline.first.text, '换个写法。');
    final rows = await db.customSelect(
      'SELECT COUNT(*) AS c FROM intermediate_round_artifacts '
      'WHERE session_id = ? AND turn_number = 1',
      variables: [Variable.withString('dir-test-1')],
    ).getSingle();
    expect(rows.read<int>('c'), 1, reason: '重生成覆盖同 turnNumber，不留旧行');
  });

  // ── 停止保留半截正文 + failed 态直发 ─────────────────────────────

  test('mode=advanced：直播正文流出后手动停止 → 保留为未完成稿件（不再蒸发）', () async {
    final controller = buildController(
      const [],
      hangAt: 0,
    );

    unawaited(controller.sendMessage('苏明远进入荒庙'));
    await hangClient.hangFired.future.timeout(const Duration(seconds: 20));
    // HTTP 层吐帧 ≠ 模型层建块：等 liveBlocks 出现非空文本块再停止
    // （太早停止会走「无稿清场」分支）。
    expect(
      await until(
        () => controller.state.liveBlocks.any(
          (b) => b.kind == AgentLiveBlockKind.text && !b.isEmpty,
        ),
      ),
      isTrue,
      reason: '等待直播正文块到达',
    );

    await controller.cancel();
    expect(
      await until(
        () =>
            controller.state.phase == IntermediatePhase.failed &&
            !controller.state.isStopping,
      ),
      isTrue,
      reason: '等待停止落定',
    );

    // 停止≠丢弃：进「已停止」failed 态，直播块与 pending 气泡保留
    expect(controller.state.failureContext?.errorCode, 'user_stopped');
    expect(
      controller.state.failureContext?.failedPhase,
      IntermediatePhase.generating,
    );
    expect(
      controller.state.liveBlocks.any(
        (b) => b.kind == AgentLiveBlockKind.text && !b.isEmpty,
      ),
      isTrue,
      reason: '半截直播正文保留为未完成稿件',
    );
    expect(controller.state.pendingUserMessage, isNotNull);
  });

  test('mode=advanced：停止后的 failed 态直发新消息 → 事务性清残留无幽灵轮', () async {
    final controller = buildController(
      [
        finishRoundStep('call_f1', '完整的第二轮正文。'),
        finishRoundExemption('call_f1b', '完整的第二轮正文。'),
      ],
      hangAt: 0,
    );

    unawaited(controller.sendMessage('第一条'));
    await hangClient.hangFired.future.timeout(const Duration(seconds: 20));
    expect(
      await until(
        () => controller.state.liveBlocks.any(
          (b) => b.kind == AgentLiveBlockKind.text && !b.isEmpty,
        ),
      ),
      isTrue,
    );
    await controller.cancel();
    expect(
      await until(
        () =>
            controller.state.phase == IntermediatePhase.failed &&
            !controller.state.isStopping,
      ),
      isTrue,
    );

    // failed 态直发：不再要求先清空本轮
    await controller.sendMessage('第二条');

    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.failureContext, isNull);
    expect(controller.state.liveBlocks, isEmpty, reason: '旧直播块随新轮清理，不残留');
    // 幽灵轮检查：第一轮从未持久化，库里只有第二轮一对消息
    final messages = await db.customSelect(
      'SELECT role, content FROM chat_messages WHERE session_id = ? '
      'ORDER BY created_at ASC',
      variables: [Variable.withString('dir-test-1')],
    ).get();
    expect(messages, hasLength(2));
    expect(messages.last.read<String>('content'), contains('完整的第二轮正文'));
  });
}

/// 只记录 applyCharacterCard 调用（其余接口 noSuchMethod 兜底）。
class _RecordingApplyService implements ResourceApplyService {
  _RecordingApplyService(this.calls);

  final List<String> calls;

  @override
  Future<int> applyCharacterCard({
    required String sessionId,
    required String cardId,
    required String defaultCharacterName,
    required String duplicateErrorMessage,
    String? defaultSettingName,
  }) async {
    calls.add(cardId);
    return 3;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
