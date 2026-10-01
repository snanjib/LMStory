import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/network/http_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/presentation/controllers/advanced_chat_controller.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/datasources/llm_remote_datasource.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session_settings.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/data/repositories/factual_repository_impl.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/story_runtime/data/persistence_service_impl.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';

import '../../../test_helpers/stub_failure_log_repository.dart';

/// finish_round 参数流直播接线（正文交付契约设计 §4.3，导演侧 e2e）
///
/// 真实 SSE 解析链 + 内存 drift：验证 prose 参数增量 → liveBlocks 直播、
/// 权威替换、Gemini 整块退化、工具卡不漏正文。
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
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _SseHttpClient implements HttpClient {
  _SseHttpClient(this.responses);

  final List<String> responses;
  int callCount = 0;

  @override
  Stream<String> streamPost(
    String url,
    Map<String, String> headers, {
    String? body,
    Encoding encoding = utf8,
    CancellationToken? cancelToken,
    Duration? connectTimeout,
    Duration? readTimeout,
  }) {
    final response = responses[callCount];
    callCount++;
    return Stream.value(response);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

String _sse(List<String> jsons) => jsons.map((j) => 'data: $j\n\n').join();

/// 可控 SSE 客户端——测试侧逐帧送数，取消语义与真实客户端一致
///（stream_post_native：取消时 addError(CancelledException) 再 close）
class _GatedSseHttpClient implements HttpClient {
  final StreamController<String> _controller = StreamController<String>();
  var _listened = false;

  /// 送出一帧 SSE 数据（订阅建立前送入会被单订阅流缓冲，订阅即达）
  void emit(String sseFrame) => _controller.add(sseFrame);

  @override
  Stream<String> streamPost(
    String url,
    Map<String, String> headers, {
    String? body,
    Encoding encoding = utf8,
    CancellationToken? cancelToken,
    Duration? connectTimeout,
    Duration? readTimeout,
  }) {
    if (_listened) return const Stream.empty();
    _listened = true;
    cancelToken?.bind(() {
      if (!_controller.isClosed) {
        _controller
          ..addError(const CancelledException('Request was cancelled'))
          ..close();
      }
    });
    return _controller.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

String _textDelta(String content) =>
    '{"choices":[{"delta":{"content":${jsonEncode(content)}},"finish_reason":null}]}';

/// 工具调用首片（id+name+首段参数——Start 与 Args 同片发出）
String _toolCallStart(int index, String id, String name, String args) =>
    '{"choices":[{"delta":{"tool_calls":[{"index":$index,"id":"$id","type":"function","function":{"name":"$name","arguments":${jsonEncode(args)}}}]},"finish_reason":null}]}';

/// 工具调用参数续片
String _toolCallArgs(int index, String args) =>
    '{"choices":[{"delta":{"tool_calls":[{"index":$index,"function":{"arguments":${jsonEncode(args)}}}]},"finish_reason":null}]}';

String _finish(String reason) =>
    '{"choices":[{"delta":{},"finish_reason":"$reason"}]}';

AdvancedChatController _buildController(
  List<String> sseResponses, {
  int? maxSteps,
  AgentEventLogRepository? eventLog,
  HttpClient? httpClient,
}) {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final chatRepo = ChatRepositoryImpl(database: db);
  final experienceRepo = ExperienceRepositoryImpl(
    database: db,
    vectorEngine: const VectorEngine(),
  );
  final factualRepo = FactualRepositoryImpl(database: db);

  return AdvancedChatController(
    chatRepository: chatRepo,
    configurationResolver: _FakeResolver(),
    llmService: LlmRemoteDataSource(
      httpClient: httpClient ?? _SseHttpClient(sseResponses),
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
    failureLogRepository: const StubFailureLogRepository(),
    tokenCounter: TokenCounter(),
    getConfig: () async => const AdvancedConfig(),
    logger: const Logger('test'),
    session: ChatSession(
      sessionId: 'dir-prose-test',
      maxSteps: maxSteps,
      title: '测试导演',
      mode: 'advanced',
      createdAt: DateTime.now(),
      lastActiveAt: DateTime.now(),
      messageCount: 0,
    ),
    factualRepository: factualRepo,
    agentEventLogRepository: eventLog,
  );
}

const _prose = '夜色沉下来，苏明远推开荒庙的门。\n石阶上有新的脚印。';

/// record_event_memory 一步（闸门 B 素材）
final _recordMemory = _sse([
  _toolCallStart(
    0,
    'call_m1',
    'record_event_memory',
    '{"what":"苏明远夜探荒庙","importance":3}',
  ),
  _finish('tool_calls'),
  '[DONE]',
]);

void main() {
  test('T9 轮轨迹补账：bootstrap/注入/轮内事件全量落日志（可重建消息序列）', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final eventLog = AgentEventLogRepository(database: db);
    final controller = _buildController(
      [
        // 一步完成：record_event_memory（同时验证 step/assistant/tool 事件）
        _recordMemory,
        _sse([
          _toolCallStart(
            0,
            'call_f1',
            'finish_round',
            jsonEncode({'prose': _prose}),
          ),
          _finish('tool_calls'),
          '[DONE]',
        ]),
      ],
      eventLog: eventLog,
    );

    await controller.sendMessage('苏明远进入荒庙');
    expect(controller.state.phase, IntermediatePhase.idle);

    final events = await eventLog.readEvents('dir-prose-test');
    final types = events.map((e) => e.type).toList();

    // 轮首补账：frozen（含内容）+ 初始 user/message（source=user）
    expect(types, contains(AgentEventTypes.systemFrozen));
    final frozen = events.firstWhere(
      (e) => e.type == AgentEventTypes.systemFrozen,
    );
    expect(frozen.data['content'] as String, contains('【项目规则】'));
    final initialUser = events.firstWhere(
      (e) =>
          e.type == AgentEventTypes.userMessage && e.data['source'] == 'user',
    );
    expect(initialUser.data['content'] as String, '苏明远进入荒庙');

    // 轮内事件：assistant/message（含工具调用）+ tool/result（含耗时）+
    // turn/begin + turn/end
    expect(types, contains(AgentEventTypes.assistantMessage));
    expect(types, contains(AgentEventTypes.toolResult));
    expect(types, contains(AgentEventTypes.turnBegin));
    expect(types, contains(AgentEventTypes.turnEnd));
    final toolResult = events.firstWhere(
      (e) => e.type == AgentEventTypes.toolResult,
    );
    expect(toolResult.data['durationMs'], isNotNull);

    await db.close();
  });

  test('参数分片流式直播：prose 增量逐段进直播块，正文不进工具卡', () async {
    final controller = _buildController([
      // Step 1：finish_round 参数分三片流出（gate B 首拒）
      _sse([
        _textDelta('落笔。'),
        _toolCallStart(0, 'call_f1', 'finish_round', '{"prose":"夜色'),
        _toolCallArgs(0, '沉下来，苏明远推开荒庙的门。'),
        _toolCallArgs(0, r'\n石阶上有新的脚印。"}'),
        _finish('tool_calls'),
        '[DONE]',
      ]),
      _recordMemory,
      // Step 3：二次 finish_round 放行（整片参数）
      _sse([
        _toolCallStart(
          0,
          'call_f2',
          'finish_round',
          jsonEncode({'prose': _prose}),
        ),
        _finish('tool_calls'),
        '[DONE]',
      ]),
    ]);

    await controller.sendMessage('苏明远进入荒庙');

    expect(controller.state.phase, IntermediatePhase.idle);

    // 轮时间线含完整 prose（流式增量或权威替换殊途同归；explicitReply 已
    // 交付 → 全部文本进时间线，liveBlocks 本体在 persist 后清空）
    final artifacts = controller.state.artifactsByTurnNumber![1]!;
    final textBlocks = artifacts.agentTimeline
        .where((b) => b.kind == AgentTimelineKind.narration)
        .toList();
    expect(textBlocks.map((b) => b.text), contains(_prose));

    // 工具卡不漏正文：finish_round 步骤的 argsPreview 全空
    final finishSteps = artifacts.agentSteps
        .where((s) => s.toolName == 'finish_round')
        .toList();
    expect(finishSteps, isNotEmpty);
    for (final step in finishSteps) {
      expect(step.argsPreview, '', reason: '正文唯一载体是 prose 参数，不得在工具卡露一角');
    }

    // DD1 回归：落幕步骤与时间线动作块都不得以 running 落库——collectRound
    // 在 finish_round 工具体内装配时间线（此刻仍是 running），若不同步回补，
    // 历史轮（含重启后）会渲染出永久 spinner。首轮被闸门拒的落幕卡允许
    // 保留失败态（warning/error），最终一次必须是 done。
    for (final step in finishSteps) {
      expect(
        step.isRunning,
        isFalse,
        reason: 'agentSteps 的落幕步骤不得以 running 落库',
      );
    }
    expect(
      finishSteps.last.status,
      AgentStepStatus.done,
      reason: '最终落幕步骤应为 done',
    );
    // DD2：首轮被终审闸门拒的落幕卡是"可恢复失败"——黄色 warning，
    // 而不是红色 error（整轮并未中断）。
    expect(
      finishSteps.first.status,
      AgentStepStatus.warning,
      reason: '闸门拒绝属可恢复失败，应记 warning',
    );
    expect(
      finishSteps.where((s) => s.isError).toList(),
      isEmpty,
      reason: '本轮未中断，不应出现红色失败卡',
    );
    final finishActions = artifacts.agentTimeline
        .where((b) => b.isAction && b.action!.toolName == 'finish_round')
        .toList();
    expect(finishActions, isNotEmpty, reason: '时间线应含落幕动作块');
    for (final block in finishActions) {
      expect(
        block.action!.isRunning,
        isFalse,
        reason: 'agentTimeline 的落幕动作块不得以 running 落库',
      );
    }
    expect(
      artifacts.agentTimeline
          .where((b) => b.isAction && b.action!.isRunning)
          .toList(),
      isEmpty,
      reason: '落库时间线不允许残留任何 running 动作块',
    );

    // 落库正文 = prose 参数
    final reply = controller.state.messages
        .where((m) => m.role == 'assistant')
        .reduce((a, b) => b)
        .content;
    expect(reply, _prose);
  });

  test('Gemini/非流式退化：参数整片到达无增量 → 权威路径整块出稿', () async {
    final controller = _buildController([
      _sse([
        _toolCallStart(
          0,
          'call_f1',
          'finish_round',
          jsonEncode({'prose': _prose}),
        ),
        _finish('tool_calls'),
        '[DONE]',
      ]),
      _recordMemory,
      _sse([
        _toolCallStart(
          0,
          'call_f2',
          'finish_round',
          jsonEncode({'prose': _prose}),
        ),
        _finish('tool_calls'),
        '[DONE]',
      ]),
    ]);

    await controller.sendMessage('苏明远进入荒庙');

    expect(controller.state.phase, IntermediatePhase.idle);
    final artifacts = controller.state.artifactsByTurnNumber![1]!;
    final textBlocks = artifacts.agentTimeline
        .where((b) => b.kind == AgentTimelineKind.narration)
        .toList();
    expect(
      textBlocks.map((b) => b.text),
      contains(_prose),
      reason: '无参数增量时权威替换直接整块出稿',
    );
  });

  test('权威替换：流出的围栏 prose 被解析后的剥离版本整块替换', () async {
    const fenced = '```markdown\n$_prose\n```';
    final controller = _buildController([
      _sse([
        _toolCallStart(
          0,
          'call_f1',
          'finish_round',
          jsonEncode({'prose': fenced}),
        ),
        _finish('tool_calls'),
        '[DONE]',
      ]),
      _recordMemory,
      _sse([
        _toolCallStart(
          0,
          'call_f2',
          'finish_round',
          jsonEncode({'prose': fenced}),
        ),
        _finish('tool_calls'),
        '[DONE]',
      ]),
    ]);

    await controller.sendMessage('苏明远进入荒庙');

    expect(controller.state.phase, IntermediatePhase.idle);
    final artifacts = controller.state.artifactsByTurnNumber![1]!;
    final texts = artifacts.agentTimeline
        .where((b) => b.kind == AgentTimelineKind.narration)
        .map((b) => b.text)
        .toList();
    // 流式直播会先出现带围栏原文，权威替换后以剥离版本为准
    expect(texts.last, _prose);
  });

  test('通道 B：finish_round 参数 JSON 截断 → 提取器流出的正文经文本回退收录', () async {
    final streamedProse = '雨' * 220;
    final controller = _buildController([
      // Step 1：finish_round 参数 JSON 中途截断（finish_reason=length 形态），
      // fromRawArgs 解析失败降级空 Map → 守卫信封（不提交）；
      // 但参数增量已流进 liveBlocks（通道 B 素材就位）
      _sse([
        _toolCallStart(
          0,
          'call_f1',
          'finish_round',
          '{"prose":"$streamedProse',
        ),
        _finish('length'),
        '[DONE]',
      ]),
      // Step 2：模型弃疗式短文本收尾 → completed，未提交
      _sse([_textDelta('写不动了。'), _finish('stop'), '[DONE]']),
    ]);

    await controller.sendMessage('推进剧情');

    // 非 cancelled + 有 ≥200 字文本块 → ④ 收割落库（已交付正文不得蒸发）
    expect(controller.state.phase, IntermediatePhase.idle);
    final reply = controller.state.messages
        .where((m) => m.role == 'assistant')
        .reduce((a, b) => b)
        .content;
    expect(reply, streamedProse);
    final summary =
        controller.state.artifactsByTurnNumber![1]!.agentWorkSummary;
    expect(summary?.deliveryChannel, 'text_fallback');
  });

  test('§8-5 预算尾巴：maxSteps 二次耗尽 + 仅 ≥200 字 content → text_fallback 落库',
      () async {
    final contentProse = '风' * 250;
    final controller = _buildController(
      [
        // Step 1：长正文经 content 流出 + 检索工具（未到步数上限）
        _sse([
          _textDelta(contentProse),
          _toolCallStart(0, 'call_s1', 'search_story', '{"query":"古碑"}'),
          _finish('tool_calls'),
          '[DONE]',
        ]),
        // Step 2：软着陆通牒后模型仍调工具 → 停用信封 → 二次耗尽
        _sse([
          _toolCallStart(0, 'call_x2', 'search_story', '{"query":"月光"}'),
          _finish('tool_calls'),
          '[DONE]',
        ]),
      ],
      maxSteps: 1,
    );

    await controller.sendMessage('推进剧情');

    // 修复前：maxSteps 尾巴整轮判 EAGENT，已流出的 250 字正文蒸发
    expect(controller.state.phase, IntermediatePhase.idle);
    final reply = controller.state.messages
        .where((m) => m.role == 'assistant')
        .reduce((a, b) => b)
        .content;
    expect(reply, contentProse);
    final summary =
        controller.state.artifactsByTurnNumber![1]!.agentWorkSummary;
    expect(summary?.deliveryChannel, 'text_fallback');
    // 留痕：通道收割进 artifacts 的 trace 步骤（L1 可见 + 持久化）
    expect(
      controller.state.artifactsByTurnNumber![1]!.agentSteps
          .any((s) => s.title.contains('文本回退收录')),
      isTrue,
    );
  });

  test('§8-6 展示层去重：content 里的正文副本被折叠为占位行（L2/L3）', () async {
    final longProse = '海' * 40 + '雾从山脊漫下来，灯塔的光一明一灭。' * 12; // 232 字 ≥200 阈值
    final controller = _buildController([
      // Step 1：正文先经 content 流出（契约违反形态）+ 检索工具续轮
      _sse([
        _textDelta(longProse),
        _toolCallStart(0, 'call_s1', 'search_story', '{"query":"灯塔"}'),
        _finish('tool_calls'),
        '[DONE]',
      ]),
      // Step 2：finish_round 携同一份 prose（L2 流头比对 + L3 终局锚窗）
      _sse([
        _toolCallStart(
          0,
          'call_f1',
          'finish_round',
          jsonEncode({'prose': longProse}),
        ),
        _finish('tool_calls'),
        '[DONE]',
      ]),
      _recordMemory,
      _sse([
        _toolCallStart(
          0,
          'call_f2',
          'finish_round',
          jsonEncode({'prose': longProse}),
        ),
        _finish('tool_calls'),
        '[DONE]',
      ]),
    ]);

    await controller.sendMessage('推进剧情');

    expect(controller.state.phase, IntermediatePhase.idle);
    final artifacts = controller.state.artifactsByTurnNumber![1]!;
    final texts = artifacts.agentTimeline
        .where((b) => b.kind == AgentTimelineKind.narration)
        .map((b) => b.text)
        .toList();

    // 近拷贝（content 副本与权威块同源）终局全部折叠为占位行；
    // 正文只存在于落库消息（时间线展开也只见占位行，终局干净）
    expect(texts, contains('（草稿已并入稿件）'));
    final occurrences = texts.where((t) => t == longProse).length;
    expect(occurrences, 0, reason: '重复只发生在直播区，终局必须干净');
    // 落库正文 = prose 参数
    final reply = controller.state.messages
        .where((m) => m.role == 'assistant')
        .reduce((a, b) => b)
        .content;
    expect(reply, longProse);
  });

  test('§8-5 committed 路径：prose 提交成功 → deliveryChannel=tool_args', () async {
    final controller = _buildController([
      _sse([
        _toolCallStart(
          0,
          'call_f1',
          'finish_round',
          jsonEncode({'prose': _prose}),
        ),
        _finish('tool_calls'),
        '[DONE]',
      ]),
      _recordMemory,
      _sse([
        _toolCallStart(
          0,
          'call_f2',
          'finish_round',
          jsonEncode({'prose': _prose}),
        ),
        _finish('tool_calls'),
        '[DONE]',
      ]),
    ]);

    await controller.sendMessage('推进剧情');

    expect(controller.state.phase, IntermediatePhase.idle);
    final summary =
        controller.state.artifactsByTurnNumber![1]!.agentWorkSummary;
    expect(summary?.deliveryChannel, 'tool_args');
  });

  test('DK8-4：流式中途 dispose——合帧 Timer 与取消收尾不再对已销毁 notifier 写 state', () async {
    final client = _GatedSseHttpClient();
    final controller = _buildController(const [], httpClient: client);

    final sent = controller.sendMessage('继续写');
    // 轮装配完成（reviewing 相位在首个 LLM 请求前置位）
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (controller.state.phase != IntermediatePhase.reviewing &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(controller.state.phase, IntermediatePhase.reviewing);

    // 送出一个文本增量：进 32ms 合帧缓冲（Timer 武装），间隔未到不落块
    client.emit('data: ${_textDelta('夜色沉下来')}\n\n');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      controller.state.liveBlocks,
      isEmpty,
      reason: '增量在合帧缓冲中，Timer 已武装',
    );

    controller.dispose();

    // 等过合帧间隔（32ms Timer 若未销毁，onFlush 会对已 dispose 的
    // StateNotifier 写 state → _debugIsMounted 断言 StateError）+ 取消
    // 级联（HTTP 令牌中断流 → 重试退避 → 取消检查点 → runRound 取消
    // 收尾的防御性回 idle 写经 mounted 守卫静默）。任一环节写已销毁
    // notifier 都会以 Zone uncaught 判败本用例
    await Future<void>.delayed(const Duration(seconds: 2));

    // 取消级联完成、轮收尾不再抛（异常会沿 sendMessage 逃逸成 uncaught）
    await sent.timeout(const Duration(seconds: 10));
  });
}
