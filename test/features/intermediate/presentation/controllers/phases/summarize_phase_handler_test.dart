import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session_settings.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/intermediate/presentation/controllers/phases/summarize_phase_handler.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_context.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_runtime_config.dart';
import 'package:lmstory/features/story_runtime/presentation/controllers/stream_runner.dart';

/// SummarizePhaseHandler 单元测试（Phase 6 Step 6.3 新增）
///
/// 覆盖降级链：
/// - 工具调用成功 → 解析 arguments → EventSummary
/// - 工具调用解析失败 → 降级 JSON 模式
/// - 工具调用未触发 → fallbackText 解析
/// - JSON 模式成功 / 失败 / 抛 SummarizeFailedException
/// - importance 容错（int/double/String/越界夹紧）
void main() {
  late _FakeLlmService llmService;
  late StreamRunner streamRunner;
  late SummarizePhaseHandler handler;

  setUp(() {
    llmService = _FakeLlmService(const []);
    streamRunner = StreamRunner(llmService: llmService);
    handler = SummarizePhaseHandler(
      streamRunner: streamRunner,
      logger: const Logger('test'),
    );
  });

  group('SummarizePhaseHandler.run - 工具调用模式', () {
    test('1. 工具调用成功 → 从 arguments 解析 EventSummary', () async {
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_event_summary'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_event_summary',
          arguments: {
            'summary': '勇者在后山发现古碑，碑文揭示身世',
            'tags': ['古碑', '身世'],
            'importance': 4,
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '勇者来到后山，看到了古碑...'),
        toolCallingEnabled: true,
      );

      expect(result.summary.summary, '勇者在后山发现古碑，碑文揭示身世');
      expect(result.summary.importance, 4);
      expect(result.summary.tags, ['古碑', '身世']);
      expect(result.summary.turnNumber, 1);
    });

    test('2. 工具调用 arguments 解析失败 → 降级 JSON 模式成功', () async {
      // arguments 缺 importance 字段 → 解析失败 → 触发降级
      // 第二次 LlmService 调用走 JSON 模式（fallbackText 输出 JSON）
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_event_summary'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_event_summary',
          arguments: {
            'summary': '只缺 importance',
            'tags': ['tag'],
          },
        ),
        LlmStreamDone(),
        // 第二次调用（JSON 模式降级）
        LlmTextDelta(
          '{"summary":"勇者发现古碑","tags":["古碑"],"importance":3}',
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复正文'),
        toolCallingEnabled: true,
      );

      expect(result.summary.summary, '勇者发现古碑');
      expect(result.summary.importance, 3);
      expect(result.summary.tags, ['古碑']);
    });

    test('3. 工具调用未触发 + fallbackText 是合法 JSON → 直接解析', () async {
      // LLM 不支持工具调用，输出纯 JSON 文本
      llmService.events = const [
        LlmTextDelta(
          '{"summary":"勇者发现古碑","tags":["古碑"],"importance":3}',
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.summary, '勇者发现古碑');
      expect(result.summary.importance, 3);
    });

    test('4. 工具调用未触发 + fallbackText 也空 → 降级 JSON 模式失败 → 抛异常', () async {
      // 第一轮：无任何输出（既无工具调用也无文本）
      // 第二轮：仍无输出 → SummarizeFailedException
      llmService.events = const [
        LlmStreamDone(),
        LlmStreamDone(),
      ];

      expect(
        () => handler.run(
          ctx: _makeCtx(replyText: '回复'),
          toolCallingEnabled: true,
        ),
        throwsA(isA<SummarizeFailedException>()),
      );
    });

    test('4b. 工具 schema 被供应商拒收（400 + additionalProperties）→ 降级 JSON 模式',
        () async {
      llmService.events = const [
        LlmStreamError(
          r'''Gemini stream interrupted: AppHttpException: SSE request failed with status 400 | Response: {"error":{"code":400,"message":"Invalid JSON payload received. Unknown name \"additionalProperties\" at 'tools.function_declarations[0].parameters': Cannot find field."}}''',
          code: 'BAD_REQUEST',
        ),
        LlmStreamDone(),
        LlmTextDelta(
          '{"what":"勇者发现古碑","tags":["古碑"],"importance":3}',
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复正文'),
        toolCallingEnabled: true,
      );

      expect(result.summary.what, '勇者发现古碑');
      expect(result.summary.importance, 3);
      // JSON 模式不产出 facts（与既有降级语义一致）
      expect(result.factsDeltas, isEmpty);
      expect(llmService.requests, hasLength(2));
      expect(llmService.requests[1].tools, isNull);
    });
  });

  group('SummarizePhaseHandler.run - JSON 模式', () {
    test('5. toolCallingEnabled=false → 直接 JSON 模式成功', () async {
      llmService.events = const [
        LlmTextDelta(
          '{"summary":"勇者发现古碑","tags":["古碑"],"importance":3}',
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: false,
      );

      expect(result.summary.summary, '勇者发现古碑');
      expect(result.summary.importance, 3);
      expect(result.summary.tags, ['古碑']);
    });

    test('6. JSON 模式 LLM 空输出 → 抛 SummarizeFailedException', () async {
      llmService.events = const [LlmStreamDone()];

      expect(
        () => handler.run(
          ctx: _makeCtx(replyText: '回复'),
          toolCallingEnabled: false,
        ),
        throwsA(isA<SummarizeFailedException>()),
      );
    });

    test('7. JSON 模式解析失败（summary 缺失） → 抛 SummarizeFailedException', () async {
      llmService.events = const [
        LlmTextDelta('{"tags":["古碑"],"importance":3}'),
        LlmStreamDone(),
      ];

      expect(
        () => handler.run(
          ctx: _makeCtx(replyText: '回复'),
          toolCallingEnabled: false,
        ),
        throwsA(isA<SummarizeFailedException>()),
      );
    });

    test('8. JSON 模式 importance 越界 → 夹紧到 [1,5]', () async {
      llmService.events = const [
        LlmTextDelta(
          '{"summary":"重要事件","tags":["tag"],"importance":10}',
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: false,
      );

      expect(result.summary.importance, 5);
    });

    test('9. JSON 模式 markdown 包裹 → 解析成功', () async {
      llmService.events = const [
        LlmTextDelta(
          '```json\n{"summary":"事件","tags":["t"],"importance":2}\n```',
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: false,
      );

      expect(result.summary.summary, '事件');
      expect(result.summary.importance, 2);
    });

    test('10. JSON 模式 turnNumber 由程序填充（非 LLM 输出）', () async {
      llmService.events = const [
        LlmTextDelta(
          '{"summary":"事件","tags":["t"],"importance":2}',
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复', turnNumber: 7),
        toolCallingEnabled: false,
      );

      expect(result.summary.turnNumber, 7);
    });
  });

  group('SummarizePhaseHandler.run - 工具调用 arguments 容错', () {
    test('11. importance 是字符串 "3" → 解析为 int 3', () async {
      // _coerceImportance 容错：String → int
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_event_summary'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_event_summary',
          arguments: {
            'summary': '事件摘要',
            'tags': ['tag'],
            'importance': '3',
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.importance, 3);
    });

    test('12. importance 是小数 3.5 → 取整为 3', () async {
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_event_summary'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_event_summary',
          arguments: {
            'summary': '事件摘要',
            'tags': ['tag'],
            'importance': 3.5,
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.importance, 3);
    });

    test('13. importance 越界（10）→ 夹紧到 5', () async {
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_event_summary'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_event_summary',
          arguments: {
            'summary': '事件摘要',
            'tags': ['tag'],
            'importance': 10,
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.importance, 5);
    });

    test('14. tags 是逗号字符串 → 切分', () async {
      // _coerceStringList 容错：String 按逗号切分
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_event_summary'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_event_summary',
          arguments: {
            'summary': '事件摘要',
            'tags': '古碑,身世',
            'importance': 3,
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.tags, ['古碑', '身世']);
    });

    test('15. summary 为空字符串 → 解析失败 → 降级 JSON 模式', () async {
      // summary 是空字符串 → _coerceNonEmptyString 返回 null → 解析失败
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_event_summary'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_event_summary',
          arguments: {
            'summary': '',
            'tags': ['tag'],
            'importance': 3,
          },
        ),
        LlmStreamDone(),
        // 第二次调用（JSON 模式降级）
        LlmTextDelta(
          '{"summary":"有效摘要","tags":["tag"],"importance":3}',
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.summary, '有效摘要');
    });

    // ==================== v0.2 Phase C 方案二：5W1E 工具调用参数测试 ====================

    test('16. 5W1E 完整字段工具调用 → 全部正确解析', () async {
      // 工具调用 arguments 包含所有 5W1E 字段
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_event_summary'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_event_summary',
          arguments: {
            'what': '勇者斩杀了巨龙',
            'when': '战斗结束时',
            'where': '火山口',
            'who': '勇者与巨龙',
            'significance': '获得了关键道具',
            'extra': '巨龙临死前留下一句预言',
            'summary': '勇者斩杀巨龙获得关键道具',
            'tags': ['战斗', '关键道具'],
            'importance': 4,
            'event_ended': false,
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '勇者来到火山口...'),
        toolCallingEnabled: true,
      );

      expect(result.summary.what, '勇者斩杀了巨龙');
      expect(result.summary.when, '战斗结束时');
      expect(result.summary.where, '火山口');
      expect(result.summary.who, '勇者与巨龙');
      expect(result.summary.significance, '获得了关键道具');
      expect(result.summary.extra, '巨龙临死前留下一句预言');
      // summary 字段始终保留原值
      expect(result.summary.summary, '勇者斩杀巨龙获得关键道具');
      expect(result.summary.importance, 4);
      expect(result.summary.tags, ['战斗', '关键道具']);
      expect(result.summary.eventEnded, isFalse);
    });

    test('17. what 缺失但 summary 存在 → 向后兼容（what = summary 反填）', () async {
      // 旧格式 LLM 工具调用：只传 summary，没传 what
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_event_summary'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_event_summary',
          arguments: {
            'summary': '勇者击败恶龙',
            'tags': ['战斗'],
            'importance': 3,
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.what, '勇者击败恶龙'); // 由 summary 反填
      expect(result.summary.summary, '勇者击败恶龙'); // summary 保留原值
    });

    test('18. what 和 summary 都缺失 → 解析失败 → 降级 JSON 模式', () async {
      // 必填字段 what 缺失，summary 也缺失 → 解析失败
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_event_summary'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_event_summary',
          arguments: {
            'tags': ['tag'],
            'importance': 3,
            // what 和 summary 都缺失
          },
        ),
        LlmStreamDone(),
        // 降级 JSON 模式
        LlmTextDelta(
          '{"what":"事件","importance":3,"tags":[]}',
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.what, '事件');
    });

    test('19. 5W1E 部分字段（仅 what + when + who）→ 其余为 null', () async {
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_event_summary'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_event_summary',
          arguments: {
            'what': '勇者与公主重逢',
            'when': '黄昏',
            'who': '勇者与公主',
            'importance': 4,
            'tags': ['重逢'],
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.what, '勇者与公主重逢');
      expect(result.summary.when, '黄昏');
      expect(result.summary.who, '勇者与公主');
      expect(result.summary.where, isNull);
      expect(result.summary.significance, isNull);
      expect(result.summary.extra, isNull);
      expect(result.summary.summary, isNull);
    });

    test('20. 5W1E 字段类型错误（int/array/object）→ 视为 null 不抛异常', () async {
      // _coerceNonEmptyString 仅接受 String 类型
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_event_summary'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_event_summary',
          arguments: {
            'what': '事件',
            'when': 123, // int → null
            'where': true, // bool → null
            'who': null, // null → null
            'significance': ['数组'], // List → null
            'extra': {'k': 'v'}, // Map → null
            'importance': 3,
            'tags': <String>[],
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.what, '事件');
      expect(result.summary.when, isNull);
      expect(result.summary.where, isNull);
      expect(result.summary.who, isNull);
      expect(result.summary.significance, isNull);
      expect(result.summary.extra, isNull);
    });

    test('21. event_ended 字段容错（bool/string/缺失）', () async {
      // 字符串 "true"
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_event_summary'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_event_summary',
          arguments: {
            'what': '事件',
            'importance': 3,
            'tags': <String>[],
            'event_ended': 'true',
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.eventEnded, isTrue);
    });

    test('22. what 类型错误但 summary 存在 → 仍能用 summary 反填', () async {
      // what=123（int）→ 视为缺失；summary 存在 → 反填 what
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_event_summary'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_event_summary',
          arguments: {
            'what': 123,
            'summary': '勇者击败恶龙',
            'importance': 3,
            'tags': <String>[],
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.what, '勇者击败恶龙');
      expect(result.summary.summary, '勇者击败恶龙');
    });
  });

  // ==================== DOC-11 §4.4 双工具并行调用测试（2026-07-20 新增）====================
  //
  // 覆盖 summarizing 阶段 LLM 同时/单独调用 extract_event_summary + extract_facts
  // 两个工具的各种组合，以及 _parseFactsSafely 的容错路径。
  // 另含修复 3 验证：extractFactsPrompt 已注入到 messages。
  group('SummarizePhaseHandler.run - DOC-11 §4.4 双工具并行调用', () {
    test('23. LLM 同时调用 summary + facts → 两个工具参数都解析', () async {
      llmService.events = const [
        LlmToolCallStart('call_summary', 'extract_event_summary'),
        LlmToolCallStart('call_facts', 'extract_facts'),
        LlmToolCallComplete(
          toolCallId: 'call_summary',
          name: 'extract_event_summary',
          arguments: {
            'what': '勇者救出公主',
            'importance': 4,
            'tags': ['救援'],
          },
        ),
        LlmToolCallComplete(
          toolCallId: 'call_facts',
          name: 'extract_facts',
          arguments: {
            'deltas': [
              {
                'action': 'create_entity',
                'entityType': 'character',
                'primaryName': '公主',
                'confidence': 5,
              },
            ],
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '勇者冲进塔楼...'),
        toolCallingEnabled: true,
      );

      expect(result.summary.what, '勇者救出公主');
      expect(result.summary.importance, 4);
      expect(result.factsDeltas, hasLength(1));
      expect(result.factsDeltas.first.action, FactAction.createEntity);
      expect(result.factsDeltas.first.primaryName, '公主');
      expect(result.factsDeltas.first.entityType, 'character');
      expect(result.factsDeltas.first.confidence, 5);
    });

    test('24. LLM 只调用 summary（不调用 facts）→ factsDeltas 为空', () async {
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_event_summary'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_event_summary',
          arguments: {
            'what': '事件',
            'importance': 3,
            'tags': <String>[],
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.what, '事件');
      expect(result.factsDeltas, isEmpty);
    });

    test('25. LLM 只调用 facts（不调用 summary）→ facts 解析，summary 降级 JSON', () async {
      // facts 工具被调用 → factsDeltas 解析成功
      // summary 工具未调用 → fallbackText 为空 → 降级 JSON 模式
      llmService.events = const [
        LlmToolCallStart('call_1', 'extract_facts'),
        LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_facts',
          arguments: {
            'deltas': [
              {
                'action': 'create_entity',
                'entityType': 'item',
                'primaryName': '玄铁剑',
                'confidence': 4,
              },
            ],
          },
        ),
        LlmStreamDone(),
        // 降级 JSON 模式（第二次 streamChat 调用）
        LlmTextDelta('{"what":"事件","importance":3,"tags":[]}'),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.what, '事件');
      expect(result.factsDeltas, hasLength(1));
      expect(result.factsDeltas.first.primaryName, '玄铁剑');
      expect(result.factsDeltas.first.entityType, 'item');
    });

    // ==================== DOC-11 §8.6 串行兜底机制测试（2026-07-26 新增）====================
    //
    // 验证兼容不支持 parallel_tool_calls 的模型（如 agnes-2.0-flash）：
    // 当首次并行调用只返回了 extract_event_summary 时，自动发起第二次请求
    // 单独调用 extract_facts，把两个工具的解析结果合并返回。

    test(
        '37. DOC-11 §8.6 串行兜底：LLM 只调用 summary → 自动补调 extract_facts → 返回完整 facts',
        () async {
      // 第一次调用：模型只调用 extract_event_summary（模拟 agnes-2.0-flash 不支持并行调用）
      // 第二次调用（兜底）：单独调用 extract_facts，返回 deltas 数组
      llmService.events = const [
        LlmToolCallStart('call_summary', 'extract_event_summary'),
        LlmToolCallComplete(
          toolCallId: 'call_summary',
          name: 'extract_event_summary',
          arguments: {
            'what': 'Lin Xia 在草原苏醒，结识旅法师 Elara',
            'importance': 4,
            'tags': ['穿越', '角色登场'],
            'narrativeTime': '苏醒于陌生草原之日',
          },
        ),
        LlmStreamDone(),
        // 串行兜底调用 extract_facts（第二次 streamChat 调用）
        LlmToolCallStart('call_facts', 'extract_facts'),
        LlmToolCallComplete(
          toolCallId: 'call_facts',
          name: 'extract_facts',
          arguments: {
            'deltas': [
              {
                'action': 'create_entity',
                'entityType': 'character',
                'primaryName': 'Lin Xia',
                'confidence': 5,
              },
              {
                'action': 'create_entity',
                'entityType': 'character',
                'primaryName': 'Elara',
                'confidence': 5,
              },
            ],
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复正文'),
        toolCallingEnabled: true,
      );

      // summary 正常返回
      expect(result.summary.what, 'Lin Xia 在草原苏醒，结识旅法师 Elara');
      expect(result.summary.importance, 4);
      expect(result.summary.tags, ['穿越', '角色登场']);
      expect(result.summary.narrativeTime, '苏醒于陌生草原之日');

      // facts 通过串行兜底成功解析（两个实体）
      expect(result.factsDeltas, hasLength(2));
      expect(result.factsDeltas[0].action, FactAction.createEntity);
      expect(result.factsDeltas[0].primaryName, 'Lin Xia');
      expect(result.factsDeltas[1].primaryName, 'Elara');

      // 验证触发了两次 LLM 调用（首次 + 兜底）
      expect(llmService.requests, hasLength(2));

      // 第二次请求只注入 extract_facts 一个工具
      final fallbackRequest = llmService.requests[1];
      expect(fallbackRequest.tools, hasLength(1));
      expect(fallbackRequest.tools!.first.name, 'extract_facts');
    });

    test('38. DOC-11 §8.6 串行兜底失败（如网络异常）→ facts 为空，summary 仍正常返回', () async {
      // 第一次调用：模型只调用 extract_event_summary
      // 第二次调用（兜底）：抛异常模拟网络错误（无 events 可消费）
      llmService.events = const [
        LlmToolCallStart('call_summary', 'extract_event_summary'),
        LlmToolCallComplete(
          toolCallId: 'call_summary',
          name: 'extract_event_summary',
          arguments: {
            'what': '事件',
            'importance': 3,
            'tags': <String>[],
          },
        ),
        LlmStreamDone(),
        // 兜底调用：模拟 LLM 没有输出任何内容（无 tool_call 也无 text）
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      // summary 仍然正常返回
      expect(result.summary.what, '事件');

      // facts 为空（兜底未拿到 extract_facts 调用）
      expect(result.factsDeltas, isEmpty);

      // 验证触发了两次 LLM 调用（首次 + 兜底）
      expect(llmService.requests, hasLength(2));
    });

    test('39. DOC-11 §8.6 LLM 同时调用两个工具 → 不触发串行兜底（支持并行的模型无额外开销）', () async {
      // 模型支持 parallel_tool_calls，一次调用同时返回两个工具
      llmService.events = const [
        LlmToolCallStart('call_summary', 'extract_event_summary'),
        LlmToolCallStart('call_facts', 'extract_facts'),
        LlmToolCallComplete(
          toolCallId: 'call_summary',
          name: 'extract_event_summary',
          arguments: {
            'what': '事件',
            'importance': 3,
            'tags': <String>[],
          },
        ),
        LlmToolCallComplete(
          toolCallId: 'call_facts',
          name: 'extract_facts',
          arguments: {
            'deltas': [
              {
                'action': 'create_entity',
                'entityType': 'character',
                'primaryName': '勇者',
                'confidence': 5,
              },
            ],
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      // summary 正常
      expect(result.summary.what, '事件');

      // facts 正常
      expect(result.factsDeltas, hasLength(1));
      expect(result.factsDeltas.first.primaryName, '勇者');

      // 验证只触发了一次 LLM 调用（未触发兜底）
      expect(llmService.requests, hasLength(1));
    });

    test('26. LLM 调用 facts 但 deltas 字段非数组 → factsDeltas 为空，不抛异常', () async {
      // _parseFactsSafely 容错：deltas 字段类型错误 → 记日志返回空列表
      llmService.events = const [
        LlmToolCallStart('call_summary', 'extract_event_summary'),
        LlmToolCallStart('call_facts', 'extract_facts'),
        LlmToolCallComplete(
          toolCallId: 'call_summary',
          name: 'extract_event_summary',
          arguments: {
            'what': '事件',
            'importance': 3,
            'tags': <String>[],
          },
        ),
        LlmToolCallComplete(
          toolCallId: 'call_facts',
          name: 'extract_facts',
          arguments: {
            'deltas': '不是数组', // 类型错误
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.what, '事件');
      expect(result.factsDeltas, isEmpty);
    });

    test('27. LLM 调用 facts 但 deltas 为空数组 → factsDeltas 为空', () async {
      llmService.events = const [
        LlmToolCallStart('call_summary', 'extract_event_summary'),
        LlmToolCallStart('call_facts', 'extract_facts'),
        LlmToolCallComplete(
          toolCallId: 'call_summary',
          name: 'extract_event_summary',
          arguments: {
            'what': '事件',
            'importance': 3,
            'tags': <String>[],
          },
        ),
        LlmToolCallComplete(
          toolCallId: 'call_facts',
          name: 'extract_facts',
          arguments: {
            'deltas': <Map<String, dynamic>>[],
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.what, '事件');
      expect(result.factsDeltas, isEmpty);
    });

    test('28. LLM 调用 facts 但 deltas 中有非法 action → 解析失败返回空', () async {
      // FactsDelta.fromString 遇到未知 action 抛 ArgumentError
      // _parseFactsSafely 的 try-catch 捕获并返回空列表
      llmService.events = const [
        LlmToolCallStart('call_summary', 'extract_event_summary'),
        LlmToolCallStart('call_facts', 'extract_facts'),
        LlmToolCallComplete(
          toolCallId: 'call_summary',
          name: 'extract_event_summary',
          arguments: {
            'what': '事件',
            'importance': 3,
            'tags': <String>[],
          },
        ),
        LlmToolCallComplete(
          toolCallId: 'call_facts',
          name: 'extract_facts',
          arguments: {
            'deltas': [
              {
                'action': 'unknown_action', // 非法 action
                'confidence': 3,
              },
            ],
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.what, '事件');
      expect(result.factsDeltas, isEmpty);
    });

    test('29. 多个 FactsDelta 同时解析（create_entity + update_attr + append_list）',
        () async {
      llmService.events = const [
        LlmToolCallStart('call_summary', 'extract_event_summary'),
        LlmToolCallStart('call_facts', 'extract_facts'),
        LlmToolCallComplete(
          toolCallId: 'call_summary',
          name: 'extract_event_summary',
          arguments: {
            'what': '复杂事件',
            'importance': 4,
            'tags': ['多重变更'],
          },
        ),
        LlmToolCallComplete(
          toolCallId: 'call_facts',
          name: 'extract_facts',
          arguments: {
            'deltas': [
              {
                'action': 'create_entity',
                'entityType': 'character',
                'primaryName': '李逍遥',
                'confidence': 5,
              },
              {
                'action': 'update_attr',
                'entityId': 'ent_001',
                'attrKey': 'age',
                'value': '20',
                'reason': '剧情中明确提到年龄',
                'confidence': 4,
              },
              {
                'action': 'append_list',
                'entityId': 'ent_001',
                'attrKey': 'skills',
                'value': '万剑诀',
                'confidence': 4,
              },
            ],
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.what, '复杂事件');
      expect(result.factsDeltas, hasLength(3));
      expect(result.factsDeltas[0].action, FactAction.createEntity);
      expect(result.factsDeltas[1].action, FactAction.updateAttr);
      expect(result.factsDeltas[2].action, FactAction.appendList);
      expect(result.factsDeltas[1].reason, '剧情中明确提到年龄');
      expect(result.factsDeltas[2].value, '万剑诀');
    });

    test('30. 6 种 FactAction 全部解析成功', () async {
      // 覆盖所有 6 种 action 的 JSON 解析路径
      llmService.events = const [
        LlmToolCallStart('call_summary', 'extract_event_summary'),
        LlmToolCallStart('call_facts', 'extract_facts'),
        LlmToolCallComplete(
          toolCallId: 'call_summary',
          name: 'extract_event_summary',
          arguments: {
            'what': '事件',
            'importance': 3,
            'tags': <String>[],
          },
        ),
        LlmToolCallComplete(
          toolCallId: 'call_facts',
          name: 'extract_facts',
          arguments: {
            'deltas': [
              {
                'action': 'create_entity',
                'entityType': 'character',
                'primaryName': '李逍遥',
                'confidence': 5,
              },
              {
                'action': 'update_attr',
                'entityId': 'ent_001',
                'attrKey': 'age',
                'value': '20',
                'reason': '改名',
                'confidence': 4,
              },
              {
                'action': 'append_list',
                'entityId': 'ent_001',
                'attrKey': 'skills',
                'value': '御剑术',
                'confidence': 4,
              },
              {
                'action': 'remove_from_list',
                'entityId': 'ent_001',
                'attrKey': 'skills',
                'value': '旧技能',
                'reason': '遗忘',
                'confidence': 4,
              },
              {
                'action': 'add_alias',
                'entityId': 'ent_001',
                'value': '李少侠',
                'confidence': 5,
              },
              {
                'action': 'archive_entity',
                'entityId': 'ent_002',
                'reason': '角色死亡',
                'confidence': 5,
              },
            ],
          },
        ),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.factsDeltas, hasLength(6));
      expect(result.factsDeltas[0].action, FactAction.createEntity);
      expect(result.factsDeltas[1].action, FactAction.updateAttr);
      expect(result.factsDeltas[2].action, FactAction.appendList);
      expect(result.factsDeltas[3].action, FactAction.removeFromList);
      expect(result.factsDeltas[4].action, FactAction.addAlias);
      expect(result.factsDeltas[5].action, FactAction.archiveEntity);
    });

    group('修复 3 验证：extractFactsPrompt 注入', () {
      test(
          '31. _buildMessages 注入 extractSummaryPrompt + extractFactsPrompt 两段 system 消息',
          () async {
        final ctx = _makeCtx(replyText: '回复');
        llmService.events = const [
          LlmToolCallStart('call_1', 'extract_event_summary'),
          LlmToolCallComplete(
            toolCallId: 'call_1',
            name: 'extract_event_summary',
            arguments: {
              'what': '事件',
              'importance': 3,
              'tags': <String>[],
            },
          ),
          LlmStreamDone(),
        ];

        await handler.run(ctx: ctx, toolCallingEnabled: true);

        // 验证：第一次请求的 messages 含合并后的 1 段 system 消息
        // 2026-07-26 修订：原注入两段 system message（summary + facts 分开），
        // 但 LLM 倾向把第一段当主任务，第二段当附加项，配合 tool_choice=required
        // 导致只调用 extract_event_summary 跳过 extract_facts。现合并为一段，
        // 让两个工具处于同等地位。详见 DOC-11 §8.5。
        expect(llmService.requests, isNotEmpty);
        final firstRequest = llmService.requests.first;
        final systemMessages =
            firstRequest.messages.where((m) => m['role'] == 'system').toList();
        expect(systemMessages, hasLength(1));
        // 合并后的 system message 应同时包含 extractSummaryPrompt 和 extractFactsPrompt
        final mergedContent = systemMessages[0]['content'] as String;
        // 2026-07-25 修订：{{recent_timeline}} 占位符被替换为"（首轮，暂无历史时间线）"
        // （测试中未注入 factContextBuilder，sessionId 默认空，走"首轮"分支）
        expect(
          mergedContent,
          contains(
            ctx.config.prompts.extractSummaryPrompt.replaceAll(
              '{{recent_timeline}}',
              '（首轮，暂无历史时间线）',
            ),
          ),
        );
        // 2026-07-22 修复：{{known_entities}} 占位符被替换为"（暂无已知实体）"
        // （测试中未注入 factContextBuilder，sessionId 默认空，走"暂无"分支）
        expect(
          mergedContent,
          contains(
            ctx.config.prompts.extractFactsPrompt.replaceAll(
              '{{known_entities}}',
              '（暂无已知实体）',
            ),
          ),
        );
      });

      test('32. _buildToolCallRequest 注入两个工具定义（summary + facts）', () async {
        llmService.events = const [
          LlmToolCallStart('call_1', 'extract_event_summary'),
          LlmToolCallComplete(
            toolCallId: 'call_1',
            name: 'extract_event_summary',
            arguments: {
              'what': '事件',
              'importance': 3,
              'tags': <String>[],
            },
          ),
          LlmStreamDone(),
        ];

        await handler.run(
          ctx: _makeCtx(replyText: '回复'),
          toolCallingEnabled: true,
        );

        final firstRequest = llmService.requests.first;
        expect(firstRequest.tools, isNotNull);
        expect(firstRequest.tools, hasLength(2));
        expect(firstRequest.tools![0].name, 'extract_event_summary');
        expect(firstRequest.tools![1].name, 'extract_facts');
      });

      test('33. user 消息包含【用户消息】+【回复正文】双段内容', () async {
        final ctx = _makeCtx(replyText: '勇者来到火山口');
        llmService.events = const [
          LlmToolCallStart('call_1', 'extract_event_summary'),
          LlmToolCallComplete(
            toolCallId: 'call_1',
            name: 'extract_event_summary',
            arguments: {
              'what': '事件',
              'importance': 3,
              'tags': <String>[],
            },
          ),
          LlmStreamDone(),
        ];

        await handler.run(ctx: ctx, toolCallingEnabled: true);

        final firstRequest = llmService.requests.first;
        final userMessages =
            firstRequest.messages.where((m) => m['role'] == 'user').toList();
        expect(userMessages, hasLength(1));
        final content = userMessages[0]['content'] as String;
        expect(content, contains('【用户消息】'));
        expect(content, contains('用户输入'));
        expect(content, contains('【回复正文】'));
        expect(content, contains('勇者来到火山口'));
      });

      test(
          '34. toolCallingEnabled=false 时 messages 仍含 extractFactsPrompt（JSON 模式同样注入）',
          () async {
        final ctx = _makeCtx(replyText: '回复');
        llmService.events = const [
          LlmTextDelta('{"what":"事件","importance":3,"tags":[]}'),
          LlmStreamDone(),
        ];

        await handler.run(ctx: ctx, toolCallingEnabled: false);

        // JSON 模式与工具调用模式共用 _buildMessages，prompt 注入一致
        // 2026-07-26 修订：合并为 1 段 system message（详见 DOC-11 §8.5）
        expect(llmService.requests, isNotEmpty);
        final firstRequest = llmService.requests.first;
        final systemMessages =
            firstRequest.messages.where((m) => m['role'] == 'system').toList();
        expect(systemMessages, hasLength(1));
        // 合并后的 system message 应同时包含 extractFactsPrompt 内容
        // 2026-07-22 修复：{{known_entities}} 占位符被替换为"（暂无已知实体）"
        expect(
          systemMessages[0]['content'],
          contains(
            ctx.config.prompts.extractFactsPrompt.replaceAll(
              '{{known_entities}}',
              '（暂无已知实体）',
            ),
          ),
        );
      });
    });

    test('35. JSON 模式降级时不产出 factsDeltas（始终为空）', () async {
      // toolCallingEnabled=false 直接走 JSON 模式 → factsDeltas 为空
      // （事实层依赖工具调用，JSON 降级时本轮无事实变更）
      llmService.events = const [
        LlmTextDelta('{"what":"事件","importance":3,"tags":[]}'),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: false,
      );

      expect(result.summary.what, '事件');
      expect(result.factsDeltas, isEmpty);
    });

    test('36. 工具调用失败降级 JSON 模式后 factsDeltas 也为空', () async {
      // 工具调用完全失败（无任何工具调用 + fallbackText 解析失败）
      // → 降级 JSON 模式 → factsDeltas 不复用前次解析
      // 第一轮：fallbackText 为空 → 降级
      // 第二轮：JSON 模式成功，但 factsDeltas 应为空
      llmService.events = const [
        LlmStreamDone(), // 第一轮无输出
        LlmTextDelta('{"what":"事件","importance":3,"tags":[]}'),
        LlmStreamDone(),
      ];

      final result = await handler.run(
        ctx: _makeCtx(replyText: '回复'),
        toolCallingEnabled: true,
      );

      expect(result.summary.what, '事件');
      expect(result.factsDeltas, isEmpty);
    });
  });
}

/// 构造最小可用的 RoundContext（replyText 阶段产出已填充）
RoundContext _makeCtx({required String replyText, int turnNumber = 1}) {
  return RoundContext(
    userInput: '用户输入',
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
    turnNumber: turnNumber,
    connectTimeout: const Duration(seconds: 15),
    readTimeout: const Duration(seconds: 30),
  )..replyText = replyText;
}

/// 假 LlmService：按预设事件序列发出 LlmStreamEvent 流
///
/// 与 extract_phase_handler_test 中的 _FakeLlmService 一致：支持跨调用
/// 顺序消费（用 index 游标追踪当前位置），降级路径中可调用两次 streamChat。
///
/// **扩展**：捕获每次 streamChat 调用的 [LlmRequest] 到 [requests] 列表，
/// 供测试验证 prompt 注入、tools 注入、参数透传等（DOC-11 §4.4 双工具并行）。
class _FakeLlmService implements LlmService {
  _FakeLlmService(this.events);

  /// 事件序列（工具调用流和 JSON 模式流拼接在一起，按顺序消费）
  List<LlmStreamEvent> events;

  /// 捕获所有 streamChat 调用的请求（按调用顺序）
  ///
  /// 测试通过此列表验证：
  /// - messages 中是否注入了 extractSummaryPrompt + extractFactsPrompt
  /// - tools 是否包含 extract_event_summary + extract_facts 两个工具定义
  /// - reasoningEffort / timeout 等参数是否正确透传
  final List<LlmRequest> requests = <LlmRequest>[];

  int _cursor = 0;

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) {
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
    throw UnimplementedError('summarize handler 测试不使用 chat');
  }
}
