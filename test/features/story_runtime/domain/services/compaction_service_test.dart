import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/config/intermediate_prompts_v2.dart';
import 'package:lmstory/core/network/http_client.dart' show CancellationToken;
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';
import 'package:lmstory/features/story_runtime/domain/services/compaction_service.dart';

/// LlmService mock：返回预设的 [LlmResponse]。
class _MockLlmService implements LlmService {
  _MockLlmService({this.response, this.shouldThrow = false, this.streamScript});

  final LlmResponse? response;
  final bool shouldThrow;

  /// 流式脚本（上下文用量指示）：非 null 时 streamChat 按序 emit 后返回
  final List<LlmStreamEvent>? streamScript;
  int chatCallCount = 0;
  LlmRequest? lastRequest;

  /// 全部 chat 请求（累积式压缩会并行发出压缩摘要 + 分段宏摘要两个请求）
  final List<LlmRequest> requests = <LlmRequest>[];

  @override
  Future<LlmResponse> chat(LlmRequest request) async {
    chatCallCount++;
    lastRequest = request;
    requests.add(request);
    if (shouldThrow) {
      throw Exception('Mock LLM failure');
    }
    return response ?? const LlmResponse(content: '');
  }

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) async* {
    final script = streamScript;
    if (script == null) {
      throw UnimplementedError('streamChat not scripted in this test');
    }
    for (final event in script) {
      yield event;
    }
  }
}

/// 构建测试用 ChatMessage
ChatMessage _msg({
  required String id,
  required String role,
  required String content,
  bool isSummary = false,
}) {
  return ChatMessage(
    messageId: id,
    sessionId: 'test-session',
    role: role,
    content: content,
    isSummary: isSummary,
    createdAt: DateTime(2026),
  );
}

/// 构建一组对话消息（user + assistant 交替）
List<ChatMessage> _dialogue(int rounds, {int charsPerMessage = 100}) {
  final messages = <ChatMessage>[];
  for (var i = 0; i < rounds; i++) {
    messages
      ..add(
        _msg(
          id: 'u$i',
          role: 'user',
          content: '用户消息 $i ' * (charsPerMessage ~/ 5),
        ),
      )
      ..add(
        _msg(
          id: 'a$i',
          role: 'assistant',
          content: '助手回复 $i ' * (charsPerMessage ~/ 5),
        ),
      );
  }
  return messages;
}

/// 测试用 NamingConfig（压缩 LLM 调用目标）
NamingConfig _testNamingConfig() => const NamingConfig(
      baseUrl: 'https://api.example.com',
      apiKey: 'test-key',
      modelId: 'test-model',
    );

void main() {
  group('StoryCompactionService - computeAvailableWindow', () {
    final service = StoryCompactionService(
      tokenCounter: TokenCounter(),
      llmService: _MockLlmService(),
    );

    test('正常计算：contextWindow - maxTokens', () {
      expect(
        service.computeAvailableWindow(
          contextWindow: 96000,
          maxTokens: 8192,
        ),
        87808,
      );
    });

    test('maxTokens >= contextWindow 时返回 0', () {
      expect(
        service.computeAvailableWindow(
          contextWindow: 8000,
          maxTokens: 8192,
        ),
        0,
      );
    });
  });

  group('StoryCompactionService - computeRecentMinTokens', () {
    final service = StoryCompactionService(
      tokenCounter: TokenCounter(),
      llmService: _MockLlmService(),
    );

    test('默认 recentMinRatio=null 动态计算', () {
      const budget = ContextBudget();
      // availableWindow=87808, recentMinTokenTarget=32000
      // raw = 32000/87808 = 0.3644 → 在 [0.10, 0.45] 范围内
      // floor(87808 * 0.3644) = 32000
      expect(
        service.computeRecentMinTokens(
          availableWindow: 87808,
          budget: budget,
        ),
        32000,
      );
    });

    test('自定义 recentMinRatio', () {
      const budget = ContextBudget(recentMinRatio: 0.3);
      expect(
        service.computeRecentMinTokens(
          availableWindow: 100000,
          budget: budget,
        ),
        30000,
      );
    });
  });

  group('StoryCompactionService - computeRecentMinTokens', () {
    final service = StoryCompactionService(
      tokenCounter: TokenCounter(),
      llmService: _MockLlmService(),
    );

    test('用户自定义 recentMinRatio 时直接使用', () {
      const budget = ContextBudget(recentMinRatio: 0.25);
      expect(
        service.computeRecentMinTokens(
          availableWindow: 87808,
          budget: budget,
        ),
        21952,
      );
    });

    test('recentMinRatio=null 动态计算，大窗口触发下限保护 0.10', () {
      const budget = ContextBudget();
      // availableWindow=968000, recentMinTokenTarget=32000
      // raw = 32000/968000 = 0.033 → clamp to 0.10
      expect(
        service.computeRecentMinTokens(
          availableWindow: 968000,
          budget: budget,
        ),
        96800,
      );
    });

    test('recentMinRatio=null 动态计算，小窗口触发上限保护 0.45', () {
      const budget = ContextBudget();
      // availableWindow=50000, recentMinTokenTarget=32000
      // raw = 32000/50000 = 0.64 → clamp to 0.45
      expect(
        service.computeRecentMinTokens(
          availableWindow: 50000,
          budget: budget,
        ),
        22500,
      );
    });

    test('recentMinRatio=null 动态计算，中间值不触发保护', () {
      const budget = ContextBudget();
      // availableWindow=96000, recentMinTokenTarget=32000
      // raw = 32000/96000 = 0.3333... → 在 [0.10, 0.45] 范围内
      // floor(96000 * 0.3333...) = floor(32000.0) = 32000
      expect(
        service.computeRecentMinTokens(
          availableWindow: 96000,
          budget: budget,
        ),
        32000,
      );
    });
  });

  group('StoryCompactionService - shouldCompact', () {
    test('消息不足 _minRecentMessages*2 时返回 false', () async {
      final service = StoryCompactionService(
        tokenCounter: TokenCounter(),
        llmService: _MockLlmService(),
      );
      // 只有 2 条消息（1 轮），不足 8 条（4 轮）
      final history = _dialogue(1);

      final result = await service.shouldCompact(
        history: history,
        contextWindow: 96000,
        budget: const ContextBudget(),
        rolePrompt: '你是冒险向导',
        userInput: '继续冒险',
      );

      expect(result, false);
    });

    test('availableWindow<=0 时返回 false', () async {
      final service = StoryCompactionService(
        tokenCounter: TokenCounter(),
        llmService: _MockLlmService(),
      );
      final history = _dialogue(10);

      final result = await service.shouldCompact(
        history: history,
        contextWindow: 8000,
        budget: const ContextBudget(),
        rolePrompt: '你是冒险向导',
        userInput: '继续冒险',
      );

      expect(result, false);
    });

    test('token 未超阈值时返回 false', () async {
      final service = StoryCompactionService(
        tokenCounter: TokenCounter(),
        llmService: _MockLlmService(),
      );
      // 5 轮对话，每条消息约 100 字符 → 总 token 远小于阈值
      final history = _dialogue(5, charsPerMessage: 50);

      final result = await service.shouldCompact(
        history: history,
        contextWindow: 96000,
        budget: const ContextBudget(),
        rolePrompt: '你是冒险向导',
        userInput: '继续冒险',
      );

      expect(result, false);
    });

    test('token 超阈值时返回 true', () async {
      final service = StoryCompactionService(
        tokenCounter: TokenCounter(),
        llmService: _MockLlmService(),
      );
      // 20 轮对话，每条消息约 2000 字符 → 总 token 超过阈值
      final history = _dialogue(20, charsPerMessage: 2000);

      final result = await service.shouldCompact(
        history: history,
        contextWindow: 96000,
        budget: const ContextBudget(),
        rolePrompt: '你是冒险向导',
        userInput: '继续冒险',
      );

      expect(result, true);
    });
  });

  group('StoryCompactionService - compact', () {
    group('StoryCompactionService - compact 取消通道（ST9-4）', () {
      test('cancelToken 透传到压缩 LLM 请求', () async {
        final llmService = _MockLlmService(
          response: const LlmResponse(content: '压缩摘要。'),
        );
        final service = StoryCompactionService(
          tokenCounter: TokenCounter(),
          llmService: llmService,
        );
        final token = CancellationToken();

        await service.compact(
          history: _dialogue(10, charsPerMessage: 500),
          sessionId: 'test-session',
          namingConfig: _testNamingConfig(),
          contextWindow: 96000,
          maxTokens: 8192,
          budget: const ContextBudget(),
          connectTimeout: const Duration(seconds: 30),
          readTimeout: const Duration(seconds: 60),
          cancelToken: token,
        );

        expect(llmService.requests, isNotEmpty);
        for (final request in llmService.requests) {
          expect(
            request.cancelToken,
            same(token),
            reason: 'ST9-4：取消令牌必须到达每个压缩 LLM 请求',
          );
        }
      });

      test('不传 cancelToken 时请求保持 null（既有调用方零改动）', () async {
        final llmService = _MockLlmService(
          response: const LlmResponse(content: '压缩摘要。'),
        );
        final service = StoryCompactionService(
          tokenCounter: TokenCounter(),
          llmService: llmService,
        );

        await service.compact(
          history: _dialogue(10, charsPerMessage: 500),
          sessionId: 'test-session',
          namingConfig: _testNamingConfig(),
          contextWindow: 96000,
          maxTokens: 8192,
          budget: const ContextBudget(),
          connectTimeout: const Duration(seconds: 30),
          readTimeout: const Duration(seconds: 60),
        );

        expect(llmService.lastRequest!.cancelToken, isNull);
      });
    });

    test('成功压缩：返回摘要 + 压缩后历史', () async {
      final llmService = _MockLlmService(
        response: const LlmResponse(
          content: '这是压缩摘要。来公寓第九天：主角在阁楼发现旧日记，得知公寓前身是诊所。',
        ),
      );
      final service = StoryCompactionService(
        tokenCounter: TokenCounter(),
        llmService: llmService,
      );

      // 10 轮对话
      final history = _dialogue(10, charsPerMessage: 500);
      const namingConfig = NamingConfig(
        baseUrl: 'https://api.example.com',
        apiKey: 'test-key',
        modelId: 'test-model',
      );

      final result = await service.compact(
        history: history,
        sessionId: 'test-session',
        namingConfig: namingConfig,
        contextWindow: 96000,
        maxTokens: 8192,
        budget: const ContextBudget(),
        connectTimeout: const Duration(seconds: 30),
        readTimeout: const Duration(seconds: 60),
      );

      // 验证摘要
      expect(result.summary, '这是压缩摘要。来公寓第九天：主角在阁楼发现旧日记，得知公寓前身是诊所。');
      // 验证 boundaryMessageId 不为空
      expect(result.boundaryMessageId, isNotEmpty);
      // 验证压缩后历史以摘要消息开头
      expect(result.compactedHistory.first.isSummary, true);
      expect(result.compactedHistory.first.role, 'system');
      expect(result.compactedHistory.first.content, result.summary);
      // 验证压缩后历史包含近期消息
      expect(result.compactedHistory.length, lessThan(history.length));
      expect(result.compactedHistory.length, greaterThan(1));
      // 验证 LLM 被调用一次
      expect(llmService.chatCallCount, 1);
      // 验证 LLM 请求使用压缩提示词
      expect(llmService.lastRequest!.temperature, 0.3);
      expect(llmService.lastRequest!.stream, false);
    });

    test('消息不足时抛 CompactionException', () async {
      final service = StoryCompactionService(
        tokenCounter: TokenCounter(),
        llmService: _MockLlmService(),
      );

      // 只有 2 轮对话（4 条消息），不足触发压缩
      final history = _dialogue(2);

      expect(
        () => service.compact(
          history: history,
          sessionId: 'test-session',
          namingConfig: const NamingConfig(
            baseUrl: 'https://api.example.com',
            apiKey: 'test-key',
            modelId: 'test-model',
          ),
          contextWindow: 96000,
          maxTokens: 8192,
          budget: const ContextBudget(),
          connectTimeout: const Duration(seconds: 30),
          readTimeout: const Duration(seconds: 60),
        ),
        throwsA(isA<CompactionException>()),
      );
    });

    test('LLM 返回空内容时抛 CompactionException', () async {
      final llmService = _MockLlmService(
        response: const LlmResponse(content: '   '),
      );
      final service = StoryCompactionService(
        tokenCounter: TokenCounter(),
        llmService: llmService,
      );

      final history = _dialogue(10, charsPerMessage: 500);

      expect(
        () => service.compact(
          history: history,
          sessionId: 'test-session',
          namingConfig: const NamingConfig(
            baseUrl: 'https://api.example.com',
            apiKey: 'test-key',
            modelId: 'test-model',
          ),
          contextWindow: 96000,
          maxTokens: 8192,
          budget: const ContextBudget(),
          connectTimeout: const Duration(seconds: 30),
          readTimeout: const Duration(seconds: 60),
        ),
        throwsA(isA<CompactionException>()),
      );
    });

    test('LLM 调用失败时抛 CompactionException', () async {
      final llmService = _MockLlmService(shouldThrow: true);
      final service = StoryCompactionService(
        tokenCounter: TokenCounter(),
        llmService: llmService,
      );

      final history = _dialogue(10, charsPerMessage: 500);

      expect(
        () => service.compact(
          history: history,
          sessionId: 'test-session',
          namingConfig: const NamingConfig(
            baseUrl: 'https://api.example.com',
            apiKey: 'test-key',
            modelId: 'test-model',
          ),
          contextWindow: 96000,
          maxTokens: 8192,
          budget: const ContextBudget(),
          connectTimeout: const Duration(seconds: 30),
          readTimeout: const Duration(seconds: 60),
        ),
        throwsA(isA<CompactionException>()),
      );
    });

    test('压缩后历史保留近期消息（boundary 之后的消息）', () async {
      final llmService = _MockLlmService(
        response: const LlmResponse(content: '压缩摘要内容'),
      );
      final service = StoryCompactionService(
        tokenCounter: TokenCounter(),
        llmService: llmService,
      );

      // 8 轮对话（16 条消息）
      final history = _dialogue(8, charsPerMessage: 500);

      final result = await service.compact(
        history: history,
        sessionId: 'test-session',
        namingConfig: const NamingConfig(
          baseUrl: 'https://api.example.com',
          apiKey: 'test-key',
          modelId: 'test-model',
        ),
        contextWindow: 96000,
        maxTokens: 8192,
        budget: const ContextBudget(),
        connectTimeout: const Duration(seconds: 30),
        readTimeout: const Duration(seconds: 60),
      );

      // 压缩后历史 = [summary, ...recent messages]
      // 至少保留 _minRecentMessages=4 条近期消息
      expect(
        result.compactedHistory.length,
        greaterThanOrEqualTo(5),
      ); // 1 summary + >=4 recent

      // 压缩后可见对话必须保持 user/assistant 严格配对——
      // boundary 吸附 assistant 后，保留区第一条对话是 user、最后一条是
      // assistant、对话总数为偶数（旧断言 anyOf 恰好放过 user 分支撞号链）。
      final keptDialogue =
          result.compactedHistory.where((m) => !m.isSummary).toList();
      expect(keptDialogue.first.role, 'user');
      final lastDialogue = result.compactedHistory.last;
      expect(lastDialogue.role, 'assistant');
      expect(lastDialogue.isSummary, false);
      expect(
        keptDialogue.length % 2,
        0,
        reason: '保留区对话必须完整配对，不得出现孤儿 assistant',
      );

      // boundary（最后一条被压缩的消息）必须落在 assistant 上
      final boundaryMessage = history.firstWhere(
        (m) => m.messageId == result.boundaryMessageId,
      );
      expect(
        boundaryMessage.role,
        'assistant',
        reason:
            'B1：压缩边界吸附 assistant，防止 user/assistant 被拆到压缩区与保留区两侧（孤儿 assistant + 轮号撞号链）',
      );
    });

    test('token 穿越点落在 user 上时边界吸附回 assistant', () async {
      final llmService = _MockLlmService(
        response: const LlmResponse(content: '压缩摘要内容'),
      );
      final service = StoryCompactionService(
        tokenCounter: TokenCounter(),
        llmService: llmService,
      );

      // 8 轮对话，第 5 轮 assistant 消息加重（约 3000 字符）：
      // 小 contextWindow（2000）使保留量上限压到数百 token，
      // 从尾部累积到第 5 轮 assistant 处穿越阈值——
      // 未吸附时 boundary 会落在 u5（user）上，吸附后应落在 a4（assistant）。
      final history = [
        for (var i = 0; i < 8; i++) ...[
          _msg(
            id: 'u$i',
            role: 'user',
            content: '用户消息 $i ' * 20,
          ),
          _msg(
            id: 'a$i',
            role: 'assistant',
            content:
                i == 5 ? '这是一条很长的助手回复，用来把保留量穿越点锚定在本轮。' * 100 : '助手回复 $i ' * 20,
          ),
        ],
      ];

      final result = await service.compact(
        history: history,
        sessionId: 'test-session',
        namingConfig: _testNamingConfig(),
        contextWindow: 2000,
        maxTokens: 100,
        budget: const ContextBudget(),
        connectTimeout: const Duration(seconds: 30),
        readTimeout: const Duration(seconds: 60),
      );

      // 未吸附：boundary = u5（user）；吸附后：a4（assistant）
      expect(
        result.boundaryMessageId,
        'a4',
        reason: '穿越点在 a5 时未吸附 boundary=u5(user)，吸附必须回退到 a4(assistant)',
      );
      final keptDialogue =
          result.compactedHistory.where((m) => !m.isSummary).toList();
      expect(keptDialogue.first.messageId, 'u5', reason: '保留区从 user 开始（配对完整）');
      expect(keptDialogue.length % 2, 0);
    });

    test('压缩摘要消息的 sessionId 与传入参数一致', () async {
      final llmService = _MockLlmService(
        response: const LlmResponse(content: '摘要'),
      );
      final service = StoryCompactionService(
        tokenCounter: TokenCounter(),
        llmService: llmService,
      );

      final history = _dialogue(10, charsPerMessage: 500);

      final result = await service.compact(
        history: history,
        sessionId: 'my-session-id',
        namingConfig: const NamingConfig(
          baseUrl: 'https://api.example.com',
          apiKey: 'test-key',
          modelId: 'test-model',
        ),
        contextWindow: 96000,
        maxTokens: 8192,
        budget: const ContextBudget(),
        connectTimeout: const Duration(seconds: 30),
        readTimeout: const Duration(seconds: 60),
      );

      expect(result.compactedHistory.first.sessionId, 'my-session-id');
    });

    test('protocol 和 providerOptions 透传到 LLM 请求', () async {
      final llmService = _MockLlmService(
        response: const LlmResponse(content: '摘要'),
      );
      final service = StoryCompactionService(
        tokenCounter: TokenCounter(),
        llmService: llmService,
      );

      final history = _dialogue(10, charsPerMessage: 500);
      const namingConfig = NamingConfig(
        baseUrl: 'https://api.example.com',
        apiKey: 'test-key',
        modelId: 'test-model',
        protocol: LlmProtocol.anthropic,
        providerOptions: {
          'thinking': {'type': 'enabled'},
        },
      );

      await service.compact(
        history: history,
        sessionId: 'test-session',
        namingConfig: namingConfig,
        contextWindow: 96000,
        maxTokens: 8192,
        budget: const ContextBudget(),
        connectTimeout: const Duration(seconds: 30),
        readTimeout: const Duration(seconds: 60),
      );

      expect(llmService.lastRequest!.protocol, LlmProtocol.anthropic);
      expect(llmService.lastRequest!.providerOptions, {
        'thinking': {'type': 'enabled'},
      });
    });
  });

  group('StoryCompactionService - extractPersistedSummary', () {
    test('返回 isSummary 消息内容', () {
      final history = <ChatMessage>[
        _msg(
          id: 'summary-1',
          role: 'system',
          content: '剧情骨架摘要',
          isSummary: true,
        ),
        _msg(id: 'u1', role: 'user', content: '你好'),
        _msg(id: 'a1', role: 'assistant', content: '你好！'),
      ];
      expect(
        StoryCompactionService.extractPersistedSummary(history),
        '剧情骨架摘要',
      );
    });

    test('无摘要消息时返回 null', () {
      final history = _dialogue(2);
      expect(StoryCompactionService.extractPersistedSummary(history), isNull);
    });

    test('摘要内容为空时返回 null', () {
      final history = <ChatMessage>[
        _msg(id: 'summary-1', role: 'system', content: '', isSummary: true),
        _msg(id: 'u1', role: 'user', content: '你好'),
      ];
      expect(StoryCompactionService.extractPersistedSummary(history), isNull);
    });
  });

  group('StoryCompactionService - compact 累积式摘要（2026-08-22）', () {
    test('existingSummary 作为独立 system 消息并入压缩请求', () async {
      final llmService = _MockLlmService(
        response: const LlmResponse(content: '合并后的新摘要'),
      );
      final service = StoryCompactionService(
        tokenCounter: TokenCounter(),
        llmService: llmService,
      );

      // 历史含旧摘要消息 + 足量对话（触发后续压缩分支）
      final history = <ChatMessage>[
        _msg(
          id: 'summary-old',
          role: 'system',
          content: '旧摘要占位',
          isSummary: true,
        ),
        ..._dialogue(10, charsPerMessage: 500),
      ];

      await service.compact(
        history: history,
        sessionId: 'test-session',
        namingConfig: _testNamingConfig(),
        contextWindow: 96000,
        maxTokens: 8192,
        budget: const ContextBudget(),
        connectTimeout: const Duration(seconds: 30),
        readTimeout: const Duration(seconds: 60),
        existingCompactionSummary: '来公寓第九天：主角在阁楼发现旧日记，得知公寓前身是诊所。',
      );

      // 后续压缩：并行发出 压缩摘要 + 分段宏摘要 两个请求
      expect(llmService.requests.length, 2);

      // 压缩摘要请求：第 1 条 system 为压缩提示词，第 2 条 system 为旧摘要注入
      final summaryRequest = llmService.requests.firstWhere(
        (r) =>
            (r.messages.first['content'] as String) ==
            kIntermediateCompactionPrompt,
      );
      final existingInjection = summaryRequest.messages[1]['content'] as String;
      expect(
        existingInjection
            .startsWith(kIntermediateCompactionExistingSummaryInjection),
        isTrue,
      );
      expect(
        existingInjection.contains('来公寓第九天：主角在阁楼发现旧日记，得知公寓前身是诊所。'),
        isTrue,
      );

      // 分段宏摘要请求不含旧摘要（仅覆盖本次新增轮次）
      final macroRequest = llmService.requests.firstWhere(
        (r) =>
            (r.messages.first['content'] as String) ==
            kIntermediateSegmentMacroPrompt,
      );
      for (final m in macroRequest.messages) {
        expect(m['content'], isNot(contains('来公寓第九天')));
      }
    });

    test('首次压缩（无 existingSummary）不注入旧摘要消息', () async {
      final llmService = _MockLlmService(
        response: const LlmResponse(content: '首次压缩摘要'),
      );
      final service = StoryCompactionService(
        tokenCounter: TokenCounter(),
        llmService: llmService,
      );

      await service.compact(
        history: _dialogue(10, charsPerMessage: 500),
        sessionId: 'test-session',
        namingConfig: _testNamingConfig(),
        contextWindow: 96000,
        maxTokens: 8192,
        budget: const ContextBudget(),
        connectTimeout: const Duration(seconds: 30),
        readTimeout: const Duration(seconds: 60),
      );

      expect(llmService.requests.length, 1);
      final messages = llmService.requests.single.messages;
      expect(messages[0]['content'], kIntermediateCompactionPrompt);
      // 第 2 条起即历史信封（单条 user 消息），无旧摘要注入
      expect(messages[1]['role'], 'user');
    });
  });

  // （2026-09-04 压缩正确性修复）：历史信封化——请求中禁止出现
  // assistant 角色。旧实现逐条原样追加 user/assistant，请求以剧情文本
  // 收尾、指令孤悬最前，角色扮演模型必然续写剧情而非输出摘要（实测缺陷：
  // 压缩"摘要"是成段对话与环境描写并被落库）。
  group('StoryCompactionService - 历史信封（禁止 assistant 尾巴）', () {
    test('首次压缩请求：压缩提示词 + 单条 user 信封，无 assistant 角色', () async {
      final llmService = _MockLlmService(
        response: const LlmResponse(content: '摘要'),
      );
      final service = StoryCompactionService(
        tokenCounter: TokenCounter(),
        llmService: llmService,
      );

      await service.compact(
        history: _dialogue(8, charsPerMessage: 500),
        sessionId: 'test-session',
        namingConfig: _testNamingConfig(),
        contextWindow: 96000,
        maxTokens: 8192,
        budget: const ContextBudget(),
        connectTimeout: const Duration(seconds: 30),
        readTimeout: const Duration(seconds: 60),
      );

      final request = llmService.requests.single;
      for (final m in request.messages) {
        expect(
          m['role'],
          isNot('assistant'),
          reason: '压缩请求不得包含 assistant 角色（续写偏置根源）',
        );
      }
      // 首次压缩：system(提示词) + user(信封)，恰好两条
      expect(request.messages.length, 2);
      expect(request.messages.first['content'], kIntermediateCompactionPrompt);
      final envelope = request.messages.last['content'] as String;
      expect(request.messages.last['role'], 'user');
      expect(envelope, contains('【待压缩对话历史开始】'));
      expect(envelope, contains('【待压缩对话历史结束】'));
      expect(envelope, contains('禁止续写'));
      // 历史内容在信封内以角色标签平铺
      expect(envelope, contains('用户：'));
      expect(envelope, contains('AI：'));
    });

    test('累积式压缩：两条 system + 信封；宏摘要请求同样无 assistant 角色', () async {
      final llmService = _MockLlmService(
        response: const LlmResponse(content: '新摘要'),
      );
      final service = StoryCompactionService(
        tokenCounter: TokenCounter(),
        llmService: llmService,
      );

      await service.compact(
        history: _dialogue(10, charsPerMessage: 500),
        sessionId: 'test-session',
        namingConfig: _testNamingConfig(),
        contextWindow: 96000,
        maxTokens: 8192,
        budget: const ContextBudget(),
        connectTimeout: const Duration(seconds: 30),
        readTimeout: const Duration(seconds: 60),
        existingCompactionSummary: '旧摘要全文。',
      );

      // 并行两请求：压缩摘要 + 分段宏摘要
      expect(llmService.requests.length, 2);
      for (final request in llmService.requests) {
        expect(
          request.messages.where((m) => m['role'] == 'assistant'),
          isEmpty,
          reason: '任何压缩类请求都不得包含 assistant 角色',
        );
        expect(request.messages.last['role'], 'user');
      }

      // 压缩请求 = system(提示词) + system(旧摘要注入) + user(信封)
      final summaryRequest = llmService.requests.firstWhere(
        (r) =>
            (r.messages.first['content'] as String) ==
            kIntermediateCompactionPrompt,
      );
      expect(summaryRequest.messages.length, 3);

      // 宏摘要请求 = system(宏摘要提示词) + user(信封)，收尾指令锚定自身任务
      final macroRequest = llmService.requests.firstWhere(
        (r) =>
            (r.messages.first['content'] as String) ==
            kIntermediateSegmentMacroPrompt,
      );
      expect(macroRequest.messages.length, 2);
      expect(macroRequest.messages.last['content'], contains('分段宏摘要'));
    });
  });

  group('StoryCompactionService - compact 保留量上限（死亡螺旋回归）', () {
    test('压缩后 shouldCompact 对压缩结果返回 false（64k 窗口）', () async {
      // 复现条件（修复前）：ctx=65536、maxTokens=8192 时
      // legacy 保留量 = 0.45×57344 ≈ 25805，加检索预留 9830 + 基础上下文
      // 超过触发线 32768 → shouldCompact 恒为 true → 每轮重复压缩。
      final llmService = _MockLlmService(
        response: const LlmResponse(content: '压缩后的剧情骨架摘要。'),
      );
      final service = StoryCompactionService(
        tokenCounter: TokenCounter(),
        llmService: llmService,
      );

      const contextWindow = 65536;
      const budget = ContextBudget();

      final result = await service.compact(
        history: _dialogue(30, charsPerMessage: 1500),
        sessionId: 'test-session',
        namingConfig: _testNamingConfig(),
        contextWindow: contextWindow,
        maxTokens: 8192,
        budget: budget,
        connectTimeout: const Duration(seconds: 30),
        readTimeout: const Duration(seconds: 60),
        baseContextTokens: 2000,
      );

      // 压缩结果喂回 shouldCompact（模拟次轮），必须不再触发
      final shouldCompactAgain = await service.shouldCompact(
        history: result.compactedHistory,
        contextWindow: contextWindow,
        budget: budget,
        rolePrompt: '角色提示词',
        compactionSummary: result.summary,
        userInput: '继续',
      );
      expect(
        shouldCompactAgain,
        isFalse,
        reason: '压缩完成后应低于触发线并留有增长跑道，否则会每轮重复压缩',
      );
    });
  });

  group('StoryCompactionService - _filterDialogueMessages', () {
    test('过滤掉 summary 消息和空内容消息', () async {
      final llmService = _MockLlmService(
        response: const LlmResponse(content: '摘要'),
      );
      final service = StoryCompactionService(
        tokenCounter: TokenCounter(),
        llmService: llmService,
      );

      // 构建包含 summary、空内容、user、assistant 的混合历史
      final history = <ChatMessage>[
        _msg(id: 'summary-1', role: 'system', content: '旧摘要', isSummary: true),
        _msg(id: 'u1', role: 'user', content: '你好'),
        _msg(id: 'a1', role: 'assistant', content: '你好！'),
        _msg(id: 'empty', role: 'user', content: ''),
        _msg(id: 'u2', role: 'user', content: '继续'),
        _msg(id: 'a2', role: 'assistant', content: '好的'),
      ];

      // 通过 shouldCompact 间接验证过滤逻辑
      final result = await service.shouldCompact(
        history: history,
        contextWindow: 96000,
        budget: const ContextBudget(),
        rolePrompt: '你是冒险向导',
        userInput: '继续冒险',
      );

      // 消息不足 8 条（过滤后仅 4 条对话消息），应返回 false
      expect(result, false);
    });
  });

  //  修复：压缩基数与真实对话消息计数——
  // 保证 turnNumber 跨压缩单调（recency / 按轮删除 / 时间线依赖真实轮次号）。
  group(
    'StoryCompactionService - compactedTurnBaseFor / countDialogueMessages',
    () {
      test('countDialogueMessages 只计 user/assistant，排除摘要卡', () {
        final messages = [
          _msg(id: 's0', role: 'system', content: '旧摘要', isSummary: true),
          ..._dialogue(3),
        ];
        expect(
          StoryCompactionService.countDialogueMessages(messages),
          6,
        );
      });

      test('无压缩点时基数为 0', () {
        final all = _dialogue(5);
        expect(
          StoryCompactionService.compactedTurnBaseFor(
            allMessages: all,
            compactionPoints: const [],
          ),
          0,
        );
      });

      test('boundary 在第 N 条消息时，基数 = 其前真实对话轮数', () {
        // 5 轮对话 + 头部一条旧摘要卡；boundary = a2（第 3 轮 assistant）。
        // take 含 boundary：u0,a0,u1,a1,u2,a2 共 6 条真实消息 ~/ 2 = 3。
        final all = [
          _msg(id: 's-old', role: 'system', content: '更旧摘要', isSummary: true),
          ..._dialogue(5),
        ];
        expect(
          StoryCompactionService.compactedTurnBaseFor(
            allMessages: all,
            compactionPoints: const [
              {'boundaryMessageId': 'a2', 'summaryMessageId': 'summary-1'},
            ],
          ),
          3,
        );
      });

      test('boundary 不在列表中时回退为 0（与 filterByCompactionPoint 同口径）', () {
        expect(
          StoryCompactionService.compactedTurnBaseFor(
            allMessages: _dialogue(3),
            compactionPoints: const [
              {'boundaryMessageId': 'missing', 'summaryMessageId': 's'},
            ],
          ),
          0,
        );
      });
    },
  );

  // ── 流式压缩摘要（上下文用量指示）────────────────────────────

  test('onSummaryDelta：增量按序回调，结果为完整摘要', () async {
    final deltas = <String>[];
    final service = StoryCompactionService(
      tokenCounter: TokenCounter(),
      llmService: _MockLlmService(
        streamScript: const [
          LlmTextDelta('主角'),
          LlmTextDelta('进城'),
          LlmStreamDone(),
        ],
      ),
    );

    final result = await service.compact(
      history: _dialogue(8, charsPerMessage: 500),
      sessionId: 'test-session',
      namingConfig: _testNamingConfig(),
      contextWindow: 96000,
      maxTokens: 8192,
      budget: const ContextBudget(),
      connectTimeout: const Duration(seconds: 30),
      readTimeout: const Duration(seconds: 60),
      onSummaryDelta: deltas.add,
    );

    expect(deltas, ['主角', '进城']);
    expect(result.summary, '主角进城');
  });

  test('流式错误（LlmStreamError）→ CompactionException', () async {
    final service = StoryCompactionService(
      tokenCounter: TokenCounter(),
      llmService: _MockLlmService(
        streamScript: const [
          LlmTextDelta('部分'),
          LlmStreamError('boom'),
        ],
      ),
    );

    await expectLater(
      service.compact(
        history: _dialogue(8, charsPerMessage: 500),
        sessionId: 'test-session',
        namingConfig: _testNamingConfig(),
        contextWindow: 96000,
        maxTokens: 8192,
        budget: const ContextBudget(),
        connectTimeout: const Duration(seconds: 30),
        readTimeout: const Duration(seconds: 60),
        onSummaryDelta: (_) {},
      ),
      throwsA(isA<CompactionException>()),
    );
  });

  test('onSummaryDelta 为 null：走非流式 chat 路径（既有行为不变）', () async {
    final llmService = _MockLlmService(
      response: const LlmResponse(content: '非流式摘要'),
    );
    final service = StoryCompactionService(
      tokenCounter: TokenCounter(),
      llmService: llmService,
    );

    final result = await service.compact(
      history: _dialogue(8, charsPerMessage: 500),
      sessionId: 'test-session',
      namingConfig: _testNamingConfig(),
      contextWindow: 96000,
      maxTokens: 8192,
      budget: const ContextBudget(),
      connectTimeout: const Duration(seconds: 30),
      readTimeout: const Duration(seconds: 60),
    );

    expect(result.summary, '非流式摘要');
    expect(llmService.chatCallCount, 1);
  });
}
