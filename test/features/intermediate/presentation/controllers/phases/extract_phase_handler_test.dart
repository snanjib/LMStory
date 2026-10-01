import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/config/intermediate_prompts_v2.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session_settings.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/intermediate/presentation/controllers/phases/extract_phase_handler.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_context.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_runtime_config.dart';
import 'package:lmstory/features/story_runtime/presentation/controllers/stream_runner.dart';

/// ExtractPhaseHandler 单元测试（Phase 6 Step 6.2 新增）
///
/// 覆盖降级链：
/// - 工具调用成功 → 解析 arguments → ClassifiedKeywords
/// - 工具调用空关键词 → 降级 JSON 模式
/// - 工具调用未触发 → fallbackText 解析
/// - JSON 模式成功 / 失败 / 抛 ExtractFailedException
void main() {
  late _FakeLlmService llmService;
  late StreamRunner streamRunner;
  late ExtractPhaseHandler handler;

  setUp(() {
    llmService = _FakeLlmService(const []);
    streamRunner = StreamRunner(llmService: llmService);
    handler = ExtractPhaseHandler(
      streamRunner: streamRunner,
      logger: const Logger('test'),
    );
  });

  group('ExtractPhaseHandler - 消息结构（2026-08-23 回滚后）', () {
    test('末条 user 消息带相邻任务前缀包装（防正文续写），摘要注入第 2 条', () async {
      llmService.events = const [
        LlmTextDelta(
          '{"characters":["李逍遥"],"items":[],"locations":[],"actions":[],"plots":[]}',
        ),
        LlmStreamDone(),
      ];

      final ctx = _makeCtx(userInput: '用户原始输入')
        ..compactionSummary = '来公寓第九天：主角在阁楼发现旧日记。'
        ..history = <ChatMessage>[
          ChatMessage(
            messageId: 'u0',
            sessionId: 'test-session',
            role: 'user',
            content: '上一轮用户消息',
            createdAt: DateTime(2026),
          ),
          ChatMessage(
            messageId: 'a0',
            sessionId: 'test-session',
            role: 'assistant',
            content: '上一轮助手回复',
            createdAt: DateTime(2026),
          ),
        ];

      await handler.run(ctx: ctx, toolCallingEnabled: false);

      final messages = llmService.requests.single.messages;
      // [system(提示词)] + [system(摘要)] + 历史 + [user(任务包装+输入)]
      expect(messages[0]['role'], 'system');
      expect(messages[0]['content'], kExtractKeywordsToolPrompt);
      expect(messages[1]['role'], 'system');
      expect(messages[1]['content'], '来公寓第九天：主角在阁楼发现旧日记。');
      expect(messages[2]['role'], 'user');
      expect(messages[2]['content'], '上一轮用户消息');
      expect(messages[3]['role'], 'assistant');
      expect(messages.last['role'], 'user');
      // 任务标记必须紧贴输入内容（2026-08-22 曾改为远处的 system 说明，
      // 真机复现正文续写失败，2026-08-23 回滚为相邻包装）
      expect(
        messages.last['content'],
        '【提取关键词任务 - 从以下用户消息提取关键词，'
        ' 不是角色扮演对话续写】\n\n用户原始输入',
      );
    });
  });

  group('ExtractPhaseHandler.run - 工具调用模式', () {
    test('1. 工具调用成功 → 从 arguments 解析 5 类 ClassifiedKeywords', () async {
      // 5 类关键词（characters/items/locations/actions/plots）
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_keywords'),
        LlmToolCallArgs(
          'call_1',
          '{"characters":["李逍遥"],"items":["古碑"],"locations":["蜀山"],"actions":["斩妖"],"plots":["碑文显现"]}',
        ),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_keywords',
          arguments: {
            'characters': ['李逍遥'],
            'items': ['古碑'],
            'locations': ['蜀山'],
            'actions': ['斩妖'],
            'plots': ['碑文显现'],
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(userInput: '用户输入'),
        toolCallingEnabled: true,
      );

      // entityTerms = characters + items + locations
      expect(result.entityTerms, ['李逍遥', '古碑', '蜀山']);
      // eventTerms = actions + plots
      expect(result.eventTerms, ['斩妖', '碑文显现']);
      expect(result.isNotEmpty, isTrue);
    });

    test('2. 工具调用返回空关键词 → 直接返回空关键词（不降级 JSON 模式）', () async {
      // Phase 6 Step 6.4 修复：工具调用成功时信任 LLM 输出，即使空关键词
      // 也直接返回（LLM 的有意输出），不降级到 JSON 模式。
      // 这避免了空关键词场景下多余的 LLM 请求，同时与 compact 降级配合
      // （空关键词 → 跳过检索 → compact 触发 → 草稿即终稿）。
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_keywords'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_keywords',
          arguments: {
            'characters': <String>[],
            'items': <String>[],
            'locations': <String>[],
            'actions': <String>[],
            'plots': <String>[],
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(userInput: '用户输入'),
        toolCallingEnabled: true,
      );

      // 空关键词直接返回，不触发 JSON 模式降级（只调用 1 次 LLM）
      expect(result.entityTerms, isEmpty);
      expect(result.eventTerms, isEmpty);
      expect(llmService.callCount, 1);
    });

    test('3. 工具调用未触发 + fallbackText 是合法 JSON → 直接解析', () async {
      // LLM 不支持工具调用，输出纯 JSON 文本（5 类关键词）
      llmService.events = const [
        LlmTextDelta(
          '{"characters":["李逍遥"],"items":["古碑"],"locations":[],"actions":[],"plots":[]}',
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(userInput: '用户输入'),
        toolCallingEnabled: true,
      );

      // entityTerms = characters + items + locations
      expect(result.entityTerms, ['李逍遥', '古碑']);
      expect(result.eventTerms, isEmpty);
    });

    test('4. 工具调用未触发 + fallbackText 也空 → 降级 JSON 模式失败 → 抛异常', () async {
      // 第一轮：无任何输出（既无工具调用也无文本）
      // 第二轮：仍无输出 → ExtractFailedException
      llmService.events = const [
        LlmStreamDone(),
        LlmStreamDone(),
      ];

      expect(
        () => handler.run(
          ctx: _makeCtx(userInput: '用户输入'),
          toolCallingEnabled: true,
        ),
        throwsA(isA<ExtractFailedException>()),
      );
    });
  });

  group('ExtractPhaseHandler.run - JSON 模式', () {
    test('5. toolCallingEnabled=false → 直接 JSON 模式成功', () async {
      // 5 类关键词 JSON
      llmService.events = const [
        LlmTextDelta(
          '{"characters":["李逍遥"],"items":["古碑"],"locations":["蜀山"],"actions":["斩妖"],"plots":["碑文显现"]}',
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(userInput: '用户输入'),
        toolCallingEnabled: false,
      );

      expect(result.entityTerms, ['李逍遥', '古碑', '蜀山']);
      expect(result.eventTerms, ['斩妖', '碑文显现']);
    });

    test('6. JSON 模式 LLM 空输出 → 抛 ExtractFailedException', () async {
      llmService.events = const [LlmStreamDone()];

      expect(
        () => handler.run(
          ctx: _makeCtx(userInput: '用户输入'),
          toolCallingEnabled: false,
        ),
        throwsA(isA<ExtractFailedException>()),
      );
    });

    test('7. JSON 模式解析失败（非 JSON 文本） → 抛 ExtractFailedException', () async {
      llmService.events = const [
        LlmTextDelta('这不是 JSON，是普通文字'),
        LlmStreamDone(),
      ];

      expect(
        () => handler.run(
          ctx: _makeCtx(userInput: '用户输入'),
          toolCallingEnabled: false,
        ),
        throwsA(isA<ExtractFailedException>()),
      );
    });

    test('8. JSON 模式兼容旧数组格式 ["古碑"] → 全部归入 characters', () async {
      // parseKeywords 兼容旧格式：数组 → 全部归入 characters
      llmService.events = const [
        LlmTextDelta('["古碑","后山"]'),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(userInput: '用户输入'),
        toolCallingEnabled: false,
      );

      // 旧数组格式归入 characters，entityTerms = characters + items + locations
      expect(result.entityTerms, ['古碑', '后山']);
      expect(result.eventTerms, isEmpty);
    });

    test('9. JSON 模式 markdown 包裹 → 解析成功', () async {
      // _preprocessJson 剥离 markdown 代码块（5 类关键词）
      llmService.events = const [
        LlmTextDelta(
          '```json\n{"characters":["李逍遥"],"items":["古碑"],"locations":[],"actions":[],"plots":[]}\n```',
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(userInput: '用户输入'),
        toolCallingEnabled: false,
      );

      expect(result.entityTerms, ['李逍遥', '古碑']);
    });
  });

  group('ExtractPhaseHandler.run - 工具调用 arguments 容错', () {
    test('10. arguments 中 characters 是逗号字符串 → 切分', () async {
      // _coerceStringList 容错：String 按逗号切分（characters 通道）
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_keywords'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_keywords',
          arguments: {
            'characters': '李逍遥,赵灵儿',
            'items': <String>[],
            'locations': <String>[],
            'actions': <String>[],
            'plots': ['碑文显现'],
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(userInput: '用户输入'),
        toolCallingEnabled: true,
      );

      // characters 切分后 = ['李逍遥', '赵灵儿']，entityTerms = characters + items + locations
      expect(result.entityTerms, ['李逍遥', '赵灵儿']);
      expect(result.eventTerms, ['碑文显现']);
    });

    test('11. arguments 中所有实体类缺失 → entityTerms 为空但 eventTerms 有值', () async {
      // characters/items/locations 全缺失，但 actions/plots 有值
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_keywords'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_keywords',
          arguments: {
            'actions': ['斩妖'],
            'plots': ['碑文显现'],
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(userInput: '用户输入'),
        toolCallingEnabled: true,
      );

      // 3 类实体全缺失 → entityTerms 空
      expect(result.entityTerms, isEmpty);
      // 但经历类有值 → eventTerms 非空
      expect(result.eventTerms, ['斩妖', '碑文显现']);
      // 整体非空
      expect(result.isNotEmpty, isTrue);
    });
  });
}

/// 构造最小可用的 RoundContext（extracting 前置，输入为 userInput + history）
RoundContext _makeCtx({required String userInput}) {
  return RoundContext(
    userInput: userInput,
    history: const <ChatMessage>[],
    settings: const ChatSessionSettings(
      modelId: 'test-model',
      presetId: 'preset-1',
      systemPrompt: '',
      temperature: 0.8,
      topP: 0.95,
      maxTokens: 2048,
      autoCompaction: true,
      compactionThreshold: 0.6,
      streamEnabled: true,
    ),
    generatingNamingConfig: const NamingConfig(
      baseUrl: 'https://api.example.com',
      apiKey: 'test-key',
      modelId: 'test-model',
    ),
    extractNamingConfig: const NamingConfig(
      baseUrl: 'https://api.example.com',
      apiKey: 'test-key',
      modelId: 'test-model',
    ),
    reviewingNamingConfig: const NamingConfig(
      baseUrl: 'https://api.example.com',
      apiKey: 'test-key',
      modelId: 'test-model',
    ),
    summarizeNamingConfig: const NamingConfig(
      baseUrl: 'https://api.example.com',
      apiKey: 'test-key',
      modelId: 'test-model',
    ),
    contextWindow: 32768,
    config: const IntermediateConfig().storyRuntime,
    embeddingConfig: null,
    turnNumber: 1,
    connectTimeout: const Duration(seconds: 15),
    readTimeout: const Duration(seconds: 30),
  );
}

/// 假 LlmService：按预设事件序列发出 LlmStreamEvent 流
///
/// 与 stream_runner_test 中的 _FakeLlmService 不同：本测试的 handler 会
/// 在降级路径中调用两次 streamChat（工具调用 + JSON 模式），所以 events
/// 列表支持跨调用顺序消费（用 index 游标追踪当前位置）。
class _FakeLlmService implements LlmService {
  _FakeLlmService(this.events);

  /// 事件序列（工具调用流和 JSON 模式流拼接在一起，按顺序消费）
  List<LlmStreamEvent> events;

  int _cursor = 0;

  /// streamChat 调用次数（验证是否触发 JSON 模式降级）
  int callCount = 0;

  /// 全部 streamChat 请求（断言消息结构用）
  final List<LlmRequest> requests = <LlmRequest>[];

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) {
    callCount++;
    requests.add(request);
    // 第一次调用：消费从 _cursor 到第一个 LlmStreamDone 之后
    // 后续调用（降级）：继续消费剩余事件
    final batch = <LlmStreamEvent>[];
    while (_cursor < events.length) {
      final e = events[_cursor];
      _cursor++;
      batch.add(e);
      if (e is LlmStreamDone) break;
    }
    return Stream<LlmStreamEvent>.fromIterable(batch);
  }

  @override
  Future<LlmResponse> chat(LlmRequest request) async {
    throw UnimplementedError('extract handler 测试不使用 chat');
  }
}
