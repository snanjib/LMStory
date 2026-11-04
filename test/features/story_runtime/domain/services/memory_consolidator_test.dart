import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/story_runtime/domain/services/memory_consolidator.dart';

/// MemoryConsolidator 单元测试
///
/// 验证：
/// - LLM 调用参数（temperature/maxTokens/responseFormat/messages）
/// - JSON 解析容错（前后说明文字 / 字段类型修复 / 越界过滤）
/// - 失败降级（异常 / 超时 / 非法 JSON → 空列表）
/// - 空输入短路（不调用 LLM）
void main() {
  const namingConfig = NamingConfig(
    baseUrl: 'https://api.example.com',
    apiKey: 'sk-test',
    modelId: 'test-model',
  );
  const prompt = '系统提示词';

  ExperientialMemory buildMemory({
    required String memoryId,
    required int turnNumber,
    String summary = '勇者走进酒馆',
    int importance = 2,
    List<String> tags = const ['酒馆'],
  }) {
    return ExperientialMemory(
      memoryId: memoryId,
      sessionId: 's1',
      summary: summary,
      importance: importance,
      tags: tags,
      turnNumber: turnNumber,
      createdAt: DateTime(2026),
    );
  }

  group('MemoryConsolidator.consolidate', () {
    test('1. 空输入 → 返回空列表，不调用 LLM', () async {
      final llm = _StubLlmService();
      final consolidator = MemoryConsolidator(llmService: llm);

      final result = await consolidator.consolidate(
        memories: const [],
        namingConfig: namingConfig,
        consolidationPrompt: prompt,
      );

      expect(result, isEmpty);
      expect(llm.chatCalls, 0);
    });

    test('2. 正常路径：LLM 返回合法 JSON → 解析为合并记忆列表', () async {
      final llm = _StubLlmService(
        responseContent: '{"consolidated":['
            '{"summary":"勇者在后山发现古碑，碑文揭示其身世秘密",'
            '"tags":["古碑","身世"],"importance":4},'
            '{"summary":"勇者与酒馆老板结盟，获得关键线索",'
            '"tags":["酒馆老板","结盟"],"importance":3}'
            ']}',
      );
      final consolidator = MemoryConsolidator(llmService: llm);

      final result = await consolidator.consolidate(
        memories: [
          buildMemory(memoryId: 'm1', turnNumber: 1),
          buildMemory(memoryId: 'm2', turnNumber: 2),
        ],
        namingConfig: namingConfig,
        consolidationPrompt: prompt,
      );

      expect(result, hasLength(2));
      expect(result[0].summary, '勇者在后山发现古碑，碑文揭示其身世秘密');
      expect(result[0].tags, ['古碑', '身世']);
      expect(result[0].importance, 4);
      expect(result[1].summary, '勇者与酒馆老板结盟，获得关键线索');
      expect(result[1].importance, 3);
      expect(llm.chatCalls, 1);
    });

    test('3. LLM 返回带前后说明文字的 JSON → 仍能正确解析', () async {
      final llm = _StubLlmService(
        responseContent: '好的，以下是合并结果：\n'
            '{"consolidated":[{"summary":"合并节点","tags":["标签"],"importance":3}]}\n'
            '以上为合并结果。',
      );
      final consolidator = MemoryConsolidator(llmService: llm);

      final result = await consolidator.consolidate(
        memories: [buildMemory(memoryId: 'm1', turnNumber: 1)],
        namingConfig: namingConfig,
        consolidationPrompt: prompt,
      );

      expect(result, hasLength(1));
      expect(result[0].summary, '合并节点');
    });

    test('4. LLM 返回空 consolidated 数组 → 返回空列表', () async {
      final llm = _StubLlmService(
        responseContent: '{"consolidated":[]}',
      );
      final consolidator = MemoryConsolidator(llmService: llm);

      final result = await consolidator.consolidate(
        memories: [buildMemory(memoryId: 'm1', turnNumber: 1)],
        namingConfig: namingConfig,
        consolidationPrompt: prompt,
      );

      expect(result, isEmpty);
    });

    test('5. LLM 抛异常 → 返回空列表（降级）', () async {
      final llm = _StubLlmService(throwException: true);
      final consolidator = MemoryConsolidator(llmService: llm);

      final result = await consolidator.consolidate(
        memories: [buildMemory(memoryId: 'm1', turnNumber: 1)],
        namingConfig: namingConfig,
        consolidationPrompt: prompt,
      );

      expect(result, isEmpty);
    });

    test('6. LLM 超时 → 返回空列表（降级）', () async {
      // 直接抛 TimeoutException 模拟 .timeout() 触发的超时，
      // 避免真实等待 30 秒（consolidator 内部 30s timeout 会被 catch）
      final llm = _StubLlmService(throwTimeout: true);
      final consolidator = MemoryConsolidator(llmService: llm);

      final result = await consolidator.consolidate(
        memories: [buildMemory(memoryId: 'm1', turnNumber: 1)],
        namingConfig: namingConfig,
        consolidationPrompt: prompt,
      );

      expect(result, isEmpty);
    });

    test('7. LLM 返回非法 JSON → 返回空列表', () async {
      final llm = _StubLlmService(
        responseContent: '这不是 JSON',
      );
      final consolidator = MemoryConsolidator(llmService: llm);

      final result = await consolidator.consolidate(
        memories: [buildMemory(memoryId: 'm1', turnNumber: 1)],
        namingConfig: namingConfig,
        consolidationPrompt: prompt,
      );

      expect(result, isEmpty);
    });

    test('8. importance 字段为字符串 "4" → 正确解析为 int', () async {
      final llm = _StubLlmService(
        responseContent: '{"consolidated":['
            '{"summary":"节点","tags":["t"],"importance":"4"}'
            ']}',
      );
      final consolidator = MemoryConsolidator(llmService: llm);

      final result = await consolidator.consolidate(
        memories: [buildMemory(memoryId: 'm1', turnNumber: 1)],
        namingConfig: namingConfig,
        consolidationPrompt: prompt,
      );

      expect(result, hasLength(1));
      expect(result[0].importance, 4);
    });

    test('9. importance 越界（0 或 6）→ 该条目被跳过', () async {
      final llm = _StubLlmService(
        responseContent: '{"consolidated":['
            '{"summary":"低边界","tags":[],"importance":0},'
            '{"summary":"高边界","tags":[],"importance":6},'
            '{"summary":"合法","tags":[],"importance":3}'
            ']}',
      );
      final consolidator = MemoryConsolidator(llmService: llm);

      final result = await consolidator.consolidate(
        memories: [buildMemory(memoryId: 'm1', turnNumber: 1)],
        namingConfig: namingConfig,
        consolidationPrompt: prompt,
      );

      expect(result, hasLength(1));
      expect(result[0].summary, '合法');
    });

    test('10. summary 为空字符串 → 该条目被跳过', () async {
      final llm = _StubLlmService(
        responseContent: '{"consolidated":['
            '{"summary":"","tags":[],"importance":3},'
            '{"summary":"有效节点","tags":[],"importance":3}'
            ']}',
      );
      final consolidator = MemoryConsolidator(llmService: llm);

      final result = await consolidator.consolidate(
        memories: [buildMemory(memoryId: 'm1', turnNumber: 1)],
        namingConfig: namingConfig,
        consolidationPrompt: prompt,
      );

      expect(result, hasLength(1));
      expect(result[0].summary, '有效节点');
    });

    test('11. tags 字段为 null → 解析为空数组', () async {
      final llm = _StubLlmService(
        responseContent: '{"consolidated":['
            '{"summary":"无标签节点","tags":null,"importance":3}'
            ']}',
      );
      final consolidator = MemoryConsolidator(llmService: llm);

      final result = await consolidator.consolidate(
        memories: [buildMemory(memoryId: 'm1', turnNumber: 1)],
        namingConfig: namingConfig,
        consolidationPrompt: prompt,
      );

      expect(result, hasLength(1));
      expect(result[0].tags, isEmpty);
    });

    test(
        '12. 请求参数验证：temperature=0.3 / maxTokens=1500 / responseFormat=jsonObject / stream=false',
        () async {
      final llm = _StubLlmService(
        responseContent: '{"consolidated":[]}',
      );
      final consolidator = MemoryConsolidator(llmService: llm);

      await consolidator.consolidate(
        memories: [buildMemory(memoryId: 'm1', turnNumber: 1)],
        namingConfig: namingConfig,
        consolidationPrompt: prompt,
      );

      expect(llm.lastRequest, isNotNull);
      expect(llm.lastRequest!.temperature, 0.3);
      expect(llm.lastRequest!.maxTokens, 1500);
      expect(llm.lastRequest!.stream, isFalse);
      expect(
        llm.lastRequest!.responseFormat,
        isA<LlmResponseFormatJsonObject>(),
      );
      expect(llm.lastRequest!.baseUrl, namingConfig.baseUrl);
      expect(llm.lastRequest!.apiKey, namingConfig.apiKey);
      expect(llm.lastRequest!.modelId, namingConfig.modelId);
    });

    test('13. 请求参数验证：messages 包含 system + user 两条', () async {
      final llm = _StubLlmService(
        responseContent: '{"consolidated":[]}',
      );
      final consolidator = MemoryConsolidator(llmService: llm);

      await consolidator.consolidate(
        memories: [
          buildMemory(memoryId: 'm1', turnNumber: 3, summary: '事件A'),
          buildMemory(memoryId: 'm2', turnNumber: 5, summary: '事件B'),
        ],
        namingConfig: namingConfig,
        consolidationPrompt: '我的合并提示词',
      );

      final messages = llm.lastRequest!.messages;
      expect(messages, hasLength(2));
      expect(messages[0]['role'], 'system');
      expect(messages[0]['content'], '我的合并提示词');
      expect(messages[1]['role'], 'user');
      // user content 应包含两条记忆的轮次和摘要
      final userContent = messages[1]['content'] as String;
      expect(userContent, contains('轮次3'));
      expect(userContent, contains('事件A'));
      expect(userContent, contains('轮次5'));
      expect(userContent, contains('事件B'));
    });

    test('14. LLM 返回非对象 JSON（数组）→ 返回空列表', () async {
      final llm = _StubLlmService(
        responseContent: '[{"summary":"x","importance":3}]',
      );
      final consolidator = MemoryConsolidator(llmService: llm);

      final result = await consolidator.consolidate(
        memories: [buildMemory(memoryId: 'm1', turnNumber: 1)],
        namingConfig: namingConfig,
        consolidationPrompt: prompt,
      );

      expect(result, isEmpty);
    });

    test('15. consolidated 字段非 List（对象）→ 返回空列表', () async {
      final llm = _StubLlmService(
        responseContent: '{"consolidated":{"summary":"x","importance":3}}',
      );
      final consolidator = MemoryConsolidator(llmService: llm);

      final result = await consolidator.consolidate(
        memories: [buildMemory(memoryId: 'm1', turnNumber: 1)],
        namingConfig: namingConfig,
        consolidationPrompt: prompt,
      );

      expect(result, isEmpty);
    });

    test('16. 温度统一键：普通模型 0.3，禁发名单模型 null', () async {
      final llm = _StubLlmService(
        responseContent: '{"consolidated":[{"summary":"x","importance":3}]}',
      );
      final consolidator = MemoryConsolidator(llmService: llm);

      await consolidator.consolidate(
        memories: [buildMemory(memoryId: 'm1', turnNumber: 1)],
        namingConfig: namingConfig,
        consolidationPrompt: prompt,
      );
      expect(llm.lastRequest!.temperature, 0.3);

      const kimiNaming = NamingConfig(
        baseUrl: 'https://api.example.com',
        apiKey: 'sk-test',
        modelId: 'kimi-k2.6',
      );
      await consolidator.consolidate(
        memories: [buildMemory(memoryId: 'm2', turnNumber: 2)],
        namingConfig: kimiNaming,
        consolidationPrompt: prompt,
      );
      expect(llm.lastRequest!.temperature, isNull);
    });
  });
}

/// LlmService stub：记录调用参数，按预设返回响应。
class _StubLlmService implements LlmService {
  _StubLlmService({
    this.responseContent = '',
    this.throwException = false,
    this.throwTimeout = false,
  });

  final String responseContent;
  final bool throwException;
  final bool throwTimeout;

  int chatCalls = 0;
  LlmRequest? lastRequest;

  @override
  Future<LlmResponse> chat(LlmRequest request) async {
    chatCalls++;
    lastRequest = request;
    if (throwException) {
      throw Exception('LLM 调用失败');
    }
    if (throwTimeout) {
      throw TimeoutException('LLM 超时');
    }
    return LlmResponse(content: responseContent);
  }

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) {
    throw UnimplementedError('streamChat not used in consolidator tests');
  }
}
