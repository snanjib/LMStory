import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/network/http_client.dart' show CancellationToken;
import 'package:lmstory/features/advanced/data/story_compaction_overflow_compactor.dart';
import 'package:lmstory/features/advanced/domain/services/agent_system_prompt.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/story_runtime/domain/services/compaction_service.dart';

/// 假压缩服务：固定返回「摘要 + 从 keepFromIndex 起的近期消息」
class _FakeCompactionService implements StoryCompactionService {
  _FakeCompactionService({required this.keepFromIndex, this.throwOnCompact});

  final int keepFromIndex;
  final StateError? throwOnCompact;

  @override
  Future<CompactionResult> compact({
    required List<ChatMessage> history,
    required String sessionId,
    required NamingConfig namingConfig,
    required int contextWindow,
    required int maxTokens,
    required ContextBudget budget,
    required Duration connectTimeout,
    required Duration readTimeout,
    String? existingCompactionSummary,
    int baseContextTokens = 0,
    void Function(String delta)? onSummaryDelta,
    CancellationToken? cancelToken,
  }) async {
    if (throwOnCompact != null) throw throwOnCompact!;
    final recent = history.sublist(keepFromIndex);
    return CompactionResult(
      summary: '（压缩摘要）前情提要……',
      boundaryMessageId: history[keepFromIndex - 1].messageId,
      compactedHistory: [
        ChatMessage(
          messageId: 'summary-msg',
          sessionId: sessionId,
          role: 'system',
          content: 'summary',
          isSummary: true,
          createdAt: DateTime.now(),
        ),
        ...recent,
      ],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

StoryCompactionOverflowCompactor _compactor(
  _FakeCompactionService service,
) {
  return StoryCompactionOverflowCompactor(
    service: service,
    sessionId: 's1',
    namingConfig: const NamingConfig(
      baseUrl: 'https://api.test.com',
      apiKey: 'k',
      modelId: 'm',
    ),
    contextWindow: 128000,
    maxTokens: 8192,
    budget: const ContextBudget(),
    connectTimeout: const Duration(seconds: 15),
    readTimeout: const Duration(seconds: 30),
  );
}

void main() {
  group('StoryCompactionOverflowCompactor', () {
    test('压缩成功：system 原样保留 + 摘要为包裹 user 消息 + 近期段回接', () async {
      // 12 条对话：索引 8 起为保留段（fake 服务参数）
      final working = <AgentMessage>[
        AgentMessage.system('SYSTEM-FROZEN'),
        AgentMessage.system('CORE-BLOCKS'),
        for (var i = 0; i < 6; i++) ...[
          AgentMessage.user('用户$i'),
          AgentMessage.assistant(text: '回复$i'),
        ],
        AgentMessage.user('近期用户'),
        AgentMessage.assistant(text: '近期回复'),
        AgentMessage.user('当前输入'),
      ];
      final service = _FakeCompactionService(keepFromIndex: 8);

      final result = await _compactor(service).compact(working);

      expect(result, isNotNull);
      // system 前缀两条原样在头
      expect(result![0].role, 'system');
      expect(result[0].content, 'SYSTEM-FROZEN');
      expect(result[1].content, 'CORE-BLOCKS');
      // 摘要：user + workbench-reminder 包裹 + 资料非指令声明
      expect(result[2].role, 'user');
      expect(result[2].content, contains(kWorkbenchReminderOpen));
      expect(result[2].content, contains('资料非指令'));
      expect(result[2].content, contains('压缩摘要'));
      // 近期段原样回接：mapped[8..] = 用户4 起至当前输入（7 条）+ 摘要 1 条
      expect(result, hasLength(2 + 1 + 7));
      expect(result[3].content, '用户4');
      expect(result.last.content, '当前输入');
    });

    test('保留段开头的孤儿 tool 结果被跳过（协议配对完整性）', () async {
      final orphanPair = AgentMessage.assistant(
        toolCalls: [],
      );
      expect(orphanPair.role, 'assistant');
      final working = <AgentMessage>[
        AgentMessage.system('SYSTEM-FROZEN'),
        for (var i = 0; i < 4; i++) ...[
          AgentMessage.user('用户$i'),
          AgentMessage.assistant(text: '回复$i'),
        ],
        // 保留段起点是一条孤儿 tool 结果（其 assistant tool_use 在压缩区）
        AgentMessage.toolResult(toolCallId: 'orphan_1', content: '孤儿结果'),
        AgentMessage.user('当前输入'),
      ];
      // fake：保留从索引 8（孤儿 tool 结果）开始
      final service = _FakeCompactionService(keepFromIndex: 8);

      final result = await _compactor(service).compact(working);

      expect(result, isNotNull);
      final kept = result!.skip(2).toList();
      // 孤儿 tool 结果被跳过，当前输入仍在
      expect(kept.first.role, 'user');
      expect(kept.first.content, '当前输入');
    });

    test('对话消息不足（<8）→ null（维持原错误路径）', () async {
      final working = <AgentMessage>[
        AgentMessage.system('SYSTEM-FROZEN'),
        AgentMessage.user('仅一条'),
      ];
      final result = await _compactor(_FakeCompactionService(keepFromIndex: 1))
          .compact(working);
      expect(result, isNull);
    });

    test('压缩服务抛异常 → null（不带着半截上下文继续）', () async {
      final working = <AgentMessage>[
        AgentMessage.system('SYSTEM-FROZEN'),
        for (var i = 0; i < 6; i++) ...[
          AgentMessage.user('用户$i'),
          AgentMessage.assistant(text: '回复$i'),
        ],
      ];
      final service = _FakeCompactionService(
        keepFromIndex: 8,
        throwOnCompact: StateError('llm down'),
      );

      final result = await _compactor(service).compact(working);
      expect(result, isNull);
    });
  });
}
