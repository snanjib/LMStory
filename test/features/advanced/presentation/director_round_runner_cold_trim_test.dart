import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_host.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_round_runner.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_context.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_runtime_config.dart';
import 'package:lmstory/features/story_runtime/domain/services/compaction_service.dart';

/// 冷路径裁剪按用户配置——recoverEventLogIfNeeded
/// 在会话打开（loadHistory）时执行，此刻 runner 的 _tuning 尚未经 runRound
/// 刷新，恒为 const 默认（20）；不透出配置值时，用户配 50/0 的日志会被
/// 冷路径按 20 轮裁掉。controller 解析配置后经 retentionTurns 入参传入，
/// 本组测试锁定该契约与「恢复→裁剪」的顺序安全性。
void main() {
  late AppDatabase db;
  late AgentEventLogRepository repo;
  late _FakeHost host;
  late DirectorRoundRunner runner;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = AgentEventLogRepository(database: db);
    host = _FakeHost(eventLog: repo);
    runner = DirectorRoundRunner(host: host);
  });

  tearDown(() async => db.close());

  /// 带 turn 戳的事件构造
  AgentDurableEvent turnEvent(
    int turn,
    String type,
    Map<String, dynamic> data,
  ) =>
      AgentDurableEvent(type: type, data: {...data, 'turn': turn});

  /// 追加 [count] 个完整轮（begin+message+end）
  Future<void> appendTurns(int count) async {
    final events = <AgentDurableEvent>[
      for (var turn = 1; turn <= count; turn++) ...[
        turnEvent(turn, AgentEventTypes.turnBegin, const {}),
        turnEvent(
          turn,
          AgentEventTypes.assistantMessage,
          {'text': 't$turn'},
        ),
        turnEvent(turn, AgentEventTypes.turnEnd, const {'reason': 'finish'}),
      ],
    ];
    await repo.appendAll('s1', events);
  }

  Future<Set<int>> remainingTurns() => repo.readEvents('s1').then(
        (events) => events.map((e) => e.data['turn']).whereType<int>().toSet(),
      );

  test('冷路径裁剪按传入 retentionTurns（非 runner 默认 20）', () async {
    await appendTurns(25);

    await runner.recoverEventLogIfNeeded('s1', retentionTurns: 5);

    expect(await remainingTurns(), {21, 22, 23, 24, 25});
  });

  test('未传 retentionTurns 回落默认 20（现状语义不回退）', () async {
    await appendTurns(25);

    await runner.recoverEventLogIfNeeded('s1');

    final turns = await remainingTurns();
    expect(turns, hasLength(20));
    expect(turns, containsAll(const [6, 12, 20, 25]));
    expect(turns.any((t) => t < 6), isFalse);
  });

  test('恢复→裁剪顺序：悬挂轮补合成的事件带 turn 戳且不被随后裁剪误删', () async {
    final events = <AgentDurableEvent>[
      for (var turn = 1; turn <= 24; turn++) ...[
        turnEvent(turn, AgentEventTypes.turnBegin, const {}),
        turnEvent(turn, AgentEventTypes.assistantMessage, {'text': 't$turn'}),
        turnEvent(turn, AgentEventTypes.turnEnd, const {'reason': 'finish'}),
      ],
      // turn 25 悬挂（崩溃残留）：begin + 未配对 assistant，无 turn/end
      turnEvent(25, AgentEventTypes.turnBegin, const {}),
      turnEvent(25, AgentEventTypes.assistantMessage, const {'text': '半截稿'}),
    ];
    await repo.appendAll('s1', events);

    await runner.recoverEventLogIfNeeded('s1', retentionTurns: 2);

    final remaining = await repo.readEvents('s1');
    expect(
      remaining.map((e) => e.data['turn']).whereType<int>().toSet(),
      {24, 25},
      reason: '窗口只留最近 2 轮',
    );
    final repairedEnd = remaining.last;
    expect(repairedEnd.type, AgentEventTypes.turnEnd);
    expect(repairedEnd.data['reason'], 'interrupted');
    expect(repairedEnd.data['turn'], 25);
  });
}

/// 冷路径所需最小宿主桩：仅 storyState/logger/事件日志仓库被触碰，
/// 其余成员不在 recoverEventLogIfNeeded 的依赖面内。
class _FakeHost implements DirectorHost {
  _FakeHost({required this.eventLog});

  final AgentEventLogRepository eventLog;

  AdvancedChatState _state = AdvancedChatState.initial(
    ChatSession(
      sessionId: 's1',
      title: 'cold-trim',
      mode: 'advanced',
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      lastActiveAt: DateTime.fromMillisecondsSinceEpoch(0),
      messageCount: 0,
    ),
  );

  @override
  AdvancedChatState get storyState => _state;
  @override
  set storyState(AdvancedChatState value) => _state = value;

  @override
  RoundContext? get currentRound => null;
  @override
  bool get isStreamCancelled => false;
  @override
  Logger get logger => const Logger('test');
  @override
  AgentEventLogRepository? get agentEventLogRepository => eventLog;
  @override
  FactualRepository? get factualRepository => null;
  @override
  StoryCompactionService? get compactionService => null;

  @override
  Future<void> failRound(
    IntermediatePhase phase,
    String errorCode, {
    Object? error,
    ErrorCategory? errorCategory,
    StoryRuntimeConfig? config,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> runPersistPhase(RoundContext round) =>
      throw UnimplementedError();

  @override
  Future<Float32List?> resolveQueryVector(String queryText) async => null;

  @override
  LlmService get llmService => throw UnimplementedError();

  @override
  ExperienceRepository get experienceRepository => throw UnimplementedError();

  @override
  Future<List<ChatMessage>> loadSessionMessages(String sessionId) async =>
      const [];

  @override
  Future<Map<int, StoryRoundArtifacts>> loadSessionArtifacts(
    String sessionId,
  ) async =>
      {};
}
