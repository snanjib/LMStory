import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/network/http_client.dart' as lm;
import 'package:lmstory/core/network/llm_adapters/anthropic_compat_options.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/chat/data/datasources/llm_remote_datasource.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/intermediate/domain/services/intermediate_context_builder.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

/// 故事固定 system 前缀的最终出站回归。
///
/// 走真实 `LlmRemoteDataSource` 与真实协议适配器，止于记录 body 的本地
/// HTTP 桩；全部为合成资料，不访问模型服务。
class _RecordingHttpClient extends lm.HttpClient {
  final List<String> bodies = [];

  @override
  Stream<String> streamPost(
    String url,
    Map<String, String> headers, {
    String? body,
    Encoding encoding = utf8,
    lm.CancellationToken? cancelToken,
    Duration? connectTimeout,
    Duration? readTimeout,
    Duration? responseStartTimeout,
  }) {
    bodies.add(body ?? '');
    return const Stream<String>.empty();
  }
}

class _LocalCounter extends TokenCounter {
  @override
  Future<int> countTokens(String text) async => text.length;

  @override
  Future<List<int>> countTokensForEach(List<String> texts) async =>
      texts.map((s) => s.length).toList();

  @override
  Future<int> countTokensForMessages(List<String> texts) async =>
      texts.fold<int>(0, (n, s) => n + s.length);
}

ChatMessage _historyMessage(String id, String role, String content) =>
    ChatMessage(
      messageId: id,
      sessionId: 'synthetic',
      role: role,
      content: content,
      createdAt: DateTime(2026),
    );

ScoredMemory _microMemory(String what, int turn, {String? narrativeTime}) =>
    ScoredMemory(
      memory: ExperientialMemory(
        memoryId: 'mem-$turn',
        sessionId: 'synthetic',
        importance: 3,
        tags: const ['synthetic'],
        turnNumber: turn,
        createdAt: DateTime(2026),
        what: what,
        when: '合成时刻',
        who: '合成角色',
        narrativeTime: narrativeTime,
      ),
      fts5Score: 0.5,
      vectorScore: 0.5,
      temporalScore: 0,
      finalScore: 0.6,
    );

ScoredMemory _macroMemory(String summary) => ScoredMemory(
      memory: ExperientialMemory(
        memoryId: 'macro-1',
        sessionId: 'synthetic',
        importance: 4,
        tags: const ['synthetic'],
        turnNumber: 1,
        createdAt: DateTime(2026),
        summary: summary,
        memoryLevel: MemoryLevel.macro,
      ),
      fts5Score: 0.4,
      vectorScore: 0.5,
      temporalScore: 0,
      finalScore: 0.5,
    );

Future<Map<String, dynamic>> _captureBody(LlmRequest request) async {
  final client = _RecordingHttpClient();
  final dataSource = LlmRemoteDataSource(
    httpClient: client,
    adapterFactory: LlmAdapterFactory(),
  );
  try {
    await dataSource.streamChat(request).drain<void>();
  } catch (_) {
    // 空 SSE 流以 EMPTY_RESPONSE 收尾；body 已在发请求前捕获。
  }
  expect(client.bodies, hasLength(1));
  return jsonDecode(client.bodies.single) as Map<String, dynamic>;
}

LlmRequest _storyRequest({
  required LlmProtocol protocol,
  required String baseUrl,
  required String modelId,
  required List<Map<String, String>> messages,
  int? stableSystemPrefixCount,
  Map<String, dynamic>? providerOptions,
  List<ToolDefinition>? tools,
}) =>
    LlmRequest(
      baseUrl: baseUrl,
      apiKey: 'synthetic-key',
      modelId: modelId,
      messages: messages.map(Map<String, dynamic>.from).toList(),
      temperature: 0.8,
      topP: 1,
      maxTokens: 2000,
      modelMaxOutputTokens: 8192,
      presencePenalty: 0.1,
      frequencyPenalty: 0.1,
      protocol: protocol,
      providerOptions: providerOptions,
      tools: tools,
      toolChoice: tools == null ? null : ToolChoice.auto,
      includeUsage: true,
      stableSystemPrefixCount: stableSystemPrefixCount,
    );

List<Map<String, dynamic>> _systemBlocks(Map<String, dynamic> body) =>
    (body['system'] as List).cast<Map<String, dynamic>>();

int _markerCount(Map<String, dynamic> body) =>
    jsonEncode(body).split('cache_control').length - 1;

// 线上相邻 text 块直接首尾相接，不额外补分隔符。
String _joinedBlockText(List<Map<String, dynamic>> blocks) =>
    blocks.map((block) => block['text'] as String).join();

String _joinedSourceSystem(List<Map<String, String>> messages) => messages
    .where((message) => message['role'] == 'system')
    .map((message) => message['content'] ?? '')
    .where((text) => text.isNotEmpty)
    .join('\n\n');

String _contentText(Object? content) {
  if (content is String) return content;
  if (content is List) {
    final buffer = StringBuffer();
    for (final part in content) {
      if (part is Map<String, dynamic> && part['text'] is String) {
        buffer.write(part['text']);
      }
    }
    return buffer.toString();
  }
  return '';
}

String _filler(int chars) {
  const unit = '合成历史段落用于测试缓存前缀结构，不含任何真实故事内容。';
  final buffer = StringBuffer();
  while (buffer.length < chars) {
    buffer.write(unit);
  }
  return buffer.toString().substring(0, chars);
}

void main() {
  final builder = IntermediateContextBuilder(tokenCounter: _LocalCounter());
  const prompts = PromptsConfig();
  const anthropicCapabilitiesOn = {
    kAnthropicCapabilitiesOption: {'stable_system_cache': true},
  };
  const anthropicCapabilitiesOff = {
    kAnthropicCapabilitiesOption: {'stable_system_cache': false},
  };

  final history = [
    _historyMessage('u1', 'user', 'HISTORY_USER_1 ${_filler(300)}'),
    _historyMessage('a1', 'assistant', 'HISTORY_ASSISTANT_1 ${_filler(500)}'),
    _historyMessage('u2', 'user', 'HISTORY_USER_2 ${_filler(300)}'),
    _historyMessage('a2', 'assistant', 'HISTORY_ASSISTANT_2 ${_filler(500)}'),
  ];
  final memories = [
    _macroMemory('MACRO_SUMMARY_TURN_1 ${_filler(200)}'),
    _microMemory('MICRO_A ${_filler(150)}', 1),
  ];
  final summary = 'COMPACTION_SUMMARY_TURN_2 ${_filler(400)}';
  final factA = '【世界设定】\nFACT_A 世界设定版本甲。 ${_filler(600)}';
  final factB = '【世界设定】\nFACT_B 世界设定版本乙。 ${_filler(600)}';

  Future<IntermediatePromptAssembly> generate({
    String factBlock = '',
    List<ScoredMemory> retrievedMemories = const [],
    String? compactionSummary,
  }) =>
      builder.buildGeneratePromptAssembly(
        userInput: 'CURRENT_INPUT_TURN_3 ${_filler(100)}',
        history: history,
        sessionSystemPrompt: 'ROLE_RULES ${_filler(400)}',
        contextWindow: 200000,
        maxTokens: 2000,
        prompts: prompts,
        retrievedMemories: retrievedMemories,
        factBlock: factBlock,
        currentTurnNumber: 3,
        compactionSummary: compactionSummary,
        retrievalRatio: 0.15,
      );

  Future<IntermediatePromptAssembly> review({
    String factBlock = '',
    List<ScoredMemory> retrievedMemories = const [],
  }) =>
      builder.buildReviewPromptAssembly(
        userInput: 'CURRENT_INPUT_TURN_3 ${_filler(100)}',
        generated: 'GENERATED_TURN_3 ${_filler(1200)}',
        retrievedMemories: retrievedMemories,
        sessionSystemPrompt: 'ROLE_RULES ${_filler(400)}',
        contextWindow: 200000,
        maxTokens: 2000,
        currentTurnNumber: 3,
        prompts: prompts,
        factBlock: factBlock,
        retrievalRatio: 0.15,
      );

  group('Anthropic 官方端点最终 body', () {
    test('生成：稳定段首末标记、动态资料不标、文本无损、总数≤4', () async {
      final assembly = await generate(
        factBlock: factA,
        retrievedMemories: memories,
        compactionSummary: summary,
      );
      final request = _storyRequest(
        protocol: LlmProtocol.anthropic,
        baseUrl: 'https://api.anthropic.com',
        modelId: 'claude-sonnet-4-6',
        messages: assembly.messages,
        stableSystemPrefixCount: assembly.stableSystemPrefixCount,
      );
      final body = await _captureBody(request);

      expect(assembly.stableSystemPrefixCount, 2);
      final blocks = _systemBlocks(body);
      expect(blocks, hasLength(4));
      expect(blocks[0]['cache_control'], {'type': 'ephemeral'});
      expect(blocks[1]['cache_control'], {'type': 'ephemeral'});
      expect(blocks[2].containsKey('cache_control'), isFalse);
      expect(blocks[3].containsKey('cache_control'), isFalse);
      expect(_joinedBlockText(blocks), _joinedSourceSystem(assembly.messages));
      expect(_markerCount(body), lessThanOrEqualTo(4));

      final wireMessages =
          (body['messages'] as List).cast<Map<String, dynamic>>();
      final sourceNonSystem = assembly.messages
          .where((message) => message['role'] != 'system')
          .toList();
      expect(wireMessages, hasLength(sourceNonSystem.length));
      for (var i = 0; i < wireMessages.length; i++) {
        expect(wireMessages[i]['role'], sourceNonSystem[i]['role']);
        expect(
          _contentText(wireMessages[i]['content']),
          sourceNonSystem[i]['content'],
        );
      }
      expect(jsonEncode(body), isNot(contains('stable_system_cache')));
      expect(jsonEncode(body), isNot(contains('anthropic_capabilities')));
    });

    test('生成无摘要：只有角色提示词属于稳定段', () async {
      final assembly = await generate(
        factBlock: factA,
        retrievedMemories: memories,
      );
      final body = await _captureBody(
        _storyRequest(
          protocol: LlmProtocol.anthropic,
          baseUrl: 'https://api.anthropic.com',
          modelId: 'claude-sonnet-4-6',
          messages: assembly.messages,
          stableSystemPrefixCount: assembly.stableSystemPrefixCount,
        ),
      );

      expect(assembly.stableSystemPrefixCount, 1);
      final blocks = _systemBlocks(body);
      expect(blocks, hasLength(3));
      expect(blocks[0]['cache_control'], {'type': 'ephemeral'});
      expect(blocks[1].containsKey('cache_control'), isFalse);
      expect(blocks[2].containsKey('cache_control'), isFalse);
      expect(_joinedBlockText(blocks), _joinedSourceSystem(assembly.messages));
    });

    test('动态资料变化不改前两个稳定块', () async {
      final base = await generate(
        factBlock: factA,
        retrievedMemories: memories,
        compactionSummary: summary,
      );
      final changed = await generate(
        factBlock: factB,
        retrievedMemories: memories,
        compactionSummary: summary,
      );
      final baseBody = await _captureBody(
        _storyRequest(
          protocol: LlmProtocol.anthropic,
          baseUrl: 'https://api.anthropic.com',
          modelId: 'claude-sonnet-4-6',
          messages: base.messages,
          stableSystemPrefixCount: base.stableSystemPrefixCount,
        ),
      );
      final changedBody = await _captureBody(
        _storyRequest(
          protocol: LlmProtocol.anthropic,
          baseUrl: 'https://api.anthropic.com',
          modelId: 'claude-sonnet-4-6',
          messages: changed.messages,
          stableSystemPrefixCount: changed.stableSystemPrefixCount,
        ),
      );

      final baseBlocks = _systemBlocks(baseBody);
      final changedBlocks = _systemBlocks(changedBody);
      expect(jsonEncode(baseBlocks[0]), jsonEncode(changedBlocks[0]));
      expect(jsonEncode(baseBlocks[1]), jsonEncode(changedBlocks[1]));
      expect(changedBlocks[2]['text'], isNot(baseBlocks[2]['text']));
    });

    test('空角色 + 摘要：过滤后稳定位落在摘要，动态资料不被误标', () async {
      final assembly = await builder.buildGeneratePromptAssembly(
        userInput: 'CURRENT_INPUT_TURN_3 ${_filler(100)}',
        history: history,
        sessionSystemPrompt: null,
        contextWindow: 200000,
        maxTokens: 2000,
        prompts: const PromptsConfig(defaultRolePrompt: ''),
        retrievedMemories: memories,
        factBlock: factA,
        currentTurnNumber: 3,
        compactionSummary: summary,
        retrievalRatio: 0.15,
      );
      expect(assembly.stableSystemPrefixCount, 1);

      final body = await _captureBody(
        _storyRequest(
          protocol: LlmProtocol.anthropic,
          baseUrl: 'https://api.anthropic.com',
          modelId: 'claude-sonnet-4-6',
          messages: assembly.messages,
          stableSystemPrefixCount: assembly.stableSystemPrefixCount,
        ),
      );

      final blocks = _systemBlocks(body);
      expect(blocks, hasLength(3));
      expect(blocks[0]['text'], summary);
      expect(blocks[0]['cache_control'], {'type': 'ephemeral'});
      expect(blocks[1].containsKey('cache_control'), isFalse);
      expect(blocks[2].containsKey('cache_control'), isFalse);
      expect(_joinedBlockText(blocks), _joinedSourceSystem(assembly.messages));
    });

    test('审查：角色与审查规则两块标记，动态资料不标', () async {
      final assembly = await review(
        factBlock: factA,
        retrievedMemories: memories,
      );
      final body = await _captureBody(
        _storyRequest(
          protocol: LlmProtocol.anthropic,
          baseUrl: 'https://api.anthropic.com',
          modelId: 'claude-haiku-4-5',
          messages: assembly.messages,
          stableSystemPrefixCount: assembly.stableSystemPrefixCount,
        ),
      );

      expect(assembly.stableSystemPrefixCount, 2);
      final blocks = _systemBlocks(body);
      expect(blocks, hasLength(4));
      expect(blocks[0]['cache_control'], {'type': 'ephemeral'});
      expect(blocks[1]['cache_control'], {'type': 'ephemeral'});
      expect(blocks[2].containsKey('cache_control'), isFalse);
      expect(blocks[3].containsKey('cache_control'), isFalse);
      expect(_markerCount(body), 2);
      expect(_joinedBlockText(blocks), _joinedSourceSystem(assembly.messages));
      final wireMessages =
          (body['messages'] as List).cast<Map<String, dynamic>>();
      expect(wireMessages, hasLength(1));
      expect(wireMessages.single['content'], contains('GENERATED_TURN_3'));
    });
  });

  group('Anthropic 第三方端点能力开关', () {
    test('未声明能力：保持旧字符串 system', () async {
      final assembly = await generate(
        factBlock: factA,
        retrievedMemories: memories,
        compactionSummary: summary,
      );
      final body = await _captureBody(
        _storyRequest(
          protocol: LlmProtocol.anthropic,
          baseUrl: 'https://relay.example.com/v1',
          modelId: 'relay-claude',
          messages: assembly.messages,
          stableSystemPrefixCount: assembly.stableSystemPrefixCount,
        ),
      );
      expect(body['system'], isA<String>());
      final baseline = await _captureBody(
        _storyRequest(
          protocol: LlmProtocol.anthropic,
          baseUrl: 'https://relay.example.com/v1',
          modelId: 'relay-claude',
          messages: assembly.messages,
        ),
      );
      expect(jsonEncode(body), jsonEncode(baseline));
    });

    test('显式 true：按稳定段分块并标记', () async {
      final assembly = await generate(
        factBlock: factA,
        retrievedMemories: memories,
        compactionSummary: summary,
      );
      final body = await _captureBody(
        _storyRequest(
          protocol: LlmProtocol.anthropic,
          baseUrl: 'https://relay.example.com/v1',
          modelId: 'relay-claude',
          messages: assembly.messages,
          stableSystemPrefixCount: assembly.stableSystemPrefixCount,
          providerOptions: anthropicCapabilitiesOn,
        ),
      );
      final blocks = _systemBlocks(body);
      expect(blocks, hasLength(4));
      expect(blocks[0]['cache_control'], {'type': 'ephemeral'});
      expect(blocks[1]['cache_control'], {'type': 'ephemeral'});
      expect(_joinedBlockText(blocks), _joinedSourceSystem(assembly.messages));
    });

    test('显式 false：即使官方端点也回到旧字符串', () async {
      final assembly = await generate(
        factBlock: factA,
        retrievedMemories: memories,
        compactionSummary: summary,
      );
      final body = await _captureBody(
        _storyRequest(
          protocol: LlmProtocol.anthropic,
          baseUrl: 'https://api.anthropic.com',
          modelId: 'claude-sonnet-4-6',
          messages: assembly.messages,
          stableSystemPrefixCount: assembly.stableSystemPrefixCount,
          providerOptions: anthropicCapabilitiesOff,
        ),
      );
      expect(body['system'], isA<String>());
      final baseline = await _captureBody(
        _storyRequest(
          protocol: LlmProtocol.anthropic,
          baseUrl: 'https://api.anthropic.com',
          modelId: 'claude-sonnet-4-6',
          messages: assembly.messages,
        ),
      );
      expect(jsonEncode(body), jsonEncode(baseline));
    });
  });

  group('其他协议与带工具请求不受本批影响', () {
    final protocolCases =
        <({String id, LlmProtocol protocol, String baseUrl, String modelId})>[
      (
        id: 'openai-chat',
        protocol: LlmProtocol.openaiCompatible,
        baseUrl: 'https://api.openai.com/v1',
        modelId: 'gpt-4.1-mini',
      ),
      (
        id: 'deepseek-chat',
        protocol: LlmProtocol.openaiCompatible,
        baseUrl: 'https://api.deepseek.com',
        modelId: 'deepseek-chat',
      ),
      (
        id: 'openai-responses',
        protocol: LlmProtocol.openaiResponses,
        baseUrl: 'https://api.openai.com/v1',
        modelId: 'gpt-5-mini',
      ),
      (
        id: 'gemini',
        protocol: LlmProtocol.geminiNative,
        baseUrl: 'https://generativelanguage.googleapis.com',
        modelId: 'gemini-3.6-flash',
      ),
    ];

    test('四个协议的最终 body 与不传元数据时完全一致', () async {
      final assembly = await generate(
        factBlock: factA,
        retrievedMemories: memories,
        compactionSummary: summary,
      );
      for (final protocolCase in protocolCases) {
        final withoutMetadata = await _captureBody(
          _storyRequest(
            protocol: protocolCase.protocol,
            baseUrl: protocolCase.baseUrl,
            modelId: protocolCase.modelId,
            messages: assembly.messages,
          ),
        );
        final withMetadata = await _captureBody(
          _storyRequest(
            protocol: protocolCase.protocol,
            baseUrl: protocolCase.baseUrl,
            modelId: protocolCase.modelId,
            messages: assembly.messages,
            stableSystemPrefixCount: assembly.stableSystemPrefixCount,
          ),
        );
        expect(
          jsonEncode(withMetadata),
          jsonEncode(withoutMetadata),
          reason: '${protocolCase.id} 不应消费稳定前缀元数据',
        );
      }
    });

    test('Anthropic 带工具请求（导演路径）保持旧 body', () async {
      final assembly = await generate(
        factBlock: factA,
        retrievedMemories: memories,
        compactionSummary: summary,
      );
      const tools = [
        ToolDefinition(
          name: 'search_story',
          description: 'search',
          parameters: {'type': 'object'},
        ),
      ];
      final withoutMetadata = await _captureBody(
        _storyRequest(
          protocol: LlmProtocol.anthropic,
          baseUrl: 'https://api.anthropic.com',
          modelId: 'claude-sonnet-4-6',
          messages: assembly.messages,
          tools: tools,
        ),
      );
      final withMetadata = await _captureBody(
        _storyRequest(
          protocol: LlmProtocol.anthropic,
          baseUrl: 'https://api.anthropic.com',
          modelId: 'claude-sonnet-4-6',
          messages: assembly.messages,
          tools: tools,
          stableSystemPrefixCount: assembly.stableSystemPrefixCount,
        ),
      );
      expect(jsonEncode(withMetadata), jsonEncode(withoutMetadata));
    });
  });
}
